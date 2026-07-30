# Copilot instructions for az-utils

## Azure CLI authentication in PowerShell scripts

**Always use the `azure-cli-auth-skill` skill when creating or updating any PowerShell script that
uses the Azure CLI (`az`).** The skill is defined in
[`.copilot/skills/azure-cli-auth-skill/SKILL.md`](../.copilot/skills/azure-cli-auth-skill/SKILL.md).

It provides the required pattern for authenticating `az` to a specific Entra tenant using an
isolated `AZURE_CONFIG_DIR` session that is torn down on exit, so the caller's default `az login`
is never modified. This is mandatory for any script that may run against a subscription in a
different tenant than the operator's default login, because directory lookups (`az ad user show`,
`az rest` to Microsoft Graph, etc.) otherwise resolve against the wrong tenant.

When a script only ever runs against the ambient login and never performs directory lookups, the
isolated-session pattern is optional — but still prefer exposing `-Tenant` / `-UseDeviceCode`
parameters for consistency across the repo.

## General conventions

- Scripts are PowerShell using the Azure CLI (`az`), with approved `Verb-Noun` names.
- Use `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`.
- Wrap `az` calls in a helper that checks `$LASTEXITCODE` and throws on failure.
- Update [`SCRIPTS.md`](../SCRIPTS.md) in the same commit whenever you add, modify, or delete a script.
