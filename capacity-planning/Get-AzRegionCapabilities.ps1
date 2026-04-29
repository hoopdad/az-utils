[CmdletBinding()]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptName = 'Get-AzRegionCapabilities'
$metadataErrors = [System.Collections.Generic.List[object]]::new()
$metadataWarnings = [System.Collections.Generic.List[string]]::new()

function Add-MetadataError {
    param(
        [Parameter(Mandatory)]
        [string]$Step,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $metadataErrors.Add([ordered]@{
            step    = $Step
            message = $Message
        })
}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)]
        [string]$Step,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter()]
        [string]$Subscription,

        [Parameter()]
        [switch]$ExpectJson = $true
    )

    $azArguments = @($Arguments)
    if (-not [string]::IsNullOrWhiteSpace($Subscription)) {
        $azArguments += @('--subscription', $Subscription)
    }
    $azArguments += '--only-show-errors'
    if ($ExpectJson) {
        $azArguments += @('--output', 'json')
    }

    try {
        $commandOutput = & az @azArguments 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = ($commandOutput | Out-String).Trim()
    }
    catch {
        Add-MetadataError -Step $Step -Message $_.Exception.Message
        return $null
    }

    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($outputText)) {
            $outputText = "Azure CLI exited with code $exitCode."
        }
        Add-MetadataError -Step $Step -Message $outputText
        return $null
    }

    if (-not $ExpectJson) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($outputText)) {
        return $null
    }

    try {
        return $outputText | ConvertFrom-Json -Depth 100
    }
    catch {
        Add-MetadataError -Step $Step -Message "Failed to parse Azure CLI JSON output. $($_.Exception.Message)"
        return $null
    }
}

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory)]
        [string]$Step,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter()]
        [string]$Subscription
    )

    return Invoke-AzCli -Step $Step -Arguments $Arguments -Subscription $Subscription -ExpectJson
}

function Get-CapabilityValue {
    param(
        [Parameter()]
        [object[]]$Capabilities,

        [Parameter(Mandatory)]
        [string]$Name
    )

    foreach ($capability in @($Capabilities)) {
        if ($capability.name -eq $Name) {
            return $capability.value
        }
    }

    return $null
}

function Convert-ToNumberOrNull {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $doubleValue = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$doubleValue)) {
        if ($doubleValue -eq [math]::Truncate($doubleValue)) {
            return [int]$doubleValue
        }

        return [double]$doubleValue
    }

    return $null
}

function Get-NormalizedZones {
    param(
        [Parameter()]
        [AllowNull()]
        [object[]]$Zones
    )

    return @($Zones | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
}

function Get-ObjectPropertyValue {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

$subscriptionArgs = @('account', 'show')
if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $subscriptionArgs += @('--subscription', $SubscriptionId)
}

$subscription = Invoke-AzCliJson -Step 'account-show' -Arguments $subscriptionArgs
$resolvedSubscriptionId = if ($null -ne $subscription) { [string]$subscription.id } else { $null }
$resolvedSubscriptionName = if ($null -ne $subscription) { [string]$subscription.name } else { $null }

if ([string]::IsNullOrWhiteSpace($resolvedSubscriptionId)) {
    Add-MetadataError -Step 'account-show' -Message 'Unable to determine the current subscription.'
}

$regions = @()
$vmSkusRaw = @()

if (-not [string]::IsNullOrWhiteSpace($resolvedSubscriptionId)) {
    $regionData = Invoke-AzCliJson -Step 'list-locations' -Arguments @('account', 'list-locations') -Subscription $resolvedSubscriptionId
    if ($null -ne $regionData) {
        $regions = @($regionData)
    }

    $vmSkuData = Invoke-AzCliJson -Step 'list-vm-skus' -Arguments @('vm', 'list-skus', '--resource-type', 'virtualMachines') -Subscription $resolvedSubscriptionId
    if ($null -ne $vmSkuData) {
        $vmSkusRaw = @($vmSkuData)
    }
}

$vmSkusByRegion = @{}
$vmFamilySets = @{}
$totalVmSkuRecords = 0
$subscriptionRegions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($region in $regions) {
    $null = $subscriptionRegions.Add(([string]$region.name).ToLowerInvariant())
}

foreach ($sku in $vmSkusRaw) {
    $vCpus = Convert-ToNumberOrNull -Value (Get-CapabilityValue -Capabilities $sku.capabilities -Name 'vCPUs')
    $memoryGb = Convert-ToNumberOrNull -Value (Get-CapabilityValue -Capabilities $sku.capabilities -Name 'MemoryGB')
    $restrictions = @($sku.restrictions)

    $locationEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($locationInfo in @($sku.locationInfo)) {
        if ([string]::IsNullOrWhiteSpace([string]$locationInfo.location)) {
            continue
        }

        $locationEntries.Add([ordered]@{
                region = ([string]$locationInfo.location).ToLowerInvariant()
                zones  = (Get-NormalizedZones -Zones $locationInfo.zones)
            })
    }

    if ($locationEntries.Count -eq 0) {
        foreach ($location in @($sku.locations)) {
            if ([string]::IsNullOrWhiteSpace([string]$location)) {
                continue
            }

            $locationEntries.Add([ordered]@{
                    region = ([string]$location).ToLowerInvariant()
                    zones  = @()
                })
        }
    }

    foreach ($locationEntry in $locationEntries) {
        $regionName = [string]$locationEntry.region
        if ($subscriptionRegions.Count -gt 0 -and -not $subscriptionRegions.Contains($regionName)) {
            continue
        }

        if (-not $vmSkusByRegion.ContainsKey($regionName)) {
            $vmSkusByRegion[$regionName] = [System.Collections.Generic.List[object]]::new()
            $vmFamilySets[$regionName] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }

        $vmSkusByRegion[$regionName].Add([ordered]@{
                name         = $sku.name
                family       = $sku.family
                vCPUs        = $vCpus
                memoryGB     = $memoryGb
                zones        = @($locationEntry.zones)
                restrictions = $restrictions
            })
        $null = $vmFamilySets[$regionName].Add([string]$sku.family)
        $totalVmSkuRecords++
    }
}

$vmSkusByRegionOutput = [ordered]@{}
foreach ($regionName in ($vmSkusByRegion.Keys | Sort-Object)) {
    $vmSkusByRegionOutput[$regionName] = @($vmSkusByRegion[$regionName] | Sort-Object family, name)
}

$regionRecords = foreach ($region in ($regions | Sort-Object name)) {
    $normalizedRegionName = ([string]$region.name).ToLowerInvariant()
    $pairedRegion = $null
    $pairedRegionEntries = Get-ObjectPropertyValue -InputObject (Get-ObjectPropertyValue -InputObject $region -PropertyName 'metadata') -PropertyName 'pairedRegion'
    if ($null -ne $pairedRegionEntries) {
        $pairedRegion = @($pairedRegionEntries | Select-Object -ExpandProperty name -First 1)
    }

    $availabilityZones = @()
    $availabilityZoneMappings = Get-ObjectPropertyValue -InputObject $region -PropertyName 'availabilityZoneMappings'
    if ($null -ne $availabilityZoneMappings) {
        $availabilityZones = Get-NormalizedZones -Zones ($availabilityZoneMappings | Select-Object -ExpandProperty logicalZone)
    }

    [ordered]@{
        name                = $normalizedRegionName
        displayName         = $region.displayName
        pairedRegion        = if ($pairedRegion) { [string]$pairedRegion } else { $null }
        availabilityZones   = $availabilityZones
        vmFamiliesAvailable = if ($vmFamilySets.ContainsKey($normalizedRegionName)) { $vmFamilySets[$normalizedRegionName].Count } else { 0 }
    }
}

$regionsWithZoneSupport = @($regionRecords | Where-Object { @($_.availabilityZones).Count -gt 0 }).Count

$envelope = [ordered]@{
    metadata = [ordered]@{
        scriptName       = $scriptName
        subscriptionId   = $resolvedSubscriptionId
        subscriptionName = $resolvedSubscriptionName
        collectedAt      = [DateTime]::UtcNow.ToString('o')
        errors           = @($metadataErrors)
        warnings         = @($metadataWarnings | Sort-Object -Unique)
    }
    summary  = [ordered]@{
        totalRegions            = @($regionRecords).Count
        regionsWithZoneSupport  = $regionsWithZoneSupport
        totalVmSkus             = $totalVmSkuRecords
    }
    records  = [ordered]@{
        regions        = @($regionRecords)
        vmSkusByRegion = $vmSkusByRegionOutput
    }
}

$resolvedOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($resolvedOutputPath)) {
    $resolvedOutputPath = (Get-Location).Path
}

if (-not (Test-Path -LiteralPath $resolvedOutputPath)) {
    $null = New-Item -Path $resolvedOutputPath -ItemType Directory -Force
}

$outputFile = Join-Path -Path $resolvedOutputPath -ChildPath 'region-capabilities.json'
$envelope | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $outputFile -Encoding utf8

Write-Host "Regions: $($envelope.summary.totalRegions)"
Write-Host "Regions with zone support: $($envelope.summary.regionsWithZoneSupport)"
Write-Host "Total VM SKUs: $($envelope.summary.totalVmSkus)"
Write-Host "Output: $outputFile"

if ($envelope.metadata.errors.Count -gt 0) {
    Write-Warning ("Encountered {0} error(s). See metadata.errors in {1}" -f $envelope.metadata.errors.Count, $outputFile)
}
if ($envelope.metadata.warnings.Count -gt 0) {
    Write-Warning ("Encountered {0} warning(s). See metadata.warnings in {1}" -f $envelope.metadata.warnings.Count, $outputFile)
}
