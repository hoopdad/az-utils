[CmdletBinding()]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$SubscriptionFile,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$UsersFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Invoke-AzText {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $commandText = "az $($Arguments -join ' ')"
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: $commandText`n$($output | Out-String)"
    }

    return (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
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

function Get-NonCommentLines {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return @(
        Get-Content -LiteralPath $Path |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    )
}

function Get-SubscriptionTargets {
    param(
        [string]$RequestedSubscriptionId,
        [string]$RequestedSubscriptionFile
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedSubscriptionId) -and -not [string]::IsNullOrWhiteSpace($RequestedSubscriptionFile)) {
        throw 'Specify only one of -SubscriptionId or -SubscriptionFile.'
    }

    $targets = New-Object System.Collections.Generic.List[object]

    if (-not [string]::IsNullOrWhiteSpace($RequestedSubscriptionFile)) {
        $lines = Get-NonCommentLines -Path $RequestedSubscriptionFile
        foreach ($line in $lines) {
            $parts = $line -split ',', 2
            $id = ($parts[0].Trim() -replace '#.*', '').Trim()
            if ([string]::IsNullOrWhiteSpace($id)) {
                continue
            }

            $displayName = if ($parts.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($parts[1])) { ($parts[1].Trim() -replace '#.*', '').Trim() } else { '' }
            $targets.Add([pscustomobject]@{
                    SubscriptionId = $id
                    DisplayName    = $displayName
                })
        }

        if ($targets.Count -eq 0) {
            throw "No valid subscription IDs found in '$RequestedSubscriptionFile'."
        }

        return @($targets.ToArray())
    }

    $accountArgs = @('account', 'show', '--output', 'json', '--only-show-errors')
    if (-not [string]::IsNullOrWhiteSpace($RequestedSubscriptionId)) {
        $accountArgs += @('--subscription', $RequestedSubscriptionId)
    }

    $account = Invoke-AzJson -Arguments $accountArgs
    if ($null -eq $account -or [string]::IsNullOrWhiteSpace([string]$account.id)) {
        throw 'Unable to resolve the Azure subscription to onboard.'
    }

    $targets.Add([pscustomobject]@{
            SubscriptionId = [string]$account.id
            DisplayName    = [string]$account.name
        })

    return @($targets.ToArray())
}

function Get-UserEmails {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $emails = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-NonCommentLines -Path $Path)) {
        $email = ($line -replace '#.*', '').Trim()
        if ([string]::IsNullOrWhiteSpace($email)) {
            continue
        }

        $emails.Add($email)
    }

    return @($emails | Select-Object -Unique)
}

function Resolve-UserObjectIds {
    param(
        [Parameter(Mandatory)]
        [string[]]$Emails,

        [Parameter(Mandatory)]
        [System.Collections.Generic.List[string]]$Errors
    )

    $resolvedUsers = New-Object System.Collections.Generic.List[object]

    foreach ($email in $Emails) {
        try {
            $objectId = Invoke-AzText -Arguments @('ad', 'user', 'show', '--id', $email, '--query', 'id', '--output', 'tsv', '--only-show-errors')
            if ([string]::IsNullOrWhiteSpace($objectId)) {
                Write-Warning "User '$email' was not found. Skipping."
                $Errors.Add("User not found: $email")
                continue
            }

            $resolvedUsers.Add([pscustomobject]@{
                    Email    = $email
                    ObjectId = $objectId
                })
            Write-Status "Resolved user '$email' to object ID '$objectId'." Green
        }
        catch {
            Write-Warning "Unable to resolve user '$email'. Skipping. $($_.Exception.Message)"
            $Errors.Add("Failed to resolve user '$email': $($_.Exception.Message)")
        }
    }

    return @($resolvedUsers.ToArray())
}

function Wait-ManagedServicesProviderRegistration {
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionIdToCheck
    )

    $maxAttempts = 20
    $delaySeconds = 15

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $provider = Invoke-AzJson -Arguments @('provider', 'show', '--namespace', 'Microsoft.ManagedServices', '--subscription', $SubscriptionIdToCheck, '--output', 'json', '--only-show-errors')
        $state = [string]$provider.registrationState
        if ($state -eq 'Registered') {
            return
        }

        if ($attempt -lt $maxAttempts) {
            Write-Status "Waiting for Microsoft.ManagedServices registration on subscription '$SubscriptionIdToCheck' (current state: $state)..." Yellow
            Start-Sleep -Seconds $delaySeconds
        }
    }

    throw "Microsoft.ManagedServices provider registration did not reach 'Registered' for subscription '$SubscriptionIdToCheck'."
}

function Test-IsAlreadyExistsError {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    return $Message -match 'already exists'
}

$roleDefinitions = @(
    @{ Id = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'; Name = 'Reader' }
)
$scriptErrors = New-Object System.Collections.Generic.List[string]
$subscriptionErrors = New-Object System.Collections.Generic.List[string]
$subscriptionsProcessed = 0
$subscriptionsSucceeded = 0
$subscriptionsFailed = 0
$roleAssignmentsCreated = 0
$roleAssignmentsSkipped = 0
$roleAssignmentErrors = 0

$subscriptionTargets = Get-SubscriptionTargets -RequestedSubscriptionId $SubscriptionId -RequestedSubscriptionFile $SubscriptionFile
$userEmails = Get-UserEmails -Path $UsersFile
if (@($userEmails).Count -eq 0) {
    throw "No valid user email addresses found in '$UsersFile'."
}

Write-Status "Loaded $(@($userEmails).Count) user email(s) from '$UsersFile'." Green
$resolvedUsers = Resolve-UserObjectIds -Emails $userEmails -Errors $scriptErrors
if (@($resolvedUsers).Count -eq 0) {
    throw 'No user object IDs could be resolved. Aborting.'
}

Write-Status "Resolved $(@($resolvedUsers).Count) user(s) for onboarding." Green
Write-Status "Processing $(@($subscriptionTargets).Count) subscription(s)." Green

foreach ($subscriptionTarget in $subscriptionTargets) {
    $subscriptionsProcessed++
    $targetSubscriptionId = [string]$subscriptionTarget.SubscriptionId
    $targetDisplayName = [string]$subscriptionTarget.DisplayName
    $targetLabel = if ([string]::IsNullOrWhiteSpace($targetDisplayName)) { $targetSubscriptionId } else { "$targetDisplayName ($targetSubscriptionId)" }

    Write-Status "Starting Azure Lighthouse onboarding for $targetLabel..." Green

    try {
        Invoke-AzText -Arguments @('account', 'set', '--subscription', $targetSubscriptionId, '--only-show-errors') | Out-Null
        Write-Status "Set Azure CLI context to subscription '$targetSubscriptionId'." Green

        $registration = Invoke-AzJson -Arguments @('provider', 'register', '--namespace', 'Microsoft.ManagedServices', '--subscription', $targetSubscriptionId, '--output', 'json', '--only-show-errors')
        $registrationState = if ($null -eq $registration) { '' } else { [string]$registration.registrationState }
        if (-not [string]::IsNullOrWhiteSpace($registrationState)) {
            Write-Status "Microsoft.ManagedServices registration state for '$targetSubscriptionId': $registrationState" Yellow
        }

        Wait-ManagedServicesProviderRegistration -SubscriptionIdToCheck $targetSubscriptionId
        Write-Status "Microsoft.ManagedServices is registered for '$targetSubscriptionId'." Green

        $subscriptionScope = "/subscriptions/$targetSubscriptionId"
        foreach ($resolvedUser in $resolvedUsers) {
            foreach ($roleDef in $roleDefinitions) {
                $roleId = $roleDef.Id
                $roleName = $roleDef.Name
                try {
                    Invoke-AzJson -Arguments @(
                        'role', 'assignment', 'create',
                        '--assignee-object-id', [string]$resolvedUser.ObjectId,
                        '--assignee-principal-type', 'User',
                        '--role', $roleId,
                        '--scope', $subscriptionScope,
                        '--output', 'json',
                        '--only-show-errors'
                    ) | Out-Null

                    $roleAssignmentsCreated++
                    Write-Status "Assigned '$roleName' to '$($resolvedUser.Email)' on '$targetSubscriptionId'." Green
                }
                catch {
                    $errorMessage = $_.Exception.Message
                    if (Test-IsAlreadyExistsError -Message $errorMessage) {
                        $roleAssignmentsSkipped++
                        Write-Status "'$roleName' is already assigned to '$($resolvedUser.Email)' on '$targetSubscriptionId'. Skipping." Yellow
                        continue
                    }

                    $roleAssignmentErrors++
                    $assignmentError = "Subscription '$targetSubscriptionId', user '$($resolvedUser.Email)', role '$roleName': $errorMessage"
                    $scriptErrors.Add($assignmentError)
                    Write-Status $assignmentError Red
                }
            }
        }

        $subscriptionsSucceeded++
        Write-Status "Completed Azure Lighthouse onboarding for $targetLabel." Green
    }
    catch {
        $subscriptionsFailed++
        $message = "Subscription '$targetLabel' failed: $($_.Exception.Message)"
        $subscriptionErrors.Add($message)
        $scriptErrors.Add($message)
        Write-Status $message Red
    }
}

Write-Host ''
Write-Status 'Azure Lighthouse onboarding summary' Green
Write-Status "Subscriptions processed: $subscriptionsProcessed" Green
Write-Status "Subscriptions succeeded: $subscriptionsSucceeded" Green
Write-Status "Subscriptions failed: $subscriptionsFailed" $(if ($subscriptionsFailed -gt 0) { [ConsoleColor]::Red } else { [ConsoleColor]::Green })
Write-Status "Role assignments created: $roleAssignmentsCreated" Green
Write-Status "Role assignments skipped: $roleAssignmentsSkipped" Yellow
Write-Status "Role assignment errors: $roleAssignmentErrors" $(if ($roleAssignmentErrors -gt 0) { [ConsoleColor]::Red } else { [ConsoleColor]::Green })
Write-Status "Total errors tracked: $($scriptErrors.Count)" $(if ($scriptErrors.Count -gt 0) { [ConsoleColor]::Red } else { [ConsoleColor]::Green })

if ($subscriptionErrors.Count -gt 0) {
    Write-Status 'Subscription errors:' Red
    foreach ($errorItem in $subscriptionErrors) {
        Write-Status " - $errorItem" Red
    }
}

if ($scriptErrors.Count -gt 0) {
    Write-Status 'Additional warnings/errors:' Red
    foreach ($errorItem in $scriptErrors) {
        Write-Status " - $errorItem" Red
    }
}
