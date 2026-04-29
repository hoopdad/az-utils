[CmdletBinding()]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Verify resource-graph extension is available
$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'yes_without_prompt'
try {
    $extList = (az extension list -o json 2>$null | ConvertFrom-Json)
}
catch {
    throw "Unable to verify Azure CLI extensions. $($_.Exception.Message)"
}

$hasGraph = @($extList | Where-Object { $_.name -eq 'resource-graph' }).Count -gt 0
if (-not $hasGraph) {
    throw "Azure CLI resource-graph extension is required. Run 'az extension add --name resource-graph' or use Start-AzCapacityReport.ps1."
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

function Convert-ToNumber {
    param(
        [Parameter(Mandatory)]
        $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [double]0
    }

    return [double]$Value
}

function Get-UsagePercent {
    param(
        [Parameter(Mandatory)]
        [double]$CurrentUsage,

        [Parameter(Mandatory)]
        [double]$Limit
    )

    if ($Limit -le 0) {
        if ($CurrentUsage -le 0) {
            return [double]0
        }

        return [double]100
    }

    return [math]::Round(($CurrentUsage / $Limit) * 100, 2)
}

function New-QuotaRecord {
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$Region,

        [Parameter(Mandatory)]
        [string]$QuotaName,

        [Parameter(Mandatory)]
        [double]$Limit,

        [Parameter(Mandatory)]
        [double]$CurrentUsage,

        [Parameter()]
        [string]$Unit = 'Count'
    )

    [pscustomobject]@{
        provider     = $Provider
        region       = $Region
        quotaName    = $QuotaName
        limit        = $Limit
        currentUsage = $CurrentUsage
        unit         = $Unit
        usagePercent = (Get-UsagePercent -CurrentUsage $CurrentUsage -Limit $Limit)
    }
}

function Get-EffectiveSubscription {
    param(
        [string]$RequestedSubscriptionId
    )

    $accountArgs = @('account', 'show', '--output', 'json', '--only-show-errors')
    if ($RequestedSubscriptionId) {
        $accountArgs += @('--subscription', $RequestedSubscriptionId)
    }

    return Invoke-AzJson -Arguments $accountArgs
}

function Get-ResourceRegions {
    param(
        [Parameter(Mandatory)]
        [string]$EffectiveSubscriptionId
    )

    $query = 'Resources | summarize count() by location'
    $graphResult = Invoke-AzJson -Arguments @('graph', 'query', '-q', $query, '--subscriptions', $EffectiveSubscriptionId, '--output', 'json', '--only-show-errors')

    $regions = @(
        $graphResult.data |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.location) -and
                $_.location.ToString().ToLowerInvariant() -ne 'global'
            } |
            ForEach-Object { $_.location.ToString().ToLowerInvariant() } |
            Sort-Object -Unique
    )

    return $regions
}

function Get-ComputeQuotaRecords {
    param(
        [Parameter(Mandatory)]
        [string[]]$Regions,

        [Parameter(Mandatory)]
        [string]$EffectiveSubscriptionId
    )

    $records = New-Object System.Collections.Generic.List[object]

    foreach ($region in $Regions) {
        $usageItems = Invoke-AzJson -Arguments @('vm', 'list-usage', '--location', $region, '--subscription', $EffectiveSubscriptionId, '--output', 'json', '--only-show-errors')

        foreach ($item in $usageItems) {
            $quotaName = if ($item.localName) { $item.localName } else { $item.name.localizedValue }
            if ($quotaName -notmatch 'vCPUs') {
                continue
            }

            $records.Add((New-QuotaRecord -Provider 'Compute' -Region $region -QuotaName $quotaName -Limit (Convert-ToNumber $item.limit) -CurrentUsage (Convert-ToNumber $item.currentValue) -Unit 'Count'))
        }
    }

    return $records
}

function Get-NetworkQuotaRecords {
    param(
        [Parameter(Mandatory)]
        [string[]]$Regions,

        [Parameter(Mandatory)]
        [string]$EffectiveSubscriptionId
    )

    $records = New-Object System.Collections.Generic.List[object]

    foreach ($region in $Regions) {
        $usageItems = Invoke-AzJson -Arguments @('network', 'list-usages', '--location', $region, '--subscription', $EffectiveSubscriptionId, '--output', 'json', '--only-show-errors')

        foreach ($item in $usageItems) {
            $quotaName = if ($item.localName) { $item.localName } else { $item.name.localizedValue }
            $records.Add((New-QuotaRecord -Provider 'Network' -Region $region -QuotaName $quotaName -Limit (Convert-ToNumber $item.limit) -CurrentUsage (Convert-ToNumber $item.currentValue) -Unit ([string]$item.unit)))
        }
    }

    return $records
}

function Get-StorageQuotaRecord {
    param(
        [Parameter(Mandatory)]
        [string]$EffectiveSubscriptionId
    )

    $storageAccounts = Invoke-AzJson -Arguments @('storage', 'account', 'list', '--subscription', $EffectiveSubscriptionId, '--output', 'json', '--only-show-errors')
    $currentUsage = [double]@($storageAccounts).Count
    $limit = [double]250

    return New-QuotaRecord -Provider 'Storage' -Region 'global' -QuotaName 'Storage Accounts' -Limit $limit -CurrentUsage $currentUsage -Unit 'Count'
}

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (-not (Test-Path -LiteralPath $resolvedOutputPath)) {
    $null = New-Item -ItemType Directory -Path $resolvedOutputPath -Force
}

$account = Get-EffectiveSubscription -RequestedSubscriptionId $SubscriptionId
$effectiveSubscriptionId = $account.id
$regions = Get-ResourceRegions -EffectiveSubscriptionId $effectiveSubscriptionId

if (-not $regions -or $regions.Count -eq 0) {
    throw 'No Azure regions with resources were discovered for this subscription.'
}

$records = New-Object System.Collections.Generic.List[object]
(Get-ComputeQuotaRecords -Regions $regions -EffectiveSubscriptionId $effectiveSubscriptionId) | ForEach-Object { $records.Add($_) }
(Get-NetworkQuotaRecords -Regions $regions -EffectiveSubscriptionId $effectiveSubscriptionId) | ForEach-Object { $records.Add($_) }
$records.Add((Get-StorageQuotaRecord -EffectiveSubscriptionId $effectiveSubscriptionId))

$allRecords = @($records.ToArray())
$warningRecords = @($allRecords | Where-Object { $_.usagePercent -gt 80 })
$criticalRecords = @($allRecords | Where-Object { $_.usagePercent -gt 90 })
$outputFile = Join-Path -Path $resolvedOutputPath -ChildPath 'quota-usage.json'

$result = [pscustomobject]@{
    metadata = [pscustomobject]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        subscriptionId = $effectiveSubscriptionId
        subscriptionName = $account.name
        tenantId = $account.tenantId
        outputFile = $outputFile
        scriptName = 'Get-AzQuotaUsage.ps1'
    }
    summary = [pscustomobject]@{
        totalQuotasChecked = @($allRecords).Count
        quotasAbove80Percent = @($warningRecords).Count
        quotasAbove90Percent = @($criticalRecords).Count
        regionsChecked = @($regions).Count
        coverageNotes = 'Covers Compute vCPU (regional + per-family), Network, Storage account count'
    }
    records = $allRecords
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outputFile -Encoding utf8

Write-Host "Quota usage written to $outputFile"
Write-Host "Regions checked: $(@($regions).Count)"
Write-Host "Total quotas checked: $(@($allRecords).Count)"
Write-Host "Warnings (>80%): $(@($warningRecords).Count)"
Write-Host "Critical (>90%): $(@($criticalRecords).Count)"

$approachingLimits = @($allRecords | Where-Object { $_.usagePercent -gt 80 } | Sort-Object usagePercent -Descending)
if ($approachingLimits.Count -gt 0) {
    Write-Host 'Quotas approaching limits:'
    $approachingLimits |
        Select-Object provider, region, quotaName, limit, currentUsage, usagePercent |
        Format-Table -AutoSize |
        Out-String |
        Write-Host
}
else {
    Write-Host 'No quotas are currently above 80% usage.'
}
