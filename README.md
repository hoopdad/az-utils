# az-utils

Azure utility scripts for operational tasks.

## Capacity Planning

PowerShell scripts to collect Azure subscription data — resource inventory, region capabilities, quotas, usage trends, and reservations — for capacity planning and region selection discussions.

See [`capacity-planning/README.md`](capacity-planning/README.md) for full documentation.

**Quick start**:
```powershell
az login
cd capacity-planning
pwsh Start-AzCapacityReport.ps1 -OutputPath ./reports
```
