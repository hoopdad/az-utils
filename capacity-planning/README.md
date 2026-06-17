# Azure Capacity Planning Scripts

PowerShell scripts that collect Azure subscription data to support **capacity planning** and **region selection** discussions. Each script produces structured JSON output with metadata, summaries, and detailed records.

## Quick Start

```powershell
# Prerequisites: Azure CLI logged in, PowerShell 7+
az login

# Quota export for the current az account subscription
pwsh Export-AzCliResourceQuotaCsv.ps1 -OutputCsvPath ./reports/resource-quota-usage.csv

# Quota export for every enabled subscription visible to the logged-in user
pwsh Export-AzCliResourceQuotaCsv.ps1 -AllEnabledSubscriptions -OutputCsvPath ./reports/resource-quota-usage.csv

# Quota export for subscriptions from a file with an active-region manifest
pwsh Export-AzCliResourceQuotaCsv.ps1 -SubscriptionListPath ./subscriptions.txt -OutputCsvPath ./reports/resource-quota-usage.csv

# Single subscription (current or specified)
pwsh Start-AzCapacityReport.ps1 -OutputPath ./reports
pwsh Start-AzCapacityReport.ps1 -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -OutputPath ./reports

# Multiple subscriptions from a file (parallel by default)
pwsh Start-AzCapacityReport.ps1 -SubscriptionFile subscriptions.txt -OutputPath ./reports

# Control cross-subscription parallelism
pwsh Start-AzCapacityReport.ps1 -SubscriptionFile subscriptions.txt -OutputPath ./reports -MaxParallel 5
pwsh Start-AzCapacityReport.ps1 -SubscriptionFile subscriptions.txt -OutputPath ./reports -Sequential

# Or run individual scripts
pwsh Get-AzServiceInventory.ps1 -OutputPath ./reports
pwsh Get-AzQuotaUsage.ps1 -OutputPath ./reports
```

The orchestrator creates a timestamped directory (e.g., `reports/capacity-report-20260429-101347/`) containing JSON data files and a `summary.md` with key findings. When using `-SubscriptionFile`, subscriptions are processed concurrently by default and each subscription gets its own subdirectory named with the subscription name plus the first eight characters of the subscription ID, along with a `cross-subscription-summary.md` at the top level.

## Prerequisites

- **PowerShell 7+** (`pwsh`)
- **Azure CLI** (`az`) — logged in with `az login`
- **Minimum subscription access**: **Reader** on every target subscription

## Required Permissions

All scripts require the built-in **Reader** role on each target subscription. The **Reserved Instances** script attempts to list reservation orders; if the identity lacks `Microsoft.Capacity/reservationOrders/read`, the script gracefully reports `status: "skipped"` instead of failing.

| Script | Azure CLI operations | Minimum role(s) |
|--------|----------------------|-----------------|
| `Get-AzServiceInventory.ps1` | `az graph query` | Reader (subscription) |
| `Get-AzRegionCapabilities.ps1` | `az vm list-skus`, `az account list-locations` | Reader (subscription) |
| `Get-AzQuotaUsage.ps1` | `az graph query`, `az vm list-usage`, `az network list-usages`, `az storage account list` | Reader (subscription) |
| `Get-AzUsageTrends.ps1` | `az graph query`, `az monitor metrics list` | Reader (subscription) |
| `Get-AzReservedInstances.ps1` | `az reservations reservation-order list`, reservation REST fallback | Reader (subscription); reservation data shown if accessible |
| `Start-AzCapacityReport.ps1` | Runs all scripts above | Reader (subscription) |

## Scripts

### Export-AzCliResourceQuotaCsv.ps1 — Flat Quota Export

Exports one flat CSV row per resource and attaches the best matching quota metric for that resource's provider and active region. The script supports three explicit subscription targeting modes and writes a companion active-region manifest CSV for traceability.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionIds` | Current az subscription | One or more subscription IDs or names |
| `-SubscriptionListPath` | — | Text file with one subscription ID or name per line; `#` comments and `id,name` rows are supported |
| `-AllEnabledSubscriptions` | `False` | Process every enabled subscription visible to the logged-in Azure CLI identity |
| `-OutputCsvPath` | Timestamped file in current directory | Main flat CSV output |
| `-RegionFilter` | — | Limit processing to a single region |
| `-DiagnosticsCsvPath` | Derived from output path | Quota endpoint failure diagnostics |
| `-RegionManifestPath` | Derived from output path | Companion CSV showing each subscription's active regions and resource counts |

If you use `-AllEnabledSubscriptions` with no `-RegionFilter`, the script processes every enabled subscription and every active region for each subscription, where an active region is any region with at least one deployed resource. Subscriptions where the current identity cannot run `az graph query` are warned and skipped so a tenant-wide run can continue.

### Start-AzCapacityReport.ps1 — Orchestrator

Runs all five data collection scripts and generates a consolidated markdown summary. Supports single or multi-subscription operation.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionId` | Current subscription | Target Azure subscription (single mode) |
| `-SubscriptionFile` | — | Path to a text file listing subscription IDs (multi mode) |
| `-OutputPath` | Current directory | Root directory for report output |
| `-DaysBack` | `30` | Number of days for usage trend metrics |
| `-MaxParallel` | `3` | Maximum number of subscriptions to process concurrently in multi-subscription mode |
| `-Sequential` | `False` | Disable cross-subscription parallelism and process subscriptions one at a time |

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

When using `-SubscriptionFile`, the report directory is organized per subscription with a cross-subscription summary. Multiple subscriptions run in parallel unless you pass `-Sequential`:

```
reports/capacity-report-20260429-101347/
├── cross-subscription-summary.md                 # Aggregated view across all subscriptions
├── production_12345678/                          # Per-subscription directory
│   ├── service-inventory.json
│   ├── region-capabilities.json
│   ├── quota-usage.json
│   ├── usage-trends.json
│   ├── reserved-instances.json
│   └── summary.md
└── staging_87654321/
    ├── ...
    └── summary.md
```

The cross-subscription summary includes:
- Subscription overview table (resources, regions, quota warnings, reservations per sub)
- Aggregated quota warnings across all subscriptions
- Aggregated high-utilization resources across all subscriptions
- Links to per-subscription reports

#### Obfuscated Log

`Start-AzCapacityReport.ps1` also writes an `obfuscated-log.txt` file into the top-level report directory automatically. It captures the orchestrator's console output with sensitive values replaced by consistent pseudonyms, so you can safely share the log in support tickets, with consultants, or in other external troubleshooting threads.

The obfuscation currently covers subscription IDs and names, tenant/object GUIDs, email addresses, resource group names, storage account names, user home-directory paths, and resource IDs that embed subscription/resource group details.

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

**Permissions**: Attempts to read reservation orders. If the current identity lacks the necessary access, the script returns a valid JSON payload with `status: "skipped"` and a clear message instead of failing.

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
  pwsh Start-AzCapacityReport.ps1 -SubscriptionFile subscriptions.txt -OutputPath ./reports -MaxParallel 5
  pwsh Start-AzCapacityReport.ps1 -SubscriptionFile subscriptions.txt -OutputPath ./reports -Sequential
  ```
  This generates per-subscription reports plus a `cross-subscription-summary.md` with aggregated findings. Use `-MaxParallel` to tune concurrency or `-Sequential` to disable parallel collection. See `subscriptions.example.txt` for the file format.
- **Filtering**: Post-process the JSON files with PowerShell or `jq` for custom analysis:
  ```powershell
  # Find all quotas above 50% usage
  (Get-Content quota-usage.json | ConvertFrom-Json).records |
      Where-Object { $_.usagePercent -ge 50 } |
      Sort-Object usagePercent -Descending |
      Format-Table provider, region, quotaName, usagePercent
  ```
