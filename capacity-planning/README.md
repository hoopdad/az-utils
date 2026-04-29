# Azure Capacity Planning Scripts

PowerShell scripts that collect Azure subscription data to support **capacity planning** and **region selection** discussions. Each script produces structured JSON output with metadata, summaries, and detailed records.

## Quick Start

```powershell
# Prerequisites: Azure CLI logged in, PowerShell 7+
az login

# Single subscription (current or specified)
pwsh Start-AzCapacityReport.ps1 -OutputPath ./reports
pwsh Start-AzCapacityReport.ps1 -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -OutputPath ./reports

# Multiple subscriptions from a file
pwsh Start-AzCapacityReport.ps1 -SubscriptionFile subscriptions.txt -OutputPath ./reports

# Skip scripts that need elevated reservation permissions
pwsh Start-AzCapacityReport.ps1 -OutputPath ./reports -SkipElevated

# Or run individual scripts
pwsh Get-AzServiceInventory.ps1 -OutputPath ./reports
pwsh Get-AzQuotaUsage.ps1 -OutputPath ./reports
```

The orchestrator creates a timestamped directory (e.g., `reports/capacity-report-20260429-101347/`) containing JSON data files and a `summary.md` with key findings. When using `-SubscriptionFile`, each subscription gets its own subdirectory plus a `cross-subscription-summary.md` at the top level.

## Prerequisites

- **PowerShell 7+** (`pwsh`)
- **Azure CLI** (`az`) — logged in with `az login`
- **Minimum subscription access**: **Reader** on every target subscription
- **Optional elevated access** for reservations: **Reservations Reader** at the tenant or billing scope

## Required Permissions

All scripts assume the current identity can read subscription metadata. The four **core scripts** only require the built-in **Reader** role on each subscription. The **Reserved Instances** script needs one extra permission beyond Reader: `Microsoft.Capacity/reservationOrders/read`, which is provided by the built-in **Reservations Reader** role.

| Script | Azure CLI operations | Minimum role(s) | Reader sufficient? | Additional permissions beyond Reader |
|--------|----------------------|-----------------|--------------------|--------------------------------------|
| `Get-AzServiceInventory.ps1` | `az graph query` | Reader (subscription) | Yes | None |
| `Get-AzRegionCapabilities.ps1` | `az vm list-skus`, `az account list-locations` | Reader (subscription) | Yes | None |
| `Get-AzQuotaUsage.ps1` | `az graph query`, `az vm list-usage`, `az network list-usages`, `az storage account list` | Reader (subscription) | Yes | None |
| `Get-AzUsageTrends.ps1` | `az graph query`, `az monitor metrics list` | Reader (subscription) | Yes | None |
| `Get-AzReservedInstances.ps1` | `az reservations reservation-order list`, reservation REST fallback | Reader (subscription) + Reservations Reader (tenant or billing scope) | No | `Microsoft.Capacity/reservationOrders/read` via **Reservations Reader** |
| `Start-AzCapacityReport.ps1` | Runs all scripts above | Reader for core scripts; add Reservations Reader for full reservation coverage | No, not if Reserved Instances is included | Use `-SkipElevated` to run only Reader-scoped scripts |

> **Tip**: If you only have Reader on the subscription, run `Start-AzCapacityReport.ps1 -SkipElevated` to skip `Get-AzReservedInstances.ps1`.

## Scripts

### Start-AzCapacityReport.ps1 — Orchestrator

Runs all five data collection scripts and generates a consolidated markdown summary. Supports single or multi-subscription operation.

- **Core scripts (Reader only)**: Service Inventory, Region Capabilities, Quota Usage, Usage Trends
- **Elevated script**: Reserved Instances

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionId` | Current subscription | Target Azure subscription (single mode) |
| `-SubscriptionFile` | — | Path to a text file listing subscription IDs (multi mode) |
| `-OutputPath` | Current directory | Root directory for report output |
| `-DaysBack` | `30` | Number of days for usage trend metrics |
| `-SkipElevated` | `False` | Skip scripts that need permissions beyond Reader (`Get-AzReservedInstances.ps1`) |

> **Note**: `-SubscriptionId` and `-SubscriptionFile` are mutually exclusive. If neither is provided, the current `az` subscription is used.

#### Subscription File Format

A plain text file with one subscription per line. Supports comments and optional display names:

```text
# Azure Subscription IDs for capacity planning
# Format: SubscriptionId or SubscriptionId,DisplayName

xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx,Production
yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy,Staging
zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz
```

See `subscriptions.example.txt` for a template.

#### Multi-Subscription Output

When using `-SubscriptionFile`, the report directory is organized per subscription with a cross-subscription summary:

```
reports/capacity-report-20260429-101347/
├── cross-subscription-summary.md       # Aggregated view across all subscriptions
├── production/                          # Per-subscription directory
│   ├── service-inventory.json
│   ├── region-capabilities.json
│   ├── quota-usage.json
│   ├── usage-trends.json
│   ├── reserved-instances.json
│   └── summary.md
└── staging/
    ├── ...
    └── summary.md
```

The cross-subscription summary includes:
- Subscription overview table (resources, regions, quota warnings, reservations per sub)
- Aggregated quota warnings across all subscriptions
- Aggregated high-utilization resources across all subscriptions
- Links to per-subscription reports

---

### Get-AzServiceInventory.ps1 — Resource Inventory

Enumerates all resources in the subscription using Azure Resource Graph. Groups resources by type, region, and resource group.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionId` | Current subscription | Target Azure subscription |
| `-OutputPath` | Current directory | Directory for output file |

**Output**: `service-inventory.json`

**Key data**:
- Complete resource list with type, location, resource group, SKU, and tags
- Summary counts by resource type, region, and resource group
- Top resource types and regions

---

### Get-AzRegionCapabilities.ps1 — Region & SKU Availability

Collects region metadata and VM SKU availability to support region selection decisions.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionId` | Current subscription | Target Azure subscription |
| `-OutputPath` | Current directory | Directory for output file |

**Output**: `region-capabilities.json`

**Key data**:
- All regions with display names and paired regions
- Availability zone support per region
- VM SKU availability per region (family, vCPUs, memory, zone support, restrictions)

> **Note**: VM SKU enumeration queries all regions and may take 1–2 minutes.

---

### Get-AzQuotaUsage.ps1 — Quota Limits & Current Usage

Collects quota limits and current usage for Compute, Network, and Storage providers across regions where resources are deployed.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionId` | Current subscription | Target Azure subscription |
| `-OutputPath` | Current directory | Directory for output file |

**Output**: `quota-usage.json`

**Key data**:
- Compute vCPU quotas — regional totals and per-VM-family limits
- Network quotas — public IPs, load balancers, NICs, NSGs, etc.
- Storage account count vs. subscription limit
- Quotas flagged at >80% (warning) and >90% (critical) usage

**Coverage**: Only queries regions where the subscription has deployed resources to avoid unnecessary API calls.

---

### Get-AzUsageTrends.ps1 — Resource Utilization Metrics

Collects Azure Monitor metrics for supported resource types over a configurable time window. Calculates average, maximum, and P95 values for capacity planning.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionId` | Current subscription | Target Azure subscription |
| `-OutputPath` | Current directory | Directory for output file |
| `-DaysBack` | `30` | Number of days to look back for metrics |

**Output**: `usage-trends.json`

**Supported resource types and metrics**:

| Resource Type | Metrics |
|--------------|---------|
| Virtual Machines | Percentage CPU, Available Memory Bytes |
| App Services | CpuPercentage, MemoryPercentage |
| SQL Databases | cpu_percent, dtu_consumption_percent, storage_percent |
| Storage Accounts | UsedCapacity |

**Notes**:
- Resources without available metrics are skipped with warnings
- Some App Service plans expose different metric names — the script handles API errors gracefully
- Daily granularity is attempted first; falls back to hourly if unsupported

---

### Get-AzReservedInstances.ps1 — Reservations

Lists active Azure reservations with scope, term, expiration, and utilization data.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionId` | Current subscription | Target Azure subscription |
| `-OutputPath` | Current directory | Directory for output file |

**Output**: `reserved-instances.json`

**Key data**:
- All reservation orders and individual reservations
- Reservation type, SKU, quantity, term, scope
- Expiration dates with days-until-expiry calculation
- Reservations expiring within 90 days flagged

**Permissions**: Requires `Microsoft.Capacity/reservationOrders/read`, exposed through the built-in **Reservations Reader** role at the tenant or billing scope. If the current identity lacks this permission, the script returns a valid JSON payload with `status: "skipped"` and a clear permissions message instead of failing.

## Output Format

Every script produces a JSON file with a consistent envelope:

```json
{
  "metadata": {
    "scriptName": "Get-AzServiceInventory",
    "subscriptionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "subscriptionName": "my-subscription",
    "collectedAt": "2026-04-29T14:10:30Z",
    "errors": [],
    "warnings": []
  },
  "summary": {
    "...": "script-specific summary fields"
  },
  "records": [
    { "...": "script-specific detail records" }
  ]
}
```

## Example Report Output

**Single subscription**:
```
reports/capacity-report-20260429-101347/
├── service-inventory.json      # Resource inventory (68 KB)
├── region-capabilities.json    # Regions & VM SKUs (11 MB)
├── quota-usage.json            # Quota limits & usage (209 KB)
├── usage-trends.json           # Monitor metrics (12 KB)
├── reserved-instances.json     # Reservations (2 KB)
└── summary.md                  # Consolidated markdown summary
```

**Multiple subscriptions**:
```
reports/capacity-report-20260429-101347/
├── cross-subscription-summary.md
├── production/
│   ├── service-inventory.json
│   ├── ...
│   └── summary.md
└── staging/
    ├── service-inventory.json
    ├── ...
    └── summary.md
```

## Tips

- **Large subscriptions**: Region capabilities and quota usage may take several minutes on subscriptions with many deployed regions.
- **Automation**: Each script is standalone and can be run independently or integrated into CI/CD pipelines.
- **Multiple subscriptions**: List subscription IDs in a text file and run once:
  ```powershell
  pwsh Start-AzCapacityReport.ps1 -SubscriptionFile subscriptions.txt -OutputPath ./reports
  ```
  This generates per-subscription reports plus a `cross-subscription-summary.md` with aggregated findings. See `subscriptions.example.txt` for the file format.
- **Filtering**: Post-process the JSON files with PowerShell or `jq` for custom analysis:
  ```powershell
  # Find all quotas above 50% usage
  (Get-Content quota-usage.json | ConvertFrom-Json).records |
      Where-Object { $_.usagePercent -ge 50 } |
      Sort-Object usagePercent -Descending |
      Format-Table provider, region, quotaName, usagePercent
  ```
