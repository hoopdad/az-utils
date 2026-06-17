# az-utils

Azure utility scripts for operational tasks.

👉 **Quick Start:** See [SCRIPTS.md](SCRIPTS.md) for a concise guide on when to run each script and what it provides.

## Lighthouse Onboarding

PowerShell script to onboard subscriptions for Azure Lighthouse — registers the `Microsoft.ManagedServices` resource provider and assigns the Reader role to specified users.

See [`lighthouse/README.md`](lighthouse/README.md) for full documentation.

**Quick start**:
```powershell
az login
cd lighthouse
pwsh Set-AzLighthouseOnboarding.ps1 -UsersFile users.txt
```

## Capacity Planning

PowerShell scripts to collect Azure subscription data — resource inventory, region capabilities, quotas, usage trends, and reservations — for capacity planning and region selection discussions.

See [`capacity-planning/README.md`](capacity-planning/README.md) for full documentation.

**Quick start**:
```powershell
az login
cd capacity-planning
pwsh Start-AzCapacityReport.ps1 -OutputPath ./reports
```
