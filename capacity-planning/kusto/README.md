# Azure Resource Graph Capacity Planning Queries

This directory contains Azure Resource Graph KQL queries that mirror the workbook-style resource inventory views used for basic capacity planning.

## Included Queries

- `resource-inventory.kql` — resource name, type, region, resource group, and SKU display value
- `resource-summary.kql` — resource counts by Azure resource type
- `region-usage.kql` — resource counts by Azure region
- `resource-overview.kql` — top-line counts for resources, types, regions, and resource groups
- `resource-inventory-detailed.kql` — expanded inventory with SKU fields and tags

## Prerequisites

- Azure CLI (`az`)
- Logged in with `az login`
- Azure CLI `resource-graph` extension
- PowerShell 7+ (`pwsh`) to run the test script

The test script will install the `resource-graph` extension if it is missing.

## Run the Test Script

```powershell
cd /home/user/source/az-utils/capacity-planning-kusto
pwsh ./Test-ResourceGraphQueries.ps1
pwsh ./Test-ResourceGraphQueries.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

The script reads each `.kql` file from `$PSScriptRoot`, runs it with `az graph query --first 5`, validates JSON output, and checks that expected columns are present when rows are returned.

## Run Queries Manually

### Azure Portal

1. Open **Azure Portal**.
2. Go to **Resource Graph Explorer**.
3. Open one of the `.kql` files from this directory.
4. Paste the query text into the editor.
5. Run the query.

### Azure CLI

```powershell
$query = Get-Content -Raw ./resource-inventory.kql
az graph query --subscriptions <subscription-id> --first 1000 -q $query --output table
```

## Limits of Resource Graph

Azure Resource Graph is excellent for deployed resource inventory, but it does **not** expose all capacity-planning data. For example, it does not provide:

- Regional quota limits and current usage
- Azure Monitor performance metrics and utilization trends
- Reservation and savings plan inventory/details

For those portal-oriented or non-Resource-Graph data points, see the `portal-queries/` subdirectory.
