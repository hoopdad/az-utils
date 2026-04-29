[CmdletBinding()]
param(
    [Parameter()]
    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'yes_without_prompt'

function Write-Status {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [string]$Color = 'White'
    )

    Write-Host $Message -ForegroundColor $Color
}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ($output | Out-String).Trim()
    }
}

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $result = Invoke-AzCli -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$($result.Output)"
    }

    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        return $null
    }

    return $result.Output | ConvertFrom-Json -Depth 100
}

function Ensure-ResourceGraphExtension {
    $extensions = Invoke-AzCliJson -Arguments @('extension', 'list', '--output', 'json', '--only-show-errors')
    $installedNames = @($extensions | ForEach-Object { $_.name })

    if ('resource-graph' -notin $installedNames) {
        Write-Status -Message 'Installing Azure CLI resource-graph extension...' -Color 'Yellow'
        $installResult = Invoke-AzCli -Arguments @('extension', 'add', '--name', 'resource-graph', '--only-show-errors')
        if ($installResult.ExitCode -ne 0) {
            throw "Failed to install resource-graph extension.`n$($installResult.Output)"
        }
    }
}

function Resolve-Subscription {
    param(
        [string]$RequestedSubscriptionId
    )

    $arguments = @('account', 'show', '--output', 'json', '--only-show-errors')
    if (-not [string]::IsNullOrWhiteSpace($RequestedSubscriptionId)) {
        $arguments += @('--subscription', $RequestedSubscriptionId)
    }

    return Invoke-AzCliJson -Arguments $arguments
}

function Test-ExpectedColumns {
    param(
        [Parameter(Mandatory)]
        [object]$Result,

        [Parameter(Mandatory)]
        [string[]]$ExpectedColumns
    )

    if ($null -eq $Result) {
        throw 'No JSON payload was returned.'
    }

    if ($Result.PSObject.Properties.Name -notcontains 'data') {
        throw 'The JSON payload did not contain a data property.'
    }

    $data = @($Result.data)
    if ($data.Count -eq 0) {
        return [pscustomobject]@{
            Success = $true
            Message = 'Query returned 0 rows; JSON validated but column inspection was skipped.'
        }
    }

    $actualColumns = @($data[0].PSObject.Properties.Name)
    $missingColumns = @(
        foreach ($column in $ExpectedColumns) {
            if ($column -notin $actualColumns) {
                $column
            }
        }
    )

    if ($missingColumns.Count -gt 0) {
        return [pscustomobject]@{
            Success = $false
            Message = "Missing expected columns: $($missingColumns -join ', ')"
        }
    }

    return [pscustomobject]@{
        Success = $true
        Message = "Columns verified: $($ExpectedColumns -join ', ')"
    }
}

$queries = @(
    [pscustomobject]@{
        Name = 'resource-inventory'
        FileName = 'resource-inventory.kql'
        ExpectedColumns = @('name', 'type', 'location', 'resourceGroup', 'sku')
    },
    [pscustomobject]@{
        Name = 'resource-summary'
        FileName = 'resource-summary.kql'
        ExpectedColumns = @('type', 'count_')
    },
    [pscustomobject]@{
        Name = 'region-usage'
        FileName = 'region-usage.kql'
        ExpectedColumns = @('location', 'count_')
    },
    [pscustomobject]@{
        Name = 'resource-overview'
        FileName = 'resource-overview.kql'
        ExpectedColumns = @('totalResources', 'uniqueTypes', 'uniqueRegions', 'uniqueResourceGroups')
    },
    [pscustomobject]@{
        Name = 'resource-inventory-detailed'
        FileName = 'resource-inventory-detailed.kql'
        ExpectedColumns = @('name', 'type', 'location', 'resourceGroup', 'skuName', 'skuTier', 'skuSize', 'skuCapacity', 'tags')
    }
)

$passed = 0
$failed = 0
$warnings = 0

Write-Status -Message 'Validating Azure Resource Graph queries...' -Color 'Cyan'

Ensure-ResourceGraphExtension
$subscription = Resolve-Subscription -RequestedSubscriptionId $SubscriptionId
$effectiveSubscriptionId = [string]$subscription.id

if ([string]::IsNullOrWhiteSpace($effectiveSubscriptionId)) {
    throw 'Unable to resolve the active Azure subscription ID.'
}

Write-Status -Message "Using subscription: $effectiveSubscriptionId" -Color 'DarkCyan'

foreach ($queryDefinition in $queries) {
    $queryPath = Join-Path -Path $PSScriptRoot -ChildPath $queryDefinition.FileName
    Write-Status -Message "Testing $($queryDefinition.FileName)..." -Color 'Cyan'

    try {
        if (-not (Test-Path -LiteralPath $queryPath -PathType Leaf)) {
            throw "Query file not found: $queryPath"
        }

        $queryText = Get-Content -LiteralPath $queryPath -Raw
        if ([string]::IsNullOrWhiteSpace($queryText)) {
            throw 'Query file is empty.'
        }

        $result = Invoke-AzCli -Arguments @(
            'graph', 'query',
            '--subscriptions', $effectiveSubscriptionId,
            '--first', '5',
            '-q', $queryText,
            '--output', 'json',
            '--only-show-errors'
        )

        if ($result.ExitCode -ne 0) {
            throw "Azure CLI returned exit code $($result.ExitCode).`n$($result.Output)"
        }

        if ([string]::IsNullOrWhiteSpace($result.Output)) {
            throw 'Azure CLI returned an empty response.'
        }

        $json = $result.Output | ConvertFrom-Json -Depth 100
        $columnCheck = Test-ExpectedColumns -Result $json -ExpectedColumns $queryDefinition.ExpectedColumns

        if (-not $columnCheck.Success) {
            throw $columnCheck.Message
        }

        if ($columnCheck.Message -like 'Query returned 0 rows*') {
            $warnings += 1
            Write-Status -Message "PASS $($queryDefinition.Name): $($columnCheck.Message)" -Color 'Yellow'
        }
        else {
            Write-Status -Message "PASS $($queryDefinition.Name): $($columnCheck.Message)" -Color 'Green'
        }

        $passed += 1
    }
    catch {
        $failed += 1
        Write-Status -Message "FAIL $($queryDefinition.Name): $($_.Exception.Message)" -Color 'Red'
    }
}

Write-Host ''
Write-Status -Message 'Summary' -Color 'Cyan'
Write-Status -Message "Passed: $passed" -Color 'Green'
Write-Status -Message "Warnings: $warnings" -Color 'Yellow'
if ($failed -gt 0) {
    Write-Status -Message "Failed: $failed" -Color 'Red'
    exit 1
}

Write-Status -Message 'Failed: 0' -Color 'Green'
