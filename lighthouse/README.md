# Azure Lighthouse Onboarding

PowerShell script using Azure CLI to onboard subscriptions for Azure Lighthouse. Registers the `Microsoft.ManagedServices` resource provider and assigns the **Reader** role to specified users at the subscription scope.

## Quick Start

```powershell
# Prerequisites: Azure CLI logged in, PowerShell 7+
az login

# Single subscription (current context)
pwsh Set-AzLighthouseOnboarding.ps1 -UsersFile users.txt

# Single subscription (explicit)
pwsh Set-AzLighthouseOnboarding.ps1 -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -UsersFile users.txt

# Multiple subscriptions from a file
pwsh Set-AzLighthouseOnboarding.ps1 -SubscriptionFile subscriptions.txt -UsersFile users.txt
```

## Prerequisites

- **PowerShell 7+** (`pwsh`)
- **Azure CLI** (`az`) — logged in with `az login`
- **Permissions**: The executing identity must have:
  - `User Access Administrator` or `Owner` on target subscriptions (to create role assignments)
  - `Directory Reader` or equivalent in Entra ID (to resolve user emails to object IDs)

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-SubscriptionId` | No | Current subscription | Target Azure subscription (single mode) |
| `-SubscriptionFile` | No | — | Path to a text file listing subscription IDs (multi mode) |
| `-UsersFile` | **Yes** | — | Path to a text file listing user email addresses |

> **Note**: `-SubscriptionId` and `-SubscriptionFile` are mutually exclusive. If neither is provided, the current Azure CLI subscription is used.

## What It Does

For each subscription:

1. **Registers `Microsoft.ManagedServices`** resource provider (waits for registration to complete)
2. **Assigns Reader role** to each user at subscription scope (`acdd72a7-3385-48ef-bd42-f606fba81ae7`)

## File Formats

### Users File

One email address per line. Comments (`#`) and blank lines are ignored:

```text
alice@contoso.com
bob@contoso.com
```

See `users.example.txt` for a template.

### Subscriptions File

Same format as the capacity-planning scripts — one subscription per line with optional display name:

```text
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx,Production
yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy,Staging
```

See `subscriptions.example.txt` for a template.

## Error Handling

- **User resolution failures**: Users that cannot be resolved in Entra ID are skipped with a warning; the script continues with remaining users.
- **Subscription failures**: Each subscription is processed independently; a failure on one does not stop the others.
- **Duplicate role assignments**: If a role assignment already exists, it is logged as "skipped" (not an error).
- **Summary**: A color-coded summary is printed at the end with counts of successes, skips, and errors.
