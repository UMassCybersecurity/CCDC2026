#Requires -RunAsAdministrator
# Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process (if execution policy is in the way)

# Made with a healthy dosage of trial and error + LLMs

$OutputCsv = "$PWD\Service_Port_Report.csv"

# SERVICES
# NOTE: using this method instead of Get-Service bc the latter does not capture PIDs. Can also use Win32_Service but that's deprecated
$services = Get-CimInstance Win32_Service | Select-Object `
    Name,
    DisplayName,
    State,
    StartMode, # Recall, Auto = start at boot!
    ProcessId,
    PathName

# PORTS: netstat -ano and parse output
$netstatRaw = netstat -ano | Select-String -Pattern "LISTENING|ESTABLISHED"

$netstatParsed = foreach ($line in $netstatRaw.Line) {
    $clean = ($line -replace '\s+', ' ').Trim()
    $parts = $clean.Split(' ')

    # Expected format: Protocol LocalAddress ForeignAddress State PID
    if ($parts.Count -ge 5) {
        $localAddr = $parts[1]

        # Format IPv6 and IPv4 addresses.
        $lastColon = $localAddr.LastIndexOf(':')
        if ($lastColon -gt 0) {
            [PSCustomObject]@{
                Protocol     = $parts[0]
                LocalAddress = $localAddr.Substring(0, $lastColon)
                LocalPort    = $localAddr.Substring($lastColon + 1)
                procID       = [int]$parts[-1]
            }
        }
    }
}

# CORRELATING Services To Ports (TM)
$report = foreach ($svc in $services) {
    $procID = $svc.ProcessId

    # if you DO NOT want to include system-only services, exclude PID 0. I kept it in for paranoia's sake.
    # $matched = if ($procID -and $procID -ne 0) {
    $matched = if ($procID) {
        $netstatParsed | Where-Object { $_.procID -eq $procID }
    }

    if ($matched) {
        foreach ($m in $matched) {
            [PSCustomObject]@{
                ServiceName  = $svc.Name
                DisplayName  = $svc.DisplayName
                State        = $svc.State
                StartMode   = $svc.StartMode
                PID          = $procID
                Protocol     = $m.Protocol
                LocalAddress = $m.LocalAddress
                LocalPort    = $m.LocalPort
                BinaryPath  = $svc.PathName
            }
        }
    }
    else {
        # Service with no listening ports
        [PSCustomObject]@{
            ServiceName  = $svc.Name
            DisplayName  = $svc.DisplayName
            State        = $svc.State
            StartMode   = $svc.StartMode
            PID          = $procID
            Protocol     = $null
            LocalAddress = $null
            LocalPort    = $null
            BinaryPath  = $svc.PathName
        }
    }
}

# EXPORT
$report |
    Sort-Object ServiceName, LocalPort |
    Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Host "Report written to: $OutputCsv" -ForegroundColor Green # ooo look I can do fancy colors
