# Check for Admin Privileges
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Please run this script as an Administrator."
    break
}

# 1. SET VARIABLES
$managerIp = "10.0.0.2"
$tempDir   = "$env:TEMP\WazuhInstall"
if (!(Test-Path $tempDir)) { New-Item -ItemType Directory -Force -Path $tempDir | Out-Null }

$wazuhMsiUrl = "https://packages.wazuh.com/4.x/windows/wazuh-agent-4.14.1-1.msi"
$sysmonUrl   = "https://download.sysinternals.com/files/Sysmon.zip"
$sysmonConf  = "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml"

# 2. DOWNLOAD EVERYTHING
Write-Host "Downloading Wazuh, Sysmon, and Config..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $wazuhMsiUrl -OutFile "$tempDir\wazuh-agent.msi"
Invoke-WebRequest -Uri $sysmonUrl -OutFile "$tempDir\Sysmon.zip"
Invoke-WebRequest -Uri $sysmonConf -OutFile "$tempDir\sysmonconfig.xml"

# 3. INSTALL WAZUH AGENT 
Write-Host "Installing Wazuh Agent..." -ForegroundColor Cyan
Start-Process msiexec.exe -ArgumentList "/i `"$tempDir\wazuh-agent.msi`" /q WAZUH_MANAGER=`"$managerIp`"" -Wait

# 4. INSTALL SYSMON
Write-Host "Installing Sysmon..." -ForegroundColor Cyan
if (Test-Path "$tempDir\Sysmon") { Remove-Item "$tempDir\Sysmon" -Recurse -Force }
Expand-Archive -Path "$tempDir\Sysmon.zip" -DestinationPath "$tempDir\Sysmon" -Force
Start-Process "$tempDir\Sysmon\Sysmon64.exe" -ArgumentList "-accepteula -i `"$tempDir\sysmonconfig.xml`"" -Wait

# 5. ENABLE AD AUDIT POLICIES
Write-Host "Enabling Advanced Auditing..." -ForegroundColor Cyan
auditpol /set /subcategory:"Directory Service Access" /success:enable
auditpol /set /subcategory:"Kerberos Service Ticket Operations" /success:enable
auditpol /set /subcategory:"Logon" /success:enable /failure:enable

# 6. CONFIGURE WAZUH TO READ SYSMON
Write-Host "Updating Wazuh Config..." -ForegroundColor Cyan
$OssecConf = "C:\Program Files (x86)\ossec-agent\ossec.conf"
$SysmonBlock = @"
  <localfile>
    <location>Microsoft-Windows-Sysmon/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>
"@

if (Test-Path $OssecConf) {
    (Get-Content $OssecConf) -replace '</ossec_config>', "$SysmonBlock`n</ossec_config>" | Set-Content $OssecConf
}

# 7. SMART SERVICE START/RESTART
$ServiceName = "wazuhsvc"
# Get current status, suppressing errors if the service isn't found yet
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($service) {
    if ($service.Status -eq 'Running') {
        Write-Host "Wazuh is running. Restarting to apply AD and Sysmon config..." -ForegroundColor Yellow
        Restart-Service $ServiceName
    } else {
        Write-Host "Wazuh service found but stopped. Starting now..." -ForegroundColor Green
        Start-Service $ServiceName
    }
} else {
    Write-Error "Wazuh service not found. The installation may have failed."
}

Write-Host "AD Hardening & Monitoring Complete!" -ForegroundColor Green
