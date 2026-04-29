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

$scriptName = 'Get-AzServiceInventory'
$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$resolvedSubscriptionId = ''
$resolvedSubscriptionName = ''

function Add-InventoryError {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $errors.Add($Message)
    }
}

function Add-InventoryWarning {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $warnings.Add($Message)
    }
}

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

function Get-SkuDisplayValue {
    param($Sku)

    if ($null -eq $Sku) {
        return ''
    }

    if ($Sku -is [string]) {
        return $Sku
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($propertyName in 'name', 'tier', 'size', 'family', 'model', 'capacity') {
        $property = $Sku.PSObject.Properties[$propertyName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            $parts.Add([string]$property.Value)
        }
    }

    if ($parts.Count -gt 0) {
        return ($parts | Select-Object -Unique) -join ' | '
    }

    return ($Sku | ConvertTo-Json -Depth 10 -Compress)
}

function Get-GroupedCounts {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IEnumerable]$Items,

        [Parameter(Mandatory)]
        [string]$PropertyName,

        [Parameter(Mandatory)]
        [string]$OutputKey
    )

    @(
        $Items |
            Group-Object -Property $PropertyName |
            Sort-Object -Property Count, Name -Descending |
            ForEach-Object {
                [ordered]@{
                    $OutputKey = if ([string]::IsNullOrWhiteSpace([string]$_.Name)) { 'global' } else { [string]$_.Name }
                    count      = [int]$_.Count
                }
            }
    )
}

try {
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $resolvedOutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

    $subscriptionArgs = @('account', 'show', '--only-show-errors', '--output', 'json')
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $subscriptionArgs += @('--subscription', $SubscriptionId)
    }

    $subscription = Invoke-AzCliJson -Arguments $subscriptionArgs
    if ($null -eq $subscription) {
        throw 'Unable to resolve the current Azure subscription.'
    }

    $resolvedSubscriptionId = [string]$subscription.id
    $resolvedSubscriptionName = [string]$subscription.name

    if ([string]::IsNullOrWhiteSpace($resolvedSubscriptionId)) {
        throw 'Resolved subscription ID is empty.'
    }

    $query = @"
Resources
| order by id asc
| project name, type, location = tostring(location), resourceGroup = tostring(resourceGroup), tags, sku
"@

    $records = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null

    do {
        $graphArgs = @(
            'graph', 'query',
            '--subscriptions', $resolvedSubscriptionId,
            '--first', '1000',
            '-q', $query,
            '--only-show-errors',
            '--output', 'json'
        )

        if (-not [string]::IsNullOrWhiteSpace([string]$skipToken)) {
            $graphArgs += @('--skip-token', [string]$skipToken)
        }

        $page = Invoke-AzCliJson -Arguments $graphArgs
        if ($null -eq $page) {
            break
        }

        foreach ($resource in @($page.data)) {
            $location = [string]$resource.location
            $resourceGroup = [string]$resource.resourceGroup

            if ([string]::IsNullOrWhiteSpace($location)) {
                $location = 'global'
            }

            if ([string]::IsNullOrWhiteSpace($resourceGroup)) {
                $resourceGroup = 'global'
            }

            $records.Add([pscustomobject][ordered]@{
                name          = [string]$resource.name
                type          = [string]$resource.type
                location      = $location
                resourceGroup = $resourceGroup
                sku           = Get-SkuDisplayValue -Sku $resource.sku
                tags          = if ($null -eq $resource.tags) { @{} } else { $resource.tags }
            })
        }

        $skipToken = $null
        foreach ($tokenProperty in 'skipToken', 'skip_token') {
            if ($page.PSObject.Properties.Name -contains $tokenProperty) {
                $skipToken = $page.$tokenProperty
                break
            }
        }
    }
    while (-not [string]::IsNullOrWhiteSpace([string]$skipToken))

    if ($records.Count -eq 0) {
        Add-InventoryWarning -Message 'No resources were returned by Azure Resource Graph.'
    }

    $resourceTypeCounts = Get-GroupedCounts -Items $records -PropertyName 'type' -OutputKey 'type'
    $regionCounts = Get-GroupedCounts -Items $records -PropertyName 'location' -OutputKey 'region'
    $resourceGroupCounts = Get-GroupedCounts -Items $records -PropertyName 'resourceGroup' -OutputKey 'resourceGroup'

    $inventory = [ordered]@{
        metadata = [ordered]@{
            scriptName       = $scriptName
            subscriptionId   = $resolvedSubscriptionId
            subscriptionName = $resolvedSubscriptionName
            collectedAt      = (Get-Date).ToUniversalTime().ToString('o')
            errors           = @($errors)
            warnings         = @($warnings)
        }
        summary = [ordered]@{
            totalResources       = [int]$records.Count
            uniqueResourceTypes  = [int](@($resourceTypeCounts).Count)
            uniqueRegions        = [int](@($regionCounts).Count)
            uniqueResourceGroups = [int](@($resourceGroupCounts).Count)
            topResourceTypes     = @($resourceTypeCounts | Select-Object -First 5)
            topRegions           = @($regionCounts | Select-Object -First 5)
            resourceTypeCounts   = @($resourceTypeCounts)
            regionCounts         = @($regionCounts)
            resourceGroupCounts  = @($resourceGroupCounts)
        }
        records = @($records)
    }

    $outputFile = Join-Path -Path $resolvedOutputPath -ChildPath 'service-inventory.json'
    $inventory | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $outputFile -Encoding utf8

    Write-Host ("Subscription: {0} ({1})" -f $resolvedSubscriptionName, $resolvedSubscriptionId)
    Write-Host ("Output: {0}" -f $outputFile)
    Write-Host ("Total resources: {0}" -f $records.Count)

    Write-Host 'Top 5 resource types:'
    foreach ($entry in ($resourceTypeCounts | Select-Object -First 5)) {
        Write-Host (" - {0}: {1}" -f $entry.type, $entry.count)
    }

    Write-Host 'Top 5 regions:'
    foreach ($entry in ($regionCounts | Select-Object -First 5)) {
        Write-Host (" - {0}: {1}" -f $entry.region, $entry.count)
    }
}
catch {
    Add-InventoryError -Message $_.Exception.Message

    $failureEnvelope = [ordered]@{
        metadata = [ordered]@{
            scriptName       = $scriptName
            subscriptionId   = if ($resolvedSubscriptionId) { $resolvedSubscriptionId } else { $SubscriptionId }
            subscriptionName = if ($resolvedSubscriptionName) { $resolvedSubscriptionName } else { '' }
            collectedAt      = (Get-Date).ToUniversalTime().ToString('o')
            errors           = @($errors)
            warnings         = @($warnings)
        }
        summary = [ordered]@{
            totalResources       = 0
            uniqueResourceTypes  = 0
            uniqueRegions        = 0
            uniqueResourceGroups = 0
            topResourceTypes     = @()
            topRegions           = @()
            resourceTypeCounts   = @()
            regionCounts         = @()
            resourceGroupCounts  = @()
        }
        records = @()
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
            if (-not (Test-Path -LiteralPath $OutputPath)) {
                New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
            }

            $failurePath = Join-Path -Path (Resolve-Path -LiteralPath $OutputPath).Path -ChildPath 'service-inventory.json'
            $failureEnvelope | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $failurePath -Encoding utf8
            Write-Warning "Wrote failure envelope to $failurePath"
        }
    }
    catch {
        Write-Warning "Failed to write failure envelope: $($_.Exception.Message)"
    }

    Write-Error $_.Exception.Message
    exit 1
}
