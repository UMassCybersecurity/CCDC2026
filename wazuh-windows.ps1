# Check for Admin Privileges
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Please run this script as an Administrator."
    break
}

$msiUrl = "https://packages.wazuh.com/4.x/windows/wazuh-agent-4.14.1-1.msi"
$msiPath = "$env:TEMP\wazuh-agent-4.14.1-1.msi"
$managerIp = "10.0.0.2"

Write-Host "Downloading Wazuh Agent..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath

Write-Host "Installing Wazuh Agent..." -ForegroundColor Cyan
# This runs the installer using the path we defined above
Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /q WAZUH_MANAGER=`"$managerIp`"" -Wait

Write-Host "Starting Wazuh Service..." -ForegroundColor Cyan
# Reverted to the original command from your guide
Start-Service wazuhsvc

Write-Host "Installation and Configuration Complete!" -ForegroundColor Green
