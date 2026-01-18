# Modified heavily from https://gitlab.com/nuccdc/tools/-/blob/master/scripts/windows/change-pass.ps1

# NOTES:
# You can use any dictionary you like so long as its format is some genre of 'words separated by newline characters'
    # I recommend using anything *clean* from https://gist.github.com/atoponce/95c4f36f2bc12ec13242a3ccc55023af

Write-Host "Make sure you're running this with administrator priviledges!`nBe wary of changing passwords for service accounts."
Write-Host "This tool needs a wordlist. Run `curl -o https://raw.githubusercontent.com/sts10/orchard-street-wordlists/refs/heads/main/lists/orchard-street-alpha.txt before continuing."
# If ye can't run this script in PowerShell, try Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process

# DICTIONARY: words must be separated by newlines!
$wordlist = Read-Host "`n`nEnter the filepath for your wordlist file:`n"
$words = Get-Content $wordlist | Where-Object {$_.Length -ge 3} #this breaks each line into a string, filters for words > n chars.
$specialChars = "%()=?}{@#+!".ToCharArray()

function getRandomSpecialChar{
    return $specialChars[(Get-Random -Maximum $SpecialChars.Length)]
}

function Confirm-User {
    param($Username)
    $response = Read-Host "Change password for $Username ? (y/n)"
    return $response.ToLower() -eq "y"
}

# PASSWORD GENERATION
# Retuns an object with a PlainText and a SecureString password. Normally this is horrid practice...
# but since we're tracking our password changes via CSV we've already burned that bridge.
$minimumLength = 15 # To comply w/NIST, get passwords to min. 15 chars
function getRandomPass{
    param(
        [Parameter(Mandatory=$true)][int]$MinimumLength
    )
    Write-Host "getRandomPass starting..."
    
    $pass = -join @(
	    (getRandomSpecialChar)
     	((Get-Random $Words).toLower())
    	((Get-Random $Words).toUpper())
     	(Get-Random -Minimum 10 -Maximum 99)
    )
    while ($pass.length -lt $minimumLength) {
        $pass += (getRandomSpecialChar)
        $pass += (Get-Random $Words)
	}
    
    Write-Host "current pass is $pass"
    Write-Host "getRandomPass exiting..."

    return [PSCustomObject]@{
        PlainText   = $pass         
        SecureString = (ConvertTo-SecureString $pass -AsPlainText -Force)
    }
}

# OUTPUT
$Results = @()

# MAIN
$selection = Read-Host "Select which category of passwords to change:`n(1) AD`n(2) Local`n"

# AD PASSWORDS
if($selection -eq "1") {
    $adUsers = Get-ADUser -Filter * | Select-Object -Property SamAccountName

    foreach ($user in $adUsers) {
        $name = $user.samaccountname

        if (-not (Confirm-User $name)) { continue }

        $pw = getRandomPass($minimumLength)

        Set-ADAccountPassword -Identity $user -NewPassword $pw.SecureString -Reset
        
        $Results += [pscustomobject]@{
            User       = $name
            Type       = "AD"
            Password   = $pw.PlainText
            Time       = Get-Date
        }

        Write-Host "Password changed for $name"
    }

}
# LOCAL PASSWORDS
if($selection -eq "2") {
    $localUsers = get-localuser | Where-Object { $_.Name -ne "name" } | Select-Object -Property Name

    foreach ($user in $localUsers) {
        $name = $User.Name

        if (-not (Confirm-User $name)) { continue }

        $pw = getRandomPass($minimumLength)

        Set-LocalUser -Name $name -Password $pw.SecureString
        
        $Results += [pscustomobject]@{
            User       = $name
            Type       = "LOCAL"
            Password   = $pw.PlainText
            Time       = Get-Date
        }

        Write-Host "Password changed for $name"
    }
   
}

Write-Host "Exporting..."

# EXPORT!
$csvPath = "password_changes_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$Results | Export-Csv -NoTypeInformation $csvPath

Write-Host "Results exported to $csvPath"
Write-Host "If it's not there... something has gone terribly wrong."
