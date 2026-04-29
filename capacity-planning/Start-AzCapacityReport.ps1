[CmdletBinding(DefaultParameterSetName = 'Single')]
param(
    [Parameter(ParameterSetName = 'Single')]
    [string]$SubscriptionId,

    [Parameter(Mandatory, ParameterSetName = 'File')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$SubscriptionFile,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path,

    [ValidateRange(1, 3650)]
    [int]$DaysBack = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot

$scriptDefs = @(
    @{ Name = 'Service Inventory';     File = 'Get-AzServiceInventory.ps1';     Output = 'service-inventory.json' }
    @{ Name = 'Region Capabilities';   File = 'Get-AzRegionCapabilities.ps1';   Output = 'region-capabilities.json' }
    @{ Name = 'Quota Usage';           File = 'Get-AzQuotaUsage.ps1';           Output = 'quota-usage.json' }
    @{ Name = 'Usage Trends';          File = 'Get-AzUsageTrends.ps1';          Output = 'usage-trends.json' }
    @{ Name = 'Reserved Instances';    File = 'Get-AzReservedInstances.ps1';    Output = 'reserved-instances.json' }
)

function Invoke-CapacityCollection {
    param(
        [string]$SubId,
        [string]$SubName,
        [string]$ReportDir
    )

    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null

    Write-Host "`nSubscription: $SubName ($SubId)" -ForegroundColor Green
    Write-Host "Report directory: $ReportDir"
    Write-Host "Metrics window: $DaysBack days`n"

    $results = @{}

    foreach ($s in $scriptDefs) {
        $scriptPath = Join-Path $scriptDir $s.File
        if (-not (Test-Path $scriptPath)) {
            Write-Host "  [SKIP] $($s.Name) - script not found: $($s.File)" -ForegroundColor Yellow
            $results[$s.Name] = @{ Status = 'skipped'; Error = 'Script not found' }
            continue
        }

        Write-Host "Running: $($s.Name)..." -ForegroundColor Cyan -NoNewline
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            $splatParams = @{
                SubscriptionId = $SubId
                OutputPath     = $ReportDir
            }
            if ($s.Name -eq 'Usage Trends') {
                $splatParams['DaysBack'] = $DaysBack
            }

            & $scriptPath @splatParams
            $sw.Stop()

            $outputFile = Join-Path $ReportDir $s.Output
            if (Test-Path $outputFile) {
                $data = Get-Content $outputFile -Raw | ConvertFrom-Json -Depth 100
                $errs = @()
                $warns = @()
                if ($data.metadata.PSObject.Properties.Name -contains 'errors') { $errs = @($data.metadata.errors) }
                if ($data.metadata.PSObject.Properties.Name -contains 'warnings') { $warns = @($data.metadata.warnings) }
                $results[$s.Name] = @{
                    Status   = 'success'
                    Duration = $sw.Elapsed.TotalSeconds
                    Data     = $data
                    Errors   = $errs
                    Warnings = $warns
                }
                Write-Host " done ($([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" -ForegroundColor Green
            } else {
                $results[$s.Name] = @{ Status = 'no-output'; Duration = $sw.Elapsed.TotalSeconds }
                Write-Host " done (no output file)" -ForegroundColor Yellow
            }
        } catch {
            $sw.Stop()
            $results[$s.Name] = @{ Status = 'failed'; Error = $_.Exception.Message; Duration = $sw.Elapsed.TotalSeconds }
            Write-Host " FAILED ($([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" -ForegroundColor Red
            Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    return $results
}

function New-SubscriptionSummary {
    param(
        [string]$SubId,
        [string]$SubName,
        [string]$ReportDir,
        [hashtable]$Results
    )

    $md = [System.Text.StringBuilder]::new()
    [void]$md.AppendLine("# Azure Capacity Planning Report")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("| Field | Value |")
    [void]$md.AppendLine("|-------|-------|")
    [void]$md.AppendLine("| **Subscription** | $SubName ($SubId) |")
    [void]$md.AppendLine("| **Generated** | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |")
    [void]$md.AppendLine("| **Metrics Window** | $DaysBack days |")
    [void]$md.AppendLine("")

    [void]$md.AppendLine("## Collection Status")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("| Script | Status | Duration | Errors | Warnings |")
    [void]$md.AppendLine("|--------|--------|----------|--------|----------|")
    foreach ($s in $scriptDefs) {
        $r = $Results[$s.Name]
        if ($null -eq $r) { continue }
        $status = $r.Status
        $duration = if ($r.ContainsKey('Duration') -and $r.Duration) { "$([math]::Round($r.Duration, 1))s" } else { '-' }
        $errCount = if ($r.ContainsKey('Errors') -and $r.Errors) { $r.Errors.Count } else { 0 }
        $warnCount = if ($r.ContainsKey('Warnings') -and $r.Warnings) { $r.Warnings.Count } else { 0 }
        $statusIcon = switch ($status) { 'success' { '✅' } 'failed' { '❌' } 'skipped' { '⏭️' } default { '⚠️' } }
        [void]$md.AppendLine("| $($s.Name) | $statusIcon $status | $duration | $errCount | $warnCount |")
    }
    [void]$md.AppendLine("")

    if ($Results['Service Inventory'].Status -eq 'success') {
        $inv = $Results['Service Inventory'].Data
        [void]$md.AppendLine("## Service Inventory")
        [void]$md.AppendLine("")
        [void]$md.AppendLine("- **Total Resources**: $($inv.summary.totalResources)")
        [void]$md.AppendLine("- **Resource Types**: $($inv.summary.uniqueResourceTypes)")
        [void]$md.AppendLine("- **Regions**: $($inv.summary.uniqueRegions)")
        [void]$md.AppendLine("- **Resource Groups**: $($inv.summary.uniqueResourceGroups)")
        [void]$md.AppendLine("")
        if ($inv.summary.topResourceTypes) {
            [void]$md.AppendLine("### Top Resource Types")
            [void]$md.AppendLine("")
            [void]$md.AppendLine("| Type | Count |")
            [void]$md.AppendLine("|------|-------|")
            foreach ($t in $inv.summary.topResourceTypes | Select-Object -First 10) {
                [void]$md.AppendLine("| $($t.type) | $($t.count) |")
            }
            [void]$md.AppendLine("")
        }
        if ($inv.summary.topRegions) {
            [void]$md.AppendLine("### Resources by Region")
            [void]$md.AppendLine("")
            [void]$md.AppendLine("| Region | Count |")
            [void]$md.AppendLine("|--------|-------|")
            foreach ($r in $inv.summary.topRegions) {
                [void]$md.AppendLine("| $($r.region) | $($r.count) |")
            }
            [void]$md.AppendLine("")
        }
    }

    if ($Results['Quota Usage'].Status -eq 'success') {
        $q = $Results['Quota Usage'].Data
        [void]$md.AppendLine("## Quota Usage")
        [void]$md.AppendLine("")
        [void]$md.AppendLine("- **Total Quotas Checked**: $($q.summary.totalQuotasChecked)")
        [void]$md.AppendLine("- **Regions Checked**: $($q.summary.regionsChecked)")
        [void]$md.AppendLine("- **Quotas >80% Used**: $($q.summary.quotasAbove80Percent)")
        [void]$md.AppendLine("- **Quotas >90% Used**: $($q.summary.quotasAbove90Percent)")
        [void]$md.AppendLine("")

        $critical = @($q.records | Where-Object { $_.usagePercent -ge 80 })
        if ($critical.Count -gt 0) {
            [void]$md.AppendLine("### ⚠️ Quotas Approaching Limits")
            [void]$md.AppendLine("")
            [void]$md.AppendLine("| Provider | Region | Quota | Usage | Limit | % Used |")
            [void]$md.AppendLine("|----------|--------|-------|-------|-------|--------|")
            foreach ($c in $critical | Sort-Object -Property usagePercent -Descending) {
                [void]$md.AppendLine("| $($c.provider) | $($c.region) | $($c.quotaName) | $($c.currentUsage) | $($c.limit) | $([math]::Round($c.usagePercent, 1))% |")
            }
            [void]$md.AppendLine("")
        }
    }

    if ($Results['Region Capabilities'].Status -eq 'success') {
        $reg = $Results['Region Capabilities'].Data
        [void]$md.AppendLine("## Region Capabilities")
        [void]$md.AppendLine("")
        [void]$md.AppendLine("- **Total Regions**: $($reg.summary.totalRegions)")
        [void]$md.AppendLine("- **Regions with Zone Support**: $($reg.summary.regionsWithZoneSupport)")
        [void]$md.AppendLine("- **Total VM SKUs**: $($reg.summary.totalVmSkus)")
        [void]$md.AppendLine("")
    }

    if ($Results['Usage Trends'].Status -eq 'success') {
        $ut = $Results['Usage Trends'].Data
        [void]$md.AppendLine("## Usage Trends ($DaysBack days)")
        [void]$md.AppendLine("")
        [void]$md.AppendLine("- **Resources Analyzed**: $($ut.summary.totalResourcesAnalyzed)")
        [void]$md.AppendLine("- **Resource Types**: $(($ut.summary.resourceTypesAnalyzed | Measure-Object).Count)")
        [void]$md.AppendLine("- **Period**: $($ut.summary.periodStart) to $($ut.summary.periodEnd)")
        [void]$md.AppendLine("")

        $highUsage = @($ut.records | Where-Object { $_.unit -eq 'Percent' -and $_.p95 -ge 80 })
        if ($highUsage.Count -gt 0) {
            [void]$md.AppendLine("### ⚠️ High Utilization Resources (P95 ≥ 80%)")
            [void]$md.AppendLine("")
            [void]$md.AppendLine("| Resource | Metric | Avg | P95 | Max |")
            [void]$md.AppendLine("|----------|--------|-----|-----|-----|")
            foreach ($h in $highUsage | Sort-Object -Property p95 -Descending) {
                [void]$md.AppendLine("| $($h.resourceName) | $($h.metricName) | $([math]::Round($h.average, 1))% | $([math]::Round($h.p95, 1))% | $([math]::Round($h.maximum, 1))% |")
            }
            [void]$md.AppendLine("")
        }
    }

    if ($Results['Reserved Instances'].Status -eq 'success') {
        $ri = $Results['Reserved Instances'].Data
        [void]$md.AppendLine("## Reserved Instances")
        [void]$md.AppendLine("")
        [void]$md.AppendLine("- **Total Reservations**: $($ri.summary.totalReservations)")
        if ($ri.summary.activeReservations) {
            [void]$md.AppendLine("- **Active Reservations**: $($ri.summary.activeReservations)")
        }
        if ($ri.summary.expiringWithin90Days) {
            [void]$md.AppendLine("- **⚠️ Expiring Within 90 Days**: $($ri.summary.expiringWithin90Days)")
        }
        if ($ri.metadata.permissionNotes) {
            [void]$md.AppendLine("- **Permission Status**: $($ri.metadata.permissionNotes)")
        }
        [void]$md.AppendLine("")
    }

    [void]$md.AppendLine("## Report Files")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("| File | Description |")
    [void]$md.AppendLine("|------|-------------|")
    foreach ($s in $scriptDefs) {
        $outputFile = Join-Path $ReportDir $s.Output
        if (Test-Path $outputFile) {
            $size = [math]::Round((Get-Item $outputFile).Length / 1KB, 1)
            [void]$md.AppendLine("| ``$($s.Output)`` | $($s.Name) (${size} KB) |")
        }
    }
    [void]$md.AppendLine("| ``summary.md`` | This summary report |")
    [void]$md.AppendLine("")

    $summaryPath = Join-Path $ReportDir 'summary.md'
    $md.ToString() | Out-File -FilePath $summaryPath -Encoding utf8

    return $summaryPath
}

# --- Main execution ---

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Azure Capacity Planning Report" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Build list of subscriptions to process
$subscriptions = @()

if ($PSCmdlet.ParameterSetName -eq 'File') {
    $lines = Get-Content $SubscriptionFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
    foreach ($line in $lines) {
        # Support formats: "subId" or "subId,displayName" or "subId # comment"
        $parts = $line -split '[,\t]', 2
        $id = $parts[0].Trim() -replace '#.*', '' | ForEach-Object { $_.Trim() }
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $name = if ($parts.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($parts[1])) { ($parts[1].Trim() -replace '#.*', '').Trim() } else { '' }
        $subscriptions += @{ Id = $id; Name = $name }
    }
    if ($subscriptions.Count -eq 0) {
        Write-Error "No valid subscription IDs found in '$SubscriptionFile'."
        return
    }
    Write-Host "`nLoaded $($subscriptions.Count) subscription(s) from: $SubscriptionFile" -ForegroundColor Green
} else {
    # Single subscription mode
    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $accountJson = az account show -o json 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Not logged in to Azure CLI. Run 'az login' first."
            return
        }
        $account = $accountJson | ConvertFrom-Json
        $subscriptions += @{ Id = $account.id; Name = $account.name }
    } else {
        $subscriptions += @{ Id = $SubscriptionId; Name = '' }
    }
}

# Process each subscription
$allSubResults = @()

foreach ($sub in $subscriptions) {
    $subId = $sub.Id

    # Set subscription context and resolve name
    az account set --subscription $subId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n❌ Failed to set subscription: $subId" -ForegroundColor Red
        $allSubResults += @{ Id = $subId; Name = $sub.Name; Status = 'failed'; Error = 'Could not set subscription context' }
        continue
    }
    $account = az account show -o json | ConvertFrom-Json
    $subName = $account.name

    # Create per-subscription directory for multi-sub, or timestamped dir for single
    if ($subscriptions.Count -gt 1) {
        $safeName = ($subName -replace '[^\w\-]', '_').ToLower()
        $subReportDir = Join-Path $OutputPath "capacity-report-$timestamp" $safeName
    } else {
        $subReportDir = Join-Path $OutputPath "capacity-report-$timestamp"
    }

    Write-Host "`n----------------------------------------" -ForegroundColor DarkGray
    Write-Host " [$($subscriptions.IndexOf($sub) + 1)/$($subscriptions.Count)] $subName" -ForegroundColor Cyan
    Write-Host "----------------------------------------" -ForegroundColor DarkGray

    $results = Invoke-CapacityCollection -SubId $subId -SubName $subName -ReportDir $subReportDir
    $summaryPath = New-SubscriptionSummary -SubId $subId -SubName $subName -ReportDir $subReportDir -Results $results

    $successCount = @($results.Values | Where-Object { $_.Status -eq 'success' }).Count
    $failCount = @($results.Values | Where-Object { $_.Status -eq 'failed' }).Count

    $allSubResults += @{
        Id           = $subId
        Name         = $subName
        Status       = 'completed'
        ReportDir    = $subReportDir
        SummaryPath  = $summaryPath
        Results      = $results
        SuccessCount = $successCount
        FailCount    = $failCount
    }

    Write-Host "`nScripts: $successCount succeeded, $failCount failed" -ForegroundColor $(if ($failCount -gt 0) { 'Yellow' } else { 'Green' })
}

# Cross-subscription summary (when processing multiple subscriptions)
if ($subscriptions.Count -gt 1) {
    $crossMd = [System.Text.StringBuilder]::new()
    [void]$crossMd.AppendLine("# Cross-Subscription Capacity Planning Report")
    [void]$crossMd.AppendLine("")
    [void]$crossMd.AppendLine("| Field | Value |")
    [void]$crossMd.AppendLine("|-------|-------|")
    [void]$crossMd.AppendLine("| **Generated** | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |")
    [void]$crossMd.AppendLine("| **Subscriptions** | $($subscriptions.Count) |")
    [void]$crossMd.AppendLine("| **Metrics Window** | $DaysBack days |")
    [void]$crossMd.AppendLine("")

    # Subscription overview table
    [void]$crossMd.AppendLine("## Subscription Overview")
    [void]$crossMd.AppendLine("")
    [void]$crossMd.AppendLine("| Subscription | Resources | Regions | Quotas >80% | High Util | Reservations | Status |")
    [void]$crossMd.AppendLine("|-------------|-----------|---------|-------------|-----------|--------------|--------|")

    $totalResources = 0
    $totalQuotaWarnings = 0
    $totalHighUtil = 0
    $totalReservations = 0
    $allCriticalQuotas = @()
    $allHighUsage = @()

    foreach ($subResult in $allSubResults) {
        if ($subResult.Status -eq 'failed') {
            [void]$crossMd.AppendLine("| $($subResult.Name ?? $subResult.Id) | - | - | - | - | - | ❌ Failed |")
            continue
        }

        $r = $subResult.Results
        $resCount = '-'; $regCount = '-'; $quotaWarn = '-'; $highUtil = '-'; $riCount = '-'

        if ($r['Service Inventory'].Status -eq 'success') {
            $resCount = $r['Service Inventory'].Data.summary.totalResources
            $totalResources += $resCount
        }
        if ($r['Quota Usage'].Status -eq 'success') {
            $quotaWarn = $r['Quota Usage'].Data.summary.quotasAbove80Percent
            $totalQuotaWarnings += [int]$quotaWarn

            $allCriticalQuotas += @($r['Quota Usage'].Data.records | Where-Object { $_.usagePercent -ge 80 } | ForEach-Object {
                $_ | Add-Member -NotePropertyName 'subscription' -NotePropertyValue $subResult.Name -PassThru
            })
            $regCount = $r['Quota Usage'].Data.summary.regionsChecked
        }
        if ($r['Usage Trends'].Status -eq 'success') {
            $hu = @($r['Usage Trends'].Data.records | Where-Object { $_.unit -eq 'Percent' -and $_.p95 -ge 80 })
            $highUtil = $hu.Count
            $totalHighUtil += $hu.Count
            $allHighUsage += @($hu | ForEach-Object {
                $_ | Add-Member -NotePropertyName 'subscription' -NotePropertyValue $subResult.Name -PassThru
            })
        }
        if ($r['Reserved Instances'].Status -eq 'success') {
            $riCount = $r['Reserved Instances'].Data.summary.totalReservations
            $totalReservations += [int]$riCount
        }

        $statusIcon = if ($subResult.FailCount -gt 0) { "⚠️ $($subResult.SuccessCount)/5" } else { '✅' }
        [void]$crossMd.AppendLine("| $($subResult.Name) | $resCount | $regCount | $quotaWarn | $highUtil | $riCount | $statusIcon |")
    }

    [void]$crossMd.AppendLine("")
    [void]$crossMd.AppendLine("**Totals**: $totalResources resources, $totalQuotaWarnings quota warnings, $totalHighUtil high-utilization metrics, $totalReservations reservations")
    [void]$crossMd.AppendLine("")

    # Cross-subscription critical quotas
    if ($allCriticalQuotas.Count -gt 0) {
        [void]$crossMd.AppendLine("## ⚠️ Quotas Approaching Limits (All Subscriptions)")
        [void]$crossMd.AppendLine("")
        [void]$crossMd.AppendLine("| Subscription | Provider | Region | Quota | Usage | Limit | % Used |")
        [void]$crossMd.AppendLine("|-------------|----------|--------|-------|-------|-------|--------|")
        foreach ($c in $allCriticalQuotas | Sort-Object -Property usagePercent -Descending | Select-Object -First 25) {
            [void]$crossMd.AppendLine("| $($c.subscription) | $($c.provider) | $($c.region) | $($c.quotaName) | $($c.currentUsage) | $($c.limit) | $([math]::Round($c.usagePercent, 1))% |")
        }
        [void]$crossMd.AppendLine("")
    }

    # Cross-subscription high utilization
    if ($allHighUsage.Count -gt 0) {
        [void]$crossMd.AppendLine("## ⚠️ High Utilization Resources (All Subscriptions, P95 ≥ 80%)")
        [void]$crossMd.AppendLine("")
        [void]$crossMd.AppendLine("| Subscription | Resource | Metric | Avg | P95 | Max |")
        [void]$crossMd.AppendLine("|-------------|----------|--------|-----|-----|-----|")
        foreach ($h in $allHighUsage | Sort-Object -Property p95 -Descending | Select-Object -First 25) {
            [void]$crossMd.AppendLine("| $($h.subscription) | $($h.resourceName) | $($h.metricName) | $([math]::Round($h.average, 1))% | $([math]::Round($h.p95, 1))% | $([math]::Round($h.maximum, 1))% |")
        }
        [void]$crossMd.AppendLine("")
    }

    # Per-subscription report links
    [void]$crossMd.AppendLine("## Per-Subscription Reports")
    [void]$crossMd.AppendLine("")
    foreach ($subResult in $allSubResults) {
        if ($subResult.Status -eq 'completed') {
            $relPath = [System.IO.Path]::GetFileName($subResult.ReportDir)
            [void]$crossMd.AppendLine("- **$($subResult.Name)**: [$relPath/summary.md]($relPath/summary.md)")
        }
    }
    [void]$crossMd.AppendLine("")

    $crossSummaryDir = Join-Path $OutputPath "capacity-report-$timestamp"
    New-Item -ItemType Directory -Path $crossSummaryDir -Force | Out-Null
    $crossSummaryPath = Join-Path $crossSummaryDir 'cross-subscription-summary.md'
    $crossMd.ToString() | Out-File -FilePath $crossSummaryPath -Encoding utf8
}

# Final output
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Report Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$rootReportDir = Join-Path $OutputPath "capacity-report-$timestamp"
Write-Host "`nReport directory: $rootReportDir" -ForegroundColor Green

if ($subscriptions.Count -gt 1) {
    Write-Host "Cross-subscription summary: $(Join-Path $rootReportDir 'cross-subscription-summary.md')"
    $completedCount = @($allSubResults | Where-Object { $_.Status -eq 'completed' }).Count
    $failedCount = @($allSubResults | Where-Object { $_.Status -eq 'failed' }).Count
    Write-Host "`nSubscriptions: $completedCount completed, $failedCount failed" -ForegroundColor $(if ($failedCount -gt 0) { 'Yellow' } else { 'Green' })
} else {
    $r = $allSubResults[0]
    Write-Host "Summary: $($r.SummaryPath)"
    Write-Host "`nScripts: $($r.SuccessCount) succeeded, $($r.FailCount) failed" -ForegroundColor $(if ($r.FailCount -gt 0) { 'Yellow' } else { 'Green' })
}
