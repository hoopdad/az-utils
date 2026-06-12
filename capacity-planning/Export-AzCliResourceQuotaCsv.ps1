# Thanks Ravi for enhancing pagination and property handling to support large-scale resource inventories without data truncation.

[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$SubscriptionIds,

    [Parameter()]
    [string]$OutputCsvPath = (Join-Path -Path (Get-Location).Path -ChildPath ("resource-quota-usage-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),

    [Parameter()]
    [string]$RegionFilter = '',

    [Parameter()]
    [string]$DiagnosticsCsvPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'yes_without_prompt'
$script:ProviderUsageSpecCache = @{}
$script:ProviderUnsupportedUsageCache = @{}
$script:QuotaDiagnostics = New-Object System.Collections.Generic.List[object]
$script:MinimumVersions = @{
    PowerShell             = '5.1'
    AzureCli               = '2.40.0'
    ResourceGraphExtension = '2.0.0'
}

function ConvertTo-Version {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $null
    }

    if ($trimmed -match '^(\d+\.\d+\.\d+)') {
        return [version]$Matches[1]
    }

    if ($trimmed -match '^(\d+\.\d+)') {
        return [version]("{0}.0" -f $Matches[1])
    }

    return $null
}

function ConvertFrom-JsonCompat {
    param(
        [Parameter(Mandatory)]
        [string]$JsonText
    )

    $cfj = Get-Command ConvertFrom-Json -ErrorAction Stop
    $hasDepth = $false
    if ($null -ne $cfj.Parameters) {
        $hasDepth = $cfj.Parameters.ContainsKey('Depth')
    }

    if ($hasDepth) {
        return ($JsonText | ConvertFrom-Json -Depth 100)
    }

    return ($JsonText | ConvertFrom-Json)
}

function Test-PreflightDependencies {
    $errors = New-Object System.Collections.Generic.List[string]

    $psVersion = $PSVersionTable.PSVersion
    $requiredPsVersion = [version]$script:MinimumVersions.PowerShell
    if ($psVersion -lt $requiredPsVersion) {
        $errors.Add(("PowerShell {0}+ is required. Current version: {1}." -f $requiredPsVersion, $psVersion))
    }

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        $errors.Add('Azure CLI (az) is not installed or not on PATH.')
    }
    else {
        $azVersionRaw = (& az version --output json --only-show-errors 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($azVersionRaw)) {
            $errors.Add('Unable to read Azure CLI version. Run `az version` to verify your install.')
        }
        else {
            try {
                $azVersionData = ConvertFrom-JsonCompat -JsonText $azVersionRaw
                $azCliVersion = ConvertTo-Version -Value ([string]$azVersionData.'azure-cli')
                $requiredAzCliVersion = [version]$script:MinimumVersions.AzureCli

                if ($null -eq $azCliVersion) {
                    $errors.Add('Unable to parse Azure CLI version from `az version`.')
                }
                elseif ($azCliVersion -lt $requiredAzCliVersion) {
                    $errors.Add(("Azure CLI {0}+ is required. Current version: {1}." -f $requiredAzCliVersion, $azCliVersion))
                }

                $extensionVersionValue = ''
                if ($null -ne $azVersionData.extensions) {
                    $extensionVersionValue = [string]$azVersionData.extensions.'resource-graph'
                }

                if ([string]::IsNullOrWhiteSpace($extensionVersionValue)) {
                    $errors.Add((
                        "Azure CLI extension 'resource-graph' is required. Install it with: az extension add --name resource-graph"
                    ))
                }
                else {
                    $rgVersion = ConvertTo-Version -Value $extensionVersionValue
                    $requiredRgVersion = [version]$script:MinimumVersions.ResourceGraphExtension

                    if ($null -eq $rgVersion) {
                        $errors.Add("Unable to parse version for Azure CLI extension 'resource-graph'.")
                    }
                    elseif ($rgVersion -lt $requiredRgVersion) {
                        $errors.Add((
                            "Azure CLI extension 'resource-graph' {0}+ is required. Current version: {1}. Update with: az extension update --name resource-graph" -f $requiredRgVersion, $rgVersion
                        ))
                    }
                }
            }
            catch {
                $errors.Add("Failed to validate Azure CLI dependencies: $($_.Exception.Message)")
            }
        }
    }

    if ($errors.Count -gt 0) {
        throw ((@('Preflight dependency check failed:') + $errors) -join [Environment]::NewLine)
    }
}

function Add-QuotaDiagnostic {
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$SubscriptionName,

        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$Location,

        [Parameter()]
        [string]$AttemptedUrl,

        [Parameter()]
        [string]$ErrorMessage,

        [Parameter()]
        [string]$DiagnosticCategory = 'ActionableFailure'
    )

    $script:QuotaDiagnostics.Add([pscustomobject]@{
        subscriptionId   = $SubscriptionId
        subscriptionName = $SubscriptionName
        provider         = $Provider
        location         = $Location
        attemptedUrl     = $AttemptedUrl
        diagnosticCategory = $DiagnosticCategory
        errorMessage     = $ErrorMessage
    })
}

function Get-QuotaFailureCategory {
    param(
        [Parameter()]
        [string]$AttemptedUrl,

        [Parameter()]
        [string]$ErrorMessage
    )

    $combined = ("{0}`n{1}" -f [string]$AttemptedUrl, [string]$ErrorMessage).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($combined)) {
        return 'ActionableFailure'
    }

    if (
        $combined.Contains('authorizationfailed') -or
        $combined.Contains('forbidden') -or
        $combined.Contains('unauthorized') -or
        $combined.Contains('does not have authorization to perform action') -or
        $combined.Contains('insufficient privileges') -or
        $combined.Contains('permission') -or
        $combined.Contains('too many requests') -or
        $combined.Contains('throttl') -or
        $combined.Contains('timeout') -or
        $combined.Contains('temporar')
    ) {
        return 'ActionableFailure'
    }

    if (
        $combined.Contains('no usage endpoint discovered') -or
        $combined.Contains('noregisteredproviderfound') -or
        $combined.Contains('resourcetypenotfound') -or
        $combined.Contains('invalidresourcetype') -or
        $combined.Contains('resource not found') -or
        $combined.Contains('path not found') -or
        $combined.Contains('http status code 404') -or
        $combined.Contains('the requested resource was not found')
    ) {
        return 'UnsupportedEndpoint'
    }

    if ($combined.Contains('error: not found')) {
        return 'UnsupportedEndpoint'
    }

    return 'ActionableFailure'
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter()]
        [switch]$AllowFailure,

        [Parameter()]
        [ref]$FailureMessageRef
    )

    $output = & az @Arguments 2>&1
    $outputText = ($output | Out-String).Trim()

    if ($PSBoundParameters.ContainsKey('FailureMessageRef')) {
        $FailureMessageRef.Value = ''
    }

    if ($LASTEXITCODE -ne 0) {
        if ($PSBoundParameters.ContainsKey('FailureMessageRef')) {
            $FailureMessageRef.Value = $outputText
        }

        if ($AllowFailure) {
            return $null
        }

        $cmd = "az $($Arguments -join ' ')"
        throw "Azure CLI command failed: $cmd`n$outputText"
    }

    $jsonText = $outputText
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        return $null
    }

    return (ConvertFrom-JsonCompat -JsonText $jsonText)
}

function Get-Subscriptions {
    param(
        [string[]]$RequestedSubscriptionIds
    )

    $accounts = @(Invoke-AzJson -Arguments @('account', 'list', '--all', '--output', 'json', '--only-show-errors'))
    if ($RequestedSubscriptionIds -and $RequestedSubscriptionIds.Count -gt 0) {
        $lookup = @{}
        foreach ($sub in $RequestedSubscriptionIds) {
            $lookup[$sub.ToLowerInvariant()] = $true
        }

        return @(
            $accounts | Where-Object {
                $id = [string]$_.id
                $name = [string]$_.name
                $lookup.ContainsKey($id.ToLowerInvariant()) -or $lookup.ContainsKey($name.ToLowerInvariant())
            }
        )
    }

    return @($accounts | Where-Object { $_.state -eq 'Enabled' })
}

Test-PreflightDependencies

function Get-ResourcesForSubscription {
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter()]
        [string]$RegionFilter
    )

    $query = @"
resources
| where isnotempty(location)
| extend location = tolower(location)
| where location != 'global'
| extend resourceKind = tostring(['kind'])
| extend resourceProvider = tostring(split(type, '/')[0])
| project subscriptionId, name, type, location, sku = tostring(sku.name), tier = tostring(sku.tier), resourceKind, resourceProvider
"@

    if (-not [string]::IsNullOrWhiteSpace($RegionFilter)) {
        $regionLiteral = $RegionFilter.ToLowerInvariant().Replace("'", "''")
        $query += "`n| where location == '$regionLiteral'"
    }

    $allData = New-Object System.Collections.Generic.List[object]
    $skipToken = $null

    do {
        $graphArgs = @(
            'graph', 'query',
            '-q', $query,
            '--subscriptions', $SubscriptionId,
            '--first', '1000',
            '--output', 'json',
            '--only-show-errors'
        )

        if ($null -ne $skipToken) {
            $graphArgs += @('--skip-token', $skipToken)
        }

        $result = Invoke-AzJson -Arguments $graphArgs

        if ($null -eq $result -or $null -eq $result.data) {
            break
        }

        foreach ($item in $result.data) {
            $allData.Add($item)
        }

        $skipToken = $null
        $stProp = $result.PSObject.Properties['skip_token']
        if ($null -ne $stProp -and -not [string]::IsNullOrWhiteSpace([string]$stProp.Value)) {
            $skipToken = [string]$stProp.Value
        }
    } while ($null -ne $skipToken)

    return ,$allData.ToArray()
}

function Get-ObjectStringProperty {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    if ($null -eq $Object) {
        return ''
    }

    $prop = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $prop -or $null -eq $prop.Value) {
        return ''
    }

    return [string]$prop.Value
}

function Get-ResourceProviderFromRow {
    param(
        [Parameter(Mandatory)]
        [object]$Row
    )

    $provider = (Get-ObjectStringProperty -Object $Row -PropertyName 'resourceProvider').ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($provider)) {
        return $provider
    }

    $typeValue = (Get-ObjectStringProperty -Object $Row -PropertyName 'type').ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($typeValue) -and $typeValue.Contains('/')) {
        return $typeValue.Split('/')[0]
    }

    return ''
}

function Get-ProviderUsagePathSpecs {
    param(
        [Parameter(Mandatory)]
        [string]$Provider
    )

    $providerNormalized = $Provider.ToLowerInvariant()
    if ($script:ProviderUsageSpecCache.ContainsKey($providerNormalized)) {
        return $script:ProviderUsageSpecCache[$providerNormalized]
    }

    $specMap = @{}

    function Add-Spec {
        param(
            [Parameter(Mandatory)]
            [string]$Template,

            [Parameter()]
            [string[]]$Versions
        )

        if (-not $specMap.ContainsKey($Template)) {
            $specMap[$Template] = New-Object System.Collections.Generic.List[string]
        }

        foreach ($v in @($Versions)) {
            if ([string]::IsNullOrWhiteSpace([string]$v)) {
                continue
            }

            if (-not $specMap[$Template].Contains([string]$v)) {
                $specMap[$Template].Add([string]$v)
            }
        }
    }

    switch ($providerNormalized) {
        'microsoft.compute' {
            Add-Spec -Template '/subscriptions/{subscriptionId}/providers/Microsoft.Compute/locations/{location}/usages' -Versions @('2024-03-01', '2023-07-01', '2022-03-01')
        }
        'microsoft.network' {
            Add-Spec -Template '/subscriptions/{subscriptionId}/providers/Microsoft.Network/locations/{location}/usages' -Versions @('2024-05-01', '2023-09-01', '2022-05-01')
        }
        'microsoft.storage' {
            Add-Spec -Template '/subscriptions/{subscriptionId}/providers/Microsoft.Storage/locations/{location}/usages' -Versions @('2023-01-01', '2022-09-01')
        }
        'microsoft.sql' {
            Add-Spec -Template '/subscriptions/{subscriptionId}/providers/Microsoft.Sql/locations/{location}/usages' -Versions @('2021-11-01', '2020-11-01-preview')
        }
        'microsoft.web' {
            Add-Spec -Template '/subscriptions/{subscriptionId}/providers/Microsoft.Web/locations/{location}/usages' -Versions @('2023-12-01', '2022-09-01')
        }
    }

    $providerMeta = Invoke-AzJson -Arguments @(
        'provider', 'show',
        '--namespace', $Provider,
        '--output', 'json',
        '--only-show-errors'
    ) -AllowFailure

    if ($null -ne $providerMeta -and $null -ne $providerMeta.resourceTypes) {
        foreach ($rt in @($providerMeta.resourceTypes)) {
            $rtName = ([string]$rt.resourceType).ToLowerInvariant()
            $versions = @($rt.apiVersions)

            if ($rtName -eq 'locations/usages') {
                Add-Spec -Template '/subscriptions/{subscriptionId}/providers/{provider}/locations/{location}/usages' -Versions $versions
            }
            elseif ($rtName -eq 'usages') {
                Add-Spec -Template '/subscriptions/{subscriptionId}/providers/{provider}/usages' -Versions $versions
            }
        }
    }

    $specs = @(
        $specMap.GetEnumerator() |
            ForEach-Object {
                [pscustomobject]@{
                    PathTemplate = $_.Key
                    ApiVersions  = @($_.Value)
                }
            }
    )

    $script:ProviderUsageSpecCache[$providerNormalized] = $specs
    return $specs
}

function Get-UsagePayload {
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$Location,

        [Parameter()]
        [ref]$LastAttemptedUrl,

        [Parameter()]
        [ref]$LastFailureMessage
    )

    if ($PSBoundParameters.ContainsKey('LastAttemptedUrl')) {
        $LastAttemptedUrl.Value = ''
    }
    if ($PSBoundParameters.ContainsKey('LastFailureMessage')) {
        $LastFailureMessage.Value = ''
    }

    $specs = @(Get-ProviderUsagePathSpecs -Provider $Provider)
    if ($null -eq $specs -or $specs.Count -eq 0) {
        if ($PSBoundParameters.ContainsKey('LastFailureMessage')) {
            $LastFailureMessage.Value = "No usage endpoint discovered for provider '$Provider'."
        }
        return $null
    }

    foreach ($spec in $specs) {
        foreach ($apiVersion in @($spec.ApiVersions)) {
            $path = [string]$spec.PathTemplate
            $path = $path.Replace('{subscriptionId}', $SubscriptionId)
            $path = $path.Replace('{provider}', $Provider)
            $path = $path.Replace('{location}', $Location)
            $url = "https://management.azure.com${path}?api-version=$apiVersion"
            $failureMessage = ''

            $response = Invoke-AzJson -Arguments @(
                'rest',
                '--method', 'get',
                '--url', $url,
                '--output', 'json',
                '--only-show-errors'
            ) -AllowFailure -FailureMessageRef ([ref]$failureMessage)

            if ($null -ne $response -and $null -ne $response.value) {
                return $response
            }

            if ($PSBoundParameters.ContainsKey('LastAttemptedUrl')) {
                $LastAttemptedUrl.Value = $url
            }
            if ($PSBoundParameters.ContainsKey('LastFailureMessage') -and -not [string]::IsNullOrWhiteSpace($failureMessage)) {
                $LastFailureMessage.Value = $failureMessage
            }
        }
    }

    return $null
}

function Get-PreferredMetric {
    param(
        [Parameter(Mandatory)]
        [object[]]$UsageItems
    )

    $ranked = foreach ($item in $UsageItems) {
        $used = 0.0
        $limit = 0.0
        $props = $item.PSObject.Properties
        if ($null -ne $props['currentValue'] -and "$($item.currentValue)" -ne '') {
            $used = [double]$item.currentValue
        }

        if ($null -ne $props['limit'] -and "$($item.limit)" -ne '') {
            $limit = [double]$item.limit
        }

        $metric = ''
        if ($null -ne $item.name) {
            if ($item.name -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$item.name)) {
                $metric = [string]$item.name
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$item.name.localizedValue)) {
                $metric = [string]$item.name.localizedValue
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$item.name.value)) {
                $metric = [string]$item.name.value
            }
        }

        if ([string]::IsNullOrWhiteSpace($metric) -and $null -ne $item.localName) {
            $metric = [string]$item.localName
        }

        $score = if ($limit -gt 0) { 1000000.0 + ($used / $limit) } else { $used }

        [pscustomobject]@{
            quotaMetric = $metric
            quotaUsed   = $used
            quotaLimit  = $limit
            score       = $score
        }
    }

    return ($ranked | Sort-Object -Property score -Descending | Select-Object -First 1)
}

function Get-ContainerRegistryQuotaMap {
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [object[]]$Resources
    )

    $map = @{}
    $acrResources = @(
        $Resources | Where-Object {
            (Get-ResourceProviderFromRow -Row $_) -eq 'microsoft.containerregistry' -and
            (Get-ObjectStringProperty -Object $_ -PropertyName 'type').ToLowerInvariant() -eq 'microsoft.containerregistry/registries'
        }
    )

    foreach ($acr in $acrResources) {
        $name = Get-ObjectStringProperty -Object $acr -PropertyName 'name'
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $usage = Invoke-AzJson -Arguments @(
            'acr', 'show-usage',
            '--name', $name,
            '--subscription', $SubscriptionId,
            '--output', 'json',
            '--only-show-errors'
        ) -AllowFailure

        if ($null -eq $usage -or $null -eq $usage.value) {
            continue
        }

        $best = Get-PreferredMetric -UsageItems @($usage.value)
        if ($null -eq $best) {
            continue
        }

        $map[$name.ToLowerInvariant()] = $best
    }

    return $map
}

function Get-QuotaMap {
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$SubscriptionName,

        [Parameter(Mandatory)]
        [object[]]$Resources
    )

    $map = @{}
    $normalizedRows = @(
        $Resources |
            ForEach-Object {
                $provider = Get-ResourceProviderFromRow -Row $_
                $location = (Get-ObjectStringProperty -Object $_ -PropertyName 'location').ToLowerInvariant()

                if ([string]::IsNullOrWhiteSpace($provider) -or [string]::IsNullOrWhiteSpace($location)) {
                    return
                }

                [pscustomobject]@{
                    provider = $provider
                    location = $location
                }
            }
    )

    $keys = @(
        $normalizedRows |
            Group-Object -Property { "{0}|{1}" -f $_.provider, $_.location } |
            ForEach-Object { $_.Name }
    )

    foreach ($key in $keys) {
        $parts = $key.Split('|', 2)
        $provider = $parts[0]
        $location = $parts[1]

        if ([string]::IsNullOrWhiteSpace($provider) -or [string]::IsNullOrWhiteSpace($location)) {
            continue
        }

        if ($script:ProviderUnsupportedUsageCache.ContainsKey($provider)) {
            Add-QuotaDiagnostic -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Provider $provider -Location $location -ErrorMessage 'Skipped quota lookup because provider usage endpoint is marked unsupported from a previous failure.' -DiagnosticCategory 'UnsupportedEndpoint'
            continue
        }

        $lastAttemptedUrl = ''
        $lastFailureMessage = ''
        $usagePayload = Get-UsagePayload -SubscriptionId $SubscriptionId -Provider $provider -Location $location -LastAttemptedUrl ([ref]$lastAttemptedUrl) -LastFailureMessage ([ref]$lastFailureMessage)
        if ($null -eq $usagePayload -or $null -eq $usagePayload.value) {
            $diagCategory = Get-QuotaFailureCategory -AttemptedUrl $lastAttemptedUrl -ErrorMessage $lastFailureMessage
            if ($diagCategory -eq 'UnsupportedEndpoint') {
                $script:ProviderUnsupportedUsageCache[$provider] = $true
            }

            Add-QuotaDiagnostic -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Provider $provider -Location $location -AttemptedUrl $lastAttemptedUrl -ErrorMessage $lastFailureMessage -DiagnosticCategory $diagCategory
            continue
        }

        $best = Get-PreferredMetric -UsageItems @($usagePayload.value)
        if ($null -eq $best) {
            continue
        }

        $map["$provider|$location"] = $best
    }

    return $map
}

$subscriptions = Get-Subscriptions -RequestedSubscriptionIds $SubscriptionIds
if (-not $subscriptions -or $subscriptions.Count -eq 0) {
    throw 'No subscriptions matched. Use az login and verify the provided -SubscriptionIds values.'
}

$allRows = New-Object System.Collections.Generic.List[object]

foreach ($sub in $subscriptions) {
    $subscriptionId = [string]$sub.id
    $subscriptionName = [string]$sub.name

    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        continue
    }

    Write-Host ("Collecting resources for {0} ({1})..." -f $subscriptionName, $subscriptionId)
    $resources = Get-ResourcesForSubscription -SubscriptionId $subscriptionId -RegionFilter $RegionFilter
    if (-not $resources -or $resources.Count -eq 0) {
        continue
    }

    Write-Host ("Collecting quota usage for providers/regions in {0}..." -f $subscriptionName)
    $diagStartCount = $script:QuotaDiagnostics.Count
    $quotaMap = Get-QuotaMap -SubscriptionId $subscriptionId -SubscriptionName $subscriptionName -Resources $resources
    $acrQuotaMap = Get-ContainerRegistryQuotaMap -SubscriptionId $subscriptionId -Resources $resources
    $diagAdded = $script:QuotaDiagnostics.Count - $diagStartCount
    if ($diagAdded -gt 0) {
        Write-Warning ("Quota calls failed for {0} provider/location combinations in {1}. See diagnostics CSV for details." -f $diagAdded, $subscriptionName)
    }

    foreach ($res in $resources) {
        $provider = Get-ResourceProviderFromRow -Row $res
        $location = (Get-ObjectStringProperty -Object $res -PropertyName 'location').ToLowerInvariant()
        $lookupKey = "$provider|$location"

        $quota = $null
        if ($quotaMap.ContainsKey($lookupKey)) {
            $quota = $quotaMap[$lookupKey]
        }

        if ($null -eq $quota -and $provider -eq 'microsoft.containerregistry') {
            $acrKey = (Get-ObjectStringProperty -Object $res -PropertyName 'name').ToLowerInvariant()
            if ($acrQuotaMap.ContainsKey($acrKey)) {
                $quota = $acrQuotaMap[$acrKey]
            }
        }

        $allRows.Add([pscustomobject]@{
            subscriptionName = $subscriptionName
            name             = Get-ObjectStringProperty -Object $res -PropertyName 'name'
            type             = Get-ObjectStringProperty -Object $res -PropertyName 'type'
            location         = Get-ObjectStringProperty -Object $res -PropertyName 'location'
            sku              = Get-ObjectStringProperty -Object $res -PropertyName 'sku'
            tier             = Get-ObjectStringProperty -Object $res -PropertyName 'tier'
            resourceKind     = Get-ObjectStringProperty -Object $res -PropertyName 'resourceKind'
            quotaLimit       = if ($null -ne $quota) { $quota.quotaLimit } else { $null }
            quotaUsed        = if ($null -ne $quota) { $quota.quotaUsed } else { $null }
            quotaMetric      = if ($null -ne $quota) { $quota.quotaMetric } else { $null }
        })
    }
}

$outputDir = Split-Path -Path $OutputCsvPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir)) {
    $null = New-Item -ItemType Directory -Path $outputDir -Force
}

$allRows |
    Sort-Object -Property subscriptionName, type, location, name |
    Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8

Write-Host ("Export complete: {0}" -f $OutputCsvPath)

if ($script:QuotaDiagnostics.Count -gt 0) {
    if ([string]::IsNullOrWhiteSpace($DiagnosticsCsvPath)) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($OutputCsvPath)
        $dir = Split-Path -Path $OutputCsvPath -Parent
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $dir = (Get-Location).Path
        }
        $DiagnosticsCsvPath = Join-Path -Path $dir -ChildPath ("{0}-quota-diagnostics.csv" -f $base)
    }

    $diagDir = Split-Path -Path $DiagnosticsCsvPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($diagDir) -and -not (Test-Path -LiteralPath $diagDir)) {
        $null = New-Item -ItemType Directory -Path $diagDir -Force
    }

    $script:QuotaDiagnostics |
        Sort-Object -Property subscriptionName, provider, location |
        Export-Csv -Path $DiagnosticsCsvPath -NoTypeInformation -Encoding UTF8

    Write-Warning ("Quota diagnostics exported: {0}" -f $DiagnosticsCsvPath)
}