<#
.NOTICE
Sample code only. This script is provided "as is" without warranties or
guarantees of completeness, accuracy, availability, or fitness for a
particular environment. Azure resource associations, RBAC permissions, API
behavior, and Azure CLI output can vary. Review and validate the CSV before
using it for security, compliance, or remediation decisions.

.SYNOPSIS
Exports resources directly associated with Azure public IP addresses to CSV.

.DESCRIPTION
Lists public IP addresses in one or all selected subscriptions. For public IPs
attached to network interfaces, the script reports the associated virtual
machine when one exists and includes the NIC name. For other attachments, such
as load balancers, application gateways, Azure Firewall, Bastion, VPN gateways,
and NAT gateways, it reports the directly associated resource.

When -Tenant is supplied, the script signs in using an isolated Azure CLI
profile backed by a temporary AZURE_CONFIG_DIR. The isolated profile is removed
on exit, so the caller's default Azure CLI login is not changed.

.PARAMETER All
Scan all enabled subscriptions available in the selected tenant or ambient
Azure CLI session. Cannot be combined with -Subscription.

.PARAMETER Subscription
Subscription name or ID to scan. Repeat the parameter or pass an array to scan
multiple subscriptions.

.PARAMETER Tenant
Optional Entra tenant ID or domain. When supplied, sign in to that tenant using
an isolated Azure CLI profile.

.PARAMETER UseDeviceCode
Use device-code authentication for the isolated -Tenant sign-in.

.PARAMETER OutputPath
CSV output path. Defaults to .\public-resources.csv.

.EXAMPLE
.\Get-PublicResources.ps1 -All -Tenant contoso.onmicrosoft.com -UseDeviceCode

.EXAMPLE
.\Get-PublicResources.ps1 -Subscription "Production" -Tenant 00000000-0000-0000-0000-000000000000 -OutputPath .\reports\public-resources.csv

.EXAMPLE
.\Get-PublicResources.ps1 -Subscription 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [Parameter()]
    [switch]$All,

    [Parameter()]
    [Alias('s')]
    [string[]]$Subscription = @(),

    [Parameter()]
    [Alias('t')]
    [string]$Tenant,

    [Parameter()]
    [switch]$UseDeviceCode,

    [Parameter()]
    [Alias('o')]
    [string]$OutputPath = '.\public-resources.csv'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "[INFO] $Message"
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$Operation
    )

    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $output = & az @Arguments 2> $stderrPath
        $exitCode = $LASTEXITCODE
        $stderrText = (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
        $stderr = if ($null -eq $stderrText) { '' } else { $stderrText.Trim() }

        if ($exitCode -ne 0) {
            $detail = if ($stderr) { $stderr } else { 'Azure CLI returned no error details.' }
            throw "$Operation failed. Command: az $($Arguments -join ' '). Exit code: $exitCode.`n$detail"
        }

        if ($stderr) {
            Write-Warning $stderr
        }

        $json = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($json)) {
            return $null
        }

        return $json | ConvertFrom-Json -Depth 100
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Resolve-SubscriptionSelector {
    param(
        [Parameter(Mandatory)]
        [string]$Selector,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Accounts
    )

    $idMatches = @($Accounts | Where-Object { [string]$_.id -ieq $Selector })
    if ($idMatches.Count -eq 1) {
        return $idMatches[0]
    }

    $nameMatches = @($Accounts | Where-Object { [string]$_.name -ieq $Selector })
    if ($nameMatches.Count -eq 1) {
        return $nameMatches[0]
    }

    if ($nameMatches.Count -gt 1) {
        throw "Subscription name '$Selector' matched multiple subscriptions. Use a subscription ID instead."
    }

    throw "No enabled subscription was found with name or ID '$Selector'."
}

function Get-ParentResourceId {
    param(
        [Parameter(Mandatory)]
        [string]$SubresourceId
    )

    $segments = @($SubresourceId.Trim('/') -split '/')
    if ($segments.Count -lt 3) {
        throw "Cannot determine a parent resource from subresource ID '$SubresourceId'."
    }

    return '/' + ($segments[0..($segments.Count - 3)] -join '/')
}

function Get-ResourceMetadata {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceId
    )

    $segments = @($ResourceId.Trim('/') -split '/')
    $resourceGroup = ''
    $providerIndex = -1

    for ($index = 0; $index -lt $segments.Count; $index++) {
        if ($segments[$index] -ieq 'resourceGroups' -and ($index + 1) -lt $segments.Count) {
            $resourceGroup = $segments[$index + 1]
        }

        if ($segments[$index] -ieq 'providers') {
            $providerIndex = $index
        }
    }

    if ($providerIndex -lt 0 -or ($providerIndex + 3) -ge $segments.Count) {
        throw "Cannot parse Azure resource metadata from ID '$ResourceId'."
    }

    $namespace = $segments[$providerIndex + 1]
    $typeParts = [System.Collections.Generic.List[string]]::new()
    $nameParts = [System.Collections.Generic.List[string]]::new()

    for ($index = $providerIndex + 2; $index -lt $segments.Count; $index += 2) {
        $typeParts.Add($segments[$index])
        if (($index + 1) -lt $segments.Count) {
            $nameParts.Add($segments[$index + 1])
        }
    }

    return [pscustomobject]@{
        Id            = $ResourceId
        ResourceGroup = $resourceGroup
        ResourceType  = "$namespace/$($typeParts -join '/')"
        ResourceName  = $nameParts -join '/'
    }
}

function Assert-OutputPathReady {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI 'az' was not found on PATH."
}

if ($All -and $Subscription.Count -gt 0) {
    throw 'Use either -All or -Subscription, not both.'
}

Assert-OutputPathReady -Path $OutputPath

$isolatedConfigDir = $null
$previousAzureConfigDir = $env:AZURE_CONFIG_DIR

try {
    $resolvedTenantId = ''
    if (-not [string]::IsNullOrWhiteSpace($Tenant)) {
        $isolatedConfigDir = Join-Path ([System.IO.Path]::GetTempPath()) ("az-public-resources-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $isolatedConfigDir -Force | Out-Null
        $env:AZURE_CONFIG_DIR = $isolatedConfigDir

        Write-Status "Using an isolated Azure CLI profile; the default Azure CLI login will not change."
        Write-Status "Signing in to tenant '$Tenant'$(if ($UseDeviceCode) { ' using device code' } else { '' })."

        $loginArguments = @('login', '--tenant', $Tenant, '--output', 'none', '--only-show-errors')
        if ($UseDeviceCode) {
            $loginArguments += '--use-device-code'
        }

        & az @loginArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI sign-in to tenant '$Tenant' failed."
        }
    }

    $accounts = @(
        Invoke-AzJson -Arguments @(
            'account', 'list', '--all',
            '--query', "[?state=='Enabled'].{id:id,name:name,tenantId:tenantId}",
            '--output', 'json',
            '--only-show-errors'
        ) -Operation 'List enabled Azure subscriptions'
    )

    if ($accounts.Count -eq 0) {
        throw 'Azure CLI returned no enabled subscriptions. Confirm the sign-in has subscription access.'
    }

    if ($isolatedConfigDir) {
        $resolvedTenantId = [string]$accounts[0].tenantId
        $accounts = @($accounts | Where-Object { [string]$_.tenantId -ieq $resolvedTenantId })
        if ($accounts.Count -eq 0) {
            throw "No enabled subscriptions were found in tenant '$Tenant'."
        }

        Write-Status "Signed in to tenant '$Tenant' ($resolvedTenantId)."
    }

    $selectors = @($Subscription | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (-not $All -and $selectors.Count -eq 0) {
        while ($true) {
            $choice = (Read-Host 'Enter A for all subscriptions or O for one subscription').Trim()
            if ($choice -match '^(?i:a|all)$') {
                $All = $true
                break
            }

            if ($choice -match '^(?i:o|one|1)$') {
                $selector = (Read-Host 'Enter the subscription name or ID').Trim()
                if ([string]::IsNullOrWhiteSpace($selector)) {
                    Write-Warning 'Subscription name or ID cannot be empty.'
                    continue
                }

                $selectors += $selector
                break
            }

            Write-Warning 'Enter A/all or O/one.'
        }
    }

    if ($All) {
        $selectedSubscriptions = @($accounts)
    }
    else {
        $selectedSubscriptions = @(
            foreach ($selector in $selectors) {
                Resolve-SubscriptionSelector -Selector $selector -Accounts $accounts
            }
        )
    }

    $subscriptionsById = [ordered]@{}
    foreach ($selectedSubscription in $selectedSubscriptions) {
        if (-not $subscriptionsById.Contains([string]$selectedSubscription.id)) {
            $subscriptionsById[[string]$selectedSubscription.id] = $selectedSubscription
        }
    }
    $selectedSubscriptions = @($subscriptionsById.Values)

    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($selectedSubscription in $selectedSubscriptions) {
        $subscriptionId = [string]$selectedSubscription.id
        $subscriptionName = [string]$selectedSubscription.name
        Write-Status "Scanning $subscriptionName [$subscriptionId]."

        $networkInterfaces = @(
            Invoke-AzJson -Arguments @(
                'network', 'nic', 'list',
                '--subscription', $subscriptionId,
                '--query', '[].{id:id,name:name,resourceGroup:resourceGroup,virtualMachineId:virtualMachine.id}',
                '--output', 'json',
                '--only-show-errors'
            ) -Operation "List network interfaces in subscription '$subscriptionName'"
        )

        $networkInterfacesById = @{}
        foreach ($networkInterface in $networkInterfaces) {
            $networkInterfaceId = [string](Get-PropertyValue -Object $networkInterface -Name 'id')
            if (-not [string]::IsNullOrWhiteSpace($networkInterfaceId)) {
                $networkInterfacesById[$networkInterfaceId.ToLowerInvariant()] = $networkInterface
            }
        }

        $publicIpAddresses = @(
            Invoke-AzJson -Arguments @(
                'network', 'public-ip', 'list',
                '--subscription', $subscriptionId,
                '--output', 'json',
                '--only-show-errors'
            ) -Operation "List public IP addresses in subscription '$subscriptionName'"
        )

        foreach ($publicIp in $publicIpAddresses) {
            $ipConfiguration = Get-PropertyValue -Object $publicIp -Name 'ipConfiguration'
            $natGateway = Get-PropertyValue -Object $publicIp -Name 'natGateway'
            $ipConfigurationId = if ($null -eq $ipConfiguration) { '' } else { [string](Get-PropertyValue -Object $ipConfiguration -Name 'id') }
            $natGatewayId = if ($null -eq $natGateway) { '' } else { [string](Get-PropertyValue -Object $natGateway -Name 'id') }

            $attachmentId = ''
            $ipConfigurationName = ''
            if (-not [string]::IsNullOrWhiteSpace($ipConfigurationId)) {
                $attachmentId = Get-ParentResourceId -SubresourceId $ipConfigurationId
                $ipConfigurationName = ($ipConfigurationId.Trim('/') -split '/')[-1]
            }
            elseif (-not [string]::IsNullOrWhiteSpace($natGatewayId)) {
                $attachmentId = $natGatewayId
            }
            else {
                continue
            }

            $attachment = Get-ResourceMetadata -ResourceId $attachmentId
            $reportedResource = $attachment
            $nicName = ''

            if ($attachment.ResourceType -ieq 'Microsoft.Network/networkInterfaces') {
                $nicName = $attachment.ResourceName
                $networkInterfaceKey = $attachment.Id.ToLowerInvariant()
                if ($networkInterfacesById.ContainsKey($networkInterfaceKey)) {
                    $networkInterface = $networkInterfacesById[$networkInterfaceKey]
                    $virtualMachineId = [string](Get-PropertyValue -Object $networkInterface -Name 'virtualMachineId')
                    if (-not [string]::IsNullOrWhiteSpace($virtualMachineId)) {
                        $reportedResource = Get-ResourceMetadata -ResourceId $virtualMachineId
                    }
                }
            }

            $rows.Add([pscustomobject][ordered]@{
                SubscriptionId      = $subscriptionId
                SubscriptionName    = $subscriptionName
                ResourceGroup       = $reportedResource.ResourceGroup
                ResourceType        = $reportedResource.ResourceType
                ResourceName        = $reportedResource.ResourceName
                PublicIpName        = [string](Get-PropertyValue -Object $publicIp -Name 'name')
                PublicIpAddress     = [string](Get-PropertyValue -Object $publicIp -Name 'ipAddress')
                NicName             = $nicName
                IpConfigurationName = $ipConfigurationName
                PublicIpResourceGroup = [string](Get-PropertyValue -Object $publicIp -Name 'resourceGroup')
                PublicIpResourceId  = [string](Get-PropertyValue -Object $publicIp -Name 'id')
            }) | Out-Null
        }
    }

    $orderedRows = @($rows | Sort-Object SubscriptionName, ResourceGroup, ResourceType, ResourceName, PublicIpName)
    if ($orderedRows.Count -eq 0) {
        '"SubscriptionId","SubscriptionName","ResourceGroup","ResourceType","ResourceName","PublicIpName","PublicIpAddress","NicName","IpConfigurationName","PublicIpResourceGroup","PublicIpResourceId"' |
            Set-Content -LiteralPath $OutputPath -Encoding UTF8
    }
    else {
        $orderedRows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
    }

    Write-Status "Wrote $($orderedRows.Count) attached public IP resource(s) to '$OutputPath'."
}
finally {
    if ($isolatedConfigDir) {
        try {
            & az logout --only-show-errors 2>&1 | Out-Null
        }
        catch {
        }

        if ($null -eq $previousAzureConfigDir) {
            Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:AZURE_CONFIG_DIR = $previousAzureConfigDir
        }

        Remove-Item -LiteralPath $isolatedConfigDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Status 'Removed the isolated Azure CLI profile; the default login is unchanged.'
    }
}
