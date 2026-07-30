# Identity

Scripts for identity hygiene across Azure subscriptions.

## Remove-AzBlockedUserRoleAssignment.ps1

Reports and removes Azure role assignments held by user accounts that are **blocked from signing in**
(Microsoft Entra ID `accountEnabled = false`).

Blocked accounts that still carry role assignments are attractive targets for attackers looking to
regain access to your data unnoticed. Microsoft Defender for Cloud recommends removing them.

### Prerequisites

- Azure CLI (`az`) in PATH and signed in (`az login`)
- Reader (to enumerate) and User Access Administrator/Owner (to remove) on the subscription
- Directory read permission **in the subscription's tenant** to look up user `accountEnabled`
  (`az ad user show`). For cross-tenant subscriptions, use `-Tenant` (see below).

### Usage

Report only (safe — makes no changes):

```powershell
pwsh Remove-AzBlockedUserRoleAssignment.ps1 -SubscriptionName 'Contoso Prod' --dry-run
# or the PowerShell-native switch:
pwsh Remove-AzBlockedUserRoleAssignment.ps1 -SubscriptionName 'Contoso Prod' -DryRun
```

Remove the orphaned assignments (prompts before each deletion):

```powershell
pwsh Remove-AzBlockedUserRoleAssignment.ps1 -SubscriptionName 'Contoso Prod'
```

Remove without prompting:

```powershell
pwsh Remove-AzBlockedUserRoleAssignment.ps1 -SubscriptionName 'Contoso Prod' -Force
```

### Cross-tenant subscriptions

If the target subscription lives in a **different tenant** than the one you are normally signed in
to (e.g. a lab tenant while you stay logged in to your corporate tenant), pass `-Tenant`. The script
signs in to that tenant using an **isolated Azure CLI profile** (a temporary `AZURE_CONFIG_DIR`) and
tears it down on exit, so your default `az login` is **never changed**. Add `-UseDeviceCode` to
authenticate with the device-code flow instead of a browser (handy for guest access / MFA / remote
sessions).

```powershell
pwsh Remove-AzBlockedUserRoleAssignment.ps1 -SubscriptionName 'mikeo-ai-sub' `
  -Tenant d52a6857-5f44-4f8f-bcc8-420952d3225d -UseDeviceCode -DryRun
```

> **Why this matters:** user sign-in status (`accountEnabled`) must be looked up in the
> subscription's **own** tenant. Without `-Tenant`, lookups run against your default login's
> directory; valid users in another tenant then appear "unresolvable" and are (safely) skipped —
> the tool can neither confirm nor act on them. `-Tenant` points the lookups at the correct
> directory so real blocked accounts are actually detected.

### Behavior

- Resolves the subscription by name to its ID.
- Optionally signs in to `-Tenant` first, in an isolated profile that is discarded on exit.
- Lists every role assignment in the subscription held by a **User** principal (`--all`, so
  assignments at and below the subscription scope are included).
- Looks up each unique user's `accountEnabled` once (cached).
- Flags assignments whose user is blocked (`accountEnabled = false`).
- With `--dry-run`/`-DryRun`: prints the offending assignments and exits without changes.
- Without `--dry-run`: deletes each flagged assignment (confirmation unless `-Force`).
- Principals that cannot be resolved (deleted users, or a directory the current login can't read)
  are reported as warnings — grouped by principal with role and resource — and left untouched.

Exits with code `1` if any removal fails.
