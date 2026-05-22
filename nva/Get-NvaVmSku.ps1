[CmdletBinding()]
param(
    [Parameter()]
    [string]$InputCsvPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'nva.csv'),

    [Parameter()]
    [string]$OutputCsvPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'nva.with-vm-sku.csv')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $result = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$($result -join [Environment]::NewLine)"
    }

    $json = $result -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    return $json | ConvertFrom-Json -Depth 100
}

function Normalize-Value {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return $Value.Trim().ToLowerInvariant()
}

function New-PlanKey {
    param(
        [AllowNull()][string]$Publisher,
        [AllowNull()][string]$Product,
        [AllowNull()][string]$Sku,
        [AllowNull()][string]$Version
    )

    $pub = Normalize-Value -Value $Publisher
    $prod = Normalize-Value -Value $Product
    $sku = Normalize-Value -Value $Sku
    $ver = Normalize-Value -Value $Version
    return "$pub|$prod|$sku|$ver"
}

function Format-VmSkuSummary {
    param([Parameter(Mandatory)][System.Collections.IEnumerable]$Sizes)

    $grouped = @(
        $Sizes |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Group-Object |
            Sort-Object -Property Count, Name -Descending
    )

    if ($grouped.Count -eq 0) {
        return ''
    }

    return ($grouped | ForEach-Object { "{0} ({1})" -f $_.Name, $_.Count }) -join '; '
}

function Get-NestedPropertyValue {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string[]]$Path
    )

    $current = $InputObject
    foreach ($segment in $Path) {
        if ($null -eq $current) {
            return $null
        }

        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) {
            return $null
        }

        $current = $property.Value
    }

    return $current
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required but was not found in PATH.'
}

if (-not (Test-Path -LiteralPath $InputCsvPath -PathType Leaf)) {
    throw "Input CSV not found: $InputCsvPath"
}

$null = Invoke-AzCliJson -Arguments @('account', 'show', '--only-show-errors', '--output', 'json')

$rows = @()
$rows = Import-Csv -LiteralPath $InputCsvPath
if ($rows.Count -eq 0) {
    throw "Input CSV has no data rows: $InputCsvPath"
}

$firstRow = $rows | Select-Object -First 1
$columnNames = @($firstRow.PSObject.Properties.Name)

$subscriptionColumn = $null
foreach ($candidate in 'SubscriptionId', 'subscriptionId', 'iptionId') {
    if ($columnNames -contains $candidate) {
        $subscriptionColumn = $candidate
        break
    }
}

if ([string]::IsNullOrWhiteSpace($subscriptionColumn)) {
    throw "Could not find a subscription ID column. Expected one of: SubscriptionId, subscriptionId, iptionId"
}

$providerColumn = $null
foreach ($candidate in 'NVA Provider', 'Publisher', 'publisher') {
    if ($columnNames -contains $candidate) {
        $providerColumn = $candidate
        break
    }
}

$productColumn = $null
foreach ($candidate in 'Product ID / Offer', 'Offer', 'product') {
    if ($columnNames -contains $candidate) {
        $productColumn = $candidate
        break
    }
}

$skuColumn = $null
foreach ($candidate in 'SKU', 'sku') {
    if ($columnNames -contains $candidate) {
        $skuColumn = $candidate
        break
    }
}

$versionColumn = $null
foreach ($candidate in 'Version', 'version') {
    if ($columnNames -contains $candidate) {
        $versionColumn = $candidate
        break
    }
}

foreach ($required in @(
        @{ Name = 'Provider'; Column = $providerColumn },
        @{ Name = 'Product'; Column = $productColumn },
        @{ Name = 'SKU'; Column = $skuColumn },
        @{ Name = 'Version'; Column = $versionColumn }
    )) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Column)) {
        throw "Required CSV column not found for $($required.Name)."
    }
}

$subscriptionIds = @(
    $rows |
        ForEach-Object { [string]$_.$subscriptionColumn } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)

if ($subscriptionIds.Count -eq 0) {
    throw 'No subscription IDs found in input CSV.'
}

$vmSizeByPlanBySubscription = @{}
$subscriptionQueryErrors = @{}

foreach ($subscriptionId in $subscriptionIds) {
    Write-Host "Querying VMs for subscription: $subscriptionId"

    try {
        $vms = Invoke-AzCliJson -Arguments @(
            'vm', 'list',
            '--subscription', $subscriptionId,
            '--only-show-errors',
            '--output', 'json'
        )
    }
    catch {
        $subscriptionQueryErrors[$subscriptionId] = $_.Exception.Message
        Write-Warning "Skipping subscription $subscriptionId due to Azure CLI error."
        $vmSizeByPlanBySubscription[$subscriptionId] = @{}
        continue
    }

    $planMap = @{}

    foreach ($vm in @($vms)) {
        $plan = Get-NestedPropertyValue -InputObject $vm -Path @('plan')
        if ($null -eq $plan) {
            continue
        }

        $vmSize = [string](Get-NestedPropertyValue -InputObject $vm -Path @('hardwareProfile', 'vmSize'))
        if ([string]::IsNullOrWhiteSpace($vmSize)) {
            continue
        }

        $publisher = [string](Get-NestedPropertyValue -InputObject $plan -Path @('publisher'))
        $product = [string](Get-NestedPropertyValue -InputObject $plan -Path @('product'))
        $sku = [string](Get-NestedPropertyValue -InputObject $plan -Path @('name'))
        $version = [string](Get-NestedPropertyValue -InputObject $plan -Path @('version'))

        $exactKey = New-PlanKey -Publisher $publisher -Product $product -Sku $sku -Version $version
        $anyVersionKey = New-PlanKey -Publisher $publisher -Product $product -Sku $sku -Version ''

        if (-not $planMap.ContainsKey($exactKey)) {
            $planMap[$exactKey] = [System.Collections.Generic.List[string]]::new()
        }
        $planMap[$exactKey].Add($vmSize)

        if (-not $planMap.ContainsKey($anyVersionKey)) {
            $planMap[$anyVersionKey] = [System.Collections.Generic.List[string]]::new()
        }
        $planMap[$anyVersionKey].Add($vmSize)
    }

    $vmSizeByPlanBySubscription[$subscriptionId] = $planMap
}

$outputRows = [System.Collections.Generic.List[object]]::new()

foreach ($row in $rows) {
    $subscriptionId = [string]$row.$subscriptionColumn
    $provider = [string]$row.$providerColumn
    $product = [string]$row.$productColumn
    $sku = [string]$row.$skuColumn
    $version = [string]$row.$versionColumn

    $vmSku = ''
    $vmSkuMatchType = 'NoSubscriptionData'
    $subscriptionQueryError = ''

    if ($subscriptionQueryErrors.ContainsKey($subscriptionId)) {
        $vmSkuMatchType = 'SubscriptionQueryFailed'
        $subscriptionQueryError = [string]$subscriptionQueryErrors[$subscriptionId]
    }
    elseif ($vmSizeByPlanBySubscription.ContainsKey($subscriptionId)) {
        $planMap = $vmSizeByPlanBySubscription[$subscriptionId]
        $exactKey = New-PlanKey -Publisher $provider -Product $product -Sku $sku -Version $version
        $anyVersionKey = New-PlanKey -Publisher $provider -Product $product -Sku $sku -Version ''
        $vmSkuMatchType = 'NoMatch'

        if ($planMap.ContainsKey($exactKey)) {
            $vmSku = Format-VmSkuSummary -Sizes $planMap[$exactKey]
            $vmSkuMatchType = 'ExactVersion'
        }
        elseif ($planMap.ContainsKey($anyVersionKey)) {
            $vmSku = Format-VmSkuSummary -Sizes $planMap[$anyVersionKey]
            $vmSkuMatchType = 'AnyVersionFallback'
        }
    }

    $outRow = [ordered]@{}
    foreach ($column in $columnNames) {
        $outRow[$column] = $row.$column
    }
    $outRow['VM SKU'] = $vmSku
    $outRow['VM SKU Match Type'] = $vmSkuMatchType
    $outRow['Subscription Query Error'] = $subscriptionQueryError

    $outputRows.Add([pscustomobject]$outRow)
}

$outputDirectory = Split-Path -Parent $OutputCsvPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$outputRows | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Encoding UTF8
Write-Host "Wrote enriched CSV: $OutputCsvPath"
