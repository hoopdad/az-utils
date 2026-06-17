[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [Parameter(Mandatory = $true)]
    [string]$OutputFolder,

    [string]$OutputFileName = "quota-analysis.xlsx"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:SubscriptionCache = $null
$script:RegionSkuCache = @{}
$script:VmUsageCache = @{}
$script:LocationCache = $null

function Require-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Normalize-Token {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    return (($Value -replace "[^a-zA-Z0-9]", "").ToLowerInvariant())
}

function Get-LocationCache {
    if ($null -eq $script:LocationCache) {
        $locations = Invoke-AzJson -Arguments @("account", "list-locations")
        $map = @{}

        foreach ($loc in $locations) {
            $name = [string]$loc.name
            $display = [string]$loc.displayName

            foreach ($candidate in @($name, $display)) {
                if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
                $k = Normalize-Token -Value $candidate
                if (-not [string]::IsNullOrWhiteSpace($k) -and -not $map.ContainsKey($k)) {
                    $map[$k] = $name
                }
            }
        }

        $script:LocationCache = $map
    }

    return $script:LocationCache
}

function Resolve-RegionName {
    param([AllowNull()][string]$InputRegion)

    if ([string]::IsNullOrWhiteSpace($InputRegion)) {
        return $null
    }

    $cache = Get-LocationCache
    $token = Normalize-Token -Value $InputRegion
    if ($cache.ContainsKey($token)) {
        return [string]$cache[$token]
    }

    return $null
}

function Get-FieldValue {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][string[]]$Aliases
    )

    foreach ($alias in $Aliases) {
        if ($Row.PSObject.Properties.Name -contains $alias) {
            $candidate = $Row.$alias
            if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                return [string]$candidate
            }
        }
    }

    return $null
}

function Convert-ToNullableInt {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $parsed = 0
    if ([int]::TryParse($Value.Trim(), [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $command = @("az") + $Arguments + @("-o", "json")
    $output = & $command[0] $command[1..($command.Length - 1)] 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        if ($AllowFailure) {
            return $null
        }

        $argsJoined = ($Arguments -join " ")
        throw "Azure CLI command failed (az $argsJoined): $output"
    }

    if ([string]::IsNullOrWhiteSpace($output)) {
        return $null
    }

    return ($output | ConvertFrom-Json -Depth 20)
}

function Get-SubscriptionCache {
    if (-not $script:SubscriptionCache) {
        $accounts = Invoke-AzJson -Arguments @("account", "list", "--all")
        $byId = @{}
        $byNameExact = @{}

        foreach ($acct in $accounts) {
            if ($null -eq $acct.id) { continue }

            $id = [string]$acct.id
            $name = [string]$acct.name
            $byId[$id] = $acct
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $byNameExact[$name.ToLowerInvariant()] = $acct
            }
        }

        $script:SubscriptionCache = [PSCustomObject]@{
            Accounts = $accounts
            ById = $byId
            ByNameExact = $byNameExact
        }
    }

    return $script:SubscriptionCache
}

function Resolve-Subscription {
    param(
        [AllowNull()][string]$SubscriptionName,
        [AllowNull()][string]$SubscriptionId
    )

    $cache = Get-SubscriptionCache

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        if ($cache.ById.ContainsKey($SubscriptionId)) {
            $acct = $cache.ById[$SubscriptionId]
            return [PSCustomObject]@{
                SubscriptionId = [string]$acct.id
                SubscriptionName = [string]$acct.name
                MatchType = "by-id"
            }
        }

        return $null
    }

    if ([string]::IsNullOrWhiteSpace($SubscriptionName)) {
        return $null
    }

    $key = $SubscriptionName.ToLowerInvariant()
    if ($cache.ByNameExact.ContainsKey($key)) {
        $acct = $cache.ByNameExact[$key]
        return [PSCustomObject]@{
            SubscriptionId = [string]$acct.id
            SubscriptionName = [string]$acct.name
            MatchType = "exact-name"
        }
    }

    $containsMatches = @($cache.Accounts | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.name) -and
        ([string]$_.name).ToLowerInvariant().Contains($key)
    })

    if ($containsMatches.Count -eq 1) {
        $acct = $containsMatches[0]
        return [PSCustomObject]@{
            SubscriptionId = [string]$acct.id
            SubscriptionName = [string]$acct.name
            MatchType = "contains-name"
        }
    }

    return $null
}

function Get-RegionSkuRecords {
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$Region
    )

    if (-not $script:RegionSkuCache) {
        $script:RegionSkuCache = @{}
    }

    $cacheKey = "$SubscriptionId|$Region"
    if ($script:RegionSkuCache.ContainsKey($cacheKey)) {
        return $script:RegionSkuCache[$cacheKey]
    }

    $skus = Invoke-AzJson -Arguments @(
        "vm", "list-skus",
        "--resource-type", "virtualMachines",
        "--location", $Region,
        "--subscription", $SubscriptionId
    )

    $script:RegionSkuCache[$cacheKey] = @($skus)
    return $script:RegionSkuCache[$cacheKey]
}

function Get-SkuMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)][string]$SkuName
    )

    $skuRecords = Get-RegionSkuRecords -SubscriptionId $SubscriptionId -Region $Region
    $match = $skuRecords | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.name) -and
        ([string]$_.name).ToLowerInvariant() -eq $SkuName.ToLowerInvariant()
    } | Select-Object -First 1

    if ($null -eq $match) {
        return $null
    }

    $family = [string]$match.family
    $capabilities = @($match.capabilities)
    $vcpuCapability = $capabilities | Where-Object { $_.name -eq "vCPUs" } | Select-Object -First 1

    $vcpu = $null
    if ($null -ne $vcpuCapability -and -not [string]::IsNullOrWhiteSpace([string]$vcpuCapability.value)) {
        $parsed = 0
        if ([int]::TryParse([string]$vcpuCapability.value, [ref]$parsed)) {
            $vcpu = $parsed
        }
    }

    return [PSCustomObject]@{
        SkuName = [string]$match.name
        SkuFamily = $family
        CoresPerVm = $vcpu
    }
}

function Get-VmUsageRecords {
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$Region
    )

    if (-not $script:VmUsageCache) {
        $script:VmUsageCache = @{}
    }

    $cacheKey = "$SubscriptionId|$Region"
    if ($script:VmUsageCache.ContainsKey($cacheKey)) {
        return $script:VmUsageCache[$cacheKey]
    }

    $usage = Invoke-AzJson -Arguments @(
        "vm", "list-usage",
        "--location", $Region,
        "--subscription", $SubscriptionId
    )

    $script:VmUsageCache[$cacheKey] = @($usage)
    return $script:VmUsageCache[$cacheKey]
}

function Find-FamilyQuotaRecord {
    param(
        [Parameter(Mandatory = $true)]$UsageRecords,
        [Parameter(Mandatory = $true)][string]$SkuFamily
    )

    $target = Normalize-Token -Value $SkuFamily
    if ([string]::IsNullOrWhiteSpace($target)) {
        return $null
    }

    $exact = $UsageRecords | Where-Object {
        $valueName = Normalize-Token -Value ([string]$_.name.value)
        $localName = Normalize-Token -Value ([string]$_.name.localizedValue)
        ($valueName -eq $target) -or ($localName -eq $target)
    } | Select-Object -First 1

    if ($null -ne $exact) {
        return $exact
    }

    $contains = $UsageRecords | Where-Object {
        $valueName = Normalize-Token -Value ([string]$_.name.value)
        $localName = Normalize-Token -Value ([string]$_.name.localizedValue)
        $valueName.Contains($target) -or $localName.Contains($target) -or $target.Contains($valueName)
    } | Select-Object -First 1

    return $contains
}

function Ensure-ImportExcelModule {
    try {
        Import-Module ImportExcel -ErrorAction Stop
    }
    catch {
        throw "PowerShell module 'ImportExcel' is required. Install with: Install-Module ImportExcel -Scope CurrentUser"
    }
}

Require-Command -Name "az"
Ensure-ImportExcelModule

if (-not (Test-Path -LiteralPath $InputCsv -PathType Leaf)) {
    throw "Input CSV not found: $InputCsv"
}

if (-not (Test-Path -LiteralPath $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

$rows = Import-Csv -Path $InputCsv
if ($rows.Count -eq 0) {
    throw "Input CSV has no rows: $InputCsv"
}

$analysisRows = New-Object System.Collections.Generic.List[object]
$detailRows = New-Object System.Collections.Generic.List[object]
$allVmQuotaRows = New-Object System.Collections.Generic.List[object]
$uniqueSubRegion = New-Object System.Collections.Generic.HashSet[string]

$rowIndex = 0
foreach ($row in $rows) {
    $rowIndex += 1
    $notes = New-Object System.Collections.Generic.List[string]
    $status = "ok"

    $subscriptionNameInput = Get-FieldValue -Row $row -Aliases @("SubscriptionName", "Subscription Name", "subscription_name", "subscription")
    $subscriptionIdInput = Get-FieldValue -Row $row -Aliases @("SubscriptionId", "Subscription ID", "subscription_id")
    $region = Get-FieldValue -Row $row -Aliases @("AzureRegion", "Azure Region", "Region", "region", "location")
    $skuInput = Get-FieldValue -Row $row -Aliases @("Sku", "SKU", "VmSku", "VM SKU")
    $skuFamilyInput = Get-FieldValue -Row $row -Aliases @("SkuFamily", "SKU Family", "Sku Family", "VM Family")
    $coreQuantityInputRaw = Get-FieldValue -Row $row -Aliases @("CoreQuantity", "Cores", "QuantityOfCores", "AdditionalCores")
    $vmQuantityInputRaw = Get-FieldValue -Row $row -Aliases @("VmQuantity", "VMs", "QuantityOfVMs", "AdditionalVMs", "Number VM", "NumberVM", "Number of VMs")

    $coreQuantityInput = Convert-ToNullableInt -Value $coreQuantityInputRaw
    $vmQuantityInput = Convert-ToNullableInt -Value $vmQuantityInputRaw

    if ([string]::IsNullOrWhiteSpace($region)) {
        $status = "error"
        $notes.Add("Region is required.")
    }

    $regionResolved = $null
    if ($status -ne "error") {
        $regionResolved = Resolve-RegionName -InputRegion $region
        if ([string]::IsNullOrWhiteSpace($regionResolved)) {
            $status = "error"
            $notes.Add("Could not resolve region '$region' to an Azure location name.")
        }
    }

    if ([string]::IsNullOrWhiteSpace($skuInput) -and [string]::IsNullOrWhiteSpace($skuFamilyInput)) {
        $status = "error"
        $notes.Add("Either SKU or SKU Family is required.")
    }

    $resolvedSubscription = Resolve-Subscription -SubscriptionName $subscriptionNameInput -SubscriptionId $subscriptionIdInput
    $subscriptionNameResolved = $null
    $subscriptionIdResolved = $null

    if ($null -eq $resolvedSubscription) {
        $status = "error"
        $notes.Add("Could not resolve subscription from provided name/id.")
    }
    else {
        $subscriptionNameResolved = $resolvedSubscription.SubscriptionName
        $subscriptionIdResolved = $resolvedSubscription.SubscriptionId
        if ($resolvedSubscription.MatchType -eq "contains-name") {
            $notes.Add("Subscription matched by contains-name fallback.")
        }
    }

    $resolvedSkuFamily = $skuFamilyInput
    $coresPerVmDerived = $null

    if ($status -ne "error" -and -not [string]::IsNullOrWhiteSpace($skuInput)) {
        $skuMetadata = Get-SkuMetadata -SubscriptionId $subscriptionIdResolved -Region $regionResolved -SkuName $skuInput
        if ($null -eq $skuMetadata) {
            $notes.Add("Could not find SKU metadata for '$skuInput' in region '$regionResolved'.")
            if ([string]::IsNullOrWhiteSpace($resolvedSkuFamily)) {
                $status = "error"
                $notes.Add("SKU Family could not be derived and was not provided.")
            }
        }
        else {
            if ([string]::IsNullOrWhiteSpace($resolvedSkuFamily)) {
                $resolvedSkuFamily = $skuMetadata.SkuFamily
            }
            $coresPerVmDerived = $skuMetadata.CoresPerVm
        }
    }

    if ($status -ne "error" -and -not [string]::IsNullOrWhiteSpace($resolvedSkuFamily)) {
        $usageRecords = Get-VmUsageRecords -SubscriptionId $subscriptionIdResolved -Region $regionResolved
        $familyQuota = Find-FamilyQuotaRecord -UsageRecords $usageRecords -SkuFamily $resolvedSkuFamily
    }
    else {
        $usageRecords = @()
        $familyQuota = $null
    }

    $additionalCores = 0
    if ($null -ne $coreQuantityInput) {
        $additionalCores = [int]$coreQuantityInput
    }
    elseif ($null -ne $vmQuantityInput) {
        if ($null -ne $coresPerVmDerived) {
            $additionalCores = [int]$vmQuantityInput * [int]$coresPerVmDerived
        }
        else {
            $additionalCores = 0
            $notes.Add("VM quantity was provided, but cores/VM could not be derived. Additional cores defaulted to 0.")
        }
    }

    $quotaCurrent = $null
    $quotaTotal = $null
    $quotaRemaining = $null

    if ($null -ne $familyQuota) {
        $quotaCurrent = [int]$familyQuota.currentValue
        $quotaTotal = [int]$familyQuota.limit
        $quotaRemaining = $quotaTotal - $quotaCurrent
    }
    elseif ($status -ne "error") {
        $status = "warning"
        $notes.Add("Quota record for SKU family '$resolvedSkuFamily' was not found in vm list-usage for region '$regionResolved'.")
    }

    if ($status -eq "ok" -and $notes.Count -gt 0) {
        $status = "warning"
    }

    $detailRows.Add([PSCustomObject]@{
        InputRow = $rowIndex
        SubscriptionNameInput = $subscriptionNameInput
        SubscriptionIdInput = $subscriptionIdInput
        SubscriptionNameResolved = $subscriptionNameResolved
        SubscriptionIdResolved = $subscriptionIdResolved
        AzureRegion = $regionResolved
        SkuInput = $skuInput
        SkuFamilyInput = $skuFamilyInput
        SkuFamilyResolved = $resolvedSkuFamily
        VmQuantityInput = $vmQuantityInput
        CoreQuantityInput = $coreQuantityInput
        CoresPerVmDerived = $coresPerVmDerived
        AdditionalCores = $additionalCores
        QuotaCurrentCores = $quotaCurrent
        QuotaTotalCores = $quotaTotal
        QuotaRemainingCores = $quotaRemaining
        Status = $status
        Notes = ($notes -join " | ")
    }) | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($subscriptionIdResolved) -and -not [string]::IsNullOrWhiteSpace($regionResolved)) {
        $subRegionKey = "$subscriptionIdResolved|$regionResolved"
        if ($uniqueSubRegion.Add($subRegionKey)) {
            $vmUsageAll = Get-VmUsageRecords -SubscriptionId $subscriptionIdResolved -Region $regionResolved
            foreach ($usage in $vmUsageAll) {
                $nameValue = [string]$usage.name.value
                $localized = [string]$usage.name.localizedValue
                $familyLike = $nameValue -match "(?i)family" -or $localized -match "(?i)family" -or $nameValue -match "(?i)totalregionalvcpus"

                if (-not $familyLike) {
                    continue
                }

                $currentValue = $null
                $limitValue = $null
                $remainingValue = $null
                $percentUsed = $null

                if ($null -ne $usage.currentValue) { $currentValue = [int]$usage.currentValue }
                if ($null -ne $usage.limit) { $limitValue = [int]$usage.limit }
                if ($null -ne $currentValue -and $null -ne $limitValue) {
                    $remainingValue = $limitValue - $currentValue
                    if ($limitValue -gt 0) {
                        $percentUsed = [math]::Round((100.0 * $currentValue) / $limitValue, 2)
                    }
                }

                $allVmQuotaRows.Add([PSCustomObject]@{
                    SubscriptionName = $subscriptionNameResolved
                    SubscriptionId = $subscriptionIdResolved
                    AzureRegion = $regionResolved
                    QuotaNameValue = $nameValue
                    QuotaNameLocalized = $localized
                    CurrentConsumption = $currentValue
                    TotalQuota = $limitValue
                    RemainingQuota = $remainingValue
                    PercentUsed = $percentUsed
                }) | Out-Null
            }
        }
    }
}

$aggregateByKey = @{}
foreach ($detail in $detailRows) {
    $groupSubName = if (-not [string]::IsNullOrWhiteSpace([string]$detail.SubscriptionNameResolved)) { [string]$detail.SubscriptionNameResolved } else { [string]$detail.SubscriptionNameInput }
    $groupSubId = if (-not [string]::IsNullOrWhiteSpace([string]$detail.SubscriptionIdResolved)) { [string]$detail.SubscriptionIdResolved } else { [string]$detail.SubscriptionIdInput }
    $groupRegion = [string]$detail.AzureRegion
    $groupFamily = if (-not [string]::IsNullOrWhiteSpace([string]$detail.SkuFamilyResolved)) { [string]$detail.SkuFamilyResolved } else { [string]$detail.SkuFamilyInput }

    if ([string]::IsNullOrWhiteSpace($groupSubName) -and
        [string]::IsNullOrWhiteSpace($groupSubId) -and
        [string]::IsNullOrWhiteSpace($groupRegion) -and
        [string]::IsNullOrWhiteSpace($groupFamily)) {
        continue
    }

    $key = "$groupSubId|$groupSubName|$groupRegion|$groupFamily"
    if (-not $aggregateByKey.ContainsKey($key)) {
        $aggregateByKey[$key] = [PSCustomObject]@{
            SubscriptionNameResolved = $groupSubName
            SubscriptionIdResolved = $groupSubId
            AzureRegion = $groupRegion
            SkuFamilyResolved = $groupFamily
            InputRowCount = 0
            VmQuantityTotal = 0
            CoreQuantityTotal = 0
            AdditionalCoresTotal = 0
            QuotaCurrentCores = $null
            QuotaTotalCores = $null
            QuotaRemainingCores = $null
            HasError = $false
            HasWarning = $false
            Notes = New-Object System.Collections.Generic.List[string]
        }
    }

    $agg = $aggregateByKey[$key]
    $agg.InputRowCount += 1
    if ($null -ne $detail.VmQuantityInput) { $agg.VmQuantityTotal += [int]$detail.VmQuantityInput }
    if ($null -ne $detail.CoreQuantityInput) { $agg.CoreQuantityTotal += [int]$detail.CoreQuantityInput }
    if ($null -ne $detail.AdditionalCores) { $agg.AdditionalCoresTotal += [int]$detail.AdditionalCores }

    if ($null -eq $agg.QuotaCurrentCores -and $null -ne $detail.QuotaCurrentCores) {
        $agg.QuotaCurrentCores = [int]$detail.QuotaCurrentCores
    }
    if ($null -eq $agg.QuotaTotalCores -and $null -ne $detail.QuotaTotalCores) {
        $agg.QuotaTotalCores = [int]$detail.QuotaTotalCores
    }
    if ($null -eq $agg.QuotaRemainingCores -and $null -ne $detail.QuotaRemainingCores) {
        $agg.QuotaRemainingCores = [int]$detail.QuotaRemainingCores
    }

    if ($detail.Status -eq "error") { $agg.HasError = $true }
    if ($detail.Status -eq "warning") { $agg.HasWarning = $true }
    if (-not [string]::IsNullOrWhiteSpace([string]$detail.Notes)) {
        foreach ($note in ([string]$detail.Notes -split "\|")) {
            $trimmed = $note.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed) -and -not $agg.Notes.Contains($trimmed)) {
                $agg.Notes.Add($trimmed)
            }
        }
    }
}

$grouped = $aggregateByKey.Values | Sort-Object SubscriptionNameResolved, AzureRegion, SkuFamilyResolved

foreach ($g in $grouped) {
    $excelRowNumber = $analysisRows.Count + 2
    $formulaCurrentPlusAdditional = ""
    $formulaAdditionalNeeded = ""

    if ($null -ne $g.QuotaCurrentCores -and $null -ne $g.QuotaTotalCores) {
        $formulaCurrentPlusAdditional = "=G$excelRowNumber+F$excelRowNumber"
        $formulaAdditionalNeeded = "=MAX(0,J$excelRowNumber-H$excelRowNumber)"
    }

    $status = "ok"
    if ($g.HasError) { $status = "error" }
    elseif ($g.HasWarning) { $status = "warning" }

    $analysisRows.Add([PSCustomObject]@{
        SubscriptionNameResolved = $g.SubscriptionNameResolved
        SubscriptionIdResolved = $g.SubscriptionIdResolved
        AzureRegion = $g.AzureRegion
        SkuFamilyResolved = $g.SkuFamilyResolved
        InputRowCount = $g.InputRowCount
        AdditionalCoresTotal = $g.AdditionalCoresTotal
        QuotaCurrentCores = $g.QuotaCurrentCores
        QuotaTotalCores = $g.QuotaTotalCores
        QuotaRemainingCores = $g.QuotaRemainingCores
        CurrentPlusAdditionalCores = $formulaCurrentPlusAdditional
        AdditionalQuotaNeeded = $formulaAdditionalNeeded
        Status = $status
        Notes = ($g.Notes -join " | ")
    }) | Out-Null
}

if ($analysisRows.Count -eq 0) {
    $analysisRows.Add([PSCustomObject]@{
        SubscriptionNameResolved = ""
        SubscriptionIdResolved = ""
        AzureRegion = ""
        SkuFamilyResolved = ""
        InputRowCount = 0
        AdditionalCoresTotal = 0
        QuotaCurrentCores = $null
        QuotaTotalCores = $null
        QuotaRemainingCores = $null
        CurrentPlusAdditionalCores = ""
        AdditionalQuotaNeeded = ""
        Status = "error"
        Notes = "No analyzable rows were produced from input CSV."
    }) | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$workbookPath = Join-Path $OutputFolder $OutputFileName
if (-not $OutputFileName.ToLowerInvariant().EndsWith(".xlsx")) {
    $workbookPath = Join-Path $OutputFolder ("quota-analysis-$timestamp.xlsx")
}

if (Test-Path -LiteralPath $workbookPath) {
    Remove-Item -LiteralPath $workbookPath -Force
}

$analysisRows |
    Export-Excel -Path $workbookPath -WorksheetName "QuotaAnalysis" -TableName "QuotaAnalysis" -FreezeTopRow -BoldTopRow

$allVmQuotaRows |
    Export-Excel -Path $workbookPath -WorksheetName "AllVmFamilyQuotas" -TableName "AllVmFamilyQuotas" -FreezeTopRow -BoldTopRow

Write-Host "Quota analysis workbook created: $workbookPath"
