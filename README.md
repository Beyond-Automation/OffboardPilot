<div align="center">

<img src="https://img.shields.io/badge/PowerShell-5.1%2B-blue?style=flat-square&logo=powershell" />
<img src="https://img.shields.io/badge/Platform-Hybrid%20AD%20%2B%20M365-0078D4?style=flat-square&logo=microsoft" />
<img src="https://img.shields.io/badge/Version-1.0-brightgreen?style=flat-square" />
<img src="https://img.shields.io/badge/License-Commercial-red?style=flat-square" />

# OffboardPilot

**Complete hybrid AD + M365 employee offboarding automation — one script, six steps, full audit trail.**

[**→ Get OffboardPilot on Gumroad ($39)**](https://lewbeast.gumroad.com/l/hcvsr)

</div>

---

## The problem with manual offboarding

Every time an employee leaves, the same checklist runs through your head. Miss one step and the audit finds it later.

There's also a silent bug in most offboarding scripts: when you remove a user's M365 license, Exchange Online reverts their primary email address from `user@yourdomain.com` back to `user@tenant.onmicrosoft.com`. Any script that filters distribution group memberships by email address — and most do — runs after the license removal, hits the wrong address, finds nothing, and reports success.

**The user is still in every cloud DL they were ever added to.**

OffboardPilot fixes this by capturing the user's Exchange Distinguished Name *before* any license changes, then using that DN for every group query. DN is stable regardless of licensing state.

---

## What it does

| Step | Action |
|------|--------|
| 1 | Disable on-premises Active Directory account |
| 2 | Block Entra ID / Azure AD sign-in |
| 3 | Revoke all active M365 sessions and OAuth tokens |
| 4 | Convert mailbox to Shared, configure forwarding, remove licenses |
| 5 | Remove cloud-only Exchange Online distribution group memberships |
| 6 | Remove on-premises AD group memberships (including AD-synced DLs) |

After all six steps, a **color-coded reconciliation report** shows pass/fail status for every action. Every run is logged to `C:\Scripts\Logs\` for your audit trail.

---

## Built for real hybrid environments

- No hardcoded values, works in any environment out of the box
- Handles users with no EXO mailbox, EXO steps skip gracefully, AD steps continue
- Mailbox size pre-check, warns before conversion if mailbox exceeds 50GB shared quota
- EXO group membership uses Distinguished Name, prevents silent misses after license removal
- AD operations use explicit admin credentials, supports least-privilege technician accounts
- Modules auto-install on first run if missing
- Full session transcript logged automatically

---

## What's included

| File | Purpose |
|------|---------|
| `Invoke-UserOffboard.ps1` | Main offboarding engine |
| `Get-EXOGroupMembership.ps1` | Diagnostic utility, audit EXO group memberships before/after |
| `Reset-TestAccount.ps1` | Reset a test account to clean state for lab re-runs |

---

## Requirements

- PowerShell 5.1 (recommended), PS7 compatible via RSAT shim
- RSAT Active Directory module
- ExchangeOnlineManagement module
- Microsoft.Graph.Authentication module
- Domain-connected Windows workstation
- AD admin credentials plus Exchange Online and M365 admin credentials

All required modules are checked at startup and auto-installed if missing.

---

## Get OffboardPilot

Full, commented PowerShell source. No compiled executables, no obfuscation.

<div align="center">

[**Purchase on Gumroad, $39 one-time**](https://lewbeast.gumroad.com/l/hcvsr)

</div>

---

## About

**Randall Lewis** - Senior Infrastructure Solutions Engineer

**Beyond Automation** - Engineering Smarter IT Operations

[beyondautomation.io](https://beyondautomation.io)
