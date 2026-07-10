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

function Get-AzErrorCategory {
    param([AllowNull()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return 'Unknown' }
    $text = $Message.ToLowerInvariant()
    if ($text -match 'serviceunavailable|unknowndownstreamfailure|too ?many requests|throttl|timeout|temporar|please retry again|internalservererror|badgateway|gatewaytimeout|connection reset') {
        return 'Transient'
    }
    if ($text -match 'subscriptionnotregistered|invalidresourcenamespace|missingsubscriptionregistration|not registered to|is not registered|azure subscription id .+ not found|resource namespace .+ is invalid|badrequest|notfound') {
        return 'UnsupportedOrUnavailable'
    }
    return 'Other'
}

function Get-QuotaCollectionStatusFromError {
    param([AllowNull()][string]$ErrorText)

    switch (Get-AzErrorCategory -Message $ErrorText) {
        'Transient' { return 'CollectFailedTransient' }
        'UnsupportedOrUnavailable' { return 'SkippedUnsupportedOrUnregistered' }
        default { return 'CollectFailed' }
    }
}

function Get-ShortErrorText {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxLength = 280
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $trimmed = (($Text -replace '\s+', ' ').Trim())
    if ($trimmed.Length -le $MaxLength) { return $trimmed }
    return ($trimmed.Substring(0, $MaxLength) + '...')
}

function Invoke-AzJsonResult {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 6)][int]$MaxAttempts = 3,
        [ValidateRange(1, 30)][int]$InitialRetryDelaySeconds = 2
    )

    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        Write-DebugLog "az $($Arguments -join ' ') (attempt $attempt/$MaxAttempts)"
        $raw = & az @Arguments 2>&1
        $text = ($raw | Out-String).Trim()
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            if ([string]::IsNullOrWhiteSpace($text)) {
                return [pscustomobject]@{
                    Success = $true; Data = $null; ExitCode = 0; ErrorText = $null; Category = 'None'; Attempts = $attempt
                }
            }
            try {
                return [pscustomobject]@{
                    Success = $true; Data = ($text | ConvertFrom-Json -Depth 100); ExitCode = 0; ErrorText = $null; Category = 'None'; Attempts = $attempt
                }
            }
            catch {
                return [pscustomobject]@{
                    Success = $false; Data = $null; ExitCode = 0; ErrorText = "Failed to parse JSON output: $_"; Category = 'Other'; Attempts = $attempt
                }
            }
        }

        $category = Get-AzErrorCategory -Message $text
        if ($category -eq 'Transient' -and $attempt -lt $MaxAttempts) {
            $delay = [int][math]::Ceiling($InitialRetryDelaySeconds * [math]::Pow(2, ($attempt - 1)))
            Write-DebugLog "Transient az failure; retrying in ${delay}s. Message: $(Get-ShortErrorText -Text $text -MaxLength 160)"
            Start-Sleep -Seconds $delay
            continue
        }

        return [pscustomobject]@{
            Success = $false; Data = $null; ExitCode = $exitCode; ErrorText = $text; Category = $category; Attempts = $attempt
        }
    }

    return [pscustomobject]@{
        Success = $false; Data = $null; ExitCode = -1; ErrorText = 'Azure CLI command failed after retries.'; Category = 'Other'; Attempts = $attempt
    }
}

function Invoke-AzJsonSafe {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = Invoke-AzJsonResult -Arguments $Arguments
    if (-not $result.Success) {
        throw "az $($Arguments -join ' ') failed with exit code $($result.ExitCode) ($($result.Category)). $($result.ErrorText)"
    }
    return $result.Data
}

function Invoke-AzRestJsonSafe {
    param([Parameter(Mandatory)][string]$Url)

    $maxAttempts = 3
    $attempt = 0
    while ($attempt -lt $maxAttempts) {
        $attempt++
        Write-DebugLog "az rest --method get --url $Url (attempt $attempt/$maxAttempts)"
        $raw = & az rest --method get --url $Url -o json --only-show-errors 2>&1
        $text = ($raw | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
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

        $category = Get-AzErrorCategory -Message $text
        if ($category -eq 'Transient' -and $attempt -lt $maxAttempts) {
            $delay = [int][math]::Ceiling(2 * [math]::Pow(2, ($attempt - 1)))
            Write-DebugLog "Transient az rest failure; retrying in ${delay}s. Message: $(Get-ShortErrorText -Text $text -MaxLength 160)"
            Start-Sleep -Seconds $delay
            continue
        }
        throw "az rest --method get --url $Url failed with exit code $exitCode ($category). $text"
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
        [AllowNull()][AllowEmptyCollection()][object[]]$Groups,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Groups) { return 0.0 }
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

function Normalize-QuotaMetricValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try { $number = [double]$Value } catch { return $null }
    if ($number -gt 1000000000) { return $null }
    if ($number -lt 0) { return $null }
    return $number
}

function Get-UsagePercentValue ([object]$Used, [object]$Limit) {
    $usedValue = Normalize-QuotaMetricValue -Value $Used
    $limitValue = Normalize-QuotaMetricValue -Value $Limit
    if ($null -eq $usedValue -or $null -eq $limitValue) { return $null }
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
        return [pscustomobject]@{
            Lookup = $lookup
            Success = $false
            ErrorText = $_.Exception.Message
        }
    }
    foreach ($item in @($items)) {
        if ($null -eq $item -or -not $item.PSObject.Properties['properties']) { continue }
        $key = Get-QuotaItemKey -Item $item
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($item.properties.PSObject.Properties['usages'] -and $null -ne $item.properties.usages -and $item.properties.usages.PSObject.Properties['value']) {
            $lookup[$key] = [double]$item.properties.usages.value
        }
    }
    return [pscustomobject]@{
        Lookup = $lookup
        Success = $true
        ErrorText = $null
    }
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
        [Parameter(Mandatory)][bool]$IsQuotaApplicable,
        [string]$CollectionStatus = 'Collected',
        [AllowNull()][string]$CollectionDetail = $null,
        [ValidateSet('Quota', 'Status')][string]$RowType = 'Quota',
        [AllowNull()][string]$NotApplicableReason = $null
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
        Available = $null
        UsagePercent = (Get-UsagePercentValue $Used $Limit)
        IsQuotaApplicable = $IsQuotaApplicable
        NotApplicableReason = $NotApplicableReason
        RowType = $RowType
        CustomerStatus = $null
        CollectionStatus = $CollectionStatus
        CollectionDetail = $CollectionDetail
    }
}

function New-QuotaStatusRow {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$SubscriptionName,
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$CollectionStatus,
        [AllowNull()][string]$CollectionDetail
    )

    New-QuotaRow -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Region $Region -Provider $Provider -QuotaName 'Collection status' -Used $null -Limit $null -Unit 'N/A' -IsQuotaApplicable $false -CollectionStatus $CollectionStatus -CollectionDetail $CollectionDetail -RowType 'Status' -NotApplicableReason 'StatusOnly'
}

function Normalize-QuotaRow {
    param([Parameter(Mandatory)][object]$Row)

    if (-not $Row.PSObject.Properties['CollectionStatus']) {
        $Row | Add-Member -NotePropertyName CollectionStatus -NotePropertyValue 'Collected'
    }
    if (-not $Row.PSObject.Properties['CollectionDetail']) {
        $Row | Add-Member -NotePropertyName CollectionDetail -NotePropertyValue $null
    }
    if (-not $Row.PSObject.Properties['RowType']) {
        $Row | Add-Member -NotePropertyName RowType -NotePropertyValue 'Quota'
    }
    if (-not $Row.PSObject.Properties['NotApplicableReason']) {
        $Row | Add-Member -NotePropertyName NotApplicableReason -NotePropertyValue $null
    }
    if (-not $Row.PSObject.Properties['Available']) {
        $Row | Add-Member -NotePropertyName Available -NotePropertyValue $null
    }
    if (-not $Row.PSObject.Properties['CustomerStatus']) {
        $Row | Add-Member -NotePropertyName CustomerStatus -NotePropertyValue $null
    }

    $hadSentinel = $false
    foreach ($metric in @('Used', 'Limit')) {
        if (-not $Row.PSObject.Properties[$metric]) { continue }
        $normalized = Normalize-QuotaMetricValue -Value $Row.$metric
        if ($null -ne $Row.$metric -and -not [string]::IsNullOrWhiteSpace([string]$Row.$metric) -and $null -eq $normalized) {
            $hadSentinel = $true
        }
        $Row.$metric = $normalized
    }

    if ($hadSentinel) {
        if ($Row.PSObject.Properties['IsQuotaApplicable']) { $Row.IsQuotaApplicable = $false }
        if ([string]::IsNullOrWhiteSpace([string]$Row.CollectionStatus) -or [string]$Row.CollectionStatus -eq 'Collected') {
            $Row.CollectionStatus = 'CollectedWithSentinelNormalization'
        }
        if ([string]::IsNullOrWhiteSpace([string]$Row.CollectionDetail)) {
            $Row.CollectionDetail = 'Provider returned negative sentinel values; normalized to blank.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$Row.NotApplicableReason)) {
            $Row.NotApplicableReason = 'ProviderSentinelValue'
        }
    }

    if ($Row.PSObject.Properties['CollectionDetail']) {
        $Row.CollectionDetail = Get-ShortErrorText -Text ([string]$Row.CollectionDetail) -MaxLength 280
    }

    if ($Row.PSObject.Properties['IsQuotaApplicable'] -and -not [bool]$Row.IsQuotaApplicable) {
        if ([string]::IsNullOrWhiteSpace([string]$Row.NotApplicableReason)) {
            $Row.NotApplicableReason = 'NotApplicable'
        }
        $Row.UsagePercent = $null
        $Row.Available = $null
    }
    else {
        if ($Row.PSObject.Properties['UsagePercent']) {
            $Row.UsagePercent = Get-UsagePercentValue -Used $Row.Used -Limit $Row.Limit
        }
        else {
            $Row | Add-Member -NotePropertyName UsagePercent -NotePropertyValue (Get-UsagePercentValue -Used $Row.Used -Limit $Row.Limit)
        }
        $usedValue = Normalize-QuotaMetricValue -Value $Row.Used
        $limitValue = Normalize-QuotaMetricValue -Value $Row.Limit
        if ($null -eq $usedValue -or $null -eq $limitValue) {
            $Row.Available = $null
        }
        else {
            $Row.Available = [math]::Round(($limitValue - $usedValue), 2)
        }
    }

    $statusMap = @{
        'Collected' = 'Collected'
        'CollectedWithSentinelNormalization' = 'CollectedNormalized'
        'CollectedWithMissingUsage' = 'CollectedMissingUsage'
        'CollectedWithPartialSourceFailure' = 'CollectedPartial'
        'NoQuotaData' = 'NotCollectedNoData'
        'SkippedNotRegistered' = 'NotCollectedNotRegistered'
        'SkippedUnsupportedOrUnregistered' = 'NotCollectedUnsupported'
        'CollectFailedTransient' = 'NotCollectedTransient'
        'CollectFailed' = 'NotCollectedFailed'
    }
    $statusKey = [string]$Row.CollectionStatus
    $Row.CustomerStatus = if ($statusMap.ContainsKey($statusKey)) { $statusMap[$statusKey] } else { 'Unknown' }

    return $Row
}

#endregion

#region ── Provider Configuration ─────────────────────────────────────

# Additional quota providers queried via the Azure Quota API (az quota list).
# Compute and Network use dedicated CLI commands for richer data. Some services
# such as SQL and messaging do not work through Microsoft.Quota and are handled
# by service-specific fallback collection below.
# To add a provider: append @{ Label = 'Display Name'; Namespace = 'Microsoft.Provider' }
$script:QuotaApiProviders = @(
    @{ Label = 'Machine Learning';           Namespace = 'Microsoft.MachineLearningServices' }
    @{ Label = 'Storage';                    Namespace = 'Microsoft.Storage' }
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

    $u = $null; $l = $null
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
        [Parameter(Mandatory)][string]$Region,
        [AllowNull()][hashtable]$ProviderReadinessLookup = $null
    )

    # Compute
    try {
        $items = Invoke-AzJsonSafe -Arguments @('vm', 'list-usage', '--location', $Region, '--subscription', $SubscriptionId, '-o', 'json', '--only-show-errors')
        foreach ($item in @($items)) {
            if ($null -eq $item) { continue }
            $n = Resolve-QuotaName -Item $item; $u = [double]$item.currentValue; $l = [double]$item.limit
            $isApplicable = ($l -gt 0)
            $reason = if ($isApplicable) { $null } else { 'ZeroLimitOrNotAvailableInRegion' }
            New-QuotaRow -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Region $Region -Provider 'Compute' -QuotaName $n -Used $u -Limit $l -Unit 'Count' -IsQuotaApplicable $isApplicable -NotApplicableReason $reason
        }
    }
    catch {
        Write-Warning "Compute quota failed for $SubscriptionName / $Region : $_"
        $detail = Get-ShortErrorText -Text $_.Exception.Message
        $status = Get-QuotaCollectionStatusFromError -ErrorText $_.Exception.Message
        New-QuotaStatusRow -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Region $Region -Provider 'Compute' -CollectionStatus $status -CollectionDetail $detail
    }

    # Network
    try {
        $items = Invoke-AzJsonSafe -Arguments @('network', 'list-usages', '--location', $Region, '--subscription', $SubscriptionId, '-o', 'json', '--only-show-errors')
        foreach ($item in @($items)) {
            if ($null -eq $item) { continue }
            $n = Resolve-QuotaName -Item $item; $u = [double]$item.currentValue; $l = [double]$item.limit
            $unit = if ($item.PSObject.Properties['unit'] -and -not [string]::IsNullOrWhiteSpace([string]$item.unit)) { [string]$item.unit } else { 'Count' }
            $isApplicable = ($l -gt 0)
            $reason = if ($isApplicable) { $null } else { 'ZeroLimitOrNotAvailableInRegion' }
            New-QuotaRow -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Region $Region -Provider 'Network' -QuotaName $n -Used $u -Limit $l -Unit $unit -IsQuotaApplicable $isApplicable -NotApplicableReason $reason
        }
    }
    catch {
        Write-Warning "Network quota failed for $SubscriptionName / $Region : $_"
        $detail = Get-ShortErrorText -Text $_.Exception.Message
        $status = Get-QuotaCollectionStatusFromError -ErrorText $_.Exception.Message
        New-QuotaStatusRow -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Region $Region -Provider 'Network' -CollectionStatus $status -CollectionDetail $detail
    }

    # Additional providers via Azure Quota API
    foreach ($provider in $script:QuotaApiProviders) {
        $readinessKey = ("{0}|{1}" -f $SubscriptionId, $provider.Namespace).ToLowerInvariant()
        if ($ProviderReadinessLookup -and $ProviderReadinessLookup.ContainsKey($readinessKey) -and -not [bool]$ProviderReadinessLookup[$readinessKey]) {
            New-QuotaStatusRow -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Region $Region -Provider $provider.Label -CollectionStatus 'SkippedNotRegistered' -CollectionDetail "Provider namespace $($provider.Namespace) is not registered for this subscription."
            continue
        }
        try {
            $scope = Get-QuotaScope -SubscriptionId $SubscriptionId -ProviderNamespace $provider.Namespace -Region $Region
            $usageResult = Get-QuotaUsageLookup -Scope $scope
            $usageLookup = $usageResult.Lookup
            $items = Invoke-AzJsonSafe -Arguments @('quota', 'list', '--scope', $scope, '-o', 'json', '--only-show-errors')
            if (@($items).Count -eq 0) {
                New-QuotaStatusRow -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Region $Region -Provider $provider.Label -CollectionStatus 'NoQuotaData' -CollectionDetail 'Quota API returned no rows for this provider and region.'
                continue
            }
            foreach ($item in @($items)) {
                if ($null -eq $item -or -not $item.PSObject.Properties['properties']) { continue }
                $q = Resolve-QuotaApiItem -Item $item
                $used = Resolve-QuotaUsageValue -Item $item -UsageLookup $usageLookup
                $applicable = if ($item.properties.PSObject.Properties['isQuotaApplicable']) { [bool]$item.properties.isQuotaApplicable } else { $true }
                $status = 'Collected'
                $detail = $null
                if (-not $usageResult.Success -and $null -eq $used) {
                    $status = 'CollectedWithMissingUsage'
                    $detail = 'Usage endpoint failed; quota list values were collected.'
                }
                New-QuotaRow -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Region $Region -Provider $provider.Label -QuotaName $q.Name -Used $used -Limit $q.Limit -Unit $q.Unit -IsQuotaApplicable $applicable -CollectionStatus $status -CollectionDetail $detail
            }
        }
        catch {
            Write-Warning "$($provider.Label) quota failed for $SubscriptionName / $Region : $_"
            $detail = Get-ShortErrorText -Text $_.Exception.Message
            $status = Get-QuotaCollectionStatusFromError -ErrorText $_.Exception.Message
            New-QuotaStatusRow -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Region $Region -Provider $provider.Label -CollectionStatus $status -CollectionDetail $detail
        }
    }
}

function Get-AzPipelineQuotas {
    param(
        [Parameter(Mandatory)][object[]]$SubsRegions,
        [int]$ThrottleLimit = 8,
        [switch]$Sequential,
        [AllowNull()][object[]]$ProviderRegistrations = $null
    )

    $total = $SubsRegions.Count
    $providerReadinessLookup = @{}
    foreach ($registration in @($ProviderRegistrations)) {
        if ($null -eq $registration) { continue }
        if (-not $registration.PSObject.Properties['SubscriptionId'] -or -not $registration.PSObject.Properties['ProviderNamespace']) { continue }
        $lookupKey = ("{0}|{1}" -f [string]$registration.SubscriptionId, [string]$registration.ProviderNamespace).ToLowerInvariant()
        $providerReadinessLookup[$lookupKey] = [bool]$registration.Ready
    }

    if ($Sequential -or $total -le 1) {
        $i = 0
        $results = foreach ($item in $SubsRegions) {
            $i++; Write-Host "  [$i/$total] $($item.SubscriptionName) / $($item.Region)"
            Get-QuotasForRegion -SubscriptionId $item.SubscriptionId -SubscriptionName $item.SubscriptionName -Region $item.Region -ProviderReadinessLookup $providerReadinessLookup
        }
        return @($results | Where-Object { $null -ne $_ })
    }

    Write-Host "  Collecting $total subscription-region combos ($ThrottleLimit parallel)..."
    $quotaProviders = $script:QuotaApiProviders
    $readinessLookup = $providerReadinessLookup
    $results = $SubsRegions | ForEach-Object -Parallel {
        $subId = [string]$_.SubscriptionId; $subName = [string]$_.SubscriptionName; $region = [string]$_.Region
        $providers = $using:quotaProviders
        $providerLookup = $using:readinessLookup

        function _Normalize($value) {
            if ($null -eq $value) { return $null }
            if ([string]::IsNullOrWhiteSpace([string]$value)) { return $null }
            try { $number = [double]$value } catch { return $null }
            if ($number -gt 1000000000) { return $null }
            if ($number -lt 0) { return $null }
            return $number
        }
        function _Pct($u, $l) {
            $uv = _Normalize $u
            $lv = _Normalize $l
            if ($null -eq $uv -or $null -eq $lv) { return $null }
            if ($lv -le 0) { return $(if ($uv -gt 0) { 100.0 } else { 0.0 }) }
            [math]::Round(($uv / $lv) * 100, 2)
        }
        function _Name($item) {
            if ($item.PSObject.Properties['localName'] -and -not [string]::IsNullOrWhiteSpace([string]$item.localName)) { return [string]$item.localName }
            if ($null -ne $item.name) {
                if ($item.name -is [string]) { return $item.name }
                if ($item.name.PSObject.Properties['localizedValue'] -and -not [string]::IsNullOrWhiteSpace([string]$item.name.localizedValue)) { return [string]$item.name.localizedValue }
                if ($item.name.PSObject.Properties['value']) { return [string]$item.name.value }
            }
            return 'Unknown'
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
        function _ErrorCategory([AllowNull()][string]$message) {
            if ([string]::IsNullOrWhiteSpace($message)) { return 'Unknown' }
            $text = $message.ToLowerInvariant()
            if ($text -match 'serviceunavailable|unknowndownstreamfailure|too ?many requests|throttl|timeout|temporar|please retry again|internalservererror|badgateway|gatewaytimeout|connection reset') { return 'Transient' }
            if ($text -match 'subscriptionnotregistered|invalidresourcenamespace|missingsubscriptionregistration|not registered to|is not registered|azure subscription id .+ not found|resource namespace .+ is invalid|badrequest|notfound') { return 'UnsupportedOrUnavailable' }
            return 'Other'
        }
        function _StatusFromError([AllowNull()][string]$message) {
            switch (_ErrorCategory $message) {
                'Transient' { 'CollectFailedTransient' }
                'UnsupportedOrUnavailable' { 'SkippedUnsupportedOrUnregistered' }
                default { 'CollectFailed' }
            }
        }
        function _Short([AllowNull()][string]$text, [int]$maxLength = 280) {
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            $trimmed = (($text -replace '\s+', ' ').Trim())
            if ($trimmed.Length -le $maxLength) { return $trimmed }
            return ($trimmed.Substring(0, $maxLength) + '...')
        }
        function _InvokeJson([string[]]$arguments) {
            $maxAttempts = 3
            $attempt = 0
            while ($attempt -lt $maxAttempts) {
                $attempt++
                $text = (& az @arguments 2>&1 | Out-String).Trim()
                $exitCode = $LASTEXITCODE
                if ($exitCode -eq 0) {
                    if ([string]::IsNullOrWhiteSpace($text)) {
                        return [pscustomobject]@{ Success = $true; Data = $null; ErrorText = $null; Category = 'None'; ExitCode = 0; Attempts = $attempt }
                    }
                    try {
                        return [pscustomobject]@{ Success = $true; Data = ($text | ConvertFrom-Json -Depth 50); ErrorText = $null; Category = 'None'; ExitCode = 0; Attempts = $attempt }
                    }
                    catch {
                        return [pscustomobject]@{ Success = $false; Data = $null; ErrorText = "Failed to parse JSON output: $_"; Category = 'Other'; ExitCode = 0; Attempts = $attempt }
                    }
                }
                $category = _ErrorCategory $text
                if ($category -eq 'Transient' -and $attempt -lt $maxAttempts) {
                    Start-Sleep -Seconds ([int][math]::Ceiling(2 * [math]::Pow(2, ($attempt - 1))))
                    continue
                }
                return [pscustomobject]@{ Success = $false; Data = $null; ErrorText = $text; Category = $category; ExitCode = $exitCode; Attempts = $attempt }
            }
            return [pscustomobject]@{ Success = $false; Data = $null; ErrorText = 'Azure CLI command failed after retries.'; Category = 'Other'; ExitCode = -1; Attempts = $attempt }
        }
        function _QuotaRow([string]$provider, [string]$quotaName, [object]$used, [object]$limit, [string]$unit, [bool]$isApplicable, [string]$status = 'Collected', [AllowNull()][string]$detail = $null, [AllowNull()][string]$notApplicableReason = $null) {
            [pscustomobject]@{
                SubscriptionId = $subId
                SubscriptionName = $subName
                Region = $region
                Provider = $provider
                QuotaName = $quotaName
                Used = $used
                Limit = $limit
                Unit = $unit
                Available = $null
                UsagePercent = (_Pct $used $limit)
                IsQuotaApplicable = $isApplicable
                NotApplicableReason = $notApplicableReason
                RowType = 'Quota'
                CustomerStatus = $null
                CollectionStatus = $status
                CollectionDetail = $detail
            }
        }
        function _StatusRow([string]$provider, [string]$status, [AllowNull()][string]$detail) {
            [pscustomobject]@{
                SubscriptionId = $subId
                SubscriptionName = $subName
                Region = $region
                Provider = $provider
                QuotaName = 'Collection status'
                Used = $null
                Limit = $null
                Unit = 'N/A'
                Available = $null
                UsagePercent = $null
                IsQuotaApplicable = $false
                NotApplicableReason = 'StatusOnly'
                RowType = 'Status'
                CustomerStatus = $null
                CollectionStatus = $status
                CollectionDetail = $detail
            }
        }

        $compute = _InvokeJson @('vm', 'list-usage', '--location', $region, '--subscription', $subId, '-o', 'json', '--only-show-errors')
        if (-not $compute.Success) {
            Write-Warning "Compute quota failed for $subName / $region : $($compute.ErrorText)"
            _StatusRow -provider 'Compute' -status (_StatusFromError $compute.ErrorText) -detail (_Short $compute.ErrorText)
        }
        else {
            foreach ($item in @($compute.Data)) {
                if ($null -eq $item) { continue }
                $n = _Name $item; $u = [double]$item.currentValue; $l = [double]$item.limit
                $isApplicable = ($l -gt 0)
                $reason = if ($isApplicable) { $null } else { 'ZeroLimitOrNotAvailableInRegion' }
                _QuotaRow -provider 'Compute' -quotaName $n -used $u -limit $l -unit 'Count' -isApplicable $isApplicable -notApplicableReason $reason
            }
        }

        $network = _InvokeJson @('network', 'list-usages', '--location', $region, '--subscription', $subId, '-o', 'json', '--only-show-errors')
        if (-not $network.Success) {
            Write-Warning "Network quota failed for $subName / $region : $($network.ErrorText)"
            _StatusRow -provider 'Network' -status (_StatusFromError $network.ErrorText) -detail (_Short $network.ErrorText)
        }
        else {
            foreach ($item in @($network.Data)) {
                if ($null -eq $item) { continue }
                $n = _Name $item; $u = [double]$item.currentValue; $l = [double]$item.limit
                $unit = if ($item.PSObject.Properties['unit'] -and -not [string]::IsNullOrWhiteSpace([string]$item.unit)) { [string]$item.unit } else { 'Count' }
                $isApplicable = ($l -gt 0)
                $reason = if ($isApplicable) { $null } else { 'ZeroLimitOrNotAvailableInRegion' }
                _QuotaRow -provider 'Network' -quotaName $n -used $u -limit $l -unit $unit -isApplicable $isApplicable -notApplicableReason $reason
            }
        }

        foreach ($p in $providers) {
            $lookupKey = ("{0}|{1}" -f $subId, $p.Namespace).ToLowerInvariant()
            if ($providerLookup.ContainsKey($lookupKey) -and -not [bool]$providerLookup[$lookupKey]) {
                _StatusRow -provider $p.Label -status 'SkippedNotRegistered' -detail "Provider namespace $($p.Namespace) is not registered for this subscription."
                continue
            }

            $scope = "/subscriptions/$subId/providers/$($p.Namespace)/locations/$region"
            $usageLookup = @{}
            $usageResult = _InvokeJson @('quota', 'usage', 'list', '--scope', $scope, '-o', 'json', '--only-show-errors')
            if (-not $usageResult.Success) {
                Write-Warning "$($p.Label) quota usage query failed for $subName / $region : $($usageResult.ErrorText)"
            }
            else {
                foreach ($usageItem in @($usageResult.Data)) {
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

            $listResult = _InvokeJson @('quota', 'list', '--scope', $scope, '-o', 'json', '--only-show-errors')
            if (-not $listResult.Success) {
                Write-Warning "$($p.Label) quota list failed for $subName / $region : $($listResult.ErrorText)"
                _StatusRow -provider $p.Label -status (_StatusFromError $listResult.ErrorText) -detail (_Short $listResult.ErrorText)
                continue
            }

            if (@($listResult.Data).Count -eq 0) {
                Write-Warning "$($p.Label) quota list returned empty output for $subName / $region"
                _StatusRow -provider $p.Label -status 'NoQuotaData' -detail 'Quota API returned no rows for this provider and region.'
                continue
            }

            foreach ($item in @($listResult.Data)) {
                if ($null -eq $item -or -not $item.PSObject.Properties['properties']) { continue }
                $props = $item.properties
                $applicable = if ($props.PSObject.Properties['isQuotaApplicable']) { [bool]$props.isQuotaApplicable } else { $true }
                $n = _Name $props
                if ($n -eq 'Unknown' -and $item.name -is [string]) { $n = $item.name }
                $u = _UsageValue $item $usageLookup
                $l = 0.0
                if ($props.PSObject.Properties['limit'] -and $null -ne $props.limit -and $props.limit.PSObject.Properties['value']) { $l = [double]$props.limit.value }
                $unit = if ($props.PSObject.Properties['unit'] -and -not [string]::IsNullOrWhiteSpace([string]$props.unit)) { [string]$props.unit } else { 'Count' }

                $status = 'Collected'
                $detail = $null
                if (-not $usageResult.Success -and $null -eq $u) {
                    $status = 'CollectedWithMissingUsage'
                    $detail = 'Usage endpoint failed; quota list values were collected.'
                }
                _QuotaRow -provider $p.Label -quotaName $n -used $u -limit $l -unit $unit -isApplicable $applicable -status $status -detail $detail
            }
        }
    } -ThrottleLimit $ThrottleLimit

    return @($results | Where-Object { $null -ne $_ })
}

function Get-AzPipelineServiceSpecificLimits {
    param(
        [Parameter(Mandatory)][object[]]$SubsRegions,
        [AllowNull()][object[]]$ProviderRegistrations = $null
    )

    $providerReadinessLookup = @{}
    foreach ($registration in @($ProviderRegistrations)) {
        if ($null -eq $registration) { continue }
        if (-not $registration.PSObject.Properties['SubscriptionId'] -or -not $registration.PSObject.Properties['ProviderNamespace']) { continue }
        $lookupKey = ("{0}|{1}" -f [string]$registration.SubscriptionId, [string]$registration.ProviderNamespace).ToLowerInvariant()
        $providerReadinessLookup[$lookupKey] = [bool]$registration.Ready
    }

    function Test-ProviderReady {
        param(
            [Parameter(Mandatory)][string]$SubscriptionId,
            [Parameter(Mandatory)][string]$Namespace
        )

        $lookupKey = ("{0}|{1}" -f $SubscriptionId, $Namespace).ToLowerInvariant()
        if ($providerReadinessLookup.Count -eq 0) { return $true }
        if (-not $providerReadinessLookup.ContainsKey($lookupKey)) { return $true }
        return [bool]$providerReadinessLookup[$lookupKey]
    }

    $subGroups = $SubsRegions | Group-Object SubscriptionId
    foreach ($subGroup in $subGroups) {
        $subId = [string]$subGroup.Name
        $subName = [string](@($subGroup.Group)[0].SubscriptionName)
        $regions = @($subGroup.Group | ForEach-Object { [string]$_.Region } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

        if (Test-ProviderReady -SubscriptionId $subId -Namespace 'Microsoft.Sql') {
            foreach ($region in $regions) {
                $sqlUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Sql/locations/$region/usages?api-version=2023-08-01"
                try {
                    $sqlUsage = Invoke-AzRestJsonSafe -Url $sqlUrl
                }
                catch {
                    $detail = Get-ShortErrorText -Text $_.Exception.Message
                    $status = Get-QuotaCollectionStatusFromError -ErrorText $_.Exception.Message
                    New-QuotaStatusRow -SubscriptionId $subId -SubscriptionName $subName -Region $region -Provider 'Azure SQL' -CollectionStatus $status -CollectionDetail $detail
                    continue
                }

                $emittedSqlRow = $false
                foreach ($item in @($sqlUsage.value)) {
                    if ($null -eq $item -or -not $item.PSObject.Properties['properties']) { continue }
                    if (-not (Test-SqlUsageIsQuotaCapacity -Item $item)) { continue }
                    $props = $item.properties
                    $name = if (-not [string]::IsNullOrWhiteSpace([string]$props.displayName)) { [string]$props.displayName } else { [string]$item.name }
                    $used = if ($props.PSObject.Properties['currentValue']) { [double]$props.currentValue } else { 0.0 }
                    $limit = if ($props.PSObject.Properties['limit']) { [double]$props.limit } else { 0.0 }
                    $unit = if ($props.PSObject.Properties['unit'] -and -not [string]::IsNullOrWhiteSpace([string]$props.unit)) { [string]$props.unit } else { 'Count' }
                    $isApplicable = ($limit -gt 0)
                    $reason = if ($isApplicable) { $null } else { 'ZeroLimitOrNotAvailableInRegion' }
                    New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region $region -Provider 'Azure SQL' -QuotaName $name -Used $used -Limit $limit -Unit $unit -IsQuotaApplicable $isApplicable -NotApplicableReason $reason
                    $emittedSqlRow = $true
                }

                if (-not $emittedSqlRow) {
                    New-QuotaStatusRow -SubscriptionId $subId -SubscriptionName $subName -Region $region -Provider 'Azure SQL' -CollectionStatus 'NoQuotaData' -CollectionDetail 'SQL usage API returned no quota-capacity rows.'
                }
            }
        }
        else {
            foreach ($region in $regions) {
                New-QuotaStatusRow -SubscriptionId $subId -SubscriptionName $subName -Region $region -Provider 'Azure SQL' -CollectionStatus 'SkippedNotRegistered' -CollectionDetail 'Provider namespace Microsoft.Sql is not registered for this subscription.'
            }
        }

        if (Test-ProviderReady -SubscriptionId $subId -Namespace 'Microsoft.DocumentDB') {
            $cosmosUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.DocumentDB/databaseAccounts?api-version=2024-11-15"
            try {
                $cosmos = Invoke-AzRestJsonSafe -Url $cosmosUrl
                $used = @($cosmos.value).Count
                New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region 'global' -Provider 'Azure Cosmos DB' -QuotaName 'Database accounts per subscription (default limit estimate)' -Used $used -Limit 250 -Unit 'Count' -IsQuotaApplicable $false -NotApplicableReason 'DefaultLimitEstimate' -CollectionDetail 'Limit uses documented default and may differ if a quota increase was approved.'
            }
            catch {
                $detail = Get-ShortErrorText -Text $_.Exception.Message
                $status = Get-QuotaCollectionStatusFromError -ErrorText $_.Exception.Message
                New-QuotaStatusRow -SubscriptionId $subId -SubscriptionName $subName -Region 'global' -Provider 'Azure Cosmos DB' -CollectionStatus $status -CollectionDetail $detail
            }
        }
        else {
            New-QuotaStatusRow -SubscriptionId $subId -SubscriptionName $subName -Region 'global' -Provider 'Azure Cosmos DB' -CollectionStatus 'SkippedNotRegistered' -CollectionDetail 'Provider namespace Microsoft.DocumentDB is not registered for this subscription.'
        }

        if (Test-ProviderReady -SubscriptionId $subId -Namespace 'Microsoft.EventHub') {
            $eventHubUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.EventHub/namespaces?api-version=2024-01-01"
            try {
                $eventHubs = Invoke-AzRestJsonSafe -Url $eventHubUrl
                $counts = @($eventHubs.value) | Group-Object { ([string]$_.location).ToLowerInvariant().Replace(' ', '') }
                foreach ($region in $regions) {
                    $used = Get-GroupCountByName -Groups $counts -Name $region
                    New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region $region -Provider 'Azure Event Hubs' -QuotaName 'Namespaces per subscription per region (default limit estimate)' -Used $used -Limit 1000 -Unit 'Count' -IsQuotaApplicable $false -NotApplicableReason 'DefaultLimitEstimate' -CollectionDetail 'Limit uses documented default and may differ if a quota increase was approved.'
                }
            }
            catch {
                $detail = Get-ShortErrorText -Text $_.Exception.Message
                $status = Get-QuotaCollectionStatusFromError -ErrorText $_.Exception.Message
                foreach ($region in $regions) {
                    New-QuotaStatusRow -SubscriptionId $subId -SubscriptionName $subName -Region $region -Provider 'Azure Event Hubs' -CollectionStatus $status -CollectionDetail $detail
                }
            }
        }
        else {
            foreach ($region in $regions) {
                New-QuotaStatusRow -SubscriptionId $subId -SubscriptionName $subName -Region $region -Provider 'Azure Event Hubs' -CollectionStatus 'SkippedNotRegistered' -CollectionDetail 'Provider namespace Microsoft.EventHub is not registered for this subscription.'
            }
        }

        if (Test-ProviderReady -SubscriptionId $subId -Namespace 'Microsoft.ServiceBus') {
            $serviceBusUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.ServiceBus/namespaces?api-version=2024-01-01"
            try {
                $serviceBus = Invoke-AzRestJsonSafe -Url $serviceBusUrl
                $counts = @($serviceBus.value) | Group-Object { ([string]$_.location).ToLowerInvariant().Replace(' ', '') }
                foreach ($region in $regions) {
                    $used = Get-GroupCountByName -Groups $counts -Name $region
                    New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region $region -Provider 'Azure Service Bus' -QuotaName 'Namespaces per subscription per region (default limit estimate)' -Used $used -Limit 1000 -Unit 'Count' -IsQuotaApplicable $false -NotApplicableReason 'DefaultLimitEstimate' -CollectionDetail 'Limit uses documented default and may differ if a quota increase was approved.'
                }
            }
            catch {
                $detail = Get-ShortErrorText -Text $_.Exception.Message
                $status = Get-QuotaCollectionStatusFromError -ErrorText $_.Exception.Message
                foreach ($region in $regions) {
                    New-QuotaStatusRow -SubscriptionId $subId -SubscriptionName $subName -Region $region -Provider 'Azure Service Bus' -CollectionStatus $status -CollectionDetail $detail
                }
            }
        }
        else {
            foreach ($region in $regions) {
                New-QuotaStatusRow -SubscriptionId $subId -SubscriptionName $subName -Region $region -Provider 'Azure Service Bus' -CollectionStatus 'SkippedNotRegistered' -CollectionDetail 'Provider namespace Microsoft.ServiceBus is not registered for this subscription.'
            }
        }

        if (Test-ProviderReady -SubscriptionId $subId -Namespace 'Microsoft.ApiManagement') {
            $apimUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.ApiManagement/service?api-version=2024-05-01"
            try {
                $apim = Invoke-AzRestJsonSafe -Url $apimUrl
                $items = @($apim.value)
                if ($items.Count -eq 0) {
                    New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region 'global' -Provider 'API Management' -QuotaName 'Service instances inventory (limits are per instance/tier)' -Used 0 -Limit 0 -Unit 'Count' -IsQuotaApplicable $false -NotApplicableReason 'PerInstanceLimit'
                }
                else {
                    foreach ($group in ($items | Group-Object { ([string]$_.location).ToLowerInvariant().Replace(' ', '') })) {
                        New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region $group.Name -Provider 'API Management' -QuotaName 'Service instances inventory (limits are per instance/tier)' -Used ([double]$group.Count) -Limit 0 -Unit 'Count' -IsQuotaApplicable $false -NotApplicableReason 'PerInstanceLimit'
                    }
                }
            }
            catch {
                $detail = Get-ShortErrorText -Text $_.Exception.Message
                $status = Get-QuotaCollectionStatusFromError -ErrorText $_.Exception.Message
                New-QuotaStatusRow -SubscriptionId $subId -SubscriptionName $subName -Region 'global' -Provider 'API Management' -CollectionStatus $status -CollectionDetail $detail
            }
        }
        else {
            New-QuotaStatusRow -SubscriptionId $subId -SubscriptionName $subName -Region 'global' -Provider 'API Management' -CollectionStatus 'SkippedNotRegistered' -CollectionDetail 'Provider namespace Microsoft.ApiManagement is not registered for this subscription.'
        }

        if (Test-ProviderReady -SubscriptionId $subId -Namespace 'Microsoft.DBforPostgreSQL') {
            $postgresFlexibleUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.DBforPostgreSQL/flexibleServers?api-version=2024-08-01"
            $postgresSingleUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.DBforPostgreSQL/servers?api-version=2017-12-01"
            $postgresFlexible = $null
            $postgresSingle = $null
            $postgresErrors = @()

            try { $postgresFlexible = Invoke-AzRestJsonSafe -Url $postgresFlexibleUrl } catch { $postgresErrors += $_.Exception.Message }
            try { $postgresSingle = Invoke-AzRestJsonSafe -Url $postgresSingleUrl } catch { $postgresErrors += $_.Exception.Message }

            if ($null -eq $postgresFlexible -and $null -eq $postgresSingle) {
                $errorText = ($postgresErrors -join ' | ')
                $detail = Get-ShortErrorText -Text $errorText
                $status = Get-QuotaCollectionStatusFromError -ErrorText $errorText
                New-QuotaStatusRow -SubscriptionId $subId -SubscriptionName $subName -Region 'global' -Provider 'Azure PostgreSQL' -CollectionStatus $status -CollectionDetail $detail
            }
            else {
                $postgresItems = @()
                if ($postgresFlexible) { $postgresItems += @($postgresFlexible.value) }
                if ($postgresSingle) { $postgresItems += @($postgresSingle.value) }
                $partialStatus = if ($postgresErrors.Count -gt 0) { 'CollectedWithPartialSourceFailure' } else { 'Collected' }
                $partialDetail = if ($postgresErrors.Count -gt 0) { Get-ShortErrorText -Text (($postgresErrors -join ' | ')) } else { $null }

                if ($postgresItems.Count -eq 0) {
                    New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region 'global' -Provider 'Azure PostgreSQL' -QuotaName 'Servers inventory (service quota API unavailable)' -Used 0 -Limit 0 -Unit 'Count' -IsQuotaApplicable $false -NotApplicableReason 'InventoryOnly' -CollectionStatus $partialStatus -CollectionDetail $partialDetail
                }
                else {
                    foreach ($group in ($postgresItems | Group-Object { ([string]$_.location).ToLowerInvariant().Replace(' ', '') })) {
                        New-QuotaRow -SubscriptionId $subId -SubscriptionName $subName -Region $group.Name -Provider 'Azure PostgreSQL' -QuotaName 'Servers inventory (service quota API unavailable)' -Used ([double]$group.Count) -Limit 0 -Unit 'Count' -IsQuotaApplicable $false -NotApplicableReason 'InventoryOnly' -CollectionStatus $partialStatus -CollectionDetail $partialDetail
                    }
                }
            }
        }
        else {
            New-QuotaStatusRow -SubscriptionId $subId -SubscriptionName $subName -Region 'global' -Provider 'Azure PostgreSQL' -CollectionStatus 'SkippedNotRegistered' -CollectionDetail 'Provider namespace Microsoft.DBforPostgreSQL is not registered for this subscription.'
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
    Write-Warning "$($notRegistered.Count) provider registration(s) are not Registered. Quota output will include explicit status rows (SkippedNotRegistered) for those providers."
}

Write-Stage -Number 4 -Name 'Quotas' -Status "Collecting quota data ($($subsRegions.Count) targets)..."
$quotas = @(
    Get-AzPipelineQuotas -SubsRegions $subsRegions -ThrottleLimit $throttle -Sequential:$Sequential -ProviderRegistrations $providerRegistrations
    Get-AzPipelineServiceSpecificLimits -SubsRegions $subsRegions -ProviderRegistrations $providerRegistrations
) | ForEach-Object { Normalize-QuotaRow -Row $_ }
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

$warnings = @($quotas | Where-Object { $_.IsQuotaApplicable -and $null -ne $_.UsagePercent -and [double]$_.UsagePercent -gt 80 })
$critical = @($quotas | Where-Object { $_.IsQuotaApplicable -and $null -ne $_.UsagePercent -and [double]$_.UsagePercent -gt 90 })
if ($warnings.Count -gt 0) {
    Write-Host "`n  Quotas >80%: $($warnings.Count)  |  >90%: $($critical.Count)" -ForegroundColor Yellow
    $critical | Sort-Object { [double]$_.UsagePercent } -Descending |
        Select-Object -First 10 SubscriptionName, Region, Provider, QuotaName, Used, Limit, UsagePercent |
        Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
}
else { Write-Host '  No quotas above 80% usage.' -ForegroundColor Green }

#endregion
