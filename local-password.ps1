<# 
***************************************************************
* Reset passwords for LOCAL (non-AD) Windows users            *
***************************************************************

Created by: ChatGPT

Features:
1) Lists all local users
2) Allows excluding accounts
3) Prompts before changing each password
4) Generates random secure passwords
5) Logs results to CSV
#>

param(
    [Parameter(Position=0, Mandatory=$false)]
    [string[]]$ExcludeUsers = @(),

    [Parameter(Position=1, Mandatory=$false)]
    [string]$OutputPath = ".\",

    [Parameter(Position=2, Mandatory=$false, HelpMessage="Uppercase characters in password")]
    [int]$UCount = 4,

    [Parameter(Position=3, Mandatory=$false, HelpMessage="Lowercase characters in password")]
    [int]$LCount = 4,

    [Parameter(Position=4, Mandatory=$false, HelpMessage="Numbers in password")]
    [int]$NCount = 3,

    [Parameter(Position=5, Mandatory=$false, HelpMessage="Special characters in password")]
    [int]$SCount = 3
)

Reg save HKLM\SAM "$($OutputPath)SAM.bak"
Reg save HKLM\SYSTEM "$($OutputPath)SYSTEM.bak"

# ==========================
# Password Character Sets
# ==========================
$uppercase = "ABCDEFGHKLMNOPRSTUVWXYZ".ToCharArray()
$lowercase = "abcdefghiklmnoprstuvwxyz".ToCharArray()
$numbers   = "0123456789".ToCharArray()
$special   = "%()=?}{@#+!".ToCharArray()

# Ensure output file exists
New-Item -Path "$($OutputPath)local-passwd.csv" -ItemType File -Force | Out-Null

# Get local users
$users = Get-LocalUser

Write-Host "Found $($users.Count) local users on this system." -ForegroundColor Cyan

# Prompt control
$YesToAll = $false
$NoToAll  = $false

foreach ($user in $users) {

    # Skip disabled users optionally
    # if (-not $user.Enabled) { continue }

    # Skip excluded accounts
    if ($ExcludeUsers -contains $user.Name) {
        Write-Output "Skipping excluded user: $($user.Name)"
        continue
    }

    # Skip remaining if NoToAll selected
    if ($NoToAll) {
        Write-Output "Skipping (No to All): $($user.Name)"
        continue
    }

    # Prompt user unless YesToAll selected
    if (-not $YesToAll) {
        Write-Host ""
        Write-Host "Change password for LOCAL user: $($user.Name) ?" -ForegroundColor Cyan
        $choice = Read-Host "[Y] Yes  [N] No  [A] Yes to All  [X] No to All"

        switch ($choice.ToUpper()) {
            "Y" { }  # do nothing, continue to password change
            "N" { Write-Output "Skipping: $($user.Name)"; continue }
            "A" { $YesToAll = $true }
            "X" { $NoToAll = $true; Write-Output "Skipping all remaining users..."; continue }
            default { Write-Output "Invalid option. Skipping user."; continue }
        }
    }

    #
    # --- Generate Password ---
    #
    $password  = ($uppercase | Get-Random -Count $UCount) -join ''
    $password += ($lowercase | Get-Random -Count $LCount) -join ''
    $password += ($numbers   | Get-Random -Count $NCount) -join ''
    $password += ($special   | Get-Random -Count $SCount) -join ''

    # Shuffle password characters
    $password = ($password.ToCharArray() | Get-Random -Count $password.Length) -join ''

    #
    # --- Set Local Password ---
    #
    try {
        $secure = ConvertTo-SecureString $password -AsPlainText -Force
        Set-LocalUser -Name $user.Name -Password $secure

        Write-Host "Password changed for: $($user.Name)" -ForegroundColor Green
        Add-Content -Path "$($OutputPath)local-passwd.csv" -Value "$($user.Name),$password"
    }
    catch {
        Write-Host "Failed to set password for $($user.Name): $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Done! Passwords saved to: $($OutputPath)local-passwd.csv" -ForegroundColor Yellow
