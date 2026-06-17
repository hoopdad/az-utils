Create a PowerShell 7 script named Invoke-AzQuotaAnalysis.ps1 in this folder that produces an Excel-based Azure VM quota analysis report from CSV input.

Do this in one pass without asking follow-up questions.

Requirements:

1) Parameters and runtime behavior
- The script must use CmdletBinding and strict mode.
- Parameters:
	- InputCsv (mandatory string)
	- OutputFolder (mandatory string)
	- OutputFileName (optional string, default quota-analysis.xlsx)
- Stop on errors by default.
- Validate prerequisites:
	- az CLI must be installed and callable.
	- ImportExcel module must be available; if missing, throw with install guidance.
- Create OutputFolder if it does not exist.
- Validate InputCsv exists and has rows.
- If OutputFileName does not end with .xlsx, generate quota-analysis-YYYYMMDD-HHMMSS.xlsx.
- Overwrite an existing workbook at the output path.

2) Input CSV schema and aliases
- Support flexible column aliases per row:
	- Subscription name: SubscriptionName, Subscription Name, subscription_name, subscription
	- Subscription id: SubscriptionId, Subscription ID, subscription_id
	- Region: AzureRegion, Azure Region, Region, region, location
	- SKU: Sku, SKU, VmSku, VM SKU
	- SKU family: SkuFamily, SKU Family, Sku Family, VM Family
	- Additional cores: CoreQuantity, Cores, QuantityOfCores, AdditionalCores
	- Additional VMs: VmQuantity, VMs, QuantityOfVMs, AdditionalVMs, Number VM, NumberVM, Number of VMs
- Region is required.
- At least one of SKU or SKU family is required.
- Cores and VMs are optional.

3) Azure CLI lookups and caching
- Use az account list --all to build a subscription cache.
- Resolve subscription:
	- If id is provided, resolve name from id.
	- Else resolve id from exact name (case-insensitive).
	- If no exact match, allow a single contains-name fallback.
	- If unresolved, mark row error.
- Normalize region input to canonical Azure location name using az account list-locations.
	- Accept either location name or display name.
	- Normalize by removing non-alphanumeric characters and lowercasing for matching.
- Cache expensive lookups by subscription+region:
	- az vm list-skus --resource-type virtualMachines --location <region> --subscription <subId>
	- az vm list-usage --location <region> --subscription <subId>

4) SKU metadata and derived values
- If SKU is present, find matching SKU record from list-skus (case-insensitive exact on SKU name).
- From SKU record derive:
	- SkuFamily (if missing in input)
	- CoresPerVm from capability name vCPUs (int)
- If SKU metadata is missing:
	- Add warning note.
	- If family still missing, mark row error.
- AdditionalCores logic:
	- If CoreQuantity is present, use it.
	- Else if VmQuantity is present and CoresPerVm is known, AdditionalCores = VmQuantity * CoresPerVm.
	- Else if VmQuantity present and CoresPerVm unknown, AdditionalCores = 0 and add warning note.

5) Quota mapping and row status
- For each resolved row with SKU family, map family to az vm list-usage records.
- Match usage record by normalized comparison against both name.value and name.localizedValue:
	- Try exact normalized match first.
	- Then try contains-based fallback.
- If matched:
	- QuotaCurrentCores = currentValue
	- QuotaTotalCores = limit
	- QuotaRemainingCores = limit - currentValue
- If not matched and row is not already error, mark warning and note that family quota was not found.
- Row status values: ok, warning, error.

6) Output detail model (uniform columns)
- Build per-input-row detail records with these fields:
	- InputRow
	- SubscriptionNameInput
	- SubscriptionIdInput
	- SubscriptionNameResolved
	- SubscriptionIdResolved
	- AzureRegion
	- SkuInput
	- SkuFamilyInput
	- SkuFamilyResolved
	- VmQuantityInput
	- CoreQuantityInput
	- CoresPerVmDerived
	- AdditionalCores
	- QuotaCurrentCores
	- QuotaTotalCores
	- QuotaRemainingCores
	- Status
	- Notes (pipe-delimited)

7) Aggregation for report sheet
- Group by Subscription (resolved preferred), Region, and SkuFamily (resolved preferred).
- Handle duplicate input rows by aggregating:
	- InputRowCount
	- VmQuantityTotal
	- CoreQuantityTotal
	- AdditionalCoresTotal
- Carry first available quota values into the group.
- Roll up severity:
	- error if any row in group is error
	- warning if none are error and at least one warning
	- otherwise ok
- De-duplicate notes and join with pipe separator.

8) Excel workbook output
- Produce workbook in OutputFolder with two worksheets:

Worksheet 1: QuotaAnalysis
- Rows are grouped aggregate rows sorted by SubscriptionNameResolved, AzureRegion, SkuFamilyResolved.
- Columns:
	- SubscriptionNameResolved
	- SubscriptionIdResolved
	- AzureRegion
	- SkuFamilyResolved
	- InputRowCount
	- AdditionalCoresTotal
	- QuotaCurrentCores
	- QuotaTotalCores
	- QuotaRemainingCores
	- CurrentPlusAdditionalCores (Excel formula)
	- AdditionalQuotaNeeded (Excel formula)
	- Status
	- Notes
- Formula rules for each row n (Excel row number starts at 2 for first data row):
	- CurrentPlusAdditionalCores = G{n}+F{n}
	- AdditionalQuotaNeeded = MAX(0,J{n}-H{n})
- If quota current/total is missing, leave formula fields empty.
- If no analyzable grouped rows exist, emit one error row with note No analyzable rows were produced from input CSV.

Worksheet 2: AllVmFamilyQuotas
- For each unique SubscriptionId+Region seen in resolved input rows, include all family/total regional vCPU usage records from az vm list-usage.
- Include only records that look family-related:
	- name.value or name.localizedValue contains Family, or
	- name.value contains Total Regional vCPUs (case-insensitive normalized check)
- Columns:
	- SubscriptionName
	- SubscriptionId
	- AzureRegion
	- QuotaNameValue
	- QuotaNameLocalized
	- CurrentConsumption
	- TotalQuota
	- RemainingQuota
	- PercentUsed (rounded to 2 decimals when TotalQuota > 0)

9) Excel formatting
- Use Export-Excel from ImportExcel.
- Freeze top row and bold header row for both sheets.
- Use table names QuotaAnalysis and AllVmFamilyQuotas.

10) Implementation details
- Implement helper functions for:
	- command prerequisite checks
	- normalized token conversion
	- CSV field alias extraction
	- nullable int parsing
	- az CLI JSON execution with optional allow-failure
	- subscription resolution
	- location resolution
	- cached SKU and usage retrieval
	- family quota record matching
- Keep in-memory caches script-scoped.
- Print final workbook path when complete.

11) Non-goals
- Do not modify .gitignore automatically.
- Do not prompt interactively.
- Assume az login is already completed.

12) Validation expectations
- Ensure the script handles mixed-quality input rows and still emits a workbook.
- Rows that cannot be resolved should be included through aggregated status/notes behavior rather than crashing the entire run, except for hard prerequisites and invalid file conditions.

Output only the completed PowerShell script content.