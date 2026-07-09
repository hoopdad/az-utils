#Requires -Version 7.0
<#
.NOTICE
    Sample code only. This script is provided "as is" without warranties or
    guarantees of completeness, accuracy, availability, or fitness for a
    particular environment. Azure service quota and usage APIs vary by tenant,
    subscription, region, provider registration state, API version, RBAC, and
    service support. The customer must review, test, and validate all output
    in their own Azure environment before relying on it for operational,
    capacity, financial, compliance, or remediation decisions.

.SYNOPSIS
    Staged pipeline for Azure quota collection across subscriptions and regions.

.DESCRIPTION
    Collects Azure quota/usage data in three stages, outputting CSV at each:

      Stage 1: Discover subscriptions         -> subscriptions.csv
      Stage 2: Discover active regions        -> subs_regions.csv
      Stage 3: Validate provider registration -> provider_registration.csv
      Stage 4: Collect quotas (all providers) -> quota.csv
      Stage 5: Inventory business services     -> inventory.csv

    Stage 4 covers Compute and Network via dedicated CLI commands, 18
    additional Azure providers via the unified Quota API (az quota extension),
    and service-specific fallback endpoints for providers not supported by
    the central Quota API.

    Each stage can be skipped by providing its output file as input, enabling
    a "resume from where you left off" workflow. Parallelized by default.

.EXAMPLE
    pwsh Get-AzQuotaPipeline.ps1 -AllEnabled
.EXAMPLE
    pwsh Get-AzQuotaPipeline.ps1 -SubscriptionId "xxxx-xxxx"
.EXAMPLE
    pwsh Get-AzQuotaPipeline.ps1 -SubscriptionsFile ./subscriptions.csv
.EXAMPLE
    pwsh Get-AzQuotaPipeline.ps1 -SubsRegionsFile ./subs_regions.csv
.EXAMPLE
    pwsh Get-AzQuotaPipeline.ps1 -AllEnabled -MaxParallel 16 -OutputDir ./reports
.EXAMPLE
    pwsh Get-AzQuotaPipeline.ps1 -AllEnabled -DebugLog
    Emits detailed debug output (subscription counts, tenant/state filtering,
    per-subscription region results, and az CLI error details) to diagnose why
    subscriptions or regions may be missing.
#>
[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [Parameter(ParameterSetName = 'Single')]
    [string]$SubscriptionId,

    [Parameter(ParameterSetName = 'SubsFile')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$SubscriptionsFile,

    [Parameter(ParameterSetName = 'RegionFile')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$SubsRegionsFile,

    [Parameter(ParameterSetName = 'All')]
    [switch]$AllEnabled,

    [Parameter()]
    [string]$OutputDir = (Get-Location).Path,

    [Parameter()]
    [ValidateRange(1, 32)]
    [int]$MaxParallel = 8,

    [Parameter()]
    [switch]$Sequential,

    [Parameter()]
    [switch]$DebugLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'yes_without_prompt'
$script:DebugLogEnabled = [bool]$DebugLog

#region ── Shared Utilities ───────────────────────────────────────────

function Write-DebugLog {
    param([Parameter(Mandatory)][string]$Message)
    if (-not $script:DebugLogEnabled) { return }
    $ts = (Get-Date).ToString('HH:mm:ss.fff')
    Write-Host "[DEBUG $ts] $Message" -ForegroundColor DarkGray
}

function Invoke-AzJsonSafe {
    param([Parameter(Mandatory)][string[]]$Arguments)
    Write-DebugLog "az $($Arguments -join ' ')"
    $raw = & az @Arguments 2>&1
    $text = ($raw | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE. $text"
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-DebugLog "az returned empty output for: az $($Arguments -join ' ')"
        return $null
    }
    try {
        return ($text | ConvertFrom-Json -Depth 100)
    }
    catch {
        throw "Failed to parse JSON for: az $($Arguments -join ' ') :: $_"
    }
}

function Invoke-AzRestJsonSafe {
    param([Parameter(Mandatory)][string]$Url)
    Write-DebugLog "az rest --method get --url $Url"
    $raw = & az rest --method get --url $Url -o json --only-show-errors 2>&1
    $text = ($raw | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "az rest --method get --url $Url failed with exit code $LASTEXITCODE. $text"
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-DebugLog "az rest returned empty output for: $Url"
        return $null
    }
    try {
        return ($text | ConvertFrom-Json -Depth 100)
    }
    catch {
        throw "Failed to parse JSON for az rest URL: $Url :: $_"
    }
}

function Invoke-AzRestJsonOptional {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Context
    )

    try {
        return Invoke-AzRestJsonSafe -Url $Url
    }
    catch {
        Write-Warning "$Context failed: $_"
        return $null
    }
}

function Get-GroupCountByName {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Groups,
        [Parameter(Mandatory)][string]$Name
    )

    $group = $Groups | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($group) { return [double]$group.Count }
    return 0.0
}

function Write-Stage {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status
    )
    Write-Host "[Stage $Number] $Name - $Status" -ForegroundColor Cyan
}

function Get-UsagePercentValue ([object]$Used, [object]$Limit) {
    if ($null -eq $Used -or $null -eq $Limit) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$Used) -or [string]::IsNullOrWhiteSpace([string]$Limit)) { return $null }
    $usedValue = [double]$Used
    $limitValue = [double]$Limit
    if ($limitValue -le 0) { return $(if ($usedValue -gt 0) { 100.0 } else { 0.0 }) }
    return [math]::Round(($usedValue / $limitValue) * 100, 2)
}

function Get-QuotaItemKey {
    param([Parameter(Mandatory)][object]$Item)
    if ($null -eq $Item.name) { return $null }
    if ($Item.name -is [string]) { return ([string]$Item.name).Trim().ToLowerInvariant() }
    if ($Item.name.PSObject.Properties['value'] -and -not [string]::IsNullOrWhiteSpace([string]$Item.name.value)) {
        return ([string]$Item.name.value).Trim().ToLowerInvariant()
    }
    return $null
}

function Get-QuotaScope {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ProviderNamespace,
        [Parameter(Mandatory)][string]$Region
    )
    return "/subscriptions/$SubscriptionId/providers/$ProviderNamespace/locations/$Region"
}

function Get-QuotaUsageLookup {
    param([Parameter(Mandatory)][string]$Scope)
    $lookup = @{}
    try {
        $items = Invoke-AzJsonSafe -Arguments @('quota', 'usage', 'list', '--scope', $Scope, '-o', 'json', '--only-show-errors')
    }
    catch {
        Write-Warning "Quota usage query failed for scope $Scope. Usage values may be blank: $_"
        return $lookup
    }
    foreach ($item in @($items)) {
        if ($null -eq $item -or -not $item.PSObject.Properties['properties']) { continue }
        $key = Get-QuotaItemKey -Item $item
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($item.properties.PSObject.Properties['usages'] -and $null -ne $item.properties.usages -and $item.properties.usages.PSObject.Properties['value']) {
            $lookup[$key] = [double]$item.properties.usages.value
        }
    }
    return $lookup
}

function Resolve-QuotaUsageValue {
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][hashtable]$UsageLookup
    )
    $key = Get-QuotaItemKey -Item $Item
    if (-not [string]::IsNullOrWhiteSpace($key) -and $UsageLookup.ContainsKey($key)) {
        return $UsageLookup[$key]
    }
    if ($Item.PSObject.Properties['properties'] -and
        $Item.properties.PSObject.Properties['usages'] -and
        $null -ne $Item.properties.usages -and
        $Item.properties.usages.PSObject.Properties['value']) {
        return [double]$Item.properties.usages.value
    }
    return $null
}

function Resolve-QuotaName {
    param([Parameter(Mandatory)][object]$Item)
    if ($Item.PSObject.Properties['localName'] -and -not [string]::IsNullOrWhiteSpace([string]$Item.localName)) {
        return [string]$Item.localName
    }
    if ($null -ne $Item.name) {
        if ($Item.name -is [string]) { return $Item.name }
        if ($Item.name.PSObject.Properties['localizedValue'] -and -not [string]::IsNullOrWhiteSpace([string]$Item.name.localizedValue)) {
            return [string]$Item.name.localizedValue
        }
        if ($Item.name.PSObject.Properties['value'] -and -not [string]::IsNullOrWhiteSpace([string]$Item.name.value)) {
            return [string]$Item.name.value
        }
    }
    return 'Unknown'
}

function New-QuotaRow {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$SubscriptionName,
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$QuotaName,
        [Parameter(Mandatory)][AllowNull()][object]$Used,
        [Parameter(Mandatory)][AllowNull()][object]$Limit,
        [Parameter(Mandatory)][string]$Unit,
        [Parameter(Mandatory)][bool]$IsQuotaApplicable
    )

    [pscustomobject]@{
        SubscriptionId = $SubscriptionId
        SubscriptionName = $SubscriptionName
        Region = $Region
        Provider = $Provider
        QuotaName = $QuotaName
        Used = $Used
        Limit = $Limit
        Unit = $Unit
        UsagePercent = (Get-UsagePercentValue $Used $Limit)
        IsQuotaApplicable = $IsQuotaApplicable
    }
}

#endregion

#region ── Provider Configuration ─────────────────────────────────────

# Additional quota providers queried via the Azure Quota API (az quota list).
# Compute and Network use dedicated CLI commands for richer data. Some services
# such as SQL and messaging do not work through Microsoft.Quota and are handled
# by service-specific fallback collection below.
# To add a provider: append @{ Label = 'Display Name'; Namespace = 'Microsoft.Provider' }
$script:QuotaApiProviders = @(
    @{ Label = 'Compute (classic)';          Namespace = 'Microsoft.ClassicCompute' }
    @{ Label = 'Machine Learning';           Namespace = 'Microsoft.MachineLearningServices' }
    @{ Label = 'Storage';                    Namespace = 'Microsoft.Storage' }
    @{ Label = 'Storage (classic)';          Namespace = 'Microsoft.ClassicStorage' }
    @{ Label = 'HPC Cache';                  Namespace = 'Microsoft.StorageCache' }
    @{ Label = 'Azure HDInsight';            Namespace = 'Microsoft.HDInsight' }
    @{ Label = 'Azure Lab Services';         Namespace = 'Microsoft.LabServices' }
    @{ Label = 'Azure Container Instances';  Namespace = 'Microsoft.ContainerInstance' }
    @{ Label = 'Dev Box';                    Namespace = 'Microsoft.DevCenter' }
    @{ Label = 'Azure Container Apps';       Namespace = 'Microsoft.App' }
    @{ Label = 'App Service';               Namespace = 'Microsoft.Web' }
    @{ Label = 'Search';                     Namespace = 'Microsoft.Search' }
    @{ Label = 'Azure VMware Solution';      Namespace = 'Microsoft.AVS' }
    @{ Label = 'Managed DevOps Pools';       Namespace = 'Microsoft.DevOpsInfrastructure' }
    @{ Label = 'Azure Database for MySQL';   Namespace = 'Microsoft.DBforMySQL' }
    @{ Label = 'Automation Accounts';        Namespace = 'Microsoft.Automation' }
    @{ Label = 'Microsoft Fabric';           Namespace = 'Microsoft.Fabric' }
    @{ Label = 'Azure Kubernetes Service';   Namespace = 'Microsoft.ContainerService' }
)

$script:ServiceSpecificProviders = @(
    @{ Label = 'Azure SQL';                  Namespace = 'Microsoft.Sql' }
    @{ Label = 'Azure PostgreSQL';           Namespace = 'Microsoft.DBforPostgreSQL' }
    @{ Label = 'Azure Cosmos DB';            Namespace = 'Microsoft.DocumentDB' }
    @{ Label = 'Azure Event Hubs';           Namespace = 'Microsoft.EventHub' }
    @{ Label = 'API Management';             Namespace = 'Microsoft.ApiManagement' }
    @{ Label = 'Azure Service Bus';          Namespace = 'Microsoft.ServiceBus' }
)

function Get-RequiredProviderNamespaces {
    @(
        'Microsoft.Quota'
        'Microsoft.Compute'
        'Microsoft.Network'
        $script:QuotaApiProviders.Namespace
        $script:ServiceSpecificProviders.Namespace
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique
}

function Test-AzPipelineProviderRegistrations {
    param([Parameter(Mandatory)][object[]]$Subscriptions)

    $providers = @(Get-RequiredProviderNamespaces)
    foreach ($sub in $Subscriptions) {
        foreach ($provider in $providers) {
            $state = 'Unknown'
            $errorText = $null
            try {
                $result = Invoke-AzJsonSafe -Arguments @('provider', 'show', '--namespace', $provider, '--subscription', $sub.SubscriptionId, '-o', 'json', '--only-show-errors')
                if ($result -and $result.PSObject.Properties['registrationState']) {
                    $state = [string]$result.registrationState
                }
                else {
                    $errorText = 'Provider registration state was not present in Azure CLI output.'
                }
            }
            catch {
                $errorText = "Unable to read provider registration state: $_"
            }

            [pscustomobject]@{
                SubscriptionId = [string]$sub.SubscriptionId
                SubscriptionName = [string]$sub.SubscriptionName
                ProviderNamespace = $provider
                RegistrationState = $state
                Ready = ($state -eq 'Registered')
                Error = $errorText
            }
        }
    }
}

function Resolve-QuotaApiItem {
    param([Parameter(Mandatory)][object]$Item)

    $props = $Item.properties
    $n = Resolve-QuotaName -Item $props
    if ($n -eq 'Unknown' -and $Item.name -is [string]) { $n = $Item.name }

    $u = 0.0; $l = 0.0
    if ($props.PSObject.Properties['usages'] -and $null -ne $props.usages -and $props.usages.PSObject.Properties['value']) { $u = [double]$props.usages.value }
    if ($props.PSObject.Properties['limit']  -and $null -ne $props.limit  -and $props.limit.PSObject.Properties['value'])  { $l = [double]$props.limit.value }
    $unit = if ($props.PSObject.Properties['unit'] -and -not [string]::IsNullOrWhiteSpace([string]$props.unit)) { [string]$props.unit } else { 'Count' }

    return @{ Name = $n; Used = $u; Limit = $l; Unit = $unit }
}

function New-InventoryRow {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$SubscriptionName,
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][string]$ResourceType,
        [Parameter(Mandatory)][int]$Count
    )

    [pscustomobject]@{
        SubscriptionId = $SubscriptionId
        SubscriptionName = $SubscriptionName
        Region = $Region
        Service = $Service
        ResourceType = $ResourceType
        Count = $Count
        IsQuotaApplicable = $false
    }
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string[]]$Names,
        [object]$DefaultValue = $null
    )

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($property) { return $property.Value }
    }

    return $DefaultValue
}

function ConvertTo-InventoryRow {
    param(
        [Parameter(Mandatory)][object]$Row,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$SubscriptionName
    )

    $service = [string](Get-ObjectPropertyValue -Object $Row -Names @('Service', 'service', 'InventoryService', 'inventoryService'))
    $resourceType = [string](Get-ObjectPropertyValue -Object $Row -Names @('ResourceType', 'resourceType', 'type'))
    $region = [string](Get-ObjectPropertyValue -Object $Row -Names @('Region', 'region', 'normalizedLocation', 'location') -DefaultValue 'global')
    $count = Get-ObjectPropertyValue -Object $Row -Names @('ResourceCount', 'resourceCount', 'Count', 'count_', 'count') -DefaultValue 0

    if ([string]::IsNullOrWhiteSpace($service) -or [string]::IsNullOrWhiteSpace($resourceType)) {
        Write-DebugLog "Skipping inventory row with unexpected Resource Graph shape: $($Row | ConvertTo-Json -Compress -Depth 10)"
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($region)) { $region = 'global' }

    New-InventoryRow -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Region $region -Service $service -ResourceType $resourceType -Count ([int]$count)
}

function Test-SqlUsageIsQuotaCapacity {
    param([Parameter(Mandatory)][object]$Item)

    $name = [string]$Item.name
    $displayName = if ($Item.PSObject.Properties['properties'] -and $Item.properties.PSObject.Properties['displayName']) { [string]$Item.properties.displayName } else { '' }
    $unit = if ($Item.PSObject.Properties['properties'] -and $Item.properties.PSObject.Properties['unit']) { [string]$Item.properties.unit } else { '' }

    if ($name -match '(?i)(DaysLeft|MonthsLeft|TokensLeft|TokenRefreshDaysLeft)') { return $false }
    if ($displayName -match '(?i)(count-?down|days until|months until|hours left|tokens left|free period expires|reset)') { return $false }
    if ($unit -match '(?i)(DaysLeft|MonthsLeft|TokensLeft|TokenRefreshDaysLeft)') { return $false }

    return $true
}

#endregion

#region ── Stage 1: Subscription Discovery ────────────────────────────

function Get-AzPipelineSubscriptions {
    param([string]$SubscriptionId, [switch]$AllEnabled)

    $account = Invoke-AzJsonSafe -Arguments @('account', 'show', '-o', 'json', '--only-show-errors')
    if (-not $account) { throw 'Not logged in to Azure CLI. Run "az login" first.' }

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $sub = Invoke-AzJsonSafe -Arguments @('account', 'show', '--subscription', $SubscriptionId, '-o', 'json', '--only-show-errors')
        if (-not $sub) { throw "Subscription '$SubscriptionId' not found or not accessible." }
        return @([pscustomobject]@{ SubscriptionId = [string]$sub.id; SubscriptionName = [string]$sub.name; TenantId = [string]$sub.tenantId })
    }

    $allAccounts = @(Invoke-AzJsonSafe -Arguments @('account', 'list', '--all', '-o', 'json', '--only-show-errors'))
    Write-DebugLog "Current account: id=$($account.id) tenantId=$($account.tenantId)"
    Write-DebugLog "az account list --all returned $($allAccounts.Count) total subscriptions."
    if ($script:DebugLogEnabled) {
        $stateGroups = $allAccounts | Group-Object state | ForEach-Object { "$($_.Name)=$($_.Count)" }
        Write-DebugLog "Subscription states: $($stateGroups -join ', ')"
        $tenantGroups = $allAccounts | Group-Object tenantId | ForEach-Object { "$($_.Name)=$($_.Count)" }
        Write-DebugLog "Subscriptions per tenant: $($tenantGroups -join ', ')"
    }

    $enabled = @($allAccounts | Where-Object { $_.state -eq 'Enabled' })
    Write-DebugLog "After state='Enabled' filter: $($enabled.Count) subscriptions."

    if ($AllEnabled) {
        $beforeTenant = $enabled.Count
        $enabled = @($enabled | Where-Object { [string]$_.tenantId -eq [string]$account.tenantId })
        Write-DebugLog "AllEnabled mode: filtered to current tenant ($($account.tenantId)): $($enabled.Count) of $beforeTenant enabled subscriptions kept."
        $otherTenant = $beforeTenant - $enabled.Count
        if ($otherTenant -gt 0) {
            Write-DebugLog "$otherTenant enabled subscription(s) excluded because they belong to a different tenant. Re-run targeting that tenant to include them."
        }
    }
    else {
        $enabled = @($enabled | Where-Object { [string]$_.id -eq [string]$account.id })
        Write-DebugLog "Default mode (no -AllEnabled/-SubscriptionId): scoped to current subscription only -> $($enabled.Count). Use -AllEnabled to collect all subscriptions in the tenant."
    }

    if ($enabled.Count -eq 0) { throw 'No enabled subscriptions found in the current tenant.' }

    return @($enabled | ForEach-Object {
        [pscustomobject]@{ SubscriptionId = [string]$_.id; SubscriptionName = [string]$_.name; TenantId = [string]$_.tenantId }
    } | Sort-Object SubscriptionName)
}

#endregion

#region ── Stage 2: Active Region Discovery ───────────────────────────

function Get-RegionsForSubscription {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$SubscriptionName
    )
    $query = "Resources | where isnotempty(location) | where tolower(location) != 'global' | summarize ResourceCount=count() by Region=tolower(location)"
    try {
        $result = Invoke-AzJsonSafe -Arguments @('graph', 'query', '-q', $query, '--subscriptions', $SubscriptionId, '--first', '1000', '-o', 'json', '--only-show-errors')
    }
    catch {
        Write-Warning "Region discovery failed for $SubscriptionName ($SubscriptionId): $_"
        return
    }
    if (-not $result -or -not $result.data) {
        Write-DebugLog "No region data returned for $SubscriptionName ($SubscriptionId). The az graph (Resource Graph) extension may be missing, or the subscription has no located resources / no read access."
        return
    }
    Write-DebugLog "$SubscriptionName ($SubscriptionId): found $(@($result.data).Count) active region(s)."
    foreach ($row in @($result.data)) {
        [pscustomobject]@{ SubscriptionId = $SubscriptionId; SubscriptionName = $SubscriptionName; Region = [string]$row.Region; ResourceCount = [int]$row.ResourceCount }
    }
}

function Get-AzPipelineRegions {
    param(
        [Parameter(Mandatory)][object[]]$Subscriptions,
        [int]$ThrottleLimit = 8,
        [switch]$Sequential
    )

    if ($Sequential -or $Subscriptions.Count -le 1) {
        $results = foreach ($sub in $Subscriptions) {
            Write-Host "  Querying regions for $($sub.SubscriptionName)..."
            Get-RegionsForSubscription -SubscriptionId $sub.SubscriptionId -SubscriptionName $sub.SubscriptionName
        }
        return @($results | Where-Object { $null -ne $_ })
    }

    Write-Host "  Querying regions for $($Subscriptions.Count) subscriptions ($ThrottleLimit parallel)..."
    $debugEnabled = $script:DebugLogEnabled
    $results = $Subscriptions | ForEach-Object -Parallel {
        $subId = $_.SubscriptionId; $subName = $_.SubscriptionName; $dbg = $using:debugEnabled
        $q = "Resources | where isnotempty(location) | where tolower(location) != 'global' | summarize ResourceCount=count() by Region=tolower(location)"
        try {
            $json = (& az graph query -q $q --subscriptions $subId --first 1000 -o json --only-show-errors 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Region query failed for $subName ($subId) exit=$LASTEXITCODE :: $json"
                if ($dbg) { Write-Host "[DEBUG] Region query failed for $subName ($subId) exit=$LASTEXITCODE :: $json" -ForegroundColor DarkGray }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($json)) {
                $rows = @(($json | ConvertFrom-Json -Depth 50).data)
                if ($dbg) { Write-Host "[DEBUG] $subName ($subId): $($rows.Count) active region(s)." -ForegroundColor DarkGray }
                foreach ($row in $rows) {
                    [pscustomobject]@{ SubscriptionId = $subId; SubscriptionName = $subName; Region = [string]$row.Region; ResourceCount = [int]$row.ResourceCount }
                }
            }
            elseif ($dbg) { Write-Host "[DEBUG] $subName ($subId): empty region result." -ForegroundColor DarkGray }
        } catch { Write-Warning "Region discovery failed for $subName : $_" }
    } -ThrottleLimit $ThrottleLimit

    return @($results | Where-Object { $null -ne $_ })
}

#endregion

#region ── Stage 3: Quota Collection ──────────────────────────────────

function Get-QuotasForRegion {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$SubscriptionName,
        [Parameter(Mandatory)][string]$Region
    )

    # Compute
    try {
        $items = Invoke-AzJsonSafe -Arguments @('vm', 'list-usage', '--location', $Region, '--subscription', $SubscriptionId, '-o', 'json', '--only-show-errors')
        foreach ($item in @($items)) {
            if ($null -eq $item) { continue }
            $n = Resolve-QuotaName -Item $item; $u = [double]$item.currentValue; $l = [double]$item.limit
            [pscustomobject]@{ SubscriptionId = $SubscriptionId; SubscriptionName = $SubscriptionName; Region = $Region; Provider = 'Compute'; QuotaName = $n; Used = $u; Limit = $l; Unit = 'Count'; UsagePercent = (Get-UsagePercentValue $u $l); IsQuotaApplicable = $true }
        }
    } catch { Write-Warning "Compute quota failed for $SubscriptionName / $Region : $_" }

    # Network
    try {
        $items = Invoke-AzJsonSafe -Arguments @('network', 'list-usages', '--location', $Region, '--subscription', $SubscriptionId, '-o', 'json', '--only-show-errors')
        foreach ($item in @($items)) {
            if ($null -eq $item) { continue }
            $n = Resolve-QuotaName -Item $item; $u = [double]$item.currentValue; $l = [double]$item.limit
            $unit = if ($item.PSObject.Properties['unit'] -and -not [string]::IsNullOrWhiteSpace([string]$item.unit)) { [string]$item.unit } else { 'Count' }
            [pscustomobject]@{ SubscriptionId = $SubscriptionId; SubscriptionName = $SubscriptionName; Region = $Region; Provider = 'Network'; QuotaName = $n; Used = $u; Limit = $l; Unit = $unit; UsagePercent = (Get-UsagePercentValue $u $l); IsQuotaApplicable = $true }
        }
    } catch { Write-Warning "Network quota failed for $SubscriptionName / $Region : $_" }

    # Additional providers via Azure Quota API
    foreach ($provider in $script:QuotaApiProviders) {
        try {
            $scope = Get-QuotaScope -SubscriptionId $SubscriptionId -ProviderNamespace $provider.Namespace -Region $Region
            $usageLookup = Get-QuotaUsageLookup -Scope $scope
            $items = Invoke-AzJsonSafe -Arguments @('quota', 'list', '--scope', $scope, '-o', 'json', '--only-show-errors')
            foreach ($item in @($items)) {
                if ($null -eq $item -or -not $item.PSObject.Properties['properties']) { continue }
                $q = Resolve-QuotaApiItem -Item $item
                $used = Resolve-QuotaUsageValue -Item $item -UsageLookup $usageLookup
                $applicable = if ($item.properties.PSObject.Properties['isQuotaApplicable']) { [bool]$item.properties.isQuotaApplicable } else { $true }
                [pscustomobject]@{ SubscriptionId = $SubscriptionId; SubscriptionName = $SubscriptionName; Region = $Region; Provider = $provider.Label; QuotaName = $q.Name; Used = $used; Limit = $q.Limit; Unit = $q.Unit; UsagePercent = (Get-UsagePercentValue $used $q.Limit); IsQuotaApplicable = $applicable }
            }
        } catch { Write-Warning "$($provider.Label) quota failed for $SubscriptionName / $Region : $_" }
    }
}

function Get-AzPipelineQuotas {
    param(
        [Parameter(Mandatory)][object[]]$SubsRegions,
        [int]$ThrottleLimit = 8,
        [switch]$Sequential
    )

    $total = $SubsRegions.Count

    if ($Sequential -or $total -le 1) {
        $i = 0
        $results = foreach ($item in $SubsRegions) {
            $i++; Write-Host "  [$i/$total] $($item.SubscriptionName) / $($item.Region)"
            Get-QuotasForRegion -SubscriptionId $item.SubscriptionId -SubscriptionName $item.SubscriptionName -Region $item.Region
        }
        return @($results | Where-Object { $null -ne $_ })
    }

    Write-Host "  Collecting $total subscription-region combos ($ThrottleLimit parallel)..."
    $quotaProviders = $script:QuotaApiProviders
    $results = $SubsRegions | ForEach-Object -Parallel {
        $subId = $_.SubscriptionId; $subName = $_.SubscriptionName; $region = $_.Region

        function _Name($item) {
            if ($item.PSObject.Properties['localName'] -and -not [string]::IsNullOrWhiteSpace([string]$item.localName)) { return [string]$item.localName }
            if ($null -ne $item.name) {
                if ($item.name -is [string]) { return $item.name }
                if ($item.name.PSObject.Properties['localizedValue'] -and -not [string]::IsNullOrWhiteSpace([string]$item.name.localizedValue)) { return [string]$item.name.localizedValue }
                if ($item.name.PSObject.Properties['value']) { return [string]$item.name.value }
            }
            return 'Unknown'
        }
        function _Pct($u, $l) {
            if ($null -eq $u -or $null -eq $l) { return $null }
            if ([string]::IsNullOrWhiteSpace([string]$u) -or [string]::IsNullOrWhiteSpace([string]$l)) { return $null }
            $uv = [double]$u; $lv = [double]$l
            if ($lv -le 0) { return $(if ($uv -gt 0) { 100.0 } else { 0.0 }) }
            [math]::Round(($uv / $lv) * 100, 2)
        }
        function _Key($item) {
            if ($null -eq $item.name) { return $null }
            if ($item.name -is [string]) { return ([string]$item.name).Trim().ToLowerInvariant() }
            if ($item.name.PSObject.Properties['value'] -and -not [string]::IsNullOrWhiteSpace([string]$item.name.value)) {
                return ([string]$item.name.value).Trim().ToLowerInvariant()
            }
            return $null
        }
        function _UsageValue($item, $lookup) {
            $key = _Key $item
            if (-not [string]::IsNullOrWhiteSpace($key) -and $lookup.ContainsKey($key)) { return $lookup[$key] }
            if ($item.PSObject.Properties['properties'] -and
                $item.properties.PSObject.Properties['usages'] -and
                $null -ne $item.properties.usages -and
                $item.properties.usages.PSObject.Properties['value']) {
                return [double]$item.properties.usages.value
            }
            return $null
        }

        try {
            $json = (& az vm list-usage --location $region --subscription $subId -o json --only-show-errors 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Compute quota failed for $subName / $region exit=$LASTEXITCODE :: $json"
            }
            elseif (-not [string]::IsNullOrWhiteSpace($json)) {
                foreach ($item in @($json | ConvertFrom-Json -Depth 50)) {
                    $n = _Name $item; $u = [double]$item.currentValue; $l = [double]$item.limit
                    [pscustomobject]@{ SubscriptionId = $subId; SubscriptionName = $subName; Region = $region; Provider = 'Compute'; QuotaName = $n; Used = $u; Limit = $l; Unit = 'Count'; UsagePercent = (_Pct $u $l); IsQuotaApplicable = $true }
                }
            }
        } catch { Write-Warning "Compute quota failed for $subName / $region : $_" }

        try {
            $json = (& az network list-usages --location $region --subscription $subId -o json --only-show-errors 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Network quota failed for $subName / $region exit=$LASTEXITCODE :: $json"
            }
            elseif (-not [string]::IsNullOrWhiteSpace($json)) {
                foreach ($item in @($json | ConvertFrom-Json -Depth 50)) {
                    $n = _Name $item; $u = [double]$item.currentValue; $l = [double]$item.limit
                    $unit = if ($item.PSObject.Properties['unit'] -and -not [string]::IsNullOrWhiteSpace([string]$item.unit)) { [string]$item.unit } else { 'Count' }
                    [pscustomobject]@{ SubscriptionId = $subId; SubscriptionName = $subName; Region = $region; Provider = 'Network'; QuotaName = $n; Used = $u; Limit = $l; Unit = $unit; UsagePercent = (_Pct $u $l); IsQuotaApplicable = $true }
                }
            }
        } catch { Write-Warning "Network quota failed for $subName / $region : $_" }

        # Additional providers via Azure Quota API
        foreach ($p in $using:quotaProviders) {
            try {
                $scope = "/subscriptions/$subId/providers/$($p.Namespace)/locations/$region"
                $usageLookup = @{}
                $usageJson = (& az quota usage list --scope $scope -o json --only-show-errors 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "$($p.Label) quota usage query failed for $subName / $region : $usageJson"
                }
                elseif (-not [string]::IsNullOrWhiteSpace($usageJson)) {
                    foreach ($usageItem in @($usageJson | ConvertFrom-Json -Depth 50)) {
                        $usageKey = _Key $usageItem
                        if ([string]::IsNullOrWhiteSpace($usageKey)) { continue }
                        if ($usageItem.PSObject.Properties['properties'] -and
                            $usageItem.properties.PSObject.Properties['usages'] -and
                            $null -ne $usageItem.properties.usages -and
                            $usageItem.properties.usages.PSObject.Properties['value']) {
                            $usageLookup[$usageKey] = [double]$usageItem.properties.usages.value
                        }
                    }
                }
                $json = (& az quota list --scope $scope -o json --only-show-errors 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "$($p.Label) quota list failed for $subName / $region : $json"
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($json)) {
                    Write-Warning "$($p.Label) quota list returned empty output for $subName / $region"
                    continue
                }
                foreach ($item in @($json | ConvertFrom-Json -Depth 50)) {
                    if ($null -eq $item -or -not $item.PSObject.Properties['properties']) { continue }
                    $props = $item.properties
                    $applicable = if ($props.PSObject.Properties['isQuotaApplicable']) { [bool]$props.isQuotaApplicable } else { $true }
                    $n = _Name $props
                    if ($n -eq 'Unknown' -and $item.name -is [string]) { $n = $item.name }
                    $u = _UsageValue $item $usageLookup
                    $l = 0.0
                    if ($props.PSObject.Properties['limit']  -and $null -ne $props.limit  -and $props.limit.PSObject.Properties['value'])  { $l = [double]$props.limit.value }
                    $unit = if ($props.PSObject.Properties['unit'] -and -not [string]::IsNullOrWhiteSpace([string]$props.unit)) { [string]$props.unit } else { 'Count' }
                    [pscustomobject]@{ SubscriptionId = $subId; SubscriptionName = $subName; Region = $region; Provider = $p.Label; QuotaName = $n; Used = $u; Limit = $l; Unit = $unit; UsagePercent = (_Pct $u $l); IsQuotaApplicable = $applicable }
                }
            } catch { Write-Warning "$($p.Label) quota failed for $subName / $region : $_" }
        }
    } -ThrottleLimit $ThrottleLimit

    return @($results | Where-Object { $null -ne $_ })
}

function Get-AzPipelineServiceSpecificLimits {
    param([Parameter(Mandatory)][object[]]$SubsRegions)

    $subGroups = $SubsRegions | Group-Object SubscriptionId
    foreach ($subGroup in $subGroups) {
        $subId = [string]$subGroup.Name
        $subName = [string](@($subGroup.Group)[0].SubscriptionName)
        $regions = @($subGroup.Group | ForEach-Object { [string]$_.Region } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

        foreach ($region in $regions) {
            $sqlUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Sql/locations/$region/usages?api-version=2023-08-01"
            $sqlUsage = Invoke-AzRestJsonOptional -Url $sqlUrl -Context "Azure SQL usage query for $subName / $region"
            foreach ($item in @($sqlUsage.value)) {
                if ($null -eq $item -or -not $item.PSObject.Properties['properties']) { continue }
                if (-not (Test-SqlUsageIsQuotaCapacity -Item $item)) { continue }
                $props = $item.properties
                $name = if (-not [string]::IsNullOrWhiteSpace([string]$props.displayName)) { [string]$props.displayName } else { [string]$item.name }
                $used = if ($props.PSObject.Properties['currentValue']) { [double]$props.currentValue } else { 0.0 }
                $limit = if ($props.PSObject.Properties['limit']) { [double]$props.limit } else { 0.0 }
                $unit = if ($props.PSObject.Properties['unit'] -and -not [string]::IsNullOrWhiteSpace([string]$props.unit)) { [string]$props.unit } else { 'Count' }
                New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region $region -Provider 'Azure SQL' -QuotaName $name -Used $used -Limit $limit -Unit $unit -IsQuotaApplicable $true
            }
        }

        $cosmosUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.DocumentDB/databaseAccounts?api-version=2024-11-15"
        $cosmos = Invoke-AzRestJsonOptional -Url $cosmosUrl -Context "Azure Cosmos DB inventory query for $subName"
        if ($cosmos) {
            $used = @($cosmos.value).Count
            New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region 'subscription' -Provider 'Azure Cosmos DB' -QuotaName 'Database accounts per subscription (default)' -Used $used -Limit 250 -Unit 'Count' -IsQuotaApplicable $true
        }

        $eventHubUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.EventHub/namespaces?api-version=2024-01-01"
        $eventHubs = Invoke-AzRestJsonOptional -Url $eventHubUrl -Context "Azure Event Hubs namespace query for $subName"
        if ($eventHubs) {
            $counts = @($eventHubs.value) | Group-Object { ([string]$_.location).ToLowerInvariant().Replace(' ', '') }
            foreach ($region in $regions) {
                $used = Get-GroupCountByName -Groups $counts -Name $region
                New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region $region -Provider 'Azure Event Hubs' -QuotaName 'Namespaces per subscription per region' -Used $used -Limit 1000 -Unit 'Count' -IsQuotaApplicable $true
            }
        }

        $serviceBusUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.ServiceBus/namespaces?api-version=2024-01-01"
        $serviceBus = Invoke-AzRestJsonOptional -Url $serviceBusUrl -Context "Azure Service Bus namespace query for $subName"
        if ($serviceBus) {
            $counts = @($serviceBus.value) | Group-Object { ([string]$_.location).ToLowerInvariant().Replace(' ', '') }
            foreach ($region in $regions) {
                $used = Get-GroupCountByName -Groups $counts -Name $region
                New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region $region -Provider 'Azure Service Bus' -QuotaName 'Namespaces per subscription per region' -Used $used -Limit 1000 -Unit 'Count' -IsQuotaApplicable $true
            }
        }

        $apimUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.ApiManagement/service?api-version=2024-05-01"
        $apim = Invoke-AzRestJsonOptional -Url $apimUrl -Context "API Management inventory query for $subName"
        if ($apim) {
            $items = @($apim.value)
            if ($items.Count -eq 0) {
                New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region 'subscription' -Provider 'API Management' -QuotaName 'Service instances inventory (limits are per instance/tier)' -Used 0 -Limit 0 -Unit 'Count' -IsQuotaApplicable $false
            }
            else {
                foreach ($group in ($items | Group-Object { ([string]$_.location).ToLowerInvariant().Replace(' ', '') })) {
                    New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region $group.Name -Provider 'API Management' -QuotaName 'Service instances inventory (limits are per instance/tier)' -Used ([double]$group.Count) -Limit 0 -Unit 'Count' -IsQuotaApplicable $false
                }
            }
        }

        $postgresFlexibleUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.DBforPostgreSQL/flexibleServers?api-version=2024-08-01"
        $postgresSingleUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.DBforPostgreSQL/servers?api-version=2017-12-01"
        $postgresFlexible = Invoke-AzRestJsonOptional -Url $postgresFlexibleUrl -Context "Azure PostgreSQL flexible server inventory query for $subName"
        $postgresSingle = Invoke-AzRestJsonOptional -Url $postgresSingleUrl -Context "Azure PostgreSQL single server inventory query for $subName"
        $postgresItems = @()
        if ($postgresFlexible) { $postgresItems += @($postgresFlexible.value) }
        if ($postgresSingle) { $postgresItems += @($postgresSingle.value) }
        if ($postgresFlexible -or $postgresSingle) {
            if ($postgresItems.Count -eq 0) {
                New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region 'subscription' -Provider 'Azure PostgreSQL' -QuotaName 'Servers inventory (service quota API unavailable)' -Used 0 -Limit 0 -Unit 'Count' -IsQuotaApplicable $false
            }
            else {
                foreach ($group in ($postgresItems | Group-Object { ([string]$_.location).ToLowerInvariant().Replace(' ', '') })) {
                    New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region $group.Name -Provider 'Azure PostgreSQL' -QuotaName 'Servers inventory (service quota API unavailable)' -Used ([double]$group.Count) -Limit 0 -Unit 'Count' -IsQuotaApplicable $false
                }
            }
        }
    }
}

function Get-AzPipelineResourceInventory {
    param(
        [Parameter(Mandatory)][object[]]$Subscriptions,
        [int]$ThrottleLimit = 8,
        [switch]$Sequential
    )

    $query = @(
        'Resources',
        '| extend lowerType = tolower(type), lowerKind = tolower(tostring(kind)), normalizedLocation = tolower(location)',
        "| extend InventoryService = case(lowerType == 'microsoft.compute/virtualmachines', 'Virtual Machines + ASR compute dependency', lowerType == 'microsoft.sqlvirtualmachine/sqlvirtualmachines', 'Microsoft SQL on IaaS Virtual Machines', lowerType in ('microsoft.desktopvirtualization/hostpools', 'microsoft.desktopvirtualization/applicationgroups', 'microsoft.desktopvirtualization/workspaces'), 'Azure Virtual Desktop (AVD)', lowerType startswith 'microsoft.netapp/', 'Azure NetApp Files', lowerType == 'microsoft.network/loadbalancers', 'Azure Load Balancer', lowerType == 'microsoft.keyvault/vaults', 'Key Vault', lowerType == 'microsoft.keyvault/managedhsms', 'Managed HSM', lowerType == 'microsoft.recoveryservices/vaults', 'Recovery Services Vaults', lowerType in ('microsoft.network/frontdoors', 'microsoft.cdn/profiles'), 'Front Door', lowerType == 'microsoft.network/networkwatchers', 'Network Watcher', lowerType == 'microsoft.insights/components', 'Application Insights', lowerType in ('microsoft.operationalinsights/workspaces', 'microsoft.insights/metricalerts', 'microsoft.insights/scheduledqueryrules', 'microsoft.insights/actiongroups', 'microsoft.insights/activitylogalerts', 'microsoft.insights/datacollectionrules'), 'Azure Monitor', lowerType == 'microsoft.datafactory/factories', 'Data Factory', lowerType == 'microsoft.kusto/clusters', 'Data Explorer', lowerType == 'microsoft.web/sites' and lowerKind contains 'functionapp', 'Function Apps', lowerType == 'microsoft.web/sites' and lowerKind !contains 'functionapp', 'App Service', lowerType == 'microsoft.servicebus/namespaces', 'Azure Service Bus', lowerType == 'microsoft.web/staticsites', 'Static Web Apps', lowerType == 'microsoft.apimanagement/service', 'API Management', lowerType == 'microsoft.sql/servers/databases', 'Azure SQL DB', lowerType == 'microsoft.app/containerapps', 'Azure Container Apps', lowerType == 'microsoft.network/applicationgateways', 'Application Gateway', lowerType == 'microsoft.storage/storageaccounts', 'Storage Accounts', lowerType == 'microsoft.appconfiguration/configurationstores', 'App Configuration', '')",
        '| where isnotempty(InventoryService)',
        '| summarize ResourceCount = count() by Service = InventoryService, ResourceType = lowerType, Region = normalizedLocation'
    ) -join ' '

    if ($Sequential -or $Subscriptions.Count -le 1) {
        $results = foreach ($sub in $Subscriptions) {
            Write-Host "  Inventory for $($sub.SubscriptionName)..."
            try {
                $result = Invoke-AzJsonSafe -Arguments @('graph', 'query', '-q', $query, '--subscriptions', $sub.SubscriptionId, '--first', '1000', '-o', 'json', '--only-show-errors')
            }
            catch {
                Write-Warning "Inventory query failed for $($sub.SubscriptionName): $_"
                continue
            }
            foreach ($row in @($result.data)) {
                ConvertTo-InventoryRow -Row $row -SubscriptionId $sub.SubscriptionId -SubscriptionName $sub.SubscriptionName
            }
        }
        return @($results | Where-Object { $null -ne $_ })
    }

    $results = $Subscriptions | ForEach-Object -Parallel {
        $subId = $_.SubscriptionId; $subName = $_.SubscriptionName; $q = $using:query
        function _Prop($object, [string[]]$names, $defaultValue = $null) {
            foreach ($name in $names) {
                $property = $object.PSObject.Properties[$name]
                if ($property) { return $property.Value }
            }
            return $defaultValue
        }
        try {
            $json = (& az graph query -q $q --subscriptions $subId --first 1000 -o json --only-show-errors 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($json)) {
                foreach ($row in @((ConvertFrom-Json $json -Depth 50).data)) {
                    $service = [string](_Prop $row @('Service', 'service', 'InventoryService', 'inventoryService'))
                    $resourceType = [string](_Prop $row @('ResourceType', 'resourceType', 'type'))
                    $region = [string](_Prop $row @('Region', 'region', 'normalizedLocation', 'location') 'global')
                    $count = _Prop $row @('ResourceCount', 'resourceCount', 'Count', 'count_', 'count') 0
                    if ([string]::IsNullOrWhiteSpace($service) -or [string]::IsNullOrWhiteSpace($resourceType)) { continue }
                    if ([string]::IsNullOrWhiteSpace($region)) { $region = 'global' }
                    [pscustomobject]@{
                        SubscriptionId = $subId
                        SubscriptionName = $subName
                        Region = $region
                        Service = $service
                        ResourceType = $resourceType
                        Count = [int]$count
                        IsQuotaApplicable = $false
                    }
                }
            }
        } catch { Write-Warning "Inventory query failed for $subName : $_" }
    } -ThrottleLimit $ThrottleLimit

    return @($results | Where-Object { $null -ne $_ })
}

#endregion

#region ── Pipeline Orchestration ─────────────────────────────────────

if (-not (Test-Path -LiteralPath $OutputDir)) {
    $null = New-Item -ItemType Directory -Path $OutputDir -Force
}

$subscriptionsCsvPath = Join-Path $OutputDir 'subscriptions.csv'
$subsRegionsCsvPath   = Join-Path $OutputDir 'subs_regions.csv'
$providerRegistrationCsvPath = Join-Path $OutputDir 'provider_registration.csv'
$quotaCsvPath         = Join-Path $OutputDir 'quota.csv'
$inventoryCsvPath     = Join-Path $OutputDir 'inventory.csv'
$startTime  = Get-Date
$throttle   = if ($Sequential) { 1 } else { $MaxParallel }
$subsRegions = $null
$subs = $null

if ($script:DebugLogEnabled) {
    Write-Host "[DEBUG] Debug logging enabled. ParameterSet=$($PSCmdlet.ParameterSetName) Throttle=$throttle OutputDir=$OutputDir" -ForegroundColor DarkGray
}

if (-not [string]::IsNullOrWhiteSpace($SubsRegionsFile)) {
    Write-Stage -Number 1 -Name 'Subscriptions' -Status 'Skipped (subs_regions input provided)'
    Write-Stage -Number 2 -Name 'Regions'       -Status 'Skipped (subs_regions input provided)'
    $subsRegions = @(Import-Csv -Path $SubsRegionsFile)
    Write-Host "  Loaded $($subsRegions.Count) subscription-region rows from $SubsRegionsFile"
}
elseif (-not [string]::IsNullOrWhiteSpace($SubscriptionsFile)) {
    Write-Stage -Number 1 -Name 'Subscriptions' -Status 'Skipped (subscriptions input provided)'
    $subs = @(Import-Csv -Path $SubscriptionsFile)
    Write-Host "  Loaded $($subs.Count) subscriptions from $SubscriptionsFile"

    Write-Stage -Number 2 -Name 'Regions' -Status 'Discovering active regions...'
    $subsRegions = @(Get-AzPipelineRegions -Subscriptions $subs -ThrottleLimit $throttle -Sequential:$Sequential)
    $subsRegions | Sort-Object SubscriptionName, Region | Export-Csv -Path $subsRegionsCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "  Found $($subsRegions.Count) subscription-region combinations -> $subsRegionsCsvPath"
}
else {
    Write-Stage -Number 1 -Name 'Subscriptions' -Status 'Discovering subscriptions...'
    $subs = @(Get-AzPipelineSubscriptions -SubscriptionId $SubscriptionId -AllEnabled:$AllEnabled)
    $subs | Export-Csv -Path $subscriptionsCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "  Found $($subs.Count) subscriptions -> $subscriptionsCsvPath"

    Write-Stage -Number 2 -Name 'Regions' -Status 'Discovering active regions...'
    $subsRegions = @(Get-AzPipelineRegions -Subscriptions $subs -ThrottleLimit $throttle -Sequential:$Sequential)
    $subsRegions | Sort-Object SubscriptionName, Region | Export-Csv -Path $subsRegionsCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "  Found $($subsRegions.Count) subscription-region combinations -> $subsRegionsCsvPath"
}

if ($subsRegions.Count -eq 0) {
    Write-Warning 'No active regions found. Nothing to collect.'
    exit 0
}

if (-not $subs) {
    $subs = @($subsRegions | Group-Object SubscriptionId | ForEach-Object {
        $first = @($_.Group)[0]
        [pscustomobject]@{
            SubscriptionId = [string]$first.SubscriptionId
            SubscriptionName = [string]$first.SubscriptionName
            TenantId = if ($first.PSObject.Properties['TenantId']) { [string]$first.TenantId } else { '' }
        }
    })
}

Write-Stage -Number 3 -Name 'Prerequisites' -Status 'Validating resource provider registrations...'
$providerRegistrations = @(Test-AzPipelineProviderRegistrations -Subscriptions $subs)
$providerRegistrations | Sort-Object SubscriptionName, ProviderNamespace | Export-Csv -Path $providerRegistrationCsvPath -NoTypeInformation -Encoding UTF8
$notRegistered = @($providerRegistrations | Where-Object { -not $_.Ready })
Write-Host "  Provider registration report -> $providerRegistrationCsvPath"
if ($notRegistered.Count -gt 0) {
    Write-Warning "$($notRegistered.Count) provider registration(s) are not Registered. Quota rows may be incomplete until prerequisites are registered."
}

Write-Stage -Number 4 -Name 'Quotas' -Status "Collecting quota data ($($subsRegions.Count) targets)..."
$quotas = @(
    Get-AzPipelineQuotas -SubsRegions $subsRegions -ThrottleLimit $throttle -Sequential:$Sequential
    Get-AzPipelineServiceSpecificLimits -SubsRegions $subsRegions
)
$quotas | Sort-Object SubscriptionName, Region, Provider, QuotaName | Export-Csv -Path $quotaCsvPath -NoTypeInformation -Encoding UTF8

Write-Stage -Number 5 -Name 'Inventory' -Status 'Collecting business service inventory...'
$inventory = @(Get-AzPipelineResourceInventory -Subscriptions $subs -ThrottleLimit $throttle -Sequential:$Sequential)
$inventory | Sort-Object SubscriptionName, Service, Region, ResourceType | Export-Csv -Path $inventoryCsvPath -NoTypeInformation -Encoding UTF8

$elapsed = (Get-Date) - $startTime
Write-Host ''
Write-Host "Pipeline complete in $($elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Green
Write-Host "  Subscriptions: $subscriptionsCsvPath"
Write-Host "  Regions:       $subsRegionsCsvPath"
Write-Host "  Provider prereqs: $providerRegistrationCsvPath"
Write-Host "  Quotas:        $quotaCsvPath ($($quotas.Count) rows)"
Write-Host "  Inventory:     $inventoryCsvPath ($($inventory.Count) rows)"

$warnings = @($quotas | Where-Object { [double]$_.UsagePercent -gt 80 })
$critical = @($quotas | Where-Object { [double]$_.UsagePercent -gt 90 })
if ($warnings.Count -gt 0) {
    Write-Host "`n  Quotas >80%: $($warnings.Count)  |  >90%: $($critical.Count)" -ForegroundColor Yellow
    $critical | Sort-Object { [double]$_.UsagePercent } -Descending |
        Select-Object -First 10 SubscriptionName, Region, Provider, QuotaName, Used, Limit, UsagePercent |
        Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
}
else { Write-Host '  No quotas above 80% usage.' -ForegroundColor Green }

#endregion
