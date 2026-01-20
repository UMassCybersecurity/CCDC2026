#!/usr/bin/env python3

###############################################
# Interactive script to create/update Ansible inventory.
# Prompts for host details and generates inventory + group_vars files.
# For each target enter:
# - Hostname
# - IP address
# - OS type (Linux/Windows)
# - Role (server/workstation/AD)
# - SSH username (for Linux hosts)
#
# Run with 'python3 inventory_gen.py'
###############################################

import os
import ipaddress
import yaml

BASE_DIR = os.getcwd()
INVENTORY_DIR = os.path.join(BASE_DIR, "inventory")
GROUP_VARS_DIR = os.path.join(BASE_DIR, "group_vars")
HOSTS_FILE = os.path.join(INVENTORY_DIR, "hosts.yml")

os.makedirs(INVENTORY_DIR, exist_ok=True)
os.makedirs(GROUP_VARS_DIR, exist_ok=True)


def load_yaml(path):
    if os.path.exists(path):
        with open(path, "r") as f:
            return yaml.safe_load(f) or {}
    return {}


def save_yaml(path, data):
    with open(path, "w") as f:
        yaml.safe_dump(data, f, sort_keys=False)


def prompt(msg):
    return input(msg).strip()


def prompt_ip():
    while True:
        ip = prompt("IP address: ")
        try:
            ipaddress.ip_address(ip)
            return ip
        except ValueError:
            print("Invalid IP")


def normalize_os(val):
    v = val.lower()
    if v in ("l", "linux"):
        return "linux"
    if v in ("w", "windows"):
        return "windows"
    return None


def normalize_role(val, os_type):
    v = val.lower()
    if v in ("s", "server"):
        return "server"
    if v in ("w", "workstation"):
        return "workstation"
    if os_type == "windows" and v == "ad":
        return "ad"
    return None


def ensure_group_vars(group, updates):
    path = os.path.join(GROUP_VARS_DIR, f"{group}.yml")
    data = load_yaml(path)
    changed = False

    for k, v in updates.items():
        if data.get(k) != v:
            data[k] = v
            changed = True

    if changed:
        save_yaml(path, data)


def main():
    inventory = load_yaml(HOSTS_FILE)

    inventory.setdefault("all", {})
    inventory["all"].setdefault("children", {})
    groups = inventory["all"]["children"]

    print("\nDefine hosts (type 'done' as hostname to finish)\n")

    # Host vars

    while True:
        hostname = prompt("Hostname: ")
        if hostname.lower() == "done":
            break

        ip = prompt_ip()

        os_type = None
        while not os_type:
            os_type = normalize_os(
                prompt("OS [l=linux, w=windows]: "))
            if not os_type:
                print("Invalid OS")

        role = None
        while not role:
            role = normalize_role(
                prompt("Role [s=server, w=workstation, ad=domain controller]: "),
                os_type)
            if not role:
                print("Invalid role")

        # Determine group
        if os_type == "windows":
            group = "windows_ad" if role == "ad" else f"windows_{role}s"
        else:
            group = f"linux_{role}s"

        groups.setdefault(group, {"hosts": {}})

        host_vars = {"ansible_host": ip}

        if os_type == "linux":
            ssh_user = prompt(f"SSH username for {hostname}: ")
            host_vars["ansible_user"] = ssh_user
            host_vars["ansible_become"] = True

        groups[group]["hosts"][hostname] = host_vars

    # Group vars

    ensure_group_vars("windows", {
        "ansible_connection": "winrm",
        "ansible_winrm_transport": "ntlm",
        "ansible_winrm_server_cert_validation": "ignore",
        "ansible_user": "ansible",
        "ansible_password": "{{ vault_windows_ansible_password }}"
    })

    ensure_group_vars("linux", {
        "ansible_connection": "ssh",
        "ansible_become": True
    })

    save_yaml(HOSTS_FILE, inventory)

    print("\nInventory and group_vars updated :D\n")


if __name__ == "__main__":
    main()
