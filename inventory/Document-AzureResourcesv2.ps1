<#
.NOTICE
Sample code only. This script is provided "as is" without warranties or
guarantees of completeness, accuracy, availability, or fitness for a
particular environment. Azure inventory, tags, API versions, RBAC permissions,
service support, and Azure CLI behavior can vary. The customer must
review, test, and validate all output in their own Azure environment before
relying on it for operational, capacity, financial, compliance, or remediation
decisions.

.SYNOPSIS
Exports Azure resource inventory to CSV.
#>

$tenantId = (Read-Host "Enter the Azure tenant ID to export resources from")
Write-Host "Exporting Azure resource inventory for tenant $tenantId..."

Write-Host "Exporting Azure resource inventory to CSV..."
$subsId = (az account list --query "[?tenantId=='$tenantId'].{id:id, name:name}" -o json | ConvertFrom-Json)
Write-Host "Found $($subsId.Count) subscriptions. Exporting resources..."

$rows = foreach ($sub in $subsId) {
    Write-Host "Exporting resources for subscription $($sub.name)..."
    az resource list --subscription $($sub.id) -o json `
        --query "[].{name:name, type:type, resourceGroup:resourceGroup, location:location, id:id, tags:tags}" |
    ConvertFrom-Json |
    Select-Object @{Name="subscriptionId"; Expression={$sub.id}},
                  @{Name="subscriptionName"; Expression={$sub.name}},
                  name, type, resourceGroup, location, id, tags
    Write-Host "Completed exporting resources for subscription $($sub.name)"
}

Write-Host "Exported $($rows.Count) resources in total. Saving to CSV..."
$rows | Export-Csv -Path "AzureResources.csv" -NoTypeInformation
write-Host "Export complete. CSV saved to AzureResources.csv."
