# ==============================
# Active Directory State Backup
# ==============================

$Desktop = [Environment]::GetFolderPath("Desktop")
$BackupRoot = Join-Path $Desktop "AD_State_Backup_$(Get-Date -Format yyyyMMdd_HHmmss)"
New-Item -ItemType Directory -Path $BackupRoot | Out-Null

# Subfolders
$GpoPath   = Join-Path $BackupRoot "GPOs"
$AdPath    = Join-Path $BackupRoot "AD_Objects"
$DnsPath   = Join-Path $BackupRoot "DNS"
$SystemStatePath = Join-Path $BackupRoot "SystemState"

New-Item -ItemType Directory -Path $GpoPath,$AdPath,$DnsPath,$SystemStatePath | Out-Null

Write-Host "[*] Backup path: $BackupRoot"

# ------------------------------
# 1. SYSTEM STATE BACKUP (NTDS + SYSVOL)
# ------------------------------
Write-Host "[*] Backing up System State (NTDS, SYSVOL, registry)..."

wbadmin start systemstatebackup `
    -backupTarget:$SystemStatePath `
    -quiet

# ------------------------------
# 2. GPO BACKUP
# ------------------------------
Write-Host "[*] Backing up GPOs..."

Import-Module GroupPolicy
Backup-GPO -All -Path $GpoPath

# ------------------------------
# 3. AD OBJECT METADATA 
# ------------------------------
Write-Host "[*] Exporting AD objects..."

Import-Module ActiveDirectory

Get-ADUser -Filter * -Properties * |
    Select Name,SamAccountName,Enabled,LastLogonDate,PasswordLastSet,MemberOf |
    Export-Csv "$AdPath\users.csv" -NoTypeInformation

Get-ADGroup -Filter * -Properties * |
    Select Name,SamAccountName,GroupCategory,GroupScope |
    Export-Csv "$AdPath\groups.csv" -NoTypeInformation

Get-ADComputer -Filter * -Properties * |
    Select Name,OperatingSystem,LastLogonDate,Enabled |
    Export-Csv "$AdPath\computers.csv" -NoTypeInformation

# ------------------------------
# 4. DNS ZONES
# ------------------------------
Write-Host "[*] Exporting DNS zones..."

$zones = Get-DnsServerZone
foreach ($z in $zones) {
    dnscmd /zoneexport $z.ZoneName "$($z.ZoneName).dns"
    Move-Item "$env:SystemRoot\System32\dns\$($z.ZoneName).dns" $DnsPath -Force
}

# ------------------------------
# 5. IFM MEDIA (FAST DC RESTORE)
# ------------------------------
Write-Host "[*] Creating IFM media..."

$IfmPath = Join-Path $BackupRoot "IFM"
New-Item -ItemType Directory -Path $IfmPath | Out-Null

ntdsutil "activate instance ntds" `
         "ifm" `
         "create sysvol full $IfmPath" `
         quit quit

# ------------------------------
# DONE
# ------------------------------
Write-Host "[+] AD State backup complete!"
Write-Host "[+] Location: $BackupRoot"
