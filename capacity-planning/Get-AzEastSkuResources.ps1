[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$SubscriptionId,

    [Parameter()]
    [ValidateSet('Table', 'Json', 'Csv')]
    [string]$OutputFormat = 'Table',

    [Parameter()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'yes_without_prompt'

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

function Get-ObjectPropertyString {
    param(
        [Parameter()]
        $InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return ''
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ''
    }

    return [string]$property.Value
}

$query = @'
Resources
| where isnotempty(sku)
| where location contains "east"
| project subscriptionId, name, type, location, sku = tostring(sku.name), tier = tostring(sku.tier), kind
| join kind=leftouter (
    ResourceContainers
    | where type == "microsoft.resources/subscriptions"
    | project subscriptionId, subscriptionName = name
) on subscriptionId
| project subscriptionName, name, type, location, sku, tier, kind
| order by type, subscriptionName
'@

$records = [System.Collections.Generic.List[object]]::new()
$skipToken = $null

do {
    $graphArgs = @(
        'graph', 'query',
        '--first', '1000',
        '-q', $query,
        '--only-show-errors',
        '--output', 'json'
    )

    if ($null -ne $SubscriptionId -and $SubscriptionId.Count -gt 0) {
        $graphArgs += @('--subscriptions')
        $graphArgs += $SubscriptionId
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$skipToken)) {
        $graphArgs += @('--skip-token', [string]$skipToken)
    }

    $page = Invoke-AzCliJson -Arguments $graphArgs
    if ($null -eq $page) {
        break
    }

    $pageData = @()
    if ($page.PSObject.Properties.Name -contains 'data' -and $null -ne $page.data) {
        $pageData = @($page.data)
    }

    foreach ($resource in $pageData) {
        $records.Add([pscustomobject][ordered]@{
            subscriptionName = Get-ObjectPropertyString -InputObject $resource -Name 'subscriptionName'
            name             = Get-ObjectPropertyString -InputObject $resource -Name 'name'
            type             = Get-ObjectPropertyString -InputObject $resource -Name 'type'
            location         = Get-ObjectPropertyString -InputObject $resource -Name 'location'
            sku              = Get-ObjectPropertyString -InputObject $resource -Name 'sku'
            tier             = Get-ObjectPropertyString -InputObject $resource -Name 'tier'
            kind             = Get-ObjectPropertyString -InputObject $resource -Name 'kind'
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

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $parent = Split-Path -Path $OutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    switch ($OutputFormat) {
        'Json' {
            ConvertTo-Json -InputObject @($records) -Depth 100 | Set-Content -LiteralPath $OutputPath -Encoding utf8
        }
        'Csv' {
            $records | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8
        }
        'Table' {
            $records | Format-Table -AutoSize | Out-String -Width 4096 | Set-Content -LiteralPath $OutputPath -Encoding utf8
        }
    }

    Write-Host ("Wrote {0} rows to {1}" -f $records.Count, $OutputPath)
    return
}

switch ($OutputFormat) {
    'Json' {
        ConvertTo-Json -InputObject @($records) -Depth 100
    }
    'Csv' {
        $records | ConvertTo-Csv -NoTypeInformation
    }
    'Table' {
        $records | Format-Table -AutoSize
    }
}
