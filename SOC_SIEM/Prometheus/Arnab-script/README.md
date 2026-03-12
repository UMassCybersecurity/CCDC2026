# Prometheus Active Directory Monitoring Stack

Automated deployment of Prometheus exporters for monitoring Windows Active Directory, ADFS, and general OS health, plus server-side alerting rules.

## Components

| Component | Description | Default Port |
|-----------|-------------|:------------:|
| [windows_exporter](https://github.com/prometheus-community/windows_exporter) | OS metrics + AD performance counters (CPU, memory, disk, services, replication, LDAP, Kerberos) | 9182 |
| [active_directory_exporter](https://github.com/jasonmcintosh/active_directory_exporter) | Dedicated AD metrics (replication partners, failures, LDAP searches) | 9164 |
| [adfs_exporter](https://github.com/cosmonaut/adfs_exporter) | AD FS metrics (token requests, auth failures, certificate expiry, extranet lockouts) | 9222 |

## Repository Structure

```
.
├── Install-PrometheusExporters.ps1   # PowerShell installer (runs on the Windows DC/ADFS server)
├── prometheus-scrape-config.yml      # Scrape config to merge into prometheus.yml (Prometheus server)
├── rules/
│   └── ad_alerts.yml                 # Alerting rules (Prometheus server)
└── README.md
```

## Prerequisites

**On the Windows target (Domain Controller / ADFS server):**
- Windows Server 2016 or later
- PowerShell 5.1+
- Administrator privileges
- Outbound internet access (to download exporter binaries from GitHub)

**On the Prometheus server (Linux):**
- Prometheus 2.x installed and running
- Network access to the Windows target on ports 9182, 9164, 9222
- (Optional) Alertmanager for receiving alerts

## Part 1: Installing the Exporters (Windows Side)

### 1. Transfer the script

Copy `Install-PrometheusExporters.ps1` to the target Windows server.

### 2. Review configuration

Open the script and adjust the variables at the top if needed:

```powershell
$InstallRoot = "C:\Prometheus"           # Where binaries are installed
$WinExporterVersion = "0.29.2"           # Check GitHub for latest
$ADExporterVersion  = "0.4.0"
$ADFSExporterVersion = "1.1.0"
```

### 3. Run the script

Open an elevated PowerShell prompt and run:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
.\Install-PrometheusExporters.ps1
```

### What the script does

| Step | Action |
|:----:|--------|
| 1 | Creates `C:\Prometheus\` directory tree |
| 2 | Downloads and installs **windows_exporter** via MSI (silent). Enables collectors: `ad`, `cpu`, `cs`, `dhcp`, `dns`, `logical_disk`, `memory`, `net`, `os`, `process`, `service`, `system`, `thermalzone`, `time` |
| 3 | Downloads **active_directory_exporter**, extracts it, and registers a Windows service |
| 4 | Downloads **adfs_exporter**, extracts it, and registers a Windows service |
| 5 | Creates inbound firewall rules for TCP ports 9182, 9164, 9222 (Domain profile only) |
| 6 | Verifies all three services are running and tests each `/metrics` HTTP endpoint |
| 7 | Removes temporary download files |

All three exporters are registered as Windows services with **automatic start** and **auto-restart on failure** (3 retries with increasing delays).

### Verify after installation

```powershell
# Check services
Get-Service windows_exporter, ad_exporter, adfs_exporter | Format-Table Name, Status

# Test endpoints
Invoke-WebRequest http://localhost:9182/metrics -UseBasicParsing | Select-Object StatusCode
Invoke-WebRequest http://localhost:9164/metrics -UseBasicParsing | Select-Object StatusCode
Invoke-WebRequest http://localhost:9222/metrics -UseBasicParsing | Select-Object StatusCode
```

## Part 2: Prometheus Server Configuration (Linux Side)

### 1. Add scrape targets

Open your Prometheus config (typically `/etc/prometheus/prometheus.yml`) and merge in the contents of `prometheus-scrape-config.yml`.

Replace all `<DC_HOSTNAME_X>` and `<ADFS_SERVER_X>` placeholders with actual FQDNs or IPs:

```yaml
# Example
- targets:
    - "dc01.corp.example.com:9182"
    - "dc02.corp.example.com:9182"
```

### 2. Install alerting rules

```bash
sudo mkdir -p /etc/prometheus/rules
sudo cp rules/ad_alerts.yml /etc/prometheus/rules/
sudo chown prometheus:prometheus /etc/prometheus/rules/ad_alerts.yml
```

Make sure `prometheus.yml` references the rules directory:

```yaml
rule_files:
  - "/etc/prometheus/rules/ad_alerts.yml"
```

### 3. Validate and reload

```bash
# Validate config
promtool check config /etc/prometheus/prometheus.yml
promtool check rules /etc/prometheus/rules/ad_alerts.yml

# Reload (pick one)
kill -HUP $(pidof prometheus)
# or, if --web.enable-lifecycle is enabled:
curl -X POST http://localhost:9090/-/reload
```

### 4. Confirm scrape targets

Open `http://<prometheus-server>:9090/targets` in your browser. All three jobs (`windows_exporter`, `ad_exporter`, `adfs_exporter`) should show **UP**.

## Part 3: Alerting Rules Reference

The rules file (`rules/ad_alerts.yml`) contains 18 alerts across 4 groups:

### AD Domain Controller Health
| Alert | Severity | Trigger |
|-------|----------|---------|
| ADReplicationFailure | critical | Replication sync failures increasing over 10m |
| ADReplicationPendingHigh | warning | >50 pending replication ops for 15m |
| ADLDAPBindTimeSlow | warning | >20 active LDAP threads for 10m |
| ADLDAPSearchRateSpike | warning | >1000 LDAP searches/sec for 5m |
| ADKerberosAuthFailures | warning | >10 Kerberos failures/sec for 10m |
| ADNTLMAuthRateHigh | info | >100 NTLM auths/sec for 15m (legacy protocol) |
| ADDRAInboundObjectsHigh | warning | >500 inbound replicated objects/sec for 10m |
| ADDCNotAdvertising | critical | DC stops advertising for 5m |

### Windows OS Health (DC-focused)
| Alert | Severity | Trigger |
|-------|----------|---------|
| ADCriticalServiceDown | critical | NTDS, DNS, KDC, Netlogon, DFSR, or W32Time stopped for 2m |
| DCHighCPU | warning | CPU >90% for 15m |
| DCLowDiskSpace | critical | Any volume >90% full for 10m |
| DCTimeSkew | critical | Clock offset >120 seconds for 5m (breaks Kerberos) |
| DCHighMemoryUsage | warning | Memory >95% for 15m |

### ADFS Health
| Alert | Severity | Trigger |
|-------|----------|---------|
| ADFSTokenRequestFailures | warning | >5 token failures/sec for 10m |
| ADFSExtranetLockouts | critical | >10 lockouts/sec for 5m (brute force indicator) |
| ADFSCertificateExpiring | warning | Certificate expires within 30 days |
| ADFSServiceDown | critical | ADFS exporter unreachable for 3m |

### Exporter Meta-Monitoring
| Alert | Severity | Trigger |
|-------|----------|---------|
| WindowsExporterDown | critical | Exporter unreachable for 3m |
| ADExporterDown | warning | Exporter unreachable for 5m |
| ExporterScrapeSlow | warning | Scrape takes >30s for 10m |

## Tuning

- **Metric names** may differ between exporter versions. After installation, browse `http://<server>:9182/metrics` to verify actual names and adjust alert expressions as needed.
- **Thresholds** in the alert rules are sensible defaults. Adjust them based on your environment's baseline. For example, a large AD forest will naturally have higher LDAP search rates.
- **Scrape intervals** default to 30s for most jobs, 60s for the AD exporter (replication metrics change slowly). Lower intervals give faster alerting but increase load.

## Uninstalling

On the Windows server:

```powershell
# Stop and remove services
Stop-Service windows_exporter, ad_exporter, adfs_exporter -Force
sc.exe delete ad_exporter
sc.exe delete adfs_exporter
# windows_exporter was installed via MSI:
msiexec /x C:\Prometheus\windows_exporter.msi /qn

# Remove files and firewall rules
Remove-Item -Recurse -Force C:\Prometheus
Remove-NetFirewallRule -DisplayName "Prometheus - windows_exporter"
Remove-NetFirewallRule -DisplayName "Prometheus - AD exporter"
Remove-NetFirewallRule -DisplayName "Prometheus - ADFS exporter"
```
