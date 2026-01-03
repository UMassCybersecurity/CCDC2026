# Modified heavily from https://gitlab.com/nuccdc/tools/-/blob/master/scripts/windows/change-pass.ps1
# 1/3/2026 NOTICE: This script is UNTESTED! I will test this on an actual computer in like two days

# Changes:
# - DONE: pull from a dictionary to make passwords human-typable
# - DONE: ability to accept/reject individual users
# - TODO: what dictionary to use? well-defined one? guaranteed to be on windows systems? soemthing custom we make?
# - TODO: error detection... maybe.
# - TODO: Exclude users (see Om's script)

# If ye can't run this script in PowerShell, try Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process


# DICTIONARY: words must be separated by newlines!
$wordlist = Read-Host "Enter the filepath for your wordlist file:`n"
$words = Get-Content $wordlist | Where-Object {$_.Length -ge 3} #this breaks each line into a string, filters for words > n chars.
$specialChars = "%()=?}{@#+!".ToCharArray()

# PASSWORD GENERATION
$minimumLength = 15 # To comply w/NIST get passwords to min. 15 chars
function getRandomPass{ 
    param(
        [Parameter(Mandatory=$true)][int]$minimumLength
    )

    do {
        $pass = (
            ($specialChars[(Get-Random -Maximum $SpecialChars.Length)]) +
            (Get-Random $Words) +
            (Get-Random $Words) +
            (Get-Random -Minimum 10 -Maximum 99)
        )
    } until ($pass.Length -ge $minimumLength) #this SHOULD make stuff like @catdog42(acetan99 in worst case. excluding special chars beca

    return (ConvertTo-SecureString $pass -AsPlainText -Force), $pass
}

# What it says on the tin.
function Confirm-User {
    param($Username)
    $response = Read-Host "Change password for $Username ? (y/n)"
    return $response.ToLower() -eq "y"
}

# OUTPUT
$Results = @()

# MAIN
$selection = Read-Host "Select which category of passwords to change:`n(1) AD`n (2) Local`n"

# AD PASSWORDS
if($selection -eq "1") {
    $adUsers = Get-ADUser -Filter * | Select-Object -Property SamAccountName
    # $names = $adUsers | Select-Object -Property SamAccountName

    foreach ($user in $adUsers) {
        $name = $user.samaccountname

        if (-not (Confirm-User $name)) { continue }

        $newPass = = Get-RandomPass($minimumLength)
        $newSecurePass = ConvertTo-SecureString $newPass -AsPlainText -Force

        Set-ADAccountPassword -Identity $user -NewPassword $newSecurePass -Reset
        
        $Results += [pscustomobject]@{
            User       = $name
            Type       = "AD"
            Password   = $newPass #plaintext
            Time       = Get-Date
        }

        Write-Host "Password changed for $name"
    }

}
# LOCAL PASSWORDS
if($selection -eq "2") {
    $localUsers = get-localuser | Where-Object { $_.Name -ne "name" } | Select-Object -Property Name

    foreach ($user in $localUsers) {
        $Name = $User.Name

        if (-not (Confirm-User $name)) { continue }

        $newPass = = Get-RandomPass($minimumLength)
        $newSecurePass = ConvertTo-SecureString $newPass -AsPlainText -Force

        $UserAccount | Set-LocalUser -Name $name -Password $newSecurePass
        
        $Results += [pscustomobject]@{
            User       = $name
            Type       = "LOCAL"
            Password   = $newPass #plaintext
            Time       = Get-Date
        }

        Write-Host "Password changed for $name"
    }
   
}

# EXPORT!
$csvPath = "password_changes_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$Results | Export-Csv -NoTypeInformation $csvPath

Write-Host "Results exported to $csvPath"
Write-Host "If it's not there... something has gone terribly wrong."
