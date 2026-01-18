#Requires -RunAsAdministrator

# 1. Get all Defender Preferences (including exclusions)
$DefenderConfig = Get-MpPreference

# 2. Display Exclusions in a formatted list (recommended for clarity)
Write-Host "`n--- File Path Exclusions ---" -ForegroundColor Cyan
$DefenderConfig.ExclusionPath | ForEach-Object { Write-Host $_ }

Write-Host "`n--- File Type Exclusions ---" -ForegroundColor Cyan
$DefenderConfig | Select-Object -Property ExclusionExtension | Format-List

Write-Host "`n--- Process Exclusions ---" -ForegroundColor Cyan
$DefenderConfig | Select-Object -Property ExclusionProcess | Format-List

Write-Host "`n--- IP Address Exclusions ---" -ForegroundColor Cyan
$DefenderConfig | Select-Object -Property ExclusionIpAddress | Format-List
