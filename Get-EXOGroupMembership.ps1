# ==============================================================================
# Written by Randall Lewis, Senior Infrastructure Solutions Engineer
# Script Name: Get-EXOGroupMembership.ps1
# Purpose: Reports all Exchange Online group memberships for a given user.
#          Shows Distribution Groups, Mail-Enabled Security Groups, and
#          Microsoft 365 Groups. Flags each as AD-Synced or Cloud-Only.
# Date: 2026-10-02
# ==============================================================================

#Requires -Version 5.1

$UserEmail = Read-Host "[?] Enter user email address"

# Connect to Exchange Online if not already connected
Write-Host "[*] Connecting to Exchange Online..." -ForegroundColor Cyan
try {
    $null = Get-OrganizationConfig -ErrorAction Stop
    Write-Host "[+] Exchange Online session already active." -ForegroundColor Green
} catch {
    try {
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
        Write-Host "[+] Exchange Online connected." -ForegroundColor Green
    } catch {
        Write-Host "[X] Failed to connect to Exchange Online: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "Checking EXO group memberships for: $UserEmail" -ForegroundColor Cyan
Write-Host ("-" * 60)

# --- Distribution Groups and Mail-Enabled Security Groups ---
Write-Host ""
Write-Host "[*] Distribution Groups / Mail-Enabled Security Groups..." -ForegroundColor Yellow
try {
    $DGs = Get-DistributionGroup -ResultSize Unlimited -ErrorAction Stop | Where-Object {
        (Get-DistributionGroupMember -Identity $_.Identity -ResultSize Unlimited -ErrorAction SilentlyContinue |
         Select-Object -ExpandProperty PrimarySmtpAddress) -contains $UserEmail
    }

    if ($DGs.Count -eq 0) {
        Write-Host "  None found." -ForegroundColor Gray
    } else {
        foreach ($G in $DGs) {
            $SyncStatus = if ($G.IsDirSynced) { "AD-Synced" } else { "Cloud-Only" }
            $Color      = if ($G.IsDirSynced) { "DarkYellow" } else { "Green" }
            Write-Host ("  [{0,-10}] {1}" -f $SyncStatus, $G.DisplayName) -ForegroundColor $Color
            Write-Host ("              Identity : {0}" -f $G.Identity) -ForegroundColor Gray
            Write-Host ("              Type     : {0}" -f $G.RecipientTypeDetails) -ForegroundColor Gray
        }
    }
} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
}

# --- Microsoft 365 Groups (Unified Groups) ---
Write-Host ""
Write-Host "[*] Microsoft 365 Groups (Unified Groups)..." -ForegroundColor Yellow
try {
    $M365Groups = Get-UnifiedGroup -ResultSize Unlimited -ErrorAction Stop | Where-Object {
        (Get-UnifiedGroupLinks -Identity $_.Identity -LinkType Members -ResultSize Unlimited -ErrorAction SilentlyContinue |
         Select-Object -ExpandProperty PrimarySmtpAddress) -contains $UserEmail
    }

    if ($M365Groups.Count -eq 0) {
        Write-Host "  None found." -ForegroundColor Gray
    } else {
        foreach ($G in $M365Groups) {
            Write-Host ("  [Cloud-Only] {0}" -f $G.DisplayName) -ForegroundColor Green
            Write-Host ("              Identity : {0}" -f $G.Identity) -ForegroundColor Gray
        }
    }
} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host ("-" * 60)
Write-Host "Scan complete." -ForegroundColor Cyan
Write-Host ""
Write-Host "Legend:" -ForegroundColor White
Write-Host "  [AD-Synced]  = Managed in on-prem AD, synced to EXO. Remove via AD (Step 6)." -ForegroundColor DarkYellow
Write-Host "  [Cloud-Only] = Exists only in EXO. Removed by Step 5 of offboarding script." -ForegroundColor Green
Write-Host ""
