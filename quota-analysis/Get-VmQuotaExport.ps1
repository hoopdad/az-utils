[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Subscription,

    [Parameter(Mandatory = $true)]
    [string]$Region,

    [string]$OutputPath = ".\vm-quota-$Region.xlsx"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Ensure required modules
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    throw "The ImportExcel module is required. Install it with: Install-Module ImportExcel -Scope CurrentUser"
}

Import-Module ImportExcel

Write-Host "Setting subscription to '$Subscription'..."
az account set --subscription $Subscription --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription." }

$subscriptionName = (az account show --query "name" -o tsv).Trim()
Write-Host "Subscription: $subscriptionName"
Write-Host "Fetching VM quota for region '$Region'..."

$json = az vm list-usage --location $Region -o json
if ($LASTEXITCODE -ne 0) { throw "Failed to retrieve VM usage for region '$Region'." }

$usages = $json | ConvertFrom-Json

$results = foreach ($item in $usages) {
    [PSCustomObject]@{
        Subscription      = $subscriptionName
        Region            = $Region
        "SKU Family Name" = $item.localName
        "Total Quota vCores" = $item.limit
        "Used vCores"     = $item.currentValue
    }
}

$results | Export-Excel -Path $OutputPath -WorksheetName "VM Quota" -AutoSize -FreezeTopRow -BoldTopRow

Write-Host "Exported $($results.Count) rows to '$OutputPath'"
