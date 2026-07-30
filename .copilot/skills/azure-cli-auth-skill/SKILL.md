---
name: azure-cli-auth-skill
description: "Use this skill whenever a script or tool needs to authenticate Azure CLI (az) to a DIFFERENT Entra tenant than the caller's default login, WITHOUT changing that default login. Triggers include: 'cross-tenant', 'log in to a lab/customer tenant', 'run against another tenant', 'isolated az login', 'device code login', 'don't change my default az account', 'guest/B2B tenant access', or any request where az work must target a specific tenant and then leave the environment signed in exactly as before. Produces an isolated, self-cleaning Azure CLI session using AZURE_CONFIG_DIR. Do NOT use for single-tenant scripts that can rely on the ambient az login."
license: Proprietary.
---

# Azure CLI Isolated Cross-Tenant Authentication

## Overview

This skill provides a battle-tested pattern for authenticating Azure CLI (`az`) to a **specific
Entra tenant** for the lifetime of a script, then tearing that session down on exit — so the
caller's **default `az login` (e.g. their corporate tenant) is never modified**.

The whole reason to do this is correctness: Azure Resource Manager calls are scoped by
subscription, but **directory lookups** (`az ad user show`, `az ad group show`, Microsoft Graph via
`az rest`) resolve against the *currently signed-in tenant*. If the target subscription lives in a
different tenant than your default login, those lookups silently resolve against the **wrong
directory** and return "does not exist" for perfectly valid principals. Signing into the
subscription's own tenant fixes this.

## Core idea

Azure CLI stores its token cache and active-account state in the directory named by the
**`AZURE_CONFIG_DIR`** environment variable (default `~/.azure`). Point that variable at a **fresh
temp folder** for the script's lifetime and `az` gets a completely private profile. Restore/delete
it on exit and the default profile is untouched. No global `az account set` is used, so no shared
state is mutated.

## Mechanism (step by step)

1. **Save + redirect the profile** (only when a target tenant is requested):
   - Capture `previous = $env:AZURE_CONFIG_DIR` (may be null/unset).
   - Create a unique temp dir: `Join-Path ([IO.Path]::GetTempPath()) ("az-<tool>-" + [guid]::NewGuid().ToString('N'))`.
   - Set `$env:AZURE_CONFIG_DIR` to it. Every `az` call in this process now uses the isolated cache.

2. **Sign in into the isolated profile:**
   - `az login --tenant <tenantId> --output none --only-show-errors`
   - Add `--use-device-code` for a browserless flow (ideal for guest/B2B, MFA, remote/SSH, containers).
   - **Invoke `az` DIRECTLY** (`& az @args`) for login — NOT through a JSON/stdout-capturing wrapper —
     so the device-code prompt ("open https://microsoft.com/devicelogin and enter CODE") streams live
     to the console.
   - Check `$LASTEXITCODE -ne 0` and `throw` on failure.

3. **Do the work** — all subsequent `az` calls automatically target the isolated tenant/token.

4. **Guaranteed teardown in a `finally` block** (runs on success, error, or Ctrl-C):
   - Best-effort `az logout --only-show-errors` (ignore errors).
   - Restore env: if `previous` was null → `Remove-Item Env:AZURE_CONFIG_DIR`; else set it back.
   - `Remove-Item -Recurse -Force` the temp dir.

## Reference implementation (PowerShell)

```powershell
param(
    [string]$Tenant,        # target tenant ID or domain; empty = use ambient login
    [switch]$UseDeviceCode  # browserless device-code flow
)

$isolatedConfigDir = $null
$previousAzureConfigDir = $env:AZURE_CONFIG_DIR
try {
    if ($Tenant) {
        $isolatedConfigDir = Join-Path ([IO.Path]::GetTempPath()) ("az-tool-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $isolatedConfigDir -Force | Out-Null
        $env:AZURE_CONFIG_DIR = $isolatedConfigDir

        $loginArgs = @('login','--tenant',$Tenant,'--output','none','--only-show-errors')
        if ($UseDeviceCode) { $loginArgs += '--use-device-code' }
        & az @loginArgs                              # direct call → prompt streams to console
        if ($LASTEXITCODE -ne 0) { throw "Sign-in to tenant '$Tenant' failed." }
    }

    # ---- all az work goes here; it uses the isolated session ----
    # e.g. $tenantId = (az account show --query tenantId -o tsv)
    #      az ad user show --id <principalId> ...   # resolves in the CORRECT tenant
}
finally {
    if ($isolatedConfigDir) {
        try { & az logout --only-show-errors 2>&1 | Out-Null } catch { }
        if ($null -eq $previousAzureConfigDir) { Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
        else { $env:AZURE_CONFIG_DIR = $previousAzureConfigDir }
        Remove-Item -LiteralPath $isolatedConfigDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
```

## Language-agnostic note

`AZURE_CONFIG_DIR` is honored by Azure CLI on all platforms and languages. The identical isolation
applies if you set the same env var before spawning `az` from Python, Node.js, or Bash — create a
temp dir, set `AZURE_CONFIG_DIR`, `az login --tenant …`, do work, then restore the var and delete
the dir in a `finally`/`trap`/`defer`.

## Key properties

- **Isolation** = per-process `AZURE_CONFIG_DIR`, not `az account set`. The default `~/.azure` is
  never read or written.
- **Process-scoped:** env changes vanish when the process ends; the `finally` is belt-and-suspenders
  for mid-session errors and Ctrl-C.
- **Correct-directory guarantee:** because you signed into the target tenant, directory lookups
  resolve against *that* tenant — the entire point of the pattern.
- **Concurrency-safe:** the GUID-named temp dir means parallel runs never collide.
- **Cross-platform temp path:** use `[IO.Path]::GetTempPath()` (Windows/Linux/macOS).

## Gotchas (tell any implementer)

- Do NOT route the `login` call through a wrapper that swallows stdout — you'll hide the device code.
- Always put teardown in `finally`/`trap`, not after the work, so errors/Ctrl-C still restore state.
- Read the subscription's home tenant with `az account show --query tenantId` AFTER login.
- Device-code auth has a limited polling window (~15 min); let the human control timing when running
  interactively rather than wrapping it in a short automated wait.
- Treat "principal not found in the correct tenant" as genuinely orphaned/deleted — distinct from a
  cross-tenant lookup miss, which this skill eliminates.

## Reference in this repo

A complete working example lives at
`identity/Remove-AzBlockedUserRoleAssignment.ps1` (see its `-Tenant` / `-UseDeviceCode` parameters
and the `try/finally` isolated-login block).
