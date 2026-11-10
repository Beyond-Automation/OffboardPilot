# ==============================================================================
# Written by Randall Lewis, Senior Infrastructure Solutions Engineer
# Script Name: Invoke-UserOffboard.ps1
# Purpose: Complete interactive employee offboarding automation for hybrid
#          Active Directory and Microsoft 365 environments. Performs AD
#          account disable, Entra ID sign-in block, session/token revocation,
#          mailbox conversion and forwarding, M365 license removal, Exchange
#          Online cloud group removal, and on-premises AD group removal
#          including AD-synced distribution lists.
#
#          Designed to run from any technician workstation with RSAT installed.
#          No environment-specific values are hardcoded.
#          Handles users with no EXO mailbox gracefully - EXO steps are skipped
#          while AD, Graph, and session steps continue normally.
#          AD operations use explicit admin credentials to support least-privilege
#          technician accounts.
#          Mailbox size pre-check prevents silent quota violations on conversion.
#          Full session transcript logged to C:\Scripts\Logs\ for audit trail.
# Date: 2026-10-03
# ==============================================================================

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

# ==============================================================================
# STAGE 1: TECHNICIAN IDENTIFICATION
# ==============================================================================
Clear-Host
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host "               ENTERPRISE HYBRID OFFBOARDING ENGINE v1.0                " -ForegroundColor Cyan
Write-Host "                     Beyond Automation - beyondautomation.io            " -ForegroundColor Cyan
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host ""

$TechnicianName = Read-Host "`[?`] Enter Technician Name"
if ([string]::IsNullOrWhiteSpace($TechnicianName)) {
    Write-Host "`[X`] Technician Name cannot be blank. Aborting." -ForegroundColor Red
    exit 1
}

# ==============================================================================
# STAGE 2: TARGET IDENTIFICATION
# ==============================================================================
Write-Host ""
Write-Host "--- [ Target Identification ] ---" -ForegroundColor Yellow

$UserEmail = Read-Host "`[?`] Enter departed user's primary SMTP email address"
if ([string]::IsNullOrWhiteSpace($UserEmail) -or $UserEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    Write-Host "`[X`] Invalid email address format. Aborting." -ForegroundColor Red
    exit 1
}

$sAMAccountName = Read-Host "`[?`] Enter on-premises sAMAccountName (Press Enter to auto-extract from email)"
if ([string]::IsNullOrWhiteSpace($sAMAccountName)) {
    $sAMAccountName = $UserEmail.Split("@")[0]
    Write-Host "`[*`] sAMAccountName defaulted to: $sAMAccountName" -ForegroundColor Yellow
}

# Start transcript logging - captures all console output from this point forward
# Log file named by user email and date for easy audit trail lookup
# Format: C:\Scripts\Logs\Offboard_user@domain.com_MM_DD_YYYY.txt
$LogDir  = 'C:\Scripts\Logs'
$LogDate = Get-Date -Format 'MM_dd_yyyy'
$LogPath = "$LogDir\Offboard_$($UserEmail)_$LogDate.txt"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
Start-Transcript -Path $LogPath -Append -ErrorAction SilentlyContinue
Write-Host "`[*`] Session transcript logging to: $LogPath" -ForegroundColor DarkCyan

# ==============================================================================
# STAGE 3: PREREQUISITE VALIDATION AND CONNECTIONS
# ==============================================================================
Write-Host ""
Write-Host "--- [ Module Verification and Connections ] ---" -ForegroundColor Yellow

$RequiredModules = @("ActiveDirectory", "ExchangeOnlineManagement", "Microsoft.Graph.Authentication")

foreach ($Module in $RequiredModules) {
    if (-not (Get-Module -ListAvailable -Name $Module)) {
        Write-Host "`[!`] Module '$Module' not found. Attempting install..." -ForegroundColor Yellow
        try {
            Install-Module -Name $Module -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
            Write-Host "`[+`] Module '$Module' installed successfully." -ForegroundColor Green
        } catch {
            Write-Host "`[X`] Failed to install '$Module': $($_.Exception.Message)" -ForegroundColor Red
            Stop-Transcript -ErrorAction SilentlyContinue
            exit 1
        }
    } else {
        Write-Host "`[+`] Module '$Module' verified." -ForegroundColor Green
    }
}

Import-Module ActiveDirectory                -ErrorAction SilentlyContinue
Import-Module ExchangeOnlineManagement       -ErrorAction SilentlyContinue
Import-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue

# Collect AD Admin credentials inline - no GUI popup required
# Passed explicitly to all AD cmdlets to support least-privilege technician accounts
Write-Host ""
Write-Host "`[*`] Enter AD Admin credentials for domain operations..." -ForegroundColor Cyan
$ADAdminUser = Read-Host "`[?`] AD Admin username (DOMAIN\username)"
$ADAdminPass = Read-Host "`[?`] AD Admin password" -AsSecureString
if ([string]::IsNullOrWhiteSpace($ADAdminUser) -or $null -eq $ADAdminPass) {
    Write-Host "`[X`] Credentials cannot be blank. Aborting." -ForegroundColor Red
    Stop-Transcript -ErrorAction SilentlyContinue
    exit 1
}
$ADCredential = New-Object System.Management.Automation.PSCredential($ADAdminUser, $ADAdminPass)
Write-Host "`[+`] AD credentials captured." -ForegroundColor Green

# Connect Exchange Online
Write-Host "`[*`] Connecting to Exchange Online..." -ForegroundColor Cyan
try {
    $null = Get-OrganizationConfig -ErrorAction Stop
    Write-Host "`[+`] Exchange Online session already active." -ForegroundColor Green
} catch {
    try {
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
        Write-Host "`[+`] Exchange Online connected." -ForegroundColor Green
    } catch {
        Write-Host "`[X`] Failed to connect to Exchange Online: $($_.Exception.Message)" -ForegroundColor Red
        Stop-Transcript -ErrorAction SilentlyContinue
        exit 1
    }
}

# Connect Microsoft Graph
Write-Host "`[*`] Connecting to Microsoft Graph..." -ForegroundColor Cyan
try {
    Connect-MgGraph -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All" -NoWelcome -ErrorAction Stop
    Write-Host "`[+`] Microsoft Graph connected." -ForegroundColor Green
} catch {
    Write-Host "`[X`] Failed to connect to Microsoft Graph: $($_.Exception.Message)" -ForegroundColor Red
    Stop-Transcript -ErrorAction SilentlyContinue
    exit 1
}

# Validate Active Directory connectivity using admin credentials
Write-Host "`[*`] Validating Active Directory connectivity..." -ForegroundColor Cyan
try {
    $DomainInfo = Get-ADDomain -Credential $ADCredential -ErrorAction Stop
    Write-Host "`[+`] Active Directory connected: $($DomainInfo.NetBIOSName)" -ForegroundColor Green
} catch {
    Write-Host "`[X`] Active Directory unreachable: $($_.Exception.Message)" -ForegroundColor Red
    Stop-Transcript -ErrorAction SilentlyContinue
    exit 1
}

# ==============================================================================
# STAGE 4: PRE-FLIGHT VERIFICATION
# ==============================================================================
Write-Host ""
Write-Host "--- [ Pre-Flight Verification ] ---" -ForegroundColor Yellow

# Verify AD Account - hard abort if not found
Write-Host "`[*`] Verifying Active Directory account..." -ForegroundColor Cyan
try {
    $ADUser = Get-ADUser -Filter "sAMAccountName -eq '$sAMAccountName'" `
                         -Properties MemberOf, DistinguishedName, ObjectGUID `
                         -Credential $ADCredential `
                         -ErrorAction Stop
    if (-not $ADUser) {
        Write-Host "`[X`] No AD account found for sAMAccountName '$sAMAccountName'. Aborting." -ForegroundColor Red
        Stop-Transcript -ErrorAction SilentlyContinue
        exit 1
    }
    $DisplayName = $ADUser.Name
    Write-Host "`[+`] AD account found: $($ADUser.DistinguishedName)" -ForegroundColor Green
} catch {
    Write-Host "`[X`] AD lookup failed: $($_.Exception.Message)" -ForegroundColor Red
    Stop-Transcript -ErrorAction SilentlyContinue
    exit 1
}

# Verify Entra ID / Graph user - hard abort if not found
Write-Host "`[*`] Verifying Entra ID identity..." -ForegroundColor Cyan
try {
    $GraphUser = Get-MgUser -UserId $UserEmail -Property "Id,DisplayName,AccountEnabled,AssignedLicenses" -ErrorAction Stop
    Write-Host "`[+`] Entra ID account found: $($GraphUser.DisplayName)" -ForegroundColor Green
} catch {
    Write-Host "`[X`] Entra ID lookup failed for '$UserEmail'. Aborting." -ForegroundColor Red
    Stop-Transcript -ErrorAction SilentlyContinue
    exit 1
}

# Verify Exchange Online Mailbox - soft check, EXO steps skipped if not found
Write-Host "`[*`] Verifying Exchange Online mailbox..." -ForegroundColor Cyan
$HasEXOMailbox = $false
$EXOUserDN     = $null   # Captured here before Step 4 can alter the primary SMTP address
try {
    $EXOMailbox = Get-Mailbox -Identity $UserEmail -ErrorAction Stop
    Write-Host "`[+`] EXO mailbox found: $($EXOMailbox.DisplayName)" -ForegroundColor Green
    $HasEXOMailbox = $true
    # Store the EXO Distinguished Name now - used in Step 5 group membership filter.
    # IMPORTANT: After Step 4 removes the license, EXO may revert the user's primary SMTP
    # to the .onmicrosoft.com address, causing a filter on $UserEmail to miss their memberships.
    # The DistinguishedName is stable and does not change when licensing is modified.
    $EXOUserDN = $EXOMailbox.DistinguishedName
    Write-Host "`[*`] EXO identity DN captured for group membership queries." -ForegroundColor DarkCyan
} catch {
    Write-Host "`[!`] No EXO mailbox found for '$UserEmail'." -ForegroundColor Yellow
    Write-Host "`[!`] Mailbox and EXO group steps will be skipped. AD and M365 identity steps will proceed." -ForegroundColor Yellow
}

# Mailbox size pre-check (only if mailbox exists)
$MailboxSizeGB   = $null
$MailboxSizeWarn = $false
if ($HasEXOMailbox) {
    Write-Host "`[*`] Checking mailbox size..." -ForegroundColor Cyan
    try {
        $MailboxStats = Get-MailboxStatistics -Identity $UserEmail -ErrorAction Stop
        $SizeString   = $MailboxStats.TotalItemSize.Value.ToString()
        if ($SizeString -match '\(([0-9,]+) bytes\)') {
            $MailboxBytes  = [long]($Matches[1] -replace ',', '')
            $MailboxSizeGB = [math]::Round($MailboxBytes / 1GB, 2)
        }
        if ($null -ne $MailboxSizeGB) {
            if ($MailboxSizeGB -ge 50) {
                $MailboxSizeWarn = $true
                Write-Host "`[!`] Mailbox size: $MailboxSizeGB GB - EXCEEDS 50GB shared mailbox quota." -ForegroundColor Yellow
            } else {
                Write-Host "`[+`] Mailbox size: $MailboxSizeGB GB - Within 50GB shared mailbox quota." -ForegroundColor Green
            }
        } else {
            Write-Host "`[!`] Could not parse mailbox size. Proceeding without size check." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "`[!`] Mailbox size check failed: $($_.Exception.Message). Proceeding without size check." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "All pre-flight checks complete." -ForegroundColor Green

# ==============================================================================
# STAGE 5: PRE-DECISION QUESTIONS
# ==============================================================================
Write-Host ""
Write-Host "--- [ Offboarding Configuration ] ---" -ForegroundColor Yellow

$DoForwarding      = $false
$ForwardTarget     = $null
$MailboxAccessMode = $null   # "ForwardOnly" | "ForwardAndMember" | "ForwardOnly-LicenseRetained" | "Skipped"

if ($HasEXOMailbox) {
    $ForwardAnswer = Read-Host "`[?`] Does this mailbox need forwarding? `[Y/N`]"
    if ($ForwardAnswer -match '^(Y|Yes)$') {

        $ForwardTarget = Read-Host "`[?`] Forward mail to (enter destination email address)"
        if ([string]::IsNullOrWhiteSpace($ForwardTarget) -or $ForwardTarget -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            Write-Host "`[X`] Invalid forwarding address entered. Aborting." -ForegroundColor Red
            Stop-Transcript -ErrorAction SilentlyContinue
            exit 1
        }

        Write-Host "`[*`] Validating forwarding destination in Exchange Online..." -ForegroundColor Cyan
        try {
            $ForwardRecipient = Get-Recipient -Identity $ForwardTarget -ErrorAction Stop
            Write-Host "`[+`] Forwarding destination validated: $($ForwardRecipient.DisplayName)" -ForegroundColor Green
            $DoForwarding = $true
        } catch {
            Write-Host "`[X`] Forwarding destination '$ForwardTarget' not found in Exchange Online. Aborting." -ForegroundColor Red
            Stop-Transcript -ErrorAction SilentlyContinue
            exit 1
        }

        if ($MailboxSizeWarn) {
            Write-Host ""
            Write-Host "`[!`] WARNING: Mailbox size is $MailboxSizeGB GB, which exceeds the 50GB shared mailbox quota." -ForegroundColor Yellow
            Write-Host "`[!`] Converting without an archive license may cause delivery failures once the cap is enforced." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "      [1] Proceed with full conversion to Shared + forwarding + remove license (accept quota risk)"
            Write-Host "      [2] Apply forwarding only, retain license, skip conversion (safest option)"
            Write-Host "      [3] Skip mailbox step entirely (handle manually)"
            $QuotaChoice = Read-Host "`[?`] Enter choice [1/2/3]"
            switch ($QuotaChoice) {
                "1" { $MailboxAccessMode = "ForwardOnly";                 Write-Host "`[!`] Proceeding with full conversion. Quota risk acknowledged." -ForegroundColor Yellow }
                "2" { $MailboxAccessMode = "ForwardOnly-LicenseRetained"; Write-Host "`[+`] Forwarding-only selected. License will be retained." -ForegroundColor Green }
                "3" { $MailboxAccessMode = "Skipped";                     Write-Host "`[!`] Mailbox step will be skipped. Manual intervention required." -ForegroundColor Yellow }
                default { Write-Host "`[X`] Invalid choice. Aborting." -ForegroundColor Red; Stop-Transcript -ErrorAction SilentlyContinue; exit 1 }
            }
        } else {
            Write-Host ""
            Write-Host "      [A] Shared mailbox + forwarding only (no inbox access for recipient)"
            Write-Host "      [B] Shared mailbox + forwarding + add recipient as member (full Outlook access)"
            $AccessChoice = Read-Host "`[?`] Enter choice [A/B]"
            switch ($AccessChoice.ToUpper()) {
                "A" { $MailboxAccessMode = "ForwardOnly" }
                "B" { $MailboxAccessMode = "ForwardAndMember" }
                default { Write-Host "`[X`] Invalid choice. Aborting." -ForegroundColor Red; Stop-Transcript -ErrorAction SilentlyContinue; exit 1 }
            }
        }
    }
}

$RemoveEXOGroups = $false
if ($HasEXOMailbox) {
    $EXOGroupAnswer = Read-Host "`[?`] Remove cloud EXO distribution group memberships? `[Y/N`]"
    if ($EXOGroupAnswer -match '^(Y|Yes)$') { $RemoveEXOGroups = $true }
}

$RemoveADGroups = $false
$ADGroupAnswer  = Read-Host "`[?`] Remove on-premises AD group memberships (includes AD-synced DLs)? `[Y/N`]"
if ($ADGroupAnswer -match '^(Y|Yes)$') { $RemoveADGroups = $true }

# ==============================================================================
# STAGE 6: ACTION PLAN SUMMARY
# ==============================================================================
Write-Host ""
Write-Host ("=" * 73) -ForegroundColor Cyan
Write-Host "                  CONFIRMED OFFBOARDING ACTION PLAN" -ForegroundColor Cyan
Write-Host ("=" * 73) -ForegroundColor Cyan
Write-Host "  Technician            : $TechnicianName"
Write-Host "  Target Email          : $UserEmail"
Write-Host "  sAMAccountName        : $sAMAccountName"
Write-Host "  Display Name          : $DisplayName"
Write-Host "  -----------------------------------------------------------------------"
Write-Host "  Disable AD Account    : YES"
Write-Host "  Block M365 Sign-In    : YES"
Write-Host "  Revoke M365 Sessions  : YES"
if ($HasEXOMailbox) {
    switch ($MailboxAccessMode) {
        "ForwardOnly"                 { Write-Host "  Mailbox Handling      : Convert to Shared + Forward to $ForwardTarget + Remove Licenses" }
        "ForwardAndMember"            { Write-Host "  Mailbox Handling      : Convert to Shared + Forward to $ForwardTarget + Add Member + Remove Licenses" }
        "ForwardOnly-LicenseRetained" { Write-Host "  Mailbox Handling      : Forward to $ForwardTarget only - License retained (mailbox over 50GB)" }
        "Skipped"                     { Write-Host "  Mailbox Handling      : Skipped - Manual intervention required (mailbox over 50GB)" }
        $null                         { Write-Host "  Mailbox Handling      : Convert to Shared + Remove Licenses (no forwarding)" }
    }
} else {
    Write-Host "  Mailbox Handling      : Skipped (no EXO mailbox found)"
}
$EXOGroupLine = if ($RemoveEXOGroups) { "YES (cloud-only distribution groups)" } else { "NO" }
Write-Host "  Remove EXO Groups     : $EXOGroupLine"
$ADGroupLine  = if ($RemoveADGroups)  { "YES (on-premises AD groups and AD-synced DLs)" } else { "NO" }
Write-Host "  Remove AD Groups      : $ADGroupLine"
Write-Host ("=" * 73) -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# STAGE 7: EXECUTION GATE
# ==============================================================================
$ProceedAnswer = Read-Host "[?] Proceed with offboarding execution? [Y/N]"
if ($ProceedAnswer -notmatch '^(Y|Yes)$') {
    Write-Host "[!] Offboarding aborted by technician." -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Stop-Transcript -ErrorAction SilentlyContinue
    exit 0
}
Write-Host ""
Write-Host "[*] Execution authorized. Starting offboarding pipeline..." -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# STAGE 8: STATUS TRACKING VARIABLES
# ==============================================================================
$Step1Status = "Skipped"
$Step2Status = "Skipped"
$Step3Status = "Skipped"
$Step4Status = "Skipped"
$Step5Status = "Skipped"
$Step6Status = "Skipped"

# ==============================================================================
# STAGE 9: EXECUTION ENGINE
# ==============================================================================

# --- Step 1: Disable On-Premises AD Account ---
Write-Host "[*] Step 1: Disabling on-premises AD account..." -ForegroundColor Cyan
try {
    Disable-ADAccount -Identity $sAMAccountName -Credential $ADCredential -ErrorAction Stop
    Write-Host "[+] Step 1: AD account disabled." -ForegroundColor Green
    $Step1Status = "Completed"
} catch {
    Write-Host "[X] Step 1 Failed: $($_.Exception.Message)" -ForegroundColor Red
    $Step1Status = "Failed: $($_.Exception.Message)"
}

# --- Step 2: Block Microsoft 365 Sign-In ---
Write-Host "[*] Step 2: Blocking Microsoft 365 sign-in..." -ForegroundColor Cyan
try {
    Update-MgUser -UserId $UserEmail -AccountEnabled:$false -ErrorAction Stop
    Write-Host "[+] Step 2: M365 sign-in blocked." -ForegroundColor Green
    $Step2Status = "Completed"
} catch {
    Write-Host "[X] Step 2 Failed: $($_.Exception.Message)" -ForegroundColor Red
    $Step2Status = "Failed: $($_.Exception.Message)"
}

# --- Step 3: Revoke Active M365 Sessions and OAuth Tokens ---
Write-Host "[*] Step 3: Revoking active M365 sessions and OAuth tokens..." -ForegroundColor Cyan
try {
    Revoke-MgUserSignInSession -UserId $UserEmail -ErrorAction Stop | Out-Null
    Write-Host "[+] Step 3: All active sessions and tokens revoked." -ForegroundColor Green
    $Step3Status = "Completed"
} catch {
    Write-Host "[X] Step 3 Failed: $($_.Exception.Message)" -ForegroundColor Red
    $Step3Status = "Failed: $($_.Exception.Message)"
}

# --- Step 4: Process Mailbox and Licensing ---
if ($HasEXOMailbox) {
    Write-Host "[*] Step 4: Processing mailbox and licensing..." -ForegroundColor Cyan

    if ($MailboxAccessMode -eq "Skipped") {
        Write-Host "[!] Step 4: Skipped per technician selection (mailbox over 50GB). Manual intervention required." -ForegroundColor Yellow
        $Step4Status = "Skipped - Mailbox size ($MailboxSizeGB GB) exceeds 50GB quota. Technician opted out. Manual intervention required."

    } elseif ($MailboxAccessMode -eq "ForwardOnly-LicenseRetained") {
        try {
            Set-Mailbox -Identity $UserEmail -ForwardingSmtpAddress $ForwardTarget -DeliverToMailboxAndForward $false -ErrorAction Stop
            Write-Host "[+] Mail forwarding configured to: $ForwardTarget" -ForegroundColor Green
            Write-Host "[!] License retained - mailbox NOT converted to Shared (size: $MailboxSizeGB GB)." -ForegroundColor Yellow
            $Step4Status = "Partial - Forwarding applied to $ForwardTarget. License retained. Conversion skipped (mailbox $MailboxSizeGB GB exceeds 50GB quota). Manual conversion required when ready."
        } catch {
            Write-Host "[X] Step 4 Failed: $($_.Exception.Message)" -ForegroundColor Red
            $Step4Status = "Failed: $($_.Exception.Message)"
        }

    } else {
        try {
            Set-Mailbox -Identity $UserEmail -Type Shared -ErrorAction Stop
            Write-Host "[+] Mailbox converted to Shared." -ForegroundColor Green

            if ($DoForwarding) {
                Set-Mailbox -Identity $UserEmail -ForwardingSmtpAddress $ForwardTarget -DeliverToMailboxAndForward $false -ErrorAction Stop
                Write-Host "[+] Mail forwarding configured to: $ForwardTarget" -ForegroundColor Green
            }

            if ($MailboxAccessMode -eq "ForwardAndMember") {
                Add-MailboxPermission -Identity $UserEmail -User $ForwardTarget -AccessRights FullAccess -InheritanceType All -AutoMapping $true -ErrorAction Stop | Out-Null
                Write-Host "[+] $ForwardTarget added as member with Full Access." -ForegroundColor Green
            }

            # Retrieve current licenses from Graph
            $MgUser       = Get-MgUser -UserId $UserEmail -Property AssignedLicenses -ErrorAction Stop
            $Licenses     = $MgUser.AssignedLicenses
            $LicenseCount = $Licenses.Count
            if ($LicenseCount -gt 0) {
                # -RemoveLicenses expects a plain string array of SKU GUIDs, NOT a hashtable array
                # Using hashtables (@{SkuId=...}) here causes: Cannot convert 'System.Collections.Hashtable' to 'Edm.Guid'
                $RemoveLicenses = [string[]]($Licenses | ForEach-Object { $_.SkuId.ToString() })
                Set-MgUserLicense -UserId $UserEmail -AddLicenses @() -RemoveLicenses $RemoveLicenses -ErrorAction Stop | Out-Null
                Write-Host "[+] $LicenseCount license(s) removed." -ForegroundColor Green
            } else {
                Write-Host "[!] No licenses found to remove." -ForegroundColor Yellow
            }

            $Step4Detail = "Completed - Shared mailbox"
            if ($DoForwarding)                             { $Step4Detail += ", forwarding to $ForwardTarget" }
            if ($MailboxAccessMode -eq "ForwardAndMember") { $Step4Detail += ", $ForwardTarget added as member" }
            $Step4Detail += ", $LicenseCount license(s) removed"
            $Step4Status  = $Step4Detail
        } catch {
            Write-Host "[X] Step 4 Failed: $($_.Exception.Message)" -ForegroundColor Red
            $Step4Status = "Failed: $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "[!] Step 4: Skipped (no EXO mailbox)." -ForegroundColor Yellow
    $Step4Status = "Skipped - no EXO mailbox"
}

# --- Step 5: Remove Cloud EXO Distribution Group Memberships ---
# NOTE: Uses $EXOUserDN (captured in Stage 4 pre-flight) instead of $UserEmail.
# After Step 4 removes the license, EXO may revert the user's primary SMTP to the
# .onmicrosoft.com address. A filter on $UserEmail would silently miss those memberships.
# Filtering by DistinguishedName is stable and unaffected by licensing changes.
if ($HasEXOMailbox -and $RemoveEXOGroups) {
    Write-Host "[*] Step 5: Processing cloud EXO distribution group memberships..." -ForegroundColor Cyan
    try {
        $EXOGroups = Get-DistributionGroup -Filter "Members -eq '$EXOUserDN'" -ErrorAction Stop
        if ($EXOGroups.Count -eq 0) {
            Write-Host "[*] Step 5: No cloud-only distribution group memberships found." -ForegroundColor Yellow
            $Step5Status = "Completed - No cloud-only group memberships found"
        } else {
            $RemovedGroups = 0
            foreach ($Group in $EXOGroups) {
                try {
                    Remove-DistributionGroupMember -Identity $Group.Identity -Member $UserEmail -Confirm:$false -ErrorAction Stop
                    Write-Host "[+] Removed from EXO group: $($Group.DisplayName)" -ForegroundColor Green
                    $RemovedGroups++
                } catch {
                    Write-Host "[!] Could not remove from '$($Group.DisplayName)': $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
            $Step5Status = "Completed - Removed from $RemovedGroups EXO group(s)"
        }
    } catch {
        Write-Host "[X] Step 5 Failed: $($_.Exception.Message)" -ForegroundColor Red
        $Step5Status = "Failed: $($_.Exception.Message)"
    }
} elseif (-not $HasEXOMailbox) {
    Write-Host "[!] Step 5: Skipped (no EXO mailbox)." -ForegroundColor Yellow
    $Step5Status = "Skipped - no EXO mailbox"
} else {
    Write-Host "[!] Step 5: Skipped per technician selection." -ForegroundColor Yellow
    $Step5Status = "Skipped - not selected"
}

# --- Step 6: Remove On-Premises AD Group Memberships ---
if ($RemoveADGroups) {
    Write-Host "[*] Step 6: Processing on-premises AD group memberships..." -ForegroundColor Cyan
    try {
        $ADGroups = Get-ADPrincipalGroupMembership -Identity $sAMAccountName -Credential $ADCredential -ErrorAction Stop |
                    Where-Object { $_.Name -ne "Domain Users" }
        if ($ADGroups.Count -eq 0) {
            Write-Host "[*] Step 6: No AD group memberships to remove." -ForegroundColor Yellow
            $Step6Status = "Completed - No group memberships found"
        } else {
            $RemovedADGroups = 0
            foreach ($Group in $ADGroups) {
                try {
                    Remove-ADGroupMember -Identity $Group -Members $sAMAccountName -Credential $ADCredential -Confirm:$false -ErrorAction Stop
                    Write-Host "[+] Removed from AD group: $($Group.Name)" -ForegroundColor Green
                    $RemovedADGroups++
                } catch {
                    Write-Host "[!] Could not remove from '$($Group.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
            $Step6Status = "Completed - Removed from $RemovedADGroups AD group(s)"
        }
    } catch {
        Write-Host "[X] Step 6 Failed: $($_.Exception.Message)" -ForegroundColor Red
        $Step6Status = "Failed: $($_.Exception.Message)"
    }
} else {
    Write-Host "[!] Step 6: Skipped per technician selection." -ForegroundColor Yellow
    $Step6Status = "Skipped - not selected"
}

# ==============================================================================
# STAGE 10: RECONCILIATION REPORT
# ==============================================================================
Write-Host ""
Write-Host ("=" * 73) -ForegroundColor Cyan
Write-Host "                     OFFBOARDING RECONCILIATION REPORT" -ForegroundColor Cyan
Write-Host ("=" * 73) -ForegroundColor Cyan
Write-Host "  Technician     : $TechnicianName"
Write-Host "  Target         : $DisplayName ($UserEmail)"
Write-Host "  sAMAccountName : $sAMAccountName"
Write-Host "  Timestamp      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "  Log File       : $LogPath" -ForegroundColor DarkCyan
Write-Host "  -----------------------------------------------------------------------"

# Display each step status with color-coded result
function Write-StepResult {
    param($StepLabel, $StepStatus)
    if     ($StepStatus -like "Completed*") { Write-Host "  $StepLabel : $StepStatus" -ForegroundColor Green  }
    elseif ($StepStatus -like "Partial*")   { Write-Host "  $StepLabel : $StepStatus" -ForegroundColor Yellow }
    elseif ($StepStatus -like "Skipped*")   { Write-Host "  $StepLabel : $StepStatus" -ForegroundColor Yellow }
    elseif ($StepStatus -like "Failed*")    { Write-Host "  $StepLabel : $StepStatus" -ForegroundColor Red    }
    else                                    { Write-Host "  $StepLabel : $StepStatus" }
}

Write-StepResult "Step 1 (AD Disable)       " $Step1Status
Write-StepResult "Step 2 (M365 Block)       " $Step2Status
Write-StepResult "Step 3 (Session Revoke)   " $Step3Status
Write-StepResult "Step 4 (Mailbox/License)  " $Step4Status
Write-StepResult "Step 5 (EXO Groups)       " $Step5Status
Write-StepResult "Step 6 (AD Groups)        " $Step6Status

Write-Host ("=" * 73) -ForegroundColor Cyan
Write-Host ""
Write-Host "[*] Offboarding pipeline complete." -ForegroundColor Cyan

# Disconnect services cleanly
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Disconnect-MgGraph -ErrorAction SilentlyContinue

Stop-Transcript -ErrorAction SilentlyContinue
