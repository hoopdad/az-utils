[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$OutputPath = (Get-Location).Path,
    [ValidateRange(1, 3650)]
    [int]$DaysBack = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure resource-graph extension is available
$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'yes_without_prompt'
try {
    $extList = (az extension list -o json 2>$null | ConvertFrom-Json)
    $hasGraph = $extList | Where-Object { $_.name -eq 'resource-graph' }
    if (-not $hasGraph) {
        Write-Host "Installing Azure CLI resource-graph extension..." -ForegroundColor Yellow
        az extension add --name resource-graph --only-show-errors
    }
} catch {
    Write-Host "Installing Azure CLI resource-graph extension..." -ForegroundColor Yellow
    az extension add --name resource-graph --only-show-errors
}

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine

    if ($exitCode -ne 0) {
        if ($AllowFailure) {
            return [pscustomobject]@{
                Succeeded = $false
                Data = $null
                Error = $outputText
            }
        }

        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$outputText"
    }

    if ([string]::IsNullOrWhiteSpace($outputText)) {
        return [pscustomobject]@{
            Succeeded = $true
            Data = $null
            Error = $null
        }
    }

    return [pscustomobject]@{
        Succeeded = $true
        Data = $outputText | ConvertFrom-Json
        Error = $null
    }
}

function Add-WarningNote {
    param(
        [System.Collections.Generic.List[string]]$Warnings,
        [string]$Message
    )

    $Warnings.Add($Message) | Out-Null
    Write-Warning $Message
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [ValidateRange(0, 100)]
        [double]$Percentile
    )

    if (-not $Values -or $Values.Count -eq 0) {
        return $null
    }

    $sorted = $Values | Sort-Object
    if ($sorted.Count -eq 1) {
        return [double]$sorted[0]
    }

    $position = (($Percentile / 100) * ($sorted.Count - 1))
    $lowerIndex = [int][Math]::Floor($position)
    $upperIndex = [int][Math]::Ceiling($position)

    if ($lowerIndex -eq $upperIndex) {
        return [double]$sorted[$lowerIndex]
    }

    $weight = $position - $lowerIndex
    return ([double]$sorted[$lowerIndex] + (([double]$sorted[$upperIndex] - [double]$sorted[$lowerIndex]) * $weight))
}

function Get-AverageValue {
    param([double[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) {
        return $null
    }

    $measure = $Values | Measure-Object -Average
    return [double]$measure.Average
}

function Get-MaximumValue {
    param([double[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) {
        return $null
    }

    $measure = $Values | Measure-Object -Maximum
    return [double]$measure.Maximum
}

function Get-FirstNumericValue {
    param([object]$Point)

    foreach ($propertyName in 'average', 'total', 'minimum', 'maximum', 'count') {
        $property = $Point.PSObject.Properties[$propertyName]
        if ($property -and $null -ne $property.Value) {
            return [double]$property.Value
        }
    }

    return $null
}

function Get-MetricStatistics {
    param(
        [Parameter(Mandatory)]
        [object]$MetricResult,
        [Parameter(Mandatory)]
        [string]$MetricName
    )

    $summarySamples = New-Object 'System.Collections.Generic.List[double]'
    $peakSamples = New-Object 'System.Collections.Generic.List[double]'

    foreach ($timeSeries in @($MetricResult.timeseries)) {
        foreach ($point in @($timeSeries.data)) {
            $representativeValue = Get-FirstNumericValue -Point $point

            $averageProperty = $point.PSObject.Properties['average']
            if ($averageProperty -and $null -ne $averageProperty.Value) {
                $summarySamples.Add([double]$averageProperty.Value) | Out-Null
            }
            elseif ($null -ne $representativeValue) {
                $summarySamples.Add([double]$representativeValue) | Out-Null
            }

            $maximumProperty = $point.PSObject.Properties['maximum']
            if ($maximumProperty -and $null -ne $maximumProperty.Value) {
                $peakSamples.Add([double]$maximumProperty.Value) | Out-Null
            }
            elseif ($null -ne $representativeValue) {
                $peakSamples.Add([double]$representativeValue) | Out-Null
            }
        }
    }

    if ($summarySamples.Count -eq 0 -and $peakSamples.Count -eq 0) {
        return $null
    }

    $summaryValues = if ($summarySamples.Count -gt 0) { $summarySamples.ToArray() } else { $peakSamples.ToArray() }
    $maximumValues = if ($peakSamples.Count -gt 0) { $peakSamples.ToArray() } else { $summaryValues }

    return [pscustomobject]@{
        MetricName = $MetricName
        Average = Get-AverageValue -Values $summaryValues
        Maximum = Get-MaximumValue -Values $maximumValues
        P95 = Get-Percentile -Values $summaryValues -Percentile 95
        DataPointCount = $summaryValues.Count
    }
}

function Invoke-MetricQuery {
    param(
        [Parameter(Mandatory)]
        [string]$Subscription,
        [Parameter(Mandatory)]
        [string]$ResourceId,
        [Parameter(Mandatory)]
        [string]$MetricName,
        [Parameter(Mandatory)]
        [string]$StartTime,
        [Parameter(Mandatory)]
        [string]$EndTime,
        [Parameter(Mandatory)]
        [string]$Interval,
        [System.Collections.Generic.List[string]]$Warnings
    )

    $arguments = @(
        'monitor', 'metrics', 'list',
        '--subscription', $Subscription,
        '--resource', $ResourceId,
        '--metric', $MetricName,
        '--aggregation', 'Average', 'Maximum',
        '--start-time', $StartTime,
        '--end-time', $EndTime,
        '--interval', $Interval,
        '--output', 'json',
        '--only-show-errors'
    )

    $result = Invoke-AzCliJson -Arguments $arguments -AllowFailure
    if ($result.Succeeded) {
        return [pscustomobject]@{
            Response = $result.Data
            IntervalUsed = $Interval
        }
    }

    if ($Interval -eq 'PT24H' -and $result.Error -match 'Commonly allowed time grains') {
        Add-WarningNote -Warnings $Warnings -Message "Daily interval was not supported for metric '$MetricName' on resource '$ResourceId'. Retrying with PT1H."
        return Invoke-MetricQuery -Subscription $Subscription -ResourceId $ResourceId -MetricName $MetricName -StartTime $StartTime -EndTime $EndTime -Interval 'PT1H' -Warnings $Warnings
    }

    Add-WarningNote -Warnings $Warnings -Message "Metric query failed for '$MetricName' on resource '$ResourceId': $($result.Error)"
    return $null
}

$scriptName = 'Get-AzUsageTrends'
$errors = New-Object 'System.Collections.Generic.List[string]'
$warnings = New-Object 'System.Collections.Generic.List[string]'
$records = New-Object 'System.Collections.Generic.List[object]'
$resourceTypesFound = [ordered]@{}
$intervalsUsed = New-Object 'System.Collections.Generic.HashSet[string]'

$supportedMetricsByType = [ordered]@{
    'Microsoft.Compute/virtualMachines' = @('Percentage CPU', 'Available Memory Bytes')
    'Microsoft.Web/sites' = @('CpuPercentage', 'MemoryPercentage')
    'Microsoft.Sql/servers/databases' = @('cpu_percent', 'dtu_consumption_percent', 'storage_percent')
    'Microsoft.Storage/storageAccounts' = @('UsedCapacity')
}

$canonicalTypesByLowerName = @{}
foreach ($resourceType in $supportedMetricsByType.Keys) {
    $canonicalTypesByLowerName[$resourceType.ToLowerInvariant()] = $resourceType
    $resourceTypesFound[$resourceType] = 0
}

$currentAccount = (Invoke-AzCliJson -Arguments @('account', 'show', '--output', 'json', '--only-show-errors')).Data
$resolvedSubscriptionId = if ($SubscriptionId) { $SubscriptionId } else { [string]$currentAccount.id }
$resolvedSubscriptionName = if ($currentAccount.name) { [string]$currentAccount.name } else { $null }

$periodEnd = (Get-Date).ToUniversalTime()
$periodStart = $periodEnd.AddDays(-1 * $DaysBack)
$periodStartText = $periodStart.ToString('yyyy-MM-ddTHH:mm:ssZ')
$periodEndText = $periodEnd.ToString('yyyy-MM-ddTHH:mm:ssZ')
$preferredInterval = if ($DaysBack -gt 14) { 'PT24H' } else { 'PT1H' }

$graphQuery = @"
Resources
| where type in~ ('microsoft.compute/virtualmachines', 'microsoft.web/sites', 'microsoft.sql/servers/databases', 'microsoft.storage/storageaccounts')
| project id, name, type, location, resourceGroup
| order by type asc, name asc
"@

$resourceDiscovery = (Invoke-AzCliJson -Arguments @(
    'graph', 'query',
    '--subscriptions', $resolvedSubscriptionId,
    '--graph-query', $graphQuery,
    '--output', 'json',
    '--only-show-errors'
)).Data

$discoveredResources = @($resourceDiscovery.data)
$resourcesByType = @{}
foreach ($resourceType in $supportedMetricsByType.Keys) {
    $resourcesByType[$resourceType] = New-Object 'System.Collections.Generic.List[object]'
}

foreach ($resource in $discoveredResources) {
    $resourceTypeKey = [string]$resource.type
    $canonicalType = $canonicalTypesByLowerName[$resourceTypeKey.ToLowerInvariant()]
    if (-not $canonicalType) {
        continue
    }

    $resourcesByType[$canonicalType].Add($resource) | Out-Null
    $resourceTypesFound[$canonicalType] = [int]$resourceTypesFound[$canonicalType] + 1
}

foreach ($resourceType in $supportedMetricsByType.Keys) {
    if ($resourceTypesFound[$resourceType] -eq 0) {
        Add-WarningNote -Warnings $warnings -Message "No resources of type '$resourceType' were found in subscription '$resolvedSubscriptionId'."
    }
}

foreach ($resourceType in $supportedMetricsByType.Keys) {
    foreach ($resource in $resourcesByType[$resourceType]) {
        foreach ($metricName in $supportedMetricsByType[$resourceType]) {
            $metricQuery = Invoke-MetricQuery -Subscription $resolvedSubscriptionId -ResourceId ([string]$resource.id) -MetricName $metricName -StartTime $periodStartText -EndTime $periodEndText -Interval $preferredInterval -Warnings $warnings
            if (-not $metricQuery) {
                continue
            }

            $intervalsUsed.Add($metricQuery.IntervalUsed) | Out-Null
            $metricPayload = $metricQuery.Response
            $metricValues = @($metricPayload.value)
            if ($metricValues.Count -eq 0) {
                Add-WarningNote -Warnings $warnings -Message "Metric '$metricName' returned no payload for resource '$($resource.id)'."
                continue
            }

            foreach ($metricValue in $metricValues) {
                $statistics = Get-MetricStatistics -MetricResult $metricValue -MetricName $metricName
                if (-not $statistics) {
                    Add-WarningNote -Warnings $warnings -Message "Metric '$metricName' returned no usable datapoints for resource '$($resource.id)'."
                    continue
                }

                $records.Add([pscustomobject][ordered]@{
                    resourceId = [string]$resource.id
                    resourceName = [string]$resource.name
                    resourceType = $resourceType
                    location = [string]$resource.location
                    resourceGroup = [string]$resource.resourceGroup
                    metricName = if ($metricValue.name -and $metricValue.name.value) { [string]$metricValue.name.value } else { $statistics.MetricName }
                    unit = if ($metricValue.unit) { [string]$metricValue.unit } else { 'Unknown' }
                    average = if ($null -ne $statistics.Average) { [Math]::Round([double]$statistics.Average, 2) } else { $null }
                    maximum = if ($null -ne $statistics.Maximum) { [Math]::Round([double]$statistics.Maximum, 2) } else { $null }
                    p95 = if ($null -ne $statistics.P95) { [Math]::Round([double]$statistics.P95, 2) } else { $null }
                    dataPointCount = [int]$statistics.DataPointCount
                }) | Out-Null
            }
        }
    }
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

$outputDirectoryPath = (Resolve-Path -LiteralPath $OutputPath).Path
$outputFile = Join-Path -Path $outputDirectoryPath -ChildPath 'usage-trends.json'

$intervalList = foreach ($intervalValue in ($intervalsUsed | Sort-Object -Unique)) { $intervalValue }
$warningList = foreach ($warningMessage in $warnings) { $warningMessage }
$recordList = foreach ($recordItem in $records) { $recordItem }

$payload = [pscustomobject][ordered]@{
    metadata = [pscustomobject][ordered]@{
        scriptName = $scriptName
        subscriptionId = $resolvedSubscriptionId
        subscriptionName = $resolvedSubscriptionName
        collectedAt = (Get-Date).ToUniversalTime().ToString('o')
        tenantId = if ($currentAccount.tenantId) { [string]$currentAccount.tenantId } else { $null }
        cloud = if ($currentAccount.environmentName) { [string]$currentAccount.environmentName } else { $null }
        outputFile = $outputFile
        intervalsUsed = @($intervalList)
        errors = @($errors)
        warnings = @($warningList)
    }
    summary = [pscustomobject][ordered]@{
        resourceTypesAnalyzed = @($supportedMetricsByType.Keys)
        totalResourcesAnalyzed = $discoveredResources.Count
        periodDays = $DaysBack
        periodStart = $periodStartText
        periodEnd = $periodEndText
        coverageNotes = 'Metrics collected for VMs, App Services, SQL DBs, Storage Accounts'
        resourcesByType = [pscustomobject]$resourceTypesFound
    }
    records = @($recordList)
}

$payload | ConvertTo-Json -Depth 10 | Set-Content -Path $outputFile -Encoding utf8

$resourceTypesWithResources = $supportedMetricsByType.Keys | Where-Object { $resourceTypesFound[$_] -gt 0 }
$highUsageRecords = @(
    $records |
        Where-Object {
            ($_.metricName -match 'percent|cpu|memory' -or $_.unit -match 'Percent') -and
            (([double]$_.p95 -ge 80) -or ([double]$_.maximum -ge 90))
        } |
        Sort-Object -Property p95, maximum -Descending |
        Select-Object -First 10
)

Write-Host "Usage trends written to $outputFile"
Write-Host "Resource types found: $(if ($resourceTypesWithResources.Count -gt 0) { $resourceTypesWithResources -join ', ' } else { 'none' })"
Write-Host "Resources analyzed: $($discoveredResources.Count)"
Write-Host "Metric summaries generated: $($records.Count)"

if ($highUsageRecords.Count -gt 0) {
    Write-Host 'Notable high-usage resources:'
    foreach ($record in $highUsageRecords) {
        Write-Host (" - {0} [{1}] {2}: p95={3}, max={4}" -f $record.resourceName, $record.resourceType, $record.metricName, $record.p95, $record.maximum)
    }
}
else {
    Write-Host 'Notable high-usage resources: none identified.'
}
