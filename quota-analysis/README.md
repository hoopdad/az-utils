# Quota Analysis

This folder contains a PowerShell script that reads a request CSV, resolves missing subscription/SKU metadata with Azure CLI, and produces a two-sheet Excel workbook for VM family quota planning.

## Script

- `Invoke-AzQuotaAnalysis.ps1`

## Prerequisites

- PowerShell 7+
- Azure CLI (`az`) with `az login`
- Access to target subscriptions
- PowerShell module `ImportExcel`

Install `ImportExcel` (if needed):

```powershell
Install-Module ImportExcel -Scope CurrentUser
```

## Input CSV Requirements

Expected columns (case-sensitive aliases are supported by the script):

- Subscription Name (optional)
- Subscription ID (optional)
- Azure Region (required)
- SKU (optional)
- SKU Family (optional)
- Quantity Of Cores (optional)
- Quantity Of VMs (optional)

Common aliases handled from existing spreadsheets include:

- `VM SKU`
- `Number VM`

Rules:

- One of SKU or SKU Family is required.
- One of Quantity Of Cores or Quantity Of VMs is optional.
- If Subscription Name is missing, it is resolved from Subscription ID.
- If Subscription ID is missing, it is resolved from Subscription Name (exact, then case-insensitive contains fallback).
- If Quantity Of VMs is provided but cores are missing, the script derives cores from VM SKU metadata.
- If SKU is provided but SKU Family is missing, the script derives SKU Family from SKU metadata.

## Usage

```powershell
pwsh ./quota-analysis/Invoke-AzQuotaAnalysis.ps1 \
  -InputCsv ./quota-analysis/input.csv \
  -OutputFolder ./quota-analysis/output
```

Optional:

```powershell
pwsh ./quota-analysis/Invoke-AzQuotaAnalysis.ps1 \
  -InputCsv ./quota-analysis/input.csv \
  -OutputFolder ./quota-analysis/output \
  -OutputFileName quota-analysis-myrun.xlsx
```

## Output Workbook

The workbook contains two sheets:

1. `QuotaAnalysis`
- Grouped by Subscription Name, Region, and SKU Family
- Duplicates in input are aggregated into one row per group
- Includes row count and summed additional cores per group
- Current quota consumption and total for the resolved subscription/region/SKU family
- Remaining quota
- `CurrentPlusAdditionalCores` formula
- `AdditionalQuotaNeeded` formula (`MAX(0, current+additional-total)`)

2. `AllVmFamilyQuotas`
- All VM quota usage rows from `az vm list-usage` for each unique subscription+region in input
- Includes consumption and total for each quota row
