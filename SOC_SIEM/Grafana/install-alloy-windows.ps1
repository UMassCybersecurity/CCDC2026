#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Grafana Alloy on Windows as a Windows Service.

.DESCRIPTION
    Downloads the latest (or specified) Grafana Alloy installer from GitHub
    and performs a silent installation. The service is configured to start
    automatically on boot.

.PARAMETER Version
    Optional. Specific version to install (e.g. "v1.13.1").
    Defaults to the latest stable release.

.PARAMETER InstallDir
    Optional. Installation directory.
    Defaults to "%ProgramFiles%\GrafanaLabs\Alloy".

.PARAMETER ConfigPath
    Optional. Path to the Alloy config file to use after install.
    If omitted, a minimal placeholder config is created.

.PARAMETER Stability
    Optional. Stability level: generally-available | public-preview | experimental
    Defaults to "generally-available".

.EXAMPLE
    .\install-alloy-windows.ps1
    .\install-alloy-windows.ps1 -Version "v1.13.1"
    .\install-alloy-windows.ps1 -ConfigPath "C:\alloy\config.alloy"
#>

[CmdletBinding()]
param (
    [string] $Version    = "",
    [string] $InstallDir = "",
    [string] $ConfigPath = "",
    [ValidateSet("generally-available", "public-preview", "experimental")]
    [string] $Stability  = "generally-available"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Step  { param([string]$msg) Write-Host "`n==> $msg" -ForegroundColor Cyan  }
function Write-Ok    { param([string]$msg) Write-Host "    [OK] $msg"  -ForegroundColor Green }
function Write-Warn  { param([string]$msg) Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail  { param([string]$msg) Write-Host "    [FAIL] $msg" -ForegroundColor Red; exit 1 }

# ── Resolve version ───────────────────────────────────────────────────────────

Write-Step "Resolving Grafana Alloy version"

if ($Version -eq "") {
    try {
        $apiUrl   = "https://api.github.com/repos/grafana/alloy/releases/latest"
        $headers  = @{ "User-Agent" = "install-alloy-ps1" }
        $release  = Invoke-RestMethod -Uri $apiUrl -Headers $headers
        $Version  = $release.tag_name
        Write-Ok "Latest stable version: $Version"
    } catch {
        Write-Fail "Could not fetch latest version from GitHub: $_"
    }
} else {
    # Normalise: ensure leading 'v'
    if (-not $Version.StartsWith("v")) { $Version = "v$Version" }
    Write-Ok "Using specified version: $Version"
}

# ── Determine architecture ────────────────────────────────────────────────────

Write-Step "Detecting system architecture"

$arch = if ([System.Environment]::Is64BitOperatingSystem) { "amd64" } else {
    Write-Fail "Alloy only supports 64-bit (amd64) Windows."
}
Write-Ok "Architecture: $arch"

# ── Download installer ────────────────────────────────────────────────────────

Write-Step "Downloading Alloy installer"

$installerFile = "alloy-installer-windows-$arch.exe"
$downloadUrl   = "https://github.com/grafana/alloy/releases/download/$Version/$installerFile"
$tempDir       = Join-Path $env:TEMP "alloy-install"
$installerPath = Join-Path $tempDir  $installerFile

if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }

try {
    Write-Host "    Downloading from: $downloadUrl"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing
    Write-Ok "Downloaded to: $installerPath"
} catch {
    Write-Fail "Download failed: $_"
}

# ── Run silent install ────────────────────────────────────────────────────────

Write-Step "Running silent installation"

$installArgs = @("/S")
if ($InstallDir -ne "") {
    $installArgs += "/D=$InstallDir"
}
$installArgs += "/STABILITY=$Stability"

Write-Host "    Installer args: $($installArgs -join ' ')"

$proc = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Write-Fail "Installer exited with code $($proc.ExitCode)"
}
Write-Ok "Alloy installed successfully"

# Resolve actual install directory
if ($InstallDir -eq "") {
    $InstallDir = Join-Path $env:ProgramFiles "GrafanaLabs\Alloy"
}

# ── Create placeholder config if none supplied ─────────────────────────────────

Write-Step "Configuring Alloy"

$defaultConfig = Join-Path $InstallDir "config.alloy"

if ($ConfigPath -ne "") {
    if (Test-Path $ConfigPath) {
        Copy-Item -Path $ConfigPath -Destination $defaultConfig -Force
        Write-Ok "Copied config from: $ConfigPath"
    } else {
        Write-Warn "Specified config not found at '$ConfigPath'. Writing placeholder."
        $ConfigPath = ""
    }
}

if ($ConfigPath -eq "") {
    if (-not (Test-Path $defaultConfig)) {
        @"
// Grafana Alloy configuration
// Reference: https://grafana.com/docs/alloy/latest/
//
// Replace this placeholder with your actual pipeline configuration.

logging {
  level  = "info"
  format = "logfmt"
}
"@ | Set-Content -Path $defaultConfig -Encoding UTF8
        Write-Ok "Placeholder config written to: $defaultConfig"
    } else {
        Write-Ok "Existing config retained at: $defaultConfig"
    }
}

# ── Enable and start the Windows Service ──────────────────────────────────────

Write-Step "Managing Alloy Windows Service"

$svcName = "Alloy"

try {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Fail "Service '$svcName' not found after installation. Check installer logs."
    }

    Set-Service -Name $svcName -StartupType Automatic
    Write-Ok "Service set to start automatically"

    if ($svc.Status -eq "Running") {
        Restart-Service -Name $svcName -Force
        Write-Ok "Service restarted"
    } else {
        Start-Service -Name $svcName
        Write-Ok "Service started"
    }
} catch {
    Write-Fail "Could not manage service '$svcName': $_"
}

# ── Verify ────────────────────────────────────────────────────────────────────

Write-Step "Verifying installation"

Start-Sleep -Seconds 2
$svc = Get-Service -Name $svcName
if ($svc.Status -eq "Running") {
    Write-Ok "Alloy service is running"
} else {
    Write-Warn "Alloy service is in state: $($svc.Status). Check Event Viewer (Windows Logs > Application) for errors."
}

# ── Cleanup ───────────────────────────────────────────────────────────────────

Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host " Grafana Alloy $Version installed successfully on Windows" -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host " Install dir : $InstallDir"
Write-Host " Config file : $defaultConfig"
Write-Host " Service     : $svcName  (startup: Automatic)"
Write-Host " UI (local)  : http://localhost:12345"
Write-Host ""
Write-Host " Service management:"
Write-Host "   Start   -> Start-Service Alloy"
Write-Host "   Stop    -> Stop-Service  Alloy"
Write-Host "   Restart -> Restart-Service Alloy"
Write-Host ""
Write-Host " Logs: Event Viewer -> Windows Logs -> Application (source: Grafana Alloy)"
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
