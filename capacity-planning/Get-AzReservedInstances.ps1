[CmdletBinding()]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'yes_without_prompt'

function ConvertTo-Array {
    param([Parameter(ValueFromPipeline = $true)]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value)
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return @($Value)
    }

    return @($Value)
}

function Get-ResourceNameFromId {
    param([string]$ResourceId)

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        return $null
    }

    return ($ResourceId.TrimEnd('/') -split '/')[-1]
}

function ConvertFrom-AzJsonText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $candidate = $Text.Trim()

    try {
        return $candidate | ConvertFrom-Json -Depth 100
    }
    catch {
    }

    if ($candidate -match '(?s)(\[.*\]|\{.*\})') {
        $candidate = $matches[1]
        return $candidate | ConvertFrom-Json -Depth 100
    }

    throw "Unable to parse Azure CLI output as JSON."
}

function Invoke-AzJson {
    param(
        [string[]]$Arguments,
        [string]$Context
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()

    if ($exitCode -ne 0) {
        $errorMessage = "Azure CLI command failed for $Context."
        if ($text) {
            $errorMessage = $text
        }

        return [pscustomobject]@{
            Success = $false
            Error   = $errorMessage
            Raw     = $text
        }
    }

    try {
        return [pscustomobject]@{
            Success = $true
            Data    = ConvertFrom-AzJsonText -Text $text
            Raw     = $text
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Error   = "Failed to parse JSON for $Context. $($_.Exception.Message)"
            Raw     = $text
        }
    }
}

function Get-FirstValue {
    param(
        $Source,
        [string[]]$Names
    )

    if ($null -eq $Source) {
        return $null
    }

    foreach ($name in $Names) {
        if ($Source.PSObject.Properties.Name -contains $name) {
            $value = $Source.$name
            if ($null -ne $value -and -not ([string]::IsNullOrWhiteSpace([string]$value))) {
                return $value
            }
        }
    }

    return $null
}

function Resolve-Scope {
    param($Reservation)

    $scope = Get-FirstValue -Source $Reservation -Names @('appliedScopeType', 'scopeType', 'scope')

    if (-not $scope -and $Reservation.PSObject.Properties.Name -contains 'properties') {
        $scope = Get-FirstValue -Source $Reservation.properties -Names @('appliedScopeType', 'scopeType', 'scope')
    }

    if (-not $scope) {
        return $null
    }

    switch -Regex ($scope.ToString()) {
        'Single|SingleAppliedScope' { return 'Single' }
        'Shared' { return 'Shared' }
        'ManagementGroup' { return 'Management Group' }
        default { return $scope }
    }
}

function Resolve-Sku {
    param($Reservation)

    if ($Reservation.PSObject.Properties.Name -contains 'sku' -and $Reservation.sku) {
        $skuValue = Get-FirstValue -Source $Reservation.sku -Names @('name', 'tier', 'size')
        if ($skuValue) {
            return $skuValue
        }
    }

    if ($Reservation.PSObject.Properties.Name -contains 'properties' -and $Reservation.properties) {
        $propertySku = Get-FirstValue -Source $Reservation.properties -Names @('skuDescription', 'skuName', 'instanceFlexibilityRatio', 'displayName')
        if ($propertySku) {
            return $propertySku
        }
    }

    return Get-FirstValue -Source $Reservation -Names @('skuDescription', 'size')
}

function Resolve-Quantity {
    param($Reservation)

    $quantity = Get-FirstValue -Source $Reservation -Names @('quantity')
    if (-not $quantity -and $Reservation.PSObject.Properties.Name -contains 'properties') {
        $quantity = Get-FirstValue -Source $Reservation.properties -Names @('quantity')
    }

    if ($null -eq $quantity -or $quantity -eq '') {
        return $null
    }

    return [double]$quantity
}

function Resolve-DateValue {
    param(
        $Source,
        [string[]]$Names
    )

    $value = Get-FirstValue -Source $Source -Names $Names
    if (-not $value) {
        return $null
    }

    try {
        return ([datetimeoffset]$value).UtcDateTime.ToString('o')
    }
    catch {
        return [string]$value
    }
}

function Get-ReservationRecords {
    param(
        [object[]]$ReservationOrders,
        [string]$ResolvedSubscriptionId,
        [System.Collections.Generic.List[string]]$Warnings,
        [System.Collections.Generic.List[string]]$Errors,
        [ref]$CoverageSource,
        [ref]$HasReservationListFailures
    )

    $records = New-Object System.Collections.Generic.List[object]

    foreach ($order in (ConvertTo-Array $ReservationOrders)) {
        $orderId = Get-ResourceNameFromId -ResourceId (Get-FirstValue -Source $order -Names @('id'))
        if (-not $orderId) {
            $orderId = Get-FirstValue -Source $order -Names @('name', 'reservationOrderId')
        }

        if (-not $orderId) {
            $Warnings.Add('Encountered a reservation order without an ID; skipping it.')
            continue
        }

        $reservationResult = Invoke-AzJson -Arguments @(
            'reservations', 'reservation', 'list',
            '--reservation-order-id', $orderId,
            '--subscription', $ResolvedSubscriptionId,
            '--only-show-errors',
            '--output', 'json'
        ) -Context "reservation list for $orderId"

        if (-not $reservationResult.Success) {
            $HasReservationListFailures.Value = $true
            $Warnings.Add("Azure CLI reservation list failed for order $orderId. Attempting REST fallback. $($reservationResult.Error)")

            $reservationResult = Invoke-AzJson -Arguments @(
                'rest', '--method', 'GET',
                '--url', "https://management.azure.com/providers/Microsoft.Capacity/reservationOrders/$orderId/reservations?api-version=2022-11-01",
                '--subscription', $ResolvedSubscriptionId,
                '--only-show-errors',
                '--output', 'json'
            ) -Context "REST reservation list for $orderId"

            if ($reservationResult.Success) {
                $CoverageSource.Value = 'Mixed (Azure CLI + REST fallback)'
            }
            else {
                $Errors.Add("Unable to enumerate reservations for order $orderId. $($reservationResult.Error)")
                continue
            }
        }

        $reservationData = $reservationResult.Data
        if ($reservationData -and $reservationData.PSObject.Properties.Name -contains 'value') {
            $reservationData = $reservationData.value
        }

        $reservationItems = ConvertTo-Array $reservationData

        foreach ($reservation in $reservationItems) {
            $properties = $null
            if ($reservation.PSObject.Properties.Name -contains 'properties') {
                $properties = $reservation.properties
            }

            $reservationType = Get-FirstValue -Source $reservation -Names @('reservedResourceType', 'reservationType')
            if (-not $reservationType -and $properties) {
                $reservationType = Get-FirstValue -Source $properties -Names @('reservedResourceType', 'reservationType')
            }

            $effectiveDateTime = $null
            $expiryDate = $null
            $displayName = $null
            $term = $null
            $region = Get-FirstValue -Source $reservation -Names @('location')
            $provisioningState = $null
            if ($properties) {
                $effectiveDateTime = Resolve-DateValue -Source $properties -Names @('effectiveDateTime', 'effectiveFromDate')
                $expiryDate = Resolve-DateValue -Source $properties -Names @('expiryDate', 'expiryDateTime', 'expiresOn')
                $displayName = Get-FirstValue -Source $properties -Names @('displayName')
                $term = Get-FirstValue -Source $properties -Names @('term')
                $provisioningState = Get-FirstValue -Source $properties -Names @('provisioningState')

                $region = Get-FirstValue -Source $properties -Names @('location', 'region')
                if (-not $region -and $properties.PSObject.Properties.Name -contains 'reservedResourceProperties' -and $properties.reservedResourceProperties) {
                    $region = Get-FirstValue -Source $properties.reservedResourceProperties -Names @('instanceFlexibility', 'region', 'location')
                }
            }

            $daysUntilExpiry = $null
            $expiringWithin90Days = $false
            if ($expiryDate) {
                try {
                    $expiry = [datetimeoffset]$expiryDate
                    $daysUntilExpiry = [int][Math]::Ceiling(($expiry.UtcDateTime - (Get-Date).ToUniversalTime()).TotalDays)
                    $expiringWithin90Days = $daysUntilExpiry -ge 0 -and $daysUntilExpiry -le 90
                }
                catch {
                }
            }

            $utilization = $null
            if ($properties) {
                $utilization = Get-FirstValue -Source $properties -Names @('utilization', 'utilizationPercentage', 'utilizationDetails')
            }

            $records.Add([pscustomobject][ordered]@{
                reservationOrderId   = $orderId
                reservationId        = Get-FirstValue -Source $reservation -Names @('name', 'reservationId')
                displayName          = $displayName
                reservationType      = $reservationType
                sku                  = Resolve-Sku -Reservation $reservation
                quantity             = Resolve-Quantity -Reservation $reservation
                term                 = $term
                scope                = Resolve-Scope -Reservation $reservation
                region               = $region
                provisioningState    = $provisioningState
                effectiveDateTime    = $effectiveDateTime
                expiryDate           = $expiryDate
                daysUntilExpiry      = $daysUntilExpiry
                expiringWithin90Days = $expiringWithin90Days
                utilization          = $utilization
                source               = $CoverageSource.Value
            })
        }
    }

    return $records
}

$warnings = New-Object System.Collections.Generic.List[string]
$errors = New-Object System.Collections.Generic.List[string]
$now = (Get-Date).ToUniversalTime()
$permissionNotes = 'No access to reservation data'
$coverageSource = 'Azure CLI'
$hasReservationListFailures = $false

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    $errors.Add('Azure CLI (az) is not installed or not available on PATH.')
}

$accountResult = $null
if ($errors.Count -eq 0) {
    if ($SubscriptionId) {
        $accountResult = Invoke-AzJson -Arguments @('account', 'show', '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'json') -Context 'subscription lookup'
        if (-not $accountResult.Success) {
            $warnings.Add("Unable to resolve subscription '$SubscriptionId'. Falling back to the current Azure CLI context. $($accountResult.Error)")
            $accountResult = $null
        }
    }

    if (-not $accountResult) {
        $accountResult = Invoke-AzJson -Arguments @('account', 'show', '--only-show-errors', '--output', 'json') -Context 'current subscription lookup'
        if (-not $accountResult.Success) {
            $errors.Add("Unable to resolve Azure subscription context. $($accountResult.Error)")
        }
    }
}

$resolvedSubscriptionId = [string]$SubscriptionId
$resolvedSubscriptionName = $null
if ($accountResult -and $accountResult.Success) {
    $resolvedSubscriptionId = [string]$accountResult.Data.id
    $resolvedSubscriptionName = [string]$accountResult.Data.name
}

$reservationOrders = @()
$orderCollectionSucceeded = $false

if ($errors.Count -eq 0) {
    $orderResult = Invoke-AzJson -Arguments @('reservations', 'reservation-order', 'list', '--subscription', $resolvedSubscriptionId, '--only-show-errors', '--output', 'json') -Context 'reservation-order list'

    if ($orderResult.Success) {
        $reservationOrders = ConvertTo-Array $orderResult.Data
        $orderCollectionSucceeded = $true
    }
    else {
        $warnings.Add("Azure CLI reservation-order list failed. Attempting REST fallback. $($orderResult.Error)")
        $orderResult = Invoke-AzJson -Arguments @(
            'rest', '--method', 'GET',
            '--url', 'https://management.azure.com/providers/Microsoft.Capacity/reservationOrders?api-version=2022-11-01',
            '--subscription', $resolvedSubscriptionId,
            '--only-show-errors',
            '--output', 'json'
        ) -Context 'reservation-order REST list'

        if ($orderResult.Success) {
            $coverageSource = 'REST fallback'
            $reservationOrders = ConvertTo-Array $orderResult.Data.value
            $orderCollectionSucceeded = $true
        }
        else {
            $errors.Add("Unable to enumerate reservation orders. $($orderResult.Error)")
        }
    }
}

$records = New-Object System.Collections.Generic.List[object]
if ($orderCollectionSucceeded -and $reservationOrders.Count -gt 0) {
    $records = Get-ReservationRecords -ReservationOrders $reservationOrders -ResolvedSubscriptionId $resolvedSubscriptionId -Warnings $warnings -Errors $errors -CoverageSource ([ref]$coverageSource) -HasReservationListFailures ([ref]$hasReservationListFailures)
}

if ($errors.Count -eq 0 -and $orderCollectionSucceeded) {
    if ($hasReservationListFailures) {
        $permissionNotes = 'Limited access to reservation data'
    }
    else {
        $permissionNotes = 'Full access to reservation data'
    }
}
elseif ($orderCollectionSucceeded -and $reservationOrders.Count -eq 0) {
    $permissionNotes = 'Full access to reservation data'
}
elseif ($warnings.Count -gt 0 -and $records.Count -gt 0) {
    $permissionNotes = 'Limited access to reservation data'
}

$typeSummary = [ordered]@{}
$activeReservations = 0
$expiringSoon = 0

foreach ($record in $records) {
    $typeKey = [string]$record.reservationType
    if ([string]::IsNullOrWhiteSpace($typeKey)) {
        $typeKey = 'Unknown'
    }

    if (-not $typeSummary.Contains($typeKey)) {
        $typeSummary[$typeKey] = 0
    }
    $typeSummary[$typeKey]++

    if ($record.expiringWithin90Days) {
        $expiringSoon++
    }

    if ($record.expiryDate) {
        try {
            if (([datetimeoffset]$record.expiryDate).UtcDateTime -ge $now) {
                $activeReservations++
            }
        }
        catch {
        }
    }
}

$coverageNotes = switch ($permissionNotes) {
    'Full access to reservation data' {
        if ($records.Count -eq 0) {
            'Reservation queries succeeded, but no reservations were returned for the current context.'
        }
        else {
            "Collected reservation data via $coverageSource."
        }
    }
    'Limited access to reservation data' {
        "Collected partial reservation data via $coverageSource. Review warnings/errors for access gaps."
    }
    default {
        'Reservation data could not be collected. Output is intentionally fail-soft so downstream tooling can still consume the file.'
    }
}

if ($records.Count -eq 0 -and $permissionNotes -eq 'Full access to reservation data') {
    $warnings.Add('No reservations were found. This is a valid result for subscriptions without Reserved Instances.')
}

$errorArray = $errors.ToArray()
$warningArray = $warnings.ToArray()
$recordArray = $records.ToArray()

$envelope = [ordered]@{
    metadata = [ordered]@{
        scriptName       = 'Get-AzReservedInstances'
        subscriptionId   = $resolvedSubscriptionId
        subscriptionName = $resolvedSubscriptionName
        collectedAt      = (Get-Date).ToUniversalTime().ToString('o')
        errors           = $errorArray
        warnings         = $warningArray
        permissionNotes  = $permissionNotes
    }
    summary = [ordered]@{
        totalReservations    = $recordArray.Count
        activeReservations   = $activeReservations
        expiringWithin90Days = $expiringSoon
        reservationsByType   = $typeSummary
        coverageNotes        = $coverageNotes
    }
    records = $recordArray
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$outputFile = Join-Path -Path $OutputPath -ChildPath 'reserved-instances.json'
$envelope | ConvertTo-Json -Depth 20 | Set-Content -Path $outputFile -Encoding UTF8

Write-Host "Reserved Instances output: $outputFile"
Write-Host "Total reservations: $($records.Count)"
$typeSummaryText = 'None'
if ($typeSummary.Count -gt 0) {
    $typeSummaryText = ($typeSummary.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
}

Write-Host "Reservation types: $typeSummaryText"
Write-Host "Expiring within 90 days: $expiringSoon"
if ($warnings.Count -gt 0 -or $errors.Count -gt 0) {
    Write-Host 'Permission/access notes:'
    $notes = @($warnings)
    $notes += @($errors)
    foreach ($message in $notes) {
        Write-Host " - $message"
    }
}
