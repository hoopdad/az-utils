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
      Stage 3: Collect quotas (all providers) -> quota.csv

    Stage 3 covers Compute and Network via dedicated CLI commands, plus 19
    additional Azure providers via the unified Quota API (az quota extension).
    To add or remove providers, edit the $QuotaApiProviders table.

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
    [switch]$Sequential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'yes_without_prompt'

#region ── Shared Utilities ───────────────────────────────────────────

function Invoke-AzJsonSafe {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $raw = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $text = ($raw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json -Depth 100)
}

function Write-Stage {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status
    )
    Write-Host "[Stage $Number] $Name - $Status" -ForegroundColor Cyan
}

function Get-UsagePercentValue ([double]$Used, [double]$Limit) {
    if ($Limit -le 0) { return $(if ($Used -gt 0) { 100.0 } else { 0.0 }) }
    return [math]::Round(($Used / $Limit) * 100, 2)
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

#endregion

#region ── Provider Configuration ─────────────────────────────────────

# Additional quota providers queried via the Azure Quota API (az quota list).
# Compute and Network use dedicated CLI commands for richer data; everything
# else goes through the unified Quota API with this table.
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
    @{ Label = 'Azure PostgreSQL';           Namespace = 'Microsoft.DBforPostgreSQL' }
    @{ Label = 'Azure Database for MySQL';   Namespace = 'Microsoft.DBforMySQL' }
    @{ Label = 'Automation Accounts';        Namespace = 'Microsoft.Automation' }
    @{ Label = 'Microsoft Fabric';           Namespace = 'Microsoft.Fabric' }
    @{ Label = 'Azure Kubernetes Service';   Namespace = 'Microsoft.ContainerService' }
)

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
    $enabled = @($allAccounts | Where-Object { $_.state -eq 'Enabled' })

    if ($AllEnabled) {
        $enabled = @($enabled | Where-Object { [string]$_.tenantId -eq [string]$account.tenantId })
    }
    else {
        $enabled = @($enabled | Where-Object { [string]$_.id -eq [string]$account.id })
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
    $result = Invoke-AzJsonSafe -Arguments @('graph', 'query', '-q', $query, '--subscriptions', $SubscriptionId, '--first', '1000', '-o', 'json', '--only-show-errors')
    if (-not $result -or -not $result.data) { return }
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
    $results = $Subscriptions | ForEach-Object -Parallel {
        $subId = $_.SubscriptionId; $subName = $_.SubscriptionName
        $q = "Resources | where isnotempty(location) | where tolower(location) != 'global' | summarize ResourceCount=count() by Region=tolower(location)"
        try {
            $json = (& az graph query -q $q --subscriptions $subId --first 1000 -o json --only-show-errors 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($json)) {
                foreach ($row in @(($json | ConvertFrom-Json -Depth 50).data)) {
                    [pscustomobject]@{ SubscriptionId = $subId; SubscriptionName = $subName; Region = [string]$row.Region; ResourceCount = [int]$row.ResourceCount }
                }
            }
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
            $scope = "subscriptions/$SubscriptionId/providers/$($provider.Namespace)/locations/$Region"
            $items = Invoke-AzJsonSafe -Arguments @('quota', 'list', '--scope', $scope, '-o', 'json', '--only-show-errors')
            foreach ($item in @($items)) {
                if ($null -eq $item -or -not $item.PSObject.Properties['properties']) { continue }
                $q = Resolve-QuotaApiItem -Item $item
                $applicable = if ($item.properties.PSObject.Properties['isQuotaApplicable']) { [bool]$item.properties.isQuotaApplicable } else { $true }
                [pscustomobject]@{ SubscriptionId = $SubscriptionId; SubscriptionName = $SubscriptionName; Region = $Region; Provider = $provider.Label; QuotaName = $q.Name; Used = $q.Used; Limit = $q.Limit; Unit = $q.Unit; UsagePercent = (Get-UsagePercentValue $q.Used $q.Limit); IsQuotaApplicable = $applicable }
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
        function _Pct([double]$u, [double]$l) { if ($l -le 0) { return $(if ($u -gt 0) { 100.0 } else { 0.0 }) }; [math]::Round(($u / $l) * 100, 2) }

        try {
            $json = (& az vm list-usage --location $region --subscription $subId -o json --only-show-errors 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($json)) {
                foreach ($item in @($json | ConvertFrom-Json -Depth 50)) {
                    $n = _Name $item; $u = [double]$item.currentValue; $l = [double]$item.limit
                    [pscustomobject]@{ SubscriptionId = $subId; SubscriptionName = $subName; Region = $region; Provider = 'Compute'; QuotaName = $n; Used = $u; Limit = $l; Unit = 'Count'; UsagePercent = (_Pct $u $l); IsQuotaApplicable = $true }
                }
            }
        } catch { Write-Warning "Compute quota failed for $subName / $region : $_" }

        try {
            $json = (& az network list-usages --location $region --subscription $subId -o json --only-show-errors 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($json)) {
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
                $scope = "subscriptions/$subId/providers/$($p.Namespace)/locations/$region"
                $json = (& az quota list --scope $scope -o json --only-show-errors 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { continue }
                foreach ($item in @($json | ConvertFrom-Json -Depth 50)) {
                    if ($null -eq $item -or -not $item.PSObject.Properties['properties']) { continue }
                    $props = $item.properties
                    $applicable = if ($props.PSObject.Properties['isQuotaApplicable']) { [bool]$props.isQuotaApplicable } else { $true }
                    $n = _Name $props
                    if ($n -eq 'Unknown' -and $item.name -is [string]) { $n = $item.name }
                    $u = 0.0; $l = 0.0
                    if ($props.PSObject.Properties['usages'] -and $null -ne $props.usages -and $props.usages.PSObject.Properties['value']) { $u = [double]$props.usages.value }
                    if ($props.PSObject.Properties['limit']  -and $null -ne $props.limit  -and $props.limit.PSObject.Properties['value'])  { $l = [double]$props.limit.value }
                    $unit = if ($props.PSObject.Properties['unit'] -and -not [string]::IsNullOrWhiteSpace([string]$props.unit)) { [string]$props.unit } else { 'Count' }
                    [pscustomobject]@{ SubscriptionId = $subId; SubscriptionName = $subName; Region = $region; Provider = $p.Label; QuotaName = $n; Used = $u; Limit = $l; Unit = $unit; UsagePercent = (_Pct $u $l); IsQuotaApplicable = $applicable }
                }
            } catch { Write-Warning "$($p.Label) quota failed for $subName / $region : $_" }
        }
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
$quotaCsvPath         = Join-Path $OutputDir 'quota.csv'
$startTime  = Get-Date
$throttle   = if ($Sequential) { 1 } else { $MaxParallel }
$subsRegions = $null

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

Write-Stage -Number 3 -Name 'Quotas' -Status "Collecting quota data ($($subsRegions.Count) targets)..."
$quotas = @(Get-AzPipelineQuotas -SubsRegions $subsRegions -ThrottleLimit $throttle -Sequential:$Sequential)
$quotas | Sort-Object SubscriptionName, Region, Provider, QuotaName | Export-Csv -Path $quotaCsvPath -NoTypeInformation -Encoding UTF8

$elapsed = (Get-Date) - $startTime
Write-Host ''
Write-Host "Pipeline complete in $($elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Green
Write-Host "  Subscriptions: $subscriptionsCsvPath"
Write-Host "  Regions:       $subsRegionsCsvPath"
Write-Host "  Quotas:        $quotaCsvPath ($($quotas.Count) rows)"

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
