# Contributing

## Maintaining Script Documentation

**Important:** Whenever you add, modify, or delete a PowerShell script, you MUST update [`SCRIPTS.md`](SCRIPTS.md) in the same commit.

Update includes:
- Script name, path, and purpose
- When to use it (workflow/scenario)
- What you need (prerequisites, permissions, input formats)
- What it provides (outputs, formats)
- Example command if applicable

This keeps the quick-reference guide in sync with the actual scripts.

## Organization

Scripts are organized by workflow:
- **capacity-planning/** — Quota and capacity analysis scripts
- **lighthouse/** — Lighthouse delegation setup
- **nva/** — Network Virtual Appliance analysis

Data files and reports go to **reports/**.
