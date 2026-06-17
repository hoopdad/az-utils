# Script Usage Guide

Quick reference for when to run each script, what you need, and what it provides.

---

## 🎯 Capacity Planning & Quota Analysis

### When: Helping a customer figure out quota and capacity

#### **Start-AzCapacityReport.ps1** (ORCHESTRATOR)
**Use when:** You need a complete capacity analysis report  
**What you need:** Azure CLI, one or more subscriptions, Reader role  
**What it provides:** JSON data files + summary.md covering service inventory, quotas, region capabilities, reserved instances, and usage trends  
**Command:** `pwsh Start-AzCapacityReport.ps1 -SubscriptionFile subs.txt -OutputPath ./reports`

#### **Export-AzCliResourceQuotaCsv.ps1**
**Use when:** You need quota data in CSV format for spreadsheet analysis  
**What you need:** Azure CLI, subscription IDs or names, Reader role, resource-graph extension  
**What it provides:** Flat CSV with quota metrics per resource, region manifest, diagnostics  
**Command:** `pwsh Export-AzCliResourceQuotaCsv.ps1 -AllEnabledSubscriptions -OutputCsvPath ./reports/quota.csv`

#### **Invoke-AzQuotaAnalysis.ps1**
**Use when:** You have a CSV request with SKU/region/quantity and need a 2-sheet Excel analysis  
**What you need:** Input CSV (SKU family, region, quantities), Azure CLI, ImportExcel module  
**What it provides:** Excel workbook with metadata resolution and capacity planning analysis  
**Command:** `pwsh Invoke-AzQuotaAnalysis.ps1 -InputCsv requests.csv -OutputFolder ./reports`

#### Individual Data Collectors (Use if you need specific data types)
- **Get-AzServiceInventory.ps1** — Resource inventory via Resource Graph
- **Get-AzQuotaUsage.ps1** — Comprehensive quota usage (VMs, network, storage)
- **Get-AzRegionCapabilities.ps1** — Available VM SKUs and regions
- **Get-AzReservedInstances.ps1** — Reserved instance details and cost
- **Get-AzUsageTrends.ps1** — Historical usage trends (configurable days)

---

## 🏢 Lighthouse Setup

### When: Setting up Lighthouse delegation for customer management

#### **Set-AzLighthouseOnboarding.ps1**
**Use when:** You need to delegate a customer subscription to your Lighthouse tenant  
**What you need:** Customer subscription ID, users/groups file, Azure CLI with tenant admin access  
**What it provides:** Lighthouse delegation registration  
**Command:** `pwsh Set-AzLighthouseOnboarding.ps1 -SubscriptionId <sub-id> -UsersFile users.txt`

---

## 🌐 Network Virtual Appliances (NVA)

### When: Reviewing Network Virtual Appliances

#### **Get-NvaVmSku.ps1**
**Use when:** You need to enrich NVA CSV with VM SKU details (cores, memory, network performance)  
**What you need:** Input CSV with NVA VM references, Azure CLI  
**What it provides:** CSV with NVA data plus resolved SKU specifications  
**Command:** `pwsh Get-NvaVmSku.ps1 -InputCsvPath nva.csv -OutputCsvPath nva-enriched.csv`

---

## 📋 Output Files

All reports, CSVs, and data files are organized in `/reports`:
- `capacity-planning-data/` — Input CSVs and analysis workbooks
- `data/` — Quota analysis Excel outputs
- `capacity-report-*/` — Generated capacity reports (JSON + summary)
- `nva*.csv` — NVA data and enriched NVA SKU data
- `resource-quota-usage*.csv` — Quota exports

---

## 🔄 Maintenance Note

**⚠️ When adding, modifying, or deleting scripts, always update this guide with:**
- Script name and purpose
- When to use it
- Prerequisites
- What it outputs

Update this file in the same commit as the script change.
