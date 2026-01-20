#!/bin/bash

###############################################
# Ansible Controller Setup Script.
# Installs Ansible, creates directory structure,
# and initializes Ansible Vault.
# Detects OS and installs dependencies accordingly.
#
# Run on Linux Ansible controller machine (or WSL).
# 'cd ~/ && sudo bash ansible_setup.sh'
#
# You will be prompted for a vault password.
# You will then need to add the Windows ansible user password
# in the editor that opens (vault). 
# Esc then :wq to save and exit.
###############################################

set -e

BASE="$HOME/ansible"
GV="$BASE/group_vars"
VAULT_FILE="$GV/vault.yml"

echo "- Installing Ansible and dependencies"

if [ -f /etc/debian_version ]; then
  sudo apt update
  sudo apt install -y ansible python3 python3-pip openssh-client
elif [ -f /etc/redhat-release ]; then
  sudo dnf install -y ansible python3 python3-pip openssh-clients
elif [ -f /etc/alpine-release ]; then
  sudo apk add ansible python3 py3-pip openssh
else
  echo "Unsupported Linux distro"
  exit 1
fi

pip3 install --user pywinrm

echo "- Creating Ansible directory structure"
mkdir -p "$BASE" "$GV"

echo "- Writing ansible.cfg"
cat <<EOF > "$BASE/ansible.cfg"
[defaults]
inventory = inventory.yml
group_vars = group_vars
host_key_checking = False
retry_files_enabled = False
stdout_callback = yaml
EOF

echo "- Writing base group_vars"

cat <<EOF > "$GV/all.yml"
ansible_python_interpreter: /usr/bin/python3
EOF

cat <<EOF > "$GV/linux.yml"
ansible_connection: ssh
EOF

cat <<EOF > "$GV/windows.yml"
ansible_user: ansible
ansible_password: "{{ vault_windows_ansible_password }}"
ansible_connection: winrm
ansible_winrm_transport: ntlm
ansible_winrm_server_cert_validation: ignore
EOF

# Create vault (prompt for vault password)
if [ ! -f "$VAULT_FILE" ]; then
  echo "- Creating Ansible Vault"
  ansible-vault create "$VAULT_FILE"
else
  echo "-- Vault already exists, skipping"
fi

echo
echo "Setup complete."
echo "Next step: run inventory_gen.py"
