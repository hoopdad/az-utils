# run with:
# pwsh Export-AzCliResourceQuotaCsv.ps1 -OutputCsvPath ./reports/resource-quota-usage.csv -AllEnabledSubscriptions

[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$SubscriptionIds,

    [Parameter()]
    [string]$SubscriptionListPath = '',

    [Parameter()]
    [switch]$AllEnabledSubscriptions,

    [Parameter()]
    [string]$OutputCsvPath = (Join-Path -Path (Get-Location).Path -ChildPath ("resource-quota-usage-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),

    [Parameter()]
    [string]$RegionFilter = '',

    [Parameter()]
    [string]$DiagnosticsCsvPath = '',

    [Parameter()]
    [string]$RegionManifestPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'yes_without_prompt'
$script:ProviderUsageSpecCache = @{}
$script:ProviderUnsupportedUsageCache = @{}
$script:UsageApiVersionCache = @{}
$script:QuotaDiagnostics = New-Object System.Collections.Generic.List[object]
$script:SkippedSubscriptions = New-Object System.Collections.Generic.List[object]
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
        $errors.Add("Azure CLI (az) is not installed or not on PATH. Install it with 'winget install Microsoft.AzureCLI' (or your package manager), then run 'az login'.")
    }
    else {
        $accountShowOutput = (& az account show --output json --only-show-errors 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            $errors.Add((
                "Azure CLI is installed but not authenticated. Run 'az login' and ensure the target subscription is selected with 'az account set --subscription <subscriptionId>'. Details: {0}" -f $accountShowOutput
            ))
        }

        $azVersionRaw = (& az version --output json --only-show-errors 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($azVersionRaw)) {
            $errors.Add("Unable to read Azure CLI version. Run 'az version' to verify your install.")
        }
        else {
            try {
                $azVersionData = ConvertFrom-JsonCompat -JsonText $azVersionRaw
                $azCliVersion = ConvertTo-Version -Value ([string]$azVersionData.'azure-cli')
                $requiredAzCliVersion = [version]$script:MinimumVersions.AzureCli

                if ($null -eq $azCliVersion) {
                    $errors.Add("Unable to parse Azure CLI version from 'az version'.")
                }
                elseif ($azCliVersion -lt $requiredAzCliVersion) {
                    $errors.Add(("Azure CLI {0}+ is required. Current version: {1}. Upgrade with 'az upgrade'." -f $requiredAzCliVersion, $azCliVersion))
                }

                $extensionVersionValue = ''
                $extensionShowOutput = (& az extension show --name resource-graph --output json --only-show-errors 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($extensionShowOutput)) {
                    $extensionData = ConvertFrom-JsonCompat -JsonText $extensionShowOutput
                    $extensionVersionValue = [string]$extensionData.version
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
        $message = @(
            'Preflight dependency check failed. Resolve the following items:'
            $errors
            'After fixing, re-run the script.'
        )
        throw ($message -join [Environment]::NewLine)
    }
}

function Test-MinimumPermissions {
    param(
        [Parameter(Mandatory)]
        [object[]]$Subscriptions,

        [Parameter()]
        [switch]$SkipInaccessibleSubscriptions
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $accessibleSubscriptions = New-Object System.Collections.Generic.List[object]
    $probeQuery = 'resources | take 1'

    foreach ($sub in @($Subscriptions)) {
        $subscriptionId = [string]$sub.id
        $subscriptionName = [string]$sub.name

        if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
            continue
        }

        $output = (& az graph query -q $probeQuery --subscriptions $subscriptionId --first 1 --output json --only-show-errors 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            $firstErrorLine = ''
            foreach ($line in ($output -split "`r?`n")) {
                $trimmed = [string]$line
                if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                    $firstErrorLine = $trimmed
                    break
                }
            }

            if ([string]::IsNullOrWhiteSpace($firstErrorLine)) {
                $firstErrorLine = $output
            }

            if ($SkipInaccessibleSubscriptions) {
                $script:SkippedSubscriptions.Add([pscustomobject]@{
                    subscriptionId   = $subscriptionId
                    subscriptionName = $subscriptionName
                    reason           = $firstErrorLine
                })
                Write-Warning ((
                    "Skipping subscription '{0}' ({1}) because az graph query failed. Reader is required. Details: {2}" -f $subscriptionName, $subscriptionId, $firstErrorLine
                ))
                continue
            }

            $errors.Add((
                "Subscription '{0}' ({1}): minimum permission check failed for 'az graph query'. Required minimum access is built-in Reader on the subscription. Fix: ask a subscription owner to grant Reader, then run 'az login' and retry. Details: {2}" -f $subscriptionName, $subscriptionId, $firstErrorLine
            ))
            continue
        }

        $accessibleSubscriptions.Add($sub)
    }

    if ($errors.Count -gt 0) {
        $message = @(
            'Preflight permission check failed. The script requires Reader on every target subscription:'
            $errors
            "Tip: If your access was just granted, refresh your token with 'az login'."
        )
        throw ($message -join [Environment]::NewLine)
    }

    if ($accessibleSubscriptions.Count -eq 0) {
        if ($SkipInaccessibleSubscriptions -and $script:SkippedSubscriptions.Count -gt 0) {
            throw 'No accessible subscriptions remain after the permission check. Grant Reader on at least one target subscription or use a narrower subscription selection.'
        }

        throw 'No subscriptions passed the permission check.'
    }

    return $accessibleSubscriptions.ToArray()
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
        [string[]]$RequestedSubscriptionIds,

        [string]$SubscriptionListPath,

        [switch]$AllEnabledSubscriptions
    )

    $currentAccount = Invoke-AzJson -Arguments @('account', 'show', '--output', 'json', '--only-show-errors')
    if ($null -eq $currentAccount -or [string]::IsNullOrWhiteSpace([string]$currentAccount.id)) {
        throw 'Unable to determine the current Azure CLI subscription. Run az account show to verify your context.'
    }

    $currentTenantId = [string]$currentAccount.tenantId
    $accounts = @(Invoke-AzJson -Arguments @('account', 'list', '--all', '--output', 'json', '--only-show-errors'))
    $enabledAccounts = @($accounts | Where-Object { $_.state -eq 'Enabled' })
    $enabledAccountsInCurrentTenant = @(
        $enabledAccounts | Where-Object { [string]$_.tenantId -eq $currentTenantId }
    )
    $resolvedSubscriptionIds = New-Object System.Collections.Generic.List[string]

    foreach ($sub in @($RequestedSubscriptionIds)) {
        $trimmed = [string]$sub
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $resolvedSubscriptionIds.Add($trimmed.Trim())
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionListPath)) {
        if (-not (Test-Path -LiteralPath $SubscriptionListPath)) {
            throw "Subscription list file not found: $SubscriptionListPath"
        }

        foreach ($line in (Get-Content -LiteralPath $SubscriptionListPath)) {
            $trimmed = ([string]$line).Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
                continue
            }

            $candidate = (($trimmed -split ',', 2)[0]).Trim()
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $resolvedSubscriptionIds.Add($candidate)
            }
        }
    }

    if ($resolvedSubscriptionIds.Count -gt 0) {
        $lookup = @{}
        foreach ($sub in @($resolvedSubscriptionIds)) {
            $lookup[$sub.ToLowerInvariant()] = $true
        }

        $matchedSubscriptions = @(
            $enabledAccounts | Where-Object {
                $id = [string]$_.id
                $name = [string]$_.name
                $lookup.ContainsKey($id.ToLowerInvariant()) -or $lookup.ContainsKey($name.ToLowerInvariant())
            }
        )

        $matchedLookup = @{}
        foreach ($match in $matchedSubscriptions) {
            $matchedLookup[[string]$match.id.ToLowerInvariant()] = $true
            $matchedLookup[[string]$match.name.ToLowerInvariant()] = $true
        }

        $unmatched = @(
            $resolvedSubscriptionIds |
                Where-Object { -not $matchedLookup.ContainsKey(([string]$_).ToLowerInvariant()) } |
                Select-Object -Unique
        )

        if ($unmatched.Count -gt 0) {
            throw ((
                "The following subscriptions were not found among enabled subscriptions visible to the current Azure CLI context: {0}" -f ($unmatched -join ', ')
            ))
        }

        return $matchedSubscriptions
    }

    if ($AllEnabledSubscriptions) {
        return $enabledAccountsInCurrentTenant
    }

    return @(
        $enabledAccountsInCurrentTenant | Where-Object { [string]$_.id -eq [string]$currentAccount.id }
    )
}

Test-PreflightDependencies

$subscriptionTargetingModeCount = 0
if ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
    $subscriptionTargetingModeCount++
}
if (-not [string]::IsNullOrWhiteSpace($SubscriptionListPath)) {
    $subscriptionTargetingModeCount++
}
if ($AllEnabledSubscriptions) {
    $subscriptionTargetingModeCount++
}

if ($subscriptionTargetingModeCount -gt 1) {
    throw 'Choose only one subscription targeting mode: -SubscriptionIds, -SubscriptionListPath, or -AllEnabledSubscriptions.'
}

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

function Get-ActiveRegionRecords {
    param(
        [Parameter(Mandatory)]
        [object[]]$Resources
    )

    return @(
        $Resources |
            ForEach-Object {
                $location = (Get-ObjectStringProperty -Object $_ -PropertyName 'location').ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($location)) {
                    return
                }

                [pscustomobject]@{
                    location = $location
                }
            } |
            Group-Object -Property location |
            Sort-Object -Property Name |
            ForEach-Object {
                [pscustomobject]@{
                    activeRegion  = [string]$_.Name
                    resourceCount = [int]$_.Count
                }
            }
    )
}

function Get-PercentText {
    param(
        [Parameter(Mandatory)]
        [double]$Numerator,

        [Parameter(Mandatory)]
        [double]$Denominator
    )

    if ($Denominator -le 0) {
        return '0%'
    }

    return ('{0}%' -f [math]::Round(($Numerator / $Denominator) * 100, 1))
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
        $versionsToTry = @($spec.ApiVersions)
        $usageCacheKey = ("{0}|{1}" -f $Provider.ToLowerInvariant(), [string]$spec.PathTemplate)
        if ($script:UsageApiVersionCache.ContainsKey($usageCacheKey)) {
            $cachedVersion = [string]$script:UsageApiVersionCache[$usageCacheKey]
            if (-not [string]::IsNullOrWhiteSpace($cachedVersion) -and $versionsToTry -contains $cachedVersion) {
                $versionsToTry = @($cachedVersion) + @($versionsToTry | Where-Object { $_ -ne $cachedVersion })
            }
        }

        foreach ($apiVersion in $versionsToTry) {
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
                $script:UsageApiVersionCache[$usageCacheKey] = $apiVersion
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
        [object[]]$Resources,

        [Parameter(Mandatory)]
        [int]$SubscriptionOrdinal,

        [Parameter(Mandatory)]
        [int]$SubscriptionCount
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

    $regionNames = @(
        $normalizedRows |
            Group-Object -Property location |
            Sort-Object -Property Name |
            ForEach-Object { [string]$_.Name }
    )

    $regionIndexByLocation = @{}
    for ($i = 0; $i -lt $regionNames.Count; $i++) {
        $regionIndexByLocation[$regionNames[$i]] = $i + 1
    }

    $announcedRegions = @{}
    $totalWorkItems = $keys.Count
    $processedWorkItems = 0
    $heartbeatInterval = 25
    $startTime = Get-Date

    foreach ($key in $keys) {
        $parts = $key.Split('|', 2)
        $provider = $parts[0]
        $location = $parts[1]

        if ([string]::IsNullOrWhiteSpace($provider) -or [string]::IsNullOrWhiteSpace($location)) {
            continue
        }

        if (-not $announcedRegions.ContainsKey($location)) {
            $announcedRegions[$location] = $true
            $regionOrdinal = 0
            if ($regionIndexByLocation.ContainsKey($location)) {
                $regionOrdinal = [int]$regionIndexByLocation[$location]
            }

            $subscriptionPercent = Get-PercentText -Numerator $SubscriptionOrdinal -Denominator $SubscriptionCount
            $regionPercent = Get-PercentText -Numerator $regionOrdinal -Denominator $regionNames.Count
            Write-Host ((
                "Working on {0} in {1} (subscription {2}/{3}, {4}; region {5}/{6}, {7})" -f
                $SubscriptionName,
                $location,
                $SubscriptionOrdinal,
                $SubscriptionCount,
                $subscriptionPercent,
                $regionOrdinal,
                $regionNames.Count,
                $regionPercent
            ))
        }

        $processedWorkItems++
        $percentComplete = 0
        if ($totalWorkItems -gt 0) {
            $percentComplete = [math]::Min(100, [math]::Floor(($processedWorkItems * 100.0) / $totalWorkItems))
        }

        Write-Progress -Id 1 -Activity ("Quota collection in {0}" -f $SubscriptionName) -Status ("{0}/{1} provider-region combinations ({2})" -f $processedWorkItems, $totalWorkItems, $location) -PercentComplete $percentComplete

        if (($processedWorkItems % $heartbeatInterval) -eq 0 -or $processedWorkItems -eq 1) {
            $elapsed = (Get-Date) - $startTime
            Write-Host ("Still working in {0}: {1}/{2} combinations processed ({3} elapsed)." -f $SubscriptionName, $processedWorkItems, $totalWorkItems, $elapsed.ToString('hh\:mm\:ss'))
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

    Write-Progress -Id 1 -Activity ("Quota collection in {0}" -f $SubscriptionName) -Completed

    return $map
}

$subscriptions = Get-Subscriptions -RequestedSubscriptionIds $SubscriptionIds -SubscriptionListPath $SubscriptionListPath -AllEnabledSubscriptions:$AllEnabledSubscriptions
if (-not $subscriptions -or $subscriptions.Count -eq 0) {
    throw 'No subscriptions matched. Use az login and verify the selected subscription targeting mode.'
}

$targetTenantId = ''
$targetTenantName = ''
if ($subscriptions.Count -gt 0) {
    $targetTenantId = [string]$subscriptions[0].tenantId
    $targetTenantName = [string]$subscriptions[0].tenantDisplayName
}

if (-not [string]::IsNullOrWhiteSpace($targetTenantId)) {
    if ([string]::IsNullOrWhiteSpace($targetTenantName)) {
        Write-Host ("Target tenant: {0}" -f $targetTenantId)
    }
    else {
        Write-Host ("Target tenant: {0} ({1})" -f $targetTenantName, $targetTenantId)
    }
}

$skipInaccessibleSubscriptions = $false
if ($AllEnabledSubscriptions -and -not ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) -and [string]::IsNullOrWhiteSpace($SubscriptionListPath)) {
    $skipInaccessibleSubscriptions = $true
}

if ($skipInaccessibleSubscriptions) {
    Write-Host 'Skipping upfront per-subscription permission probe for all-enabled mode. Inaccessible subscriptions will be skipped lazily during collection.'
}
else {
    $subscriptions = @(Test-MinimumPermissions -Subscriptions $subscriptions -SkipInaccessibleSubscriptions:$skipInaccessibleSubscriptions)
}

if ($script:SkippedSubscriptions.Count -gt 0) {
    Write-Warning ("Skipping {0} inaccessible subscriptions and continuing with {1} accessible subscriptions." -f $script:SkippedSubscriptions.Count, $subscriptions.Count)
}

$runStartTime = Get-Date
$allRows = New-Object System.Collections.Generic.List[object]
$regionManifestRows = New-Object System.Collections.Generic.List[object]
$subscriptionSummaries = New-Object System.Collections.Generic.List[object]
$subscriptionCount = $subscriptions.Count
$subscriptionOrdinal = 0

foreach ($sub in $subscriptions) {
    $subscriptionStartTime = Get-Date
    $subscriptionOrdinal++
    $subscriptionId = [string]$sub.id
    $subscriptionName = [string]$sub.name

    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        continue
    }

    $subscriptionPercent = Get-PercentText -Numerator $subscriptionOrdinal -Denominator $subscriptionCount
    Write-Host ("Collecting resources for {0} ({1}) - subscription {2}/{3} ({4})..." -f $subscriptionName, $subscriptionId, $subscriptionOrdinal, $subscriptionCount, $subscriptionPercent)

    try {
        $resources = Get-ResourcesForSubscription -SubscriptionId $subscriptionId -RegionFilter $RegionFilter
    }
    catch {
        if ($skipInaccessibleSubscriptions) {
            $reason = $_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $reason = 'Unknown error while collecting resources.'
            }

            $script:SkippedSubscriptions.Add([pscustomobject]@{
                subscriptionId   = $subscriptionId
                subscriptionName = $subscriptionName
                reason           = $reason
            })

            Write-Warning ("Skipping subscription '{0}' ({1}) due to resource discovery failure. Details: {2}" -f $subscriptionName, $subscriptionId, $reason)

            $subscriptionElapsed = (Get-Date) - $subscriptionStartTime
            $subscriptionSummaries.Add([pscustomobject]@{
                subscriptionId        = $subscriptionId
                subscriptionName      = $subscriptionName
                status                = 'Skipped'
                activeRegionCount     = 0
                resourceCount         = 0
                quotaDiagnosticCount  = 0
                elapsed               = $subscriptionElapsed.ToString('hh\:mm\:ss')
            })
            continue
        }

        throw
    }

    if (-not $resources -or $resources.Count -eq 0) {
        $regionManifestRows.Add([pscustomobject]@{
            subscriptionId     = $subscriptionId
            subscriptionName   = $subscriptionName
            activeRegion       = ''
            resourceCount      = 0
            totalActiveRegions = 0
        })

        $subscriptionElapsed = (Get-Date) - $subscriptionStartTime
        $subscriptionSummaries.Add([pscustomobject]@{
            subscriptionId        = $subscriptionId
            subscriptionName      = $subscriptionName
            status                = 'NoResources'
            activeRegionCount     = 0
            resourceCount         = 0
            quotaDiagnosticCount  = 0
            elapsed               = $subscriptionElapsed.ToString('hh\:mm\:ss')
        })
        Write-Host ("Completed {0} in {1} (no resources found)." -f $subscriptionName, $subscriptionElapsed.ToString('hh\:mm\:ss'))
        continue
    }

    $activeRegions = @(Get-ActiveRegionRecords -Resources $resources)
    $activeRegionCount = $activeRegions.Count
    foreach ($region in $activeRegions) {
        $regionManifestRows.Add([pscustomobject]@{
            subscriptionId     = $subscriptionId
            subscriptionName   = $subscriptionName
            activeRegion       = $region.activeRegion
            resourceCount      = $region.resourceCount
            totalActiveRegions = $activeRegionCount
        })
    }

    Write-Host ("Discovered {0} active regions in {1}." -f $activeRegionCount, $subscriptionName)
    Write-Host ("Collecting quota usage for providers/regions in {0}..." -f $subscriptionName)
    $diagStartCount = $script:QuotaDiagnostics.Count
    $quotaMap = Get-QuotaMap -SubscriptionId $subscriptionId -SubscriptionName $subscriptionName -Resources $resources -SubscriptionOrdinal $subscriptionOrdinal -SubscriptionCount $subscriptionCount
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
            subscriptionId   = $subscriptionId
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

    $subscriptionElapsed = (Get-Date) - $subscriptionStartTime
    $subscriptionSummaries.Add([pscustomobject]@{
        subscriptionId        = $subscriptionId
        subscriptionName      = $subscriptionName
        status                = 'Completed'
        activeRegionCount     = $activeRegionCount
        resourceCount         = $resources.Count
        quotaDiagnosticCount  = $diagAdded
        elapsed               = $subscriptionElapsed.ToString('hh\:mm\:ss')
    })
    Write-Host ("Completed {0} in {1}." -f $subscriptionName, $subscriptionElapsed.ToString('hh\:mm\:ss'))
}

$totalElapsed = (Get-Date) - $runStartTime
Write-Host ("Processed {0} subscriptions in {1}." -f $subscriptionCount, $totalElapsed.ToString('hh\:mm\:ss'))
if ($subscriptionSummaries.Count -gt 0) {
    Write-Host 'Subscription timing summary:'
    $subscriptionSummaries |
        Sort-Object -Property subscriptionName |
        ForEach-Object {
            Write-Host (" - {0}: {1} (status={2}, regions={3}, resources={4}, diagnostics={5})" -f $_.subscriptionName, $_.elapsed, $_.status, $_.activeRegionCount, $_.resourceCount, $_.quotaDiagnosticCount)
        }
}

$outputDir = Split-Path -Path $OutputCsvPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir)) {
    $null = New-Item -ItemType Directory -Path $outputDir -Force
}

$allRows |
    Sort-Object -Property subscriptionName, subscriptionId, type, location, name |
    Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8

Write-Host ("Export complete: {0}" -f $OutputCsvPath)

if ([string]::IsNullOrWhiteSpace($RegionManifestPath)) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($OutputCsvPath)
    $dir = Split-Path -Path $OutputCsvPath -Parent
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $dir = (Get-Location).Path
    }
    $RegionManifestPath = Join-Path -Path $dir -ChildPath ("{0}-active-regions.csv" -f $base)
}

$regionManifestDir = Split-Path -Path $RegionManifestPath -Parent
if (-not [string]::IsNullOrWhiteSpace($regionManifestDir) -and -not (Test-Path -LiteralPath $regionManifestDir)) {
    $null = New-Item -ItemType Directory -Path $regionManifestDir -Force
}

$regionManifestRows |
    Sort-Object -Property subscriptionName, subscriptionId, activeRegion |
    Export-Csv -Path $RegionManifestPath -NoTypeInformation -Encoding UTF8

Write-Host ("Active region manifest exported: {0}" -f $RegionManifestPath)

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