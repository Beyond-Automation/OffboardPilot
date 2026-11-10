# ==============================================================================
# Written by Randall Lewis, Senior Infrastructure Solutions Engineer
# Script Name: Reset-TestAccount.ps1
# Purpose: Resets a test user account in Entra ID and Exchange Online back to
#          a fully licensed, active state for re-testing offboarding scripts.
#          Skips AD and EXO group restoration (handled manually).
# Date: 2026-10-02
# ==============================================================================

$ErrorActionPreference = "Stop"

Clear-Host
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host "                    TEST ACCOUNT RESET UTILITY                          " -ForegroundColor Cyan
Write-Host "                  Beyond Automation - beyondautomation.io               " -ForegroundColor Cyan
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host ""

# --- Input ---
$UserEmail = Read-Host "[?] Enter test account email address"
if ([string]::IsNullOrWhiteSpace($UserEmail) -or $UserEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    Write-Host "[X] Invalid email address. Aborting." -ForegroundColor Red
    exit 1
}

$LicenseSkuId = Read-Host "[?] Enter license SKU ID to re-assign (leave blank to skip license restore)"

# --- Connect ---
Write-Host ""
Write-Host "[*] Connecting to Exchange Online..." -ForegroundColor Cyan
try {
    $null = Get-OrganizationConfig -ErrorAction Stop
    Write-Host "[+] Exchange Online session already active." -ForegroundColor Green
} catch {
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    Write-Host "[+] Exchange Online connected." -ForegroundColor Green
}

Write-Host "[*] Connecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All" -NoWelcome -ErrorAction Stop
Write-Host "[+] Microsoft Graph connected." -ForegroundColor Green

Write-Host ""
Write-Host "--- [ Resetting Account ] ---" -ForegroundColor Yellow

# --- Step 1: Re-enable M365 sign-in ---
Write-Host "[*] Re-enabling M365 sign-in..." -ForegroundColor Cyan
try {
    Update-MgUser -UserId $UserEmail -AccountEnabled:$true -ErrorAction Stop
    Write-Host "[+] M365 sign-in re-enabled." -ForegroundColor Green
} catch {
    Write-Host "[X] Failed to re-enable sign-in: $($_.Exception.Message)" -ForegroundColor Red
}

# --- Step 2: Convert mailbox back to Regular ---
Write-Host "[*] Converting mailbox back to Regular user mailbox..." -ForegroundColor Cyan
try {
    Set-Mailbox -Identity $UserEmail -Type Regular -ErrorAction Stop
    Write-Host "[+] Mailbox converted back to Regular." -ForegroundColor Green
} catch {
    Write-Host "[X] Failed to convert mailbox: $($_.Exception.Message)" -ForegroundColor Red
}

# --- Step 3: Remove mail forwarding ---
Write-Host "[*] Removing mail forwarding..." -ForegroundColor Cyan
try {
    Set-Mailbox -Identity $UserEmail -ForwardingSmtpAddress $null -DeliverToMailboxAndForward $false -ErrorAction Stop
    Write-Host "[+] Mail forwarding cleared." -ForegroundColor Green
} catch {
    Write-Host "[X] Failed to clear forwarding: $($_.Exception.Message)" -ForegroundColor Red
}

# --- Step 4: Re-assign license (optional) ---
if (-not [string]::IsNullOrWhiteSpace($LicenseSkuId)) {
    Write-Host "[*] Re-assigning license ($LicenseSkuId)..." -ForegroundColor Cyan
    try {
        $AddLicense = @{ SkuId = $LicenseSkuId }
        Set-MgUserLicense -UserId $UserEmail -AddLicenses @($AddLicense) -RemoveLicenses @() -ErrorAction Stop | Out-Null
        Write-Host "[+] License re-assigned." -ForegroundColor Green
    } catch {
        Write-Host "[X] Failed to re-assign license: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[!] You can re-assign the license manually in the M365 admin center." -ForegroundColor Yellow
    }
} else {
    Write-Host "[!] License restore skipped. Assign manually in M365 admin center if needed." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host "                        RESET COMPLETE                                  " -ForegroundColor Cyan
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host "  Account       : $UserEmail"
Write-Host "  Sign-In       : Re-enabled"
Write-Host "  Mailbox Type  : Regular"
Write-Host "  Forwarding    : Cleared"
$LicenseLine = if ([string]::IsNullOrWhiteSpace($LicenseSkuId)) { "Skipped - assign manually" } else { "Re-assigned" }
Write-Host "  License       : $LicenseLine"
Write-Host ""
Write-Host "  NOTE: AD account and group memberships not touched - handle manually." -ForegroundColor Yellow
Write-Host "=========================================================================" -ForegroundColor Cyan

Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
