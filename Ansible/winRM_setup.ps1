###############################################
# Windows Target Setup Script for Ansible.
# Allows WinRM and creates an 'ansible' admin user.
# BEFORE RUNNING: replace remoteip value with IP of Ansible controller.
# Run in Administrator PowerShell on each windows target.
# You will be prompted to enter a password for the ansible user.
###############################################

Write-Host "Enter password for the Ansible service account"
$SecurePass = Read-Host -AsSecureString

# Convert SecureString 
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePass)
$PlainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)

# Enable WinRM
winrm quickconfig -force
winrm set winrm/config/service/auth '@{NTLM="true"}'

# Firewall (CHANGE IP TO CONTROLLER IP)
netsh advfirewall firewall add rule name="WinRM" dir=in action=allow protocol=TCP localport=5985 remoteip=0.0.0.0

# Create Ansible service account
net user ansible $PlainPass /add 2>$null
net user ansible $PlainPass
net localgroup Administrators ansible /add

# Cleanup sensitive memory
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

Write-Host "WinRM configured and Ansible user ready"

