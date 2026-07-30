<#
.SYNOPSIS
    Reports (with --dry-run) and removes (without --dry-run) Azure role assignments that are
    held by user accounts blocked from signing in.

.DESCRIPTION
    Given a subscription name, this script lists every role assignment in the subscription that is
    held by a user principal, checks each user's sign-in status in Microsoft Entra ID
    (accountEnabled), and identifies assignments held by accounts that are blocked from signing in
    (accountEnabled = false).

    Blocked accounts that still carry role assignments are attractive targets for attackers looking
    to regain access unnoticed, and Microsoft Defender for Cloud recommends removing them.

    Run with --dry-run (-DryRun) to only report the orphaned assignments. Run without --dry-run to
    remove them. Removal is destructive, so it prompts for confirmation unless -Force is supplied.

.PARAMETER SubscriptionName
    Display name of the subscription to inspect.

.PARAMETER DryRun
    Report the offending role assignments without deleting anything. Equivalent to --dry-run.

.PARAMETER Force
    Skip the per-assignment confirmation prompt when performing removals.

.PARAMETER Tenant
    Optional. Entra tenant ID (or domain) that owns the subscription. When supplied, the script
    signs in to this tenant using an ISOLATED Azure CLI profile (a temporary AZURE_CONFIG_DIR) and
    tears it down on exit, so your existing default 'az login' (e.g. your corporate tenant) is left
    completely untouched. Use this when the target subscription lives in a different tenant than the
    one you are normally signed in to, otherwise user lookups resolve against the wrong directory.

.PARAMETER UseDeviceCode
    Optional. When performing the isolated -Tenant sign-in, authenticate with the device-code flow
    instead of launching a browser. Useful for cross-tenant / guest access and remote sessions.

.EXAMPLE
    pwsh Remove-AzBlockedUserRoleAssignment.ps1 -SubscriptionName 'Contoso Prod' -DryRun

.EXAMPLE
    pwsh Remove-AzBlockedUserRoleAssignment.ps1 -SubscriptionName 'Contoso Prod' -Force

.EXAMPLE
    # Scan a subscription in a different (lab) tenant without disturbing your default corp login.
    pwsh Remove-AzBlockedUserRoleAssignment.ps1 -SubscriptionName 'mikeo-ai-sub' -Tenant d52a6857-5f44-4f8f-bcc8-420952d3225d -UseDeviceCode -DryRun
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionName,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [string]$Tenant,

    [Parameter()]
    [switch]$UseDeviceCode,

    [Parameter()]
    [switch]$ShowAll,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Honor GNU-style --dry-run in addition to the PowerShell -DryRun switch.
if ($RemainingArgs -and ($RemainingArgs -contains '--dry-run')) {
    $DryRun = [switch]$true
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $commandText = "az $($Arguments -join ' ')"
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: $commandText`n$($output | Out-String)"
    }

    $jsonText = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        return $null
    }

    return $jsonText | ConvertFrom-Json -Depth 100
}

function Write-Status {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ConsoleColor]$Color = [ConsoleColor]::White
    )

    Write-Host $Message -ForegroundColor $Color
}

function Format-Scope {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Scope
    )

    if ([string]::IsNullOrWhiteSpace($Scope)) {
        return '(unknown scope)'
    }

    $segments = $Scope.Trim('/') -split '/'

    # Subscription root: /subscriptions/{id}
    if ($segments.Count -eq 2 -and $segments[0] -eq 'subscriptions') {
        return "Subscription: $($segments[1])"
    }

    # Resource group: /subscriptions/{id}/resourceGroups/{rg}
    if ($segments.Count -eq 4 -and $segments[2] -eq 'resourceGroups') {
        return "Resource group: $($segments[3])"
    }

    # Resource: .../providers/{ns}/{type}/{name}[/{subtype}/{subname}...]
    $providerIndex = [array]::LastIndexOf($segments, 'providers')
    if ($providerIndex -ge 0 -and ($segments.Count - $providerIndex) -ge 4) {
        $resourceType = $segments[$providerIndex + 2]
        $resourceName = $segments[-1]
        $rg = ''
        if ($segments.Count -ge 4 -and $segments[2] -eq 'resourceGroups') {
            $rg = " (rg: $($segments[3]))"
        }
        return "$($resourceType): $resourceName$rg"
    }

    return $Scope
}

function Get-TenantDisplayName {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$TenantId
    )

    # Prefer the value already on the account object; otherwise query Microsoft Graph (best-effort).
    try {
        $org = Invoke-AzJson -Arguments @(
            'rest', '--method', 'GET',
            '--url', 'https://graph.microsoft.com/v1.0/organization?$select=id,displayName',
            '--output', 'json',
            '--only-show-errors'
        )
        if ($null -ne $org -and $org.value) {
            $match = @($org.value | Where-Object { [string]$_.id -eq $TenantId })
            if ($match.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$match[0].displayName)) {
                return [string]$match[0].displayName
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$org.value[0].displayName)) {
                return [string]$org.value[0].displayName
            }
        }
    }
    catch {
        # Directory read may be unavailable; fall back to just the ID.
    }

    return ''
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required but was not found in PATH.'
}

# When a tenant is specified, sign in using an isolated Azure CLI profile so the caller's default
# 'az login' is never modified. AZURE_CONFIG_DIR gives az a private token cache/profile for the
# lifetime of this script; the finally block deletes it, leaving the default profile untouched.
$isolatedConfigDir = $null
$previousAzureConfigDir = $env:AZURE_CONFIG_DIR

try {
    if (-not [string]::IsNullOrWhiteSpace($Tenant)) {
        $isolatedConfigDir = Join-Path ([System.IO.Path]::GetTempPath()) ("az-identity-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $isolatedConfigDir -Force | Out-Null
        $env:AZURE_CONFIG_DIR = $isolatedConfigDir

        Write-Status "Using an isolated Azure CLI profile; your default 'az login' will not change." Cyan
        Write-Status "Signing in to tenant '$Tenant'$(if ($UseDeviceCode) { ' via device code' } else { ' via browser' })..." Yellow

        $loginArgs = @('login', '--tenant', $Tenant, '--output', 'none', '--only-show-errors')
        if ($UseDeviceCode) {
            $loginArgs += '--use-device-code'
        }

        # Call az directly (not through Invoke-AzJson) so the device-code prompt streams to the console.
        & az @loginArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI sign-in to tenant '$Tenant' failed."
        }

        Write-Status "Signed in to tenant '$Tenant' in an isolated session." Green
        Write-Host ''
    }

    # Resolve the subscription name to an ID.
$subscription = Invoke-AzJson -Arguments @(
    'account', 'show',
    '--subscription', $SubscriptionName,
    '--output', 'json',
    '--only-show-errors'
)

if ($null -eq $subscription -or [string]::IsNullOrWhiteSpace([string]$subscription.id)) {
    throw "Unable to resolve subscription '$SubscriptionName'. Confirm the name and that you have access."
}

$subscriptionId = [string]$subscription.id
$resolvedName = [string]$subscription.name
$subscriptionScope = "/subscriptions/$subscriptionId"

$tenantId = [string]$subscription.tenantId
$tenantName = Get-TenantDisplayName -TenantId $tenantId
$tenantLabel = if ([string]::IsNullOrWhiteSpace($tenantName)) { $tenantId } else { "$tenantName ($tenantId)" }

$mode = if ($DryRun) { 'DRY-RUN (report only)' } else { 'REMOVE' }
Write-Status "Tenant       : $tenantLabel" Green
Write-Status "Subscription : $resolvedName ($subscriptionId)" Green
Write-Status "Mode         : $mode" $(if ($DryRun) { [ConsoleColor]::Cyan } else { [ConsoleColor]::Yellow })
Write-Host ''

# List every role assignment in the subscription that is held by a user principal.
$assignments = @(
    Invoke-AzJson -Arguments @(
        'role', 'assignment', 'list',
        '--subscription', $subscriptionId,
        '--all',
        '--query', "[?principalType=='User']",
        '--output', 'json',
        '--only-show-errors'
    )
)

if ($assignments.Count -eq 0) {
    Write-Status 'No user role assignments were found in this subscription.' Green
    return
}

Write-Status "Evaluating $($assignments.Count) user role assignment(s) for blocked sign-in status..." Green

# Cache accountEnabled lookups so each unique principal is queried only once.
$signInStatusCache = @{}

function Get-UserSignInStatus {
    param(
        [Parameter(Mandatory)]
        [string]$PrincipalId
    )

    if ($signInStatusCache.ContainsKey($PrincipalId)) {
        return $signInStatusCache[$PrincipalId]
    }

    $status = [pscustomobject]@{
        AccountEnabled    = $null
        DisplayName       = ''
        UserPrincipalName = ''
        Error             = ''
    }

    try {
        $user = Invoke-AzJson -Arguments @(
            'ad', 'user', 'show',
            '--id', $PrincipalId,
            '--query', '{accountEnabled:accountEnabled, displayName:displayName, userPrincipalName:userPrincipalName}',
            '--output', 'json',
            '--only-show-errors'
        )

        if ($null -ne $user) {
            $status.AccountEnabled = $user.accountEnabled
            $status.DisplayName = [string]$user.displayName
            $status.UserPrincipalName = [string]$user.userPrincipalName
        }
    }
    catch {
        # A missing user is typically a deleted account (a separate recommendation), not a blocked one.
        $status.Error = $_.Exception.Message
    }

    $signInStatusCache[$PrincipalId] = $status
    return $status
}

$blocked = New-Object System.Collections.Generic.List[object]
$lookupErrors = New-Object System.Collections.Generic.List[object]
$evaluated = New-Object System.Collections.Generic.List[object]

foreach ($assignment in $assignments) {
    $principalId = [string]$assignment.principalId
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        continue
    }

    $status = Get-UserSignInStatus -PrincipalId $principalId

    if (-not [string]::IsNullOrWhiteSpace($status.Error)) {
        $lookupErrors.Add([pscustomobject]@{
                PrincipalId   = $principalId
                PrincipalName = [string]$assignment.principalName
                Role          = [string]$assignment.roleDefinitionName
                Scope         = [string]$assignment.scope
                Resource      = Format-Scope -Scope ([string]$assignment.scope)
            })
        $evaluated.Add([pscustomobject]@{
                Status = 'Unresolved'
                User   = [string]$assignment.principalName
                Role   = [string]$assignment.roleDefinitionName
                Resource = Format-Scope -Scope ([string]$assignment.scope)
            })
        continue
    }

    $signInState = if ($status.AccountEnabled -eq $false) { 'Blocked' } elseif ($status.AccountEnabled -eq $true) { 'Enabled' } else { 'Unknown' }
    $evalUser = if (-not [string]::IsNullOrWhiteSpace($status.UserPrincipalName)) { $status.UserPrincipalName } elseif (-not [string]::IsNullOrWhiteSpace($status.DisplayName)) { $status.DisplayName } else { [string]$assignment.principalName }
    $evaluated.Add([pscustomobject]@{
            Status   = $signInState
            User     = $evalUser
            Role     = [string]$assignment.roleDefinitionName
            Resource = Format-Scope -Scope ([string]$assignment.scope)
        })

    if ($status.AccountEnabled -eq $false) {
        $displayName = if (-not [string]::IsNullOrWhiteSpace($status.DisplayName)) { $status.DisplayName } else { [string]$assignment.principalName }
        $upn = if (-not [string]::IsNullOrWhiteSpace($status.UserPrincipalName)) { $status.UserPrincipalName } else { [string]$assignment.principalName }

        $blocked.Add([pscustomobject]@{
                RoleAssignmentId  = [string]$assignment.id
                Role              = [string]$assignment.roleDefinitionName
                DisplayName       = $displayName
                UserPrincipalName = $upn
                PrincipalId       = $principalId
                Scope             = [string]$assignment.scope
                Resource          = Format-Scope -Scope ([string]$assignment.scope)
            })
    }
}

Write-Host ''

if ($ShowAll) {
    Write-Status 'All evaluated user role assignments (diagnostic):' Cyan
    $enabledCount = @($evaluated | Where-Object { $_.Status -eq 'Enabled' }).Count
    $blockedCount = @($evaluated | Where-Object { $_.Status -eq 'Blocked' }).Count
    $unknownCount = @($evaluated | Where-Object { $_.Status -eq 'Unknown' }).Count
    $unresolvedCount = @($evaluated | Where-Object { $_.Status -eq 'Unresolved' }).Count
    Write-Status "  Enabled: $enabledCount  Blocked: $blockedCount  Unknown: $unknownCount  Unresolved: $unresolvedCount" Cyan
    Write-Host ''
    $evaluated |
        Sort-Object Status, User, Role |
        Format-Table Status, User, Role, Resource -AutoSize |
        Out-String |
        Write-Host
}

if ($blocked.Count -eq 0) {
    Write-Status 'No role assignments held by blocked (sign-in disabled) users were found.' Green
}
else {
    Write-Status "Found $($blocked.Count) role assignment(s) held by blocked users:" Yellow
    Write-Host ''
    $blocked |
        Select-Object DisplayName, UserPrincipalName, Role, Resource, Scope |
        Format-Table -AutoSize |
        Out-String |
        Write-Host
}

$removed = 0
$removalErrors = New-Object System.Collections.Generic.List[object]

if (-not $DryRun -and $blocked.Count -gt 0) {
    Write-Status 'Removing role assignments for blocked users...' Yellow

    foreach ($item in $blocked) {
        $target = "role '$($item.Role)' held by blocked user '$($item.UserPrincipalName)' at scope '$($item.Scope)'"

        if ($Force -or $PSCmdlet.ShouldProcess($target, 'Remove role assignment')) {
            try {
                Invoke-AzJson -Arguments @(
                    'role', 'assignment', 'delete',
                    '--ids', $item.RoleAssignmentId,
                    '--output', 'json',
                    '--only-show-errors'
                ) | Out-Null

                $removed++
                Write-Status "Removed $target." Green
            }
            catch {
                $removalErrors.Add([pscustomobject]@{
                        RoleAssignmentId = $item.RoleAssignmentId
                        Error            = $_.Exception.Message
                    })
                Write-Status "Failed to remove $target : $($_.Exception.Message)" Red
            }
        }
    }
}

Write-Host ''
Write-Status 'Summary' Green
Write-Status "  Tenant                   : $tenantLabel" Green
Write-Status "  Subscription             : $resolvedName ($subscriptionId)" Green
Write-Status "  User role assignments    : $($assignments.Count)" Green
Write-Status "  Blocked-user assignments : $($blocked.Count)" $(if ($blocked.Count -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green })

if ($DryRun) {
    Write-Status '  Action                   : none (dry-run). Re-run without --dry-run to remove.' Cyan
}
else {
    Write-Status "  Assignments removed      : $removed" Green
    if ($removalErrors.Count -gt 0) {
        Write-Status "  Removal errors           : $($removalErrors.Count)" Red
    }
}

if ($lookupErrors.Count -gt 0) {
    $uniquePrincipals = @($lookupErrors | Select-Object -ExpandProperty PrincipalId -Unique)
    Write-Host ''
    Write-Status "Warning: $($lookupErrors.Count) assignment(s) across $($uniquePrincipals.Count) unique principal(s) could not be evaluated." Yellow
    Write-Status 'This usually means the principals are deleted accounts, or the signed-in identity lacks' Yellow
    Write-Status 'Microsoft Graph directory-read permission (Directory Readers). These were left untouched:' Yellow
    Write-Host ''
    foreach ($group in ($lookupErrors | Group-Object PrincipalId)) {
        $principalName = @($group.Group | ForEach-Object { $_.PrincipalName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        $label = if ($principalName) { $principalName } else { '(name unresolved)' }
        Write-Status " Principal: $label [$($group.Name)]" Yellow
        foreach ($item in $group.Group) {
            Write-Status "   - Role '$($item.Role)' on $($item.Resource)" Yellow
        }
    }
}

    if ($removalErrors.Count -gt 0) {
        exit 1
    }
}
finally {
    if ($isolatedConfigDir) {
        # Discard the isolated session: best-effort logout, restore AZURE_CONFIG_DIR, delete temp profile.
        try { & az logout --only-show-errors 2>&1 | Out-Null } catch { }

        if ($null -eq $previousAzureConfigDir) {
            Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:AZURE_CONFIG_DIR = $previousAzureConfigDir
        }

        Remove-Item -LiteralPath $isolatedConfigDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Status 'Isolated Azure CLI session cleaned up; your default login is unchanged.' Cyan
    }
}
