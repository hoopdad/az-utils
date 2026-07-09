<#
.NOTICE
Sample code only. This script is provided "as is" without warranties or
guarantees of completeness, accuracy, availability, or fitness for a
particular environment. Azure inventory, tags, API versions, RBAC permissions,
service support, and Azure CLI behavior can vary. The customer must
review, test, and validate all output in their own Azure environment before
relying on it for operational, capacity, financial, compliance, or remediation
decisions.

.SYNOPSIS
Exports Azure resource inventory to CSV.

.DESCRIPTION
Uses Azure CLI to enumerate resources from one subscription, a list of subscriptions,
or every subscription visible to the signed-in account. The CSV includes resource
metadata, raw Azure resource type, portal-style resource type, and tags.

The script assumes you are already signed in to the intended Azure tenant. If you
provide -Tenant, subscription discovery is filtered to subscriptions whose Azure CLI
account record has that tenantId or homeTenantId.

.PARAMETER All
Export resources from all visible subscriptions. Cannot be combined with -Subscription
or -SubscriptionFile.

.PARAMETER Subscription
Subscription name or id to export. Repeat this parameter for multiple subscriptions.

.PARAMETER SubscriptionFile
Path to a text file containing subscription names or ids, one per line. Blank lines
and lines beginning with # are ignored.

.PARAMETER Tenant
Optional tenant id used to filter visible Azure CLI subscriptions before subscription
selection is applied.

.PARAMETER OutputPath
CSV output path. Parent directories are created if needed.

.EXAMPLE
.\Document-AzureResources.ps1 -All -OutputPath .\azure-resources.csv

.EXAMPLE
.\Document-AzureResources.ps1 -OutputPath .\azure-resources.csv -Subscription "00000000-0000-0000-0000-000000000000"

.EXAMPLE
.\Document-AzureResources.ps1 -Subscription "Sub A" -Subscription "Sub B" -OutputPath .\azure-resources.csv

.EXAMPLE
.\Document-AzureResources.ps1 -SubscriptionFile .\subscriptions.txt -OutputPath .\azure-resources.csv

.EXAMPLE
.\Document-AzureResources.ps1 -All -OutputPath .\azure-resources.csv -Tenant "00000000-0000-0000-0000-000000000000"

.NOTES
Preflight checks verify Azure CLI is installed, the session is signed in, and the
output directory can be created.
#>
[CmdletBinding()]
param(
    [Alias('a')]
    [switch]$All,

    [Alias('s')]
    [string[]]$Subscription = @(),

    [Alias('f')]
    [string]$SubscriptionFile,

    [Alias('t')]
    [string]$Tenant,

    [Alias('o')]
    [string]$OutputPath = ".\azure-resources.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "[INFO] $Message"
}

function Assert-AzCliInstalled {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI 'az' was not found on PATH."
    }
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Operation
    )

    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $output = & az @Arguments 2> $stderrPath
        $exitCode = $LASTEXITCODE
        $stderrRaw = Get-Content -Raw -LiteralPath $stderrPath
        $stderr = if ($null -eq $stderrRaw) { '' } else { $stderrRaw.Trim() }

        if ($exitCode -ne 0) {
            $detail = if ($stderr) { $stderr } else { 'Azure CLI returned no error details.' }
            throw "$Operation failed. Command: az $($Arguments -join ' '). Exit code: $exitCode.`n$detail"
        }

        if ($stderr) {
            Write-Warning $stderr
        }

        return ($output | Out-String)
    } finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AzCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Operation
    )

    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        & az @Arguments 2> $stderrPath | Out-Null
        $exitCode = $LASTEXITCODE
        $stderrRaw = Get-Content -Raw -LiteralPath $stderrPath
        $stderr = if ($null -eq $stderrRaw) { '' } else { $stderrRaw.Trim() }

        if ($exitCode -ne 0) {
            $detail = if ($stderr) { $stderr } else { 'Azure CLI returned no error details.' }
            throw "$Operation failed. Command: az $($Arguments -join ' '). Exit code: $exitCode.`n$detail"
        }

        if ($stderr) {
            Write-Warning $stderr
        }
    } finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Assert-AzCliSignedIn {
    Invoke-AzJson -Arguments @('account', 'show', '-o', 'json') -Operation 'Azure CLI sign-in check' | Out-Null
}

function Assert-OutputPathReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $outputParent = Split-Path -Path $Path -Parent
    if ($outputParent -and -not (Test-Path -LiteralPath $outputParent)) {
        New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
    }

    $targetDirectory = if ($outputParent) { $outputParent } else { (Get-Location).Path }
    $testPath = Join-Path -Path $targetDirectory -ChildPath ".inventory-write-test-$([Guid]::NewGuid()).tmp"
    try {
        Set-Content -LiteralPath $testPath -Value 'test' -Encoding UTF8
    } finally {
        Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PreflightChecks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Write-Status 'Running preflight checks.'
    Assert-AzCliInstalled
    Assert-AzCliSignedIn
    Assert-OutputPathReady -Path $Path
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Read-SubscriptionSelectorsFromFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Subscription file was not found: $Path"
    }

    return @(
        Get-Content -LiteralPath $Path |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    )
}

function Resolve-SubscriptionSelector {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Selector,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Accounts
    )

    $idMatches = @($Accounts | Where-Object { $_.id -ieq $Selector })
    if ($idMatches.Count -eq 1) {
        return $idMatches[0]
    }

    $nameMatches = @($Accounts | Where-Object { $_.name -ieq $Selector })
    if ($nameMatches.Count -eq 1) {
        return $nameMatches[0]
    }

    if ($nameMatches.Count -gt 1) {
        throw "Subscription name '$Selector' matched multiple subscriptions. Use a subscription id instead."
    }

    throw "No subscription found with name or id '$Selector'."
}

function Convert-TagsToString {
    param(
        [AllowNull()]
        [object]$Tags
    )

    if ($null -eq $Tags) {
        return ''
    }

    $pairs = @(
        $Tags.PSObject.Properties |
            Sort-Object Name |
            ForEach-Object {
                $value = if ($null -eq $_.Value) { '' } else { [string]$_.Value }
                "$($_.Name)=$value"
            }
    )

    return ($pairs -join ', ')
}

function Convert-ZonesToString {
    param(
        [AllowNull()]
        [object]$Zones
    )

    if ($null -eq $Zones) {
        return ''
    }

    return (@($Zones) | Where-Object { $null -ne $_ -and $_ -ne '' }) -join ','
}

function Convert-TokenToTitle {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $words = $Value -creplace '([a-z0-9])([A-Z])', '$1 $2'
    $words = $words -replace '[_-]+', ' '
    return (Get-Culture).TextInfo.ToTitleCase($words.ToLowerInvariant())
}

function Convert-ResourceTypeToPortalType {
    param(
        [AllowNull()]
        [string]$ResourceType
    )

    if ([string]::IsNullOrWhiteSpace($ResourceType)) {
        return ''
    }

    $portalTypeNames = @{
        'microsoft.app/containerapps' = 'Container App'
        'microsoft.app/managedenvironments' = 'Container Apps Environment'
        'microsoft.authorization/roleassignments' = 'Role Assignment'
        'microsoft.cognitiveservices/accounts' = 'Azure AI Services'
        'microsoft.cognitiveservices/accounts/projects' = 'Azure AI Foundry Project'
        'microsoft.compute/disks' = 'Disk'
        'microsoft.compute/snapshots' = 'Snapshot'
        'microsoft.compute/virtualmachines' = 'Virtual Machine'
        'microsoft.containerregistry/registries' = 'Container Registry'
        'microsoft.documentdb/databaseaccounts' = 'Azure Cosmos DB Account'
        'microsoft.eventgrid/systemtopics' = 'Event Grid System Topic'
        'microsoft.insights/actiongroups' = 'Action Group'
        'microsoft.keyvault/vaults' = 'Key Vault'
        'microsoft.managedidentity/userassignedidentities' = 'Managed Identity'
        'microsoft.network/loadbalancers' = 'Load Balancer'
        'microsoft.network/networkinterfaces' = 'Network Interface'
        'microsoft.network/networksecuritygroups' = 'Network Security Group'
        'microsoft.network/networkwatchers' = 'Network Watcher'
        'microsoft.network/privateendpoints' = 'Private Endpoint'
        'microsoft.network/publicipaddresses' = 'Public IP Address'
        'microsoft.network/routetables' = 'Route Table'
        'microsoft.network/virtualnetworks' = 'Virtual Network'
        'microsoft.operationalinsights/workspaces' = 'Log Analytics Workspace'
        'microsoft.storage/storageaccounts' = 'Storage Account'
        'microsoft.web/serverfarms' = 'App Service Plan'
        'microsoft.web/sites' = 'App Service'
    }

    $normalizedType = $ResourceType.Trim().ToLowerInvariant()
    if ($portalTypeNames.ContainsKey($normalizedType)) {
        return $portalTypeNames[$normalizedType]
    }

    $leafType = ($ResourceType -split '/')[-1]
    return Convert-TokenToTitle -Value $leafType
}

function Invoke-AzureResourceInventoryExport {
Invoke-PreflightChecks -Path $OutputPath

if ($All -and (($Subscription.Count -gt 0) -or $SubscriptionFile)) {
    throw "Use either -All or subscription selectors, not both."
}

$accounts = @(Invoke-AzJson -Arguments @('account', 'list', '--all', '-o', 'json') -Operation 'List Azure subscriptions' | ConvertFrom-Json)
if ($accounts.Count -eq 0) {
    throw "Azure CLI returned no subscriptions. Confirm you are signed in with 'az login'."
}

if ($Tenant) {
    $accounts = @(
        $accounts | Where-Object {
            $tenantId = Get-PropertyValue -Object $_ -Name 'tenantId'
            $homeTenantId = Get-PropertyValue -Object $_ -Name 'homeTenantId'
            $tenantId -ieq $Tenant -or $homeTenantId -ieq $Tenant
        }
    )

    if ($accounts.Count -eq 0) {
        throw "Azure CLI returned no subscriptions for tenant '$Tenant'. Use the tenant id shown by 'az account list', or sign in with 'az login --tenant $Tenant'."
    }
}

$selectors = @($Subscription)
if ($SubscriptionFile) {
    $selectors += Read-SubscriptionSelectorsFromFile -Path $SubscriptionFile
}

if (-not $All -and $selectors.Count -eq 0) {
    while ($true) {
        $choice = (Read-Host "No subscription selector supplied. Enter A for all subscriptions or O for one subscription").Trim()
        if ($choice -match '^(?i:a|all)$') {
            $All = $true
            break
        }

        if ($choice -match '^(?i:o|one|1)$') {
            $selector = (Read-Host "Enter the subscription name or id").Trim()
            if (-not $selector) {
                Write-Host "Subscription name or id cannot be empty."
                continue
            }

            $selectors += $selector
            break
        }

        Write-Host "Enter A/all or O/one."
    }
}

if ($All) {
    $selectedSubscriptions = @($accounts)
} else {
    $selectedSubscriptions = @(
        foreach ($selector in $selectors) {
            Resolve-SubscriptionSelector -Selector $selector -Accounts $accounts
        }
    )
}

$subscriptionsById = [ordered]@{}
foreach ($selectedSubscription in $selectedSubscriptions) {
    if (-not $subscriptionsById.Contains($selectedSubscription.id)) {
        $subscriptionsById[$selectedSubscription.id] = $selectedSubscription
    }
}
$selectedSubscriptions = @($subscriptionsById.Values)

if ($selectedSubscriptions.Count -eq 0) {
    throw "No subscriptions were selected."
}

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($selectedSubscription in $selectedSubscriptions) {
    Write-Status "Collecting resources for $($selectedSubscription.name) [$($selectedSubscription.id)]."
    try {
        Invoke-AzCommand -Arguments @('account', 'set', '--subscription', $selectedSubscription.id) -Operation "Set Azure CLI context to subscription '$($selectedSubscription.name)'"
        $resources = @(Invoke-AzJson -Arguments @('resource', 'list', '--subscription', $selectedSubscription.id, '-o', 'json') -Operation "List resources for subscription '$($selectedSubscription.name)'" | ConvertFrom-Json)
    } catch {
        Write-Warning "Skipping $($selectedSubscription.name) [$($selectedSubscription.id)]: $($_.Exception.Message)"
        continue
    }

    foreach ($resource in $resources) {
        $rows.Add([pscustomobject][ordered]@{
            'subscription id' = $selectedSubscription.id
            'subscription name' = $selectedSubscription.name
            'resource group' = (Get-PropertyValue -Object $resource -Name 'resourceGroup')
            'region' = (Get-PropertyValue -Object $resource -Name 'location')
            'availability zone' = (Convert-ZonesToString -Zones (Get-PropertyValue -Object $resource -Name 'zones'))
            'resource type' = (Get-PropertyValue -Object $resource -Name 'type')
            'portal type' = (Convert-ResourceTypeToPortalType -ResourceType (Get-PropertyValue -Object $resource -Name 'type'))
            'resource name' = (Get-PropertyValue -Object $resource -Name 'name')
            'tags' = (Convert-TagsToString -Tags (Get-PropertyValue -Object $resource -Name 'tags'))
        }) | Out-Null
    }
}

if ($rows.Count -eq 0) {
    '"subscription id","subscription name","resource group","region","availability zone","resource type","portal type","resource name","tags"' |
        Set-Content -LiteralPath $OutputPath -Encoding UTF8
} else {
    $rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
}

Write-Status "Wrote $($rows.Count) resources to $OutputPath"
}

try {
    Invoke-AzureResourceInventoryExport
    $global:LASTEXITCODE = 0
} catch {
    Write-Error "Azure resource inventory export failed. $($_.Exception.Message)"
    exit 1
}

$global:LASTEXITCODE = 0
