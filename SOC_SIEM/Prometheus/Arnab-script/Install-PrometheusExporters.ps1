#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Downloads and installs Prometheus Windows Exporter, Active Directory Exporter,
    and ADFS Exporter on a Windows Server.

.DESCRIPTION
    This script automates the deployment of three Prometheus exporters:
      1. windows_exporter       - General Windows metrics (CPU, memory, disk, network, etc.)
      2. active_directory_exporter - AD-specific metrics (replication, LDAP, DRA counters)
      3. adfs_exporter           - AD FS metrics (token requests, authentication failures, etc.)

    Each exporter is installed as a Windows service so it starts automatically on boot.

    Default listening ports:
      - windows_exporter:             9182
      - active_directory_exporter:    9164
      - adfs_exporter:                9222

.NOTES
    Run this script on the Domain Controller / ADFS server as Administrator.
    Adjust the $Version variables below if newer releases are available.
#>

# ------------------------------------------------------------------
# 0. CONFIGURATION - adjust versions and paths as needed
# ------------------------------------------------------------------
$ErrorActionPreference = "Stop"

$InstallRoot = "C:\Prometheus"
$TempDir     = "$env:TEMP\prom_install"

# Exporter versions (check GitHub releases for latest)
$WinExporterVersion = "0.29.2"
$ADExporterVersion  = "0.4.0"
$ADFSExporterVersion = "1.1.0"

# Download URLs
$WinExporterURL  = "https://github.com/prometheus-community/windows_exporter/releases/download/v${WinExporterVersion}/windows_exporter-${WinExporterVersion}-amd64.msi"
$ADExporterURL   = "https://github.com/jasonmcintosh/active_directory_exporter/releases/download/v${ADExporterVersion}/active_directory_exporter-${ADExporterVersion}.windows-amd64.zip"
$ADFSExporterURL = "https://github.com/cosmonaut/adfs_exporter/releases/download/v${ADFSExporterVersion}/adfs_exporter-${ADFSExporterVersion}.windows-amd64.zip"

# Firewall rule names
$FWRules = @(
    @{ Name = "Prometheus - windows_exporter";  Port = 9182 },
    @{ Name = "Prometheus - AD exporter";       Port = 9164 },
    @{ Name = "Prometheus - ADFS exporter";     Port = 9222 }
)

# ------------------------------------------------------------------
# HELPER FUNCTIONS
# ------------------------------------------------------------------
function Write-Step {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Host "  Created directory: $Path" -ForegroundColor Gray
    }
}

function Download-File {
    param([string]$Url, [string]$Destination)
    Write-Host "  Downloading: $Url" -ForegroundColor Gray
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'   # speeds up Invoke-WebRequest
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    Write-Host "  Saved to:    $Destination" -ForegroundColor Gray
}

function Create-ExporterService {
    param(
        [string]$ServiceName,
        [string]$DisplayName,
        [string]$ExePath,
        [string]$Arguments
    )

    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  Service '$ServiceName' already exists - stopping for update..." -ForegroundColor Yellow
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        & sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 2
    }

    Write-Host "  Creating service: $ServiceName" -ForegroundColor Gray
    $binPath = if ($Arguments) { "`"$ExePath`" $Arguments" } else { "`"$ExePath`"" }
    & sc.exe create $ServiceName binPath= $binPath start= auto DisplayName= $DisplayName | Out-Null
    & sc.exe description $ServiceName "Prometheus exporter - $DisplayName" | Out-Null
    & sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

    Start-Service -Name $ServiceName
    Write-Host "  Service '$ServiceName' started successfully." -ForegroundColor Green
}

# ------------------------------------------------------------------
# 1. PREPARE DIRECTORIES
# ------------------------------------------------------------------
Write-Step "Step 1: Preparing directories"
Ensure-Directory $InstallRoot
Ensure-Directory "$InstallRoot\windows_exporter"
Ensure-Directory "$InstallRoot\ad_exporter"
Ensure-Directory "$InstallRoot\adfs_exporter"
Ensure-Directory $TempDir

# ------------------------------------------------------------------
# 2. INSTALL WINDOWS EXPORTER (MSI)
# ------------------------------------------------------------------
Write-Step "Step 2: Installing windows_exporter v${WinExporterVersion}"
# The MSI installer registers the service automatically.
# We enable extra collectors relevant to AD environments.

$MsiFile = "$TempDir\windows_exporter.msi"
Download-File -Url $WinExporterURL -Destination $MsiFile

# Collectors to enable (comma-separated). Key ones for AD:
#   ad        - Active Directory performance counters
#   dns       - DNS server metrics
#   dhcp      - DHCP server metrics
#   os        - OS-level info
#   cpu, cs, logical_disk, memory, net, process, service, system - standard
$Collectors = "ad,cpu,cs,dhcp,dns,logical_disk,memory,net,os,process,service,system,thermalzone,time"

Write-Host "  Running MSI installer (silent)..." -ForegroundColor Gray
$MsiArgs = @(
    "/i", $MsiFile,
    "/qn",                                         # quiet, no UI
    "/l*v", "$TempDir\windows_exporter_install.log", # verbose log
    "ENABLED_COLLECTORS=$Collectors",
    "LISTEN_PORT=9182"
)
Start-Process msiexec.exe -ArgumentList $MsiArgs -Wait -NoNewWindow

# Verify the service is running
$svc = Get-Service -Name "windows_exporter" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Write-Host "  windows_exporter is running on port 9182." -ForegroundColor Green
} else {
    Write-Host "  Starting windows_exporter service..." -ForegroundColor Yellow
    Start-Service -Name "windows_exporter" -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------
# 3. INSTALL ACTIVE DIRECTORY EXPORTER
# ------------------------------------------------------------------
Write-Step "Step 3: Installing active_directory_exporter v${ADExporterVersion}"

$ADZip = "$TempDir\ad_exporter.zip"
Download-File -Url $ADExporterURL -Destination $ADZip

Write-Host "  Extracting archive..." -ForegroundColor Gray
Expand-Archive -Path $ADZip -DestinationPath "$InstallRoot\ad_exporter" -Force

# Locate the exe (may be nested in a subfolder)
$ADExe = Get-ChildItem -Path "$InstallRoot\ad_exporter" -Recurse -Filter "active_directory_exporter*.exe" | Select-Object -First 1
if (-not $ADExe) {
    Write-Warning "Could not find active_directory_exporter exe. You may need to adjust the download URL or extract manually."
} else {
    Create-ExporterService `
        -ServiceName  "ad_exporter" `
        -DisplayName  "Prometheus Active Directory Exporter" `
        -ExePath      $ADExe.FullName `
        -Arguments    "--web.listen-address=:9164"
}

# ------------------------------------------------------------------
# 4. INSTALL ADFS EXPORTER
# ------------------------------------------------------------------
Write-Step "Step 4: Installing adfs_exporter v${ADFSExporterVersion}"

$ADFSZip = "$TempDir\adfs_exporter.zip"
Download-File -Url $ADFSExporterURL -Destination $ADFSZip

Write-Host "  Extracting archive..." -ForegroundColor Gray
Expand-Archive -Path $ADFSZip -DestinationPath "$InstallRoot\adfs_exporter" -Force

$ADFSExe = Get-ChildItem -Path "$InstallRoot\adfs_exporter" -Recurse -Filter "adfs_exporter*.exe" | Select-Object -First 1
if (-not $ADFSExe) {
    Write-Warning "Could not find adfs_exporter exe. You may need to adjust the download URL or extract manually."
} else {
    Create-ExporterService `
        -ServiceName  "adfs_exporter" `
        -DisplayName  "Prometheus ADFS Exporter" `
        -ExePath      $ADFSExe.FullName `
        -Arguments    "--web.listen-address=:9222"
}

# ------------------------------------------------------------------
# 5. CONFIGURE FIREWALL RULES
# ------------------------------------------------------------------
Write-Step "Step 5: Configuring Windows Firewall rules"

foreach ($rule in $FWRules) {
    $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  Firewall rule '$($rule.Name)' already exists - skipping." -ForegroundColor Yellow
    } else {
        New-NetFirewallRule `
            -DisplayName $rule.Name `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort $rule.Port `
            -Action Allow `
            -Profile Domain `
            -Description "Allow Prometheus server to scrape metrics on port $($rule.Port)" | Out-Null
        Write-Host "  Created firewall rule: $($rule.Name) (TCP/$($rule.Port))" -ForegroundColor Green
    }
}

# ------------------------------------------------------------------
# 6. VERIFY ALL SERVICES
# ------------------------------------------------------------------
Write-Step "Step 6: Verification"

$Services = @("windows_exporter", "ad_exporter", "adfs_exporter")
foreach ($svcName in $Services) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc) {
        $color = if ($svc.Status -eq 'Running') { 'Green' } else { 'Red' }
        Write-Host "  $svcName : $($svc.Status)" -ForegroundColor $color
    } else {
        Write-Host "  $svcName : NOT INSTALLED" -ForegroundColor Red
    }
}

# Quick HTTP health check
$Ports = @(9182, 9164, 9222)
foreach ($port in $Ports) {
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$port/metrics" -UseBasicParsing -TimeoutSec 5
        Write-Host "  Port $port - HTTP $($response.StatusCode) OK" -ForegroundColor Green
    } catch {
        Write-Host "  Port $port - Not responding (may not be applicable if role not installed)" -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------------
# 7. CLEANUP
# ------------------------------------------------------------------
Write-Step "Step 7: Cleanup"
Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  Temporary files removed." -ForegroundColor Gray

# ------------------------------------------------------------------
# DONE
# ------------------------------------------------------------------
Write-Host "`n" -NoNewline
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Installation complete!" -ForegroundColor Green
Write-Host "" -ForegroundColor Green
Write-Host "  Metrics endpoints:" -ForegroundColor Green
Write-Host "    windows_exporter:  http://localhost:9182/metrics" -ForegroundColor Green
Write-Host "    AD exporter:       http://localhost:9164/metrics" -ForegroundColor Green
Write-Host "    ADFS exporter:     http://localhost:9222/metrics" -ForegroundColor Green
Write-Host "" -ForegroundColor Green
Write-Host "  Next: Configure your Prometheus server to scrape these" -ForegroundColor Green
Write-Host "  endpoints. See the README for prometheus.yml examples" -ForegroundColor Green
Write-Host "  and alerting rules." -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
