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

## Identity Hygiene

PowerShell script to report (with `--dry-run`) and remove Azure role assignments held by user accounts that are blocked from signing in. Supports isolated cross-tenant login via `-Tenant` / `-UseDeviceCode`.

See [`identity/README.md`](identity/README.md) for full documentation.

**Quick start**:

```powershell
az login
cd identity
pwsh Remove-AzBlockedUserRoleAssignment.ps1 -SubscriptionName '<name>' --dry-run
```

## Contributing

### Reusable skill: Azure CLI cross-tenant auth

When creating or updating any PowerShell script that uses the Azure CLI (`az`), use the repo-local
**`azure-cli-auth-skill`** skill at [`.copilot/skills/azure-cli-auth-skill/SKILL.md`](.copilot/skills/azure-cli-auth-skill/SKILL.md).
It documents the isolated `AZURE_CONFIG_DIR` pattern for authenticating to a specific tenant without
disturbing the operator's default `az login`. This expectation is also encoded in
[`.github/copilot-instructions.md`](.github/copilot-instructions.md).

