#!/usr/bin/env python3
"""
OS-agnostic system information collector.
Collects system info across Windows, Linux (Ubuntu, RHEL, Alpine, CentOS, etc.)
"""

import platform
import socket
import subprocess
import json
import re
import shutil
from typing import Dict, List, Any, Optional
from pathlib import Path
from collections import defaultdict


class SystemInfoCollector:
    """Collects basic system information in an OS-agnostic way."""
    
    def __init__(self):
        self.system = platform.system()  # 'Windows', 'Linux', 'Darwin', etc.
        self.info = {}
    
    def collect_all(self) -> Dict[str, Any]:
        """Collect all system information."""
        self.info = {
            "os": self._get_os_info(),
            "hostname": self._get_hostname(),
            "ip_addresses": self._get_ip_addresses(),
            "dns_servers": self._get_dns_servers(),
            "network_config": self._get_network_config(),
            "users": self._get_users(),
            "packages": self._get_packages(),
            "services": self._get_services(),
            "processes": self._get_processes(),
            "firewall": self._get_firewall_status(),
            "system_resources": self._get_system_resources(),
        }
        return self.info
    
    def _get_os_info(self) -> Dict[str, str]:
        """Get OS information."""
        info = {
            "system": platform.system(),
            "release": platform.release(),
            "version": platform.version(),
            "machine": platform.machine(),
            "processor": platform.processor() or self._fallback_processor(),
        }
        
        # Try to get distro info on Linux
        if self.system == "Linux":
            distro_name = self._get_linux_distro()
            if distro_name:
                info["distro"] = distro_name
        
        return info

    def _fallback_processor(self) -> str:
        """Fallback processor/model detection for platforms returning empty processor."""
        try:
            if self.system == "Linux":
                cpuinfo = Path("/proc/cpuinfo")
                if cpuinfo.exists():
                    for line in cpuinfo.read_text().split('\n'):
                        if line.lower().startswith("model name"):
                            return line.split(':', 1)[1].strip()
            if shutil.which("lscpu"):
                result = subprocess.run(
                    ["lscpu"],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                for line in result.stdout.split('\n'):
                    if "Model name" in line:
                        return line.split(':', 1)[1].strip()
            uname_p = platform.uname().processor
            if uname_p:
                return uname_p
        except Exception:
            pass
        return "unknown"
    
    def _get_linux_distro(self) -> Optional[str]:
        """Detect Linux distribution."""
        distro_files = {
            "/etc/os-release": lambda x: self._parse_os_release(x),
            "/etc/lsb-release": lambda x: self._parse_lsb_release(x),
            "/etc/redhat-release": lambda x: self._read_file(x).strip(),
            "/etc/debian_version": lambda x: f"Debian {self._read_file(x).strip()}",
            "/etc/alpine-release": lambda x: f"Alpine {self._read_file(x).strip()}",
        }
        
        for filepath, parser in distro_files.items():
            if Path(filepath).exists():
                try:
                    return parser(filepath)
                except Exception:
                    continue
        return None
    
    def _parse_os_release(self, filepath: str) -> Optional[str]:
        """Parse /etc/os-release file."""
        try:
            content = self._read_file(filepath)
            for line in content.split('\n'):
                if line.startswith('PRETTY_NAME'):
                    return line.split('=')[1].strip(' "')
                elif line.startswith('NAME'):
                    name = line.split('=')[1].strip(' "')
                    version = None
                    content_lines = content.split('\n')
                    for vline in content_lines:
                        if vline.startswith('VERSION_ID'):
                            version = vline.split('=')[1].strip(' "')
                    return f"{name} {version}" if version else name
        except Exception:
            pass
        return None
    
    def _parse_lsb_release(self, filepath: str) -> Optional[str]:
        """Parse /etc/lsb-release file."""
        try:
            content = self._read_file(filepath)
            distro = None
            version = None
            for line in content.split('\n'):
                if 'DISTRIB_ID' in line:
                    distro = line.split('=')[1].strip()
                elif 'DISTRIB_RELEASE' in line:
                    version = line.split('=')[1].strip()
            return f"{distro} {version}" if distro and version else distro
        except Exception:
            pass
        return None
    
    def _read_file(self, filepath: str) -> str:
        """Read file content."""
        try:
            with open(filepath, 'r') as f:
                return f.read()
        except Exception:
            return ""
    
    def _get_hostname(self) -> str:
        """Get system hostname."""
        return socket.gethostname()
    
    def _get_ip_addresses(self) -> List[Dict[str, str]]:
        """Get all IP addresses."""
        interfaces = []
        
        if self.system == "Windows":
            interfaces = self._get_ip_addresses_windows()
        elif self.system == "Darwin":
            interfaces = self._get_ip_addresses_darwin()
        elif self.system == "FreeBSD":
            interfaces = self._get_ip_addresses_bsd()
        else:
            interfaces = self._get_ip_addresses_linux()
        
        return interfaces

    def _get_dns_servers(self) -> List[str]:
        """Get configured DNS servers."""
        dns_servers: List[str] = []

        if self.system == "Windows":
            try:
                result = subprocess.run(
                    [
                        "powershell",
                        "-Command",
                        "Get-DnsClientServerAddress -AddressFamily IPv4,IPv6 | Select-Object -ExpandProperty ServerAddresses"
                    ],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                for line in result.stdout.split('\n'):
                    address = line.strip()
                    if address:
                        dns_servers.append(address)
            except Exception:
                pass
        elif self.system == "Darwin":
            try:
                result = subprocess.run(
                    ["scutil", "--dns"],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                for line in result.stdout.split('\n'):
                    if "nameserver[" in line:
                        parts = line.split(':')
                        if len(parts) == 2:
                            addr = parts[1].strip()
                            if addr:
                                dns_servers.append(addr)
            except Exception:
                pass
        else:
            try:
                resolv = Path("/etc/resolv.conf")
                if resolv.exists():
                    for line in resolv.read_text().split('\n'):
                        if line.startswith("nameserver"):
                            parts = line.split()
                            if len(parts) >= 2:
                                dns_servers.append(parts[1])
            except Exception:
                pass

        return dns_servers

    def _get_network_config(self) -> List[Dict[str, Any]]:
        """Get network configuration including DHCP/static indication."""
        if self.system == "Windows":
            return self._get_network_config_windows()
        if self.system == "Darwin":
            return self._get_network_config_darwin()
        if self.system == "FreeBSD":
            return self._get_network_config_freebsd()
        return self._get_network_config_linux()

    def _get_network_config_windows(self) -> List[Dict[str, Any]]:
        configs: List[Dict[str, Any]] = []
        try:
            result = subprocess.run(
                ["netsh", "interface", "ip", "show", "config"],
                capture_output=True,
                text=True,
                timeout=15
            )
            current: Dict[str, Any] = {}
            for raw_line in result.stdout.split('\n'):
                line = raw_line.strip()
                if line.startswith("Configuration for interface"):
                    if current:
                        configs.append(current)
                    match = re.search(r'"(.+?)"', line)
                    current = {"interface": match.group(1) if match else line}
                elif line.startswith("DHCP enabled"):
                    current["dhcp"] = "Yes" in line
                elif line.startswith("IP Address"):
                    current.setdefault("ipv4", []).append(line.split(':')[-1].strip())
                elif line.startswith("Subnet Prefix"):
                    current.setdefault("subnet", []).append(line.split(':')[-1].strip())
                elif line.startswith("Default Gateway"):
                    gateway_value = line.split(':')[-1].strip()
                    if gateway_value:
                        current["gateway"] = gateway_value
            if current:
                configs.append(current)
        except Exception:
            pass

        return configs

    def _get_network_config_linux(self) -> List[Dict[str, Any]]:
        configs: Dict[str, Dict[str, Any]] = {}

        try:
            result = subprocess.run(
                ["ip", "addr"],
                capture_output=True,
                text=True,
                timeout=10
            )
            current_interface = None
            for line in result.stdout.split('\n'):
                if line and not line[0].isspace():
                    parts = line.split(':')
                    if len(parts) >= 2:
                        current_interface = parts[1].strip()
                        configs.setdefault(current_interface, {"interface": current_interface})
                elif 'inet ' in line:
                    ip_fields = line.strip().split()
                    ip = ip_fields[1].split('/')[0]
                    entry = configs.setdefault(current_interface, {"interface": current_interface})
                    entry["ipv4"] = ip
                    entry["dhcp"] = "dynamic" in ip_fields
                elif 'inet6' in line and '::1' not in line:
                    ip = line.strip().split()[1].split('/')[0]
                    entry = configs.setdefault(current_interface, {"interface": current_interface})
                    entry["ipv6"] = ip
        except Exception:
            pass

        try:
            result = subprocess.run(
                ["ip", "route", "show", "default"],
                capture_output=True,
                text=True,
                timeout=5
            )
            for line in result.stdout.split('\n'):
                if not line:
                    continue
                parts = line.split()
                gateway = None
                iface = None
                if "via" in parts:
                    gateway = parts[parts.index("via") + 1]
                if "dev" in parts:
                    iface = parts[parts.index("dev") + 1]
                if iface:
                    entry = configs.setdefault(iface, {"interface": iface})
                    if gateway:
                        entry["gateway"] = gateway
        except Exception:
            pass

        return list(configs.values())

    def _get_network_config_freebsd(self) -> List[Dict[str, Any]]:
        configs: Dict[str, Dict[str, Any]] = {}
        try:
            result = subprocess.run(
                ["ifconfig", "-a"],
                capture_output=True,
                text=True,
                timeout=10
            )
            current = None
            for line in result.stdout.split('\n'):
                if line and not line[0].isspace():
                    current = line.split(':')[0]
                    configs.setdefault(current, {"interface": current})
                elif 'inet ' in line:
                    parts = line.strip().split()
                    if len(parts) >= 2:
                        configs[current]["ipv4"] = parts[1]
                elif 'inet6 ' in line and '::1' not in line:
                    parts = line.strip().split()
                    if len(parts) >= 2:
                        configs[current]["ipv6"] = parts[1].split('%')[0]
        except Exception:
            pass

        try:
            route = subprocess.run(
                ["route", "-n", "get", "default"],
                capture_output=True,
                text=True,
                timeout=5
            )
            gw = None
            iface = None
            for line in route.stdout.split('\n'):
                if "gateway:" in line:
                    gw = line.split()[1]
                if "interface:" in line:
                    iface = line.split()[1]
            if iface:
                entry = configs.setdefault(iface, {"interface": iface})
                if gw:
                    entry["gateway"] = gw
        except Exception:
            pass

        return list(configs.values())

    def _get_network_config_darwin(self) -> List[Dict[str, Any]]:
        configs: List[Dict[str, Any]] = []
        try:
            ports = subprocess.run(
                ["networksetup", "-listallhardwareports"],
                capture_output=True,
                text=True,
                timeout=10
            )
            current: Dict[str, Any] = {}
            for line in ports.stdout.split('\n'):
                if line.startswith("Hardware Port"):
                    if current:
                        configs.append(current)
                    current = {"interface": line.split(':', 1)[1].strip()}
                elif line.startswith("Device"):
                    current["device"] = line.split(':', 1)[1].strip()
                elif line.startswith("Ethernet Address"):
                    current["mac"] = line.split(':', 1)[1].strip()
            if current:
                configs.append(current)
        except Exception:
            pass

        # Enrich with IP/gateway/DHCP per device
        enriched: List[Dict[str, Any]] = []
        for cfg in configs:
            device = cfg.get("device") or cfg.get("interface")
            detail = dict(cfg)
            if not device:
                enriched.append(detail)
                continue
            try:
                info = subprocess.run(
                    ["networksetup", "-getinfo", device],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                for line in info.stdout.split('\n'):
                    if line.startswith("IP address"):
                        detail["ipv4"] = line.split(':', 1)[1].strip()
                    elif line.startswith("IPv6 IP address"):
                        detail["ipv6"] = line.split(':', 1)[1].strip()
                    elif line.startswith("Router"):
                        detail["gateway"] = line.split(':', 1)[1].strip()
                    elif line.startswith("DHCP Configuration") or line.startswith("Manual Configuration"):
                        detail["dhcp"] = line.startswith("DHCP")
            except Exception:
                pass
            enriched.append(detail)

        return enriched
    
    def _get_ip_addresses_windows(self) -> List[Dict[str, str]]:
        """Get IP addresses on Windows."""
        interfaces = []
        try:
            result = subprocess.run(
                ["ipconfig"],
                capture_output=True,
                text=True,
                timeout=10
            )
            current_adapter = None
            for line in result.stdout.split('\n'):
                if 'Adapter' in line:
                    current_adapter = line.strip()
                elif 'IPv4 Address' in line:
                    ip = line.split(':')[1].strip()
                    interfaces.append({
                        "adapter": current_adapter,
                        "ipv4": ip
                    })
                elif 'IPv6 Address' in line:
                    ip = line.split(':')[1].strip()
                    if interfaces and current_adapter in interfaces[-1].get("adapter", ""):
                        interfaces[-1]["ipv6"] = ip
        except Exception:
            pass
        
        # Fallback to socket
        if not interfaces:
            try:
                hostname = socket.gethostname()
                ip = socket.gethostbyname(hostname)
                interfaces.append({"adapter": "default", "ipv4": ip})
            except Exception:
                pass
        
        return interfaces
    
    def _get_ip_addresses_linux(self) -> List[Dict[str, str]]:
        """Get IP addresses on Linux."""
        interfaces = []
        
        # Try ip addr (most common on modern Linux)
        try:
            result = subprocess.run(
                ["ip", "addr"],
                capture_output=True,
                text=True,
                timeout=10
            )
            current_interface = None
            for line in result.stdout.split('\n'):
                if line and not line[0].isspace():
                    # Interface line
                    parts = line.split(':')
                    if len(parts) >= 2:
                        current_interface = parts[1].strip()
                elif 'inet ' in line:
                    ip_fields = line.strip().split()
                    ip = ip_fields[1].split('/')[0]
                    interfaces.append({
                        "interface": current_interface,
                        "ipv4": ip,
                        "dhcp": "dynamic" in ip_fields
                    })
                elif 'inet6' in line and '::1' not in line:
                    ip = line.strip().split()[1].split('/')[0]
                    if interfaces and current_interface:
                        if interfaces[-1].get("interface") == current_interface:
                            interfaces[-1]["ipv6"] = ip
        except Exception:
            pass
        
        # Fallback to ifconfig
        if not interfaces:
            try:
                result = subprocess.run(
                    ["ifconfig"],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                current_interface = None
                for line in result.stdout.split('\n'):
                    if line and not line[0].isspace():
                        current_interface = line.split()[0]
                    elif 'inet ' in line:
                        parts = line.split()
                        ip = parts[1].replace('addr:', '')
                        interfaces.append({
                            "interface": current_interface,
                            "ipv4": ip
                        })
            except Exception:
                pass
        
        return interfaces

    def _get_ip_addresses_darwin(self) -> List[Dict[str, str]]:
        """Get IP addresses on macOS."""
        interfaces: List[Dict[str, str]] = []
        try:
            result = subprocess.run(
                ["ipconfig", "getifaddr", "en0"],
                capture_output=True,
                text=True,
                timeout=5
            )
            ip = result.stdout.strip()
            if ip:
                interfaces.append({"interface": "en0", "ipv4": ip})
        except Exception:
            pass

        # Fallback to ifconfig for all interfaces
        try:
            result = subprocess.run(
                ["ifconfig"],
                capture_output=True,
                text=True,
                timeout=10
            )
            current = None
            for line in result.stdout.split('\n'):
                if line and not line[0].isspace():
                    current = line.split(':')[0]
                elif 'inet ' in line:
                    parts = line.strip().split()
                    if len(parts) >= 2:
                        ip = parts[1]
                        interfaces.append({"interface": current, "ipv4": ip})
                elif 'inet6 ' in line and '::1' not in line:
                    parts = line.strip().split()
                    if len(parts) >= 2:
                        ip6 = parts[1].split('%')[0]
                        if interfaces and interfaces[-1].get("interface") == current:
                            interfaces[-1]["ipv6"] = ip6
                        else:
                            interfaces.append({"interface": current, "ipv6": ip6})
        except Exception:
            pass

        return interfaces

    def _get_ip_addresses_bsd(self) -> List[Dict[str, str]]:
        """Get IP addresses on FreeBSD/pfSense."""
        interfaces: List[Dict[str, str]] = []
        try:
            result = subprocess.run(
                ["ifconfig", "-a"],
                capture_output=True,
                text=True,
                timeout=10
            )
            current = None
            for line in result.stdout.split('\n'):
                if line and not line[0].isspace():
                    current = line.split(':')[0]
                elif 'inet ' in line:
                    parts = line.strip().split()
                    if len(parts) >= 2:
                        interfaces.append({"interface": current, "ipv4": parts[1]})
                elif 'inet6 ' in line and '::1' not in line:
                    parts = line.strip().split()
                    if len(parts) >= 2:
                        ip6 = parts[1].split('%')[0]
                        if interfaces and interfaces[-1].get("interface") == current:
                            interfaces[-1]["ipv6"] = ip6
                        else:
                            interfaces.append({"interface": current, "ipv6": ip6})
        except Exception:
            pass

        return interfaces
    
    def _get_users(self) -> List[Dict[str, str]]:
        """Get system users."""
        users = []
        
        if self.system == "Windows":
            users = self._get_users_windows()
        else:
            users = self._get_users_linux()
        
        return users
    
    def _get_users_windows(self) -> List[Dict[str, str]]:
        """Get users on Windows."""
        users = []
        admin_users = set()
        try:
            admin_result = subprocess.run(
                ["net", "localgroup", "administrators"],
                capture_output=True,
                text=True,
                timeout=10
            )
            for line in admin_result.stdout.split('\n'):
                line = line.strip()
                if line and not line.lower().startswith('members') and not line.startswith('---'):
                    admin_users.add(line)

            result = subprocess.run(
                ["net", "user"],
                capture_output=True,
                text=True,
                timeout=10
            )
            in_user_section = False
            for line in result.stdout.split('\n'):
                line = line.strip()
                if '---' in line:
                    in_user_section = True
                    continue
                if in_user_section and line and not line.startswith('The command'):
                    usernames = line.split()
                    for username in usernames:
                        if username and not username.startswith('---'):
                            users.append({
                                "username": username,
                                "is_admin": username in admin_users
                            })
        except Exception:
            pass
        
        return users
    
    def _get_users_linux(self) -> List[Dict[str, str]]:
        """Get users on Linux."""
        users = []
        try:
            import pwd
            import grp

            group_map = defaultdict(list)
            for g in grp.getgrall():
                for member in g.gr_mem:
                    group_map[member].append(g.gr_name)

            for entry in pwd.getpwall():
                users.append({
                    "username": entry.pw_name,
                    "uid": str(entry.pw_uid),
                    "shell": entry.pw_shell,
                    "groups": group_map.get(entry.pw_name, [])
                })
        except Exception:
            try:
                passwd_file = "/etc/passwd"
                if Path(passwd_file).exists():
                    with open(passwd_file, 'r') as f:
                        for line in f:
                            parts = line.strip().split(':')
                            if len(parts) >= 3:
                                username = parts[0]
                                uid = parts[2]
                                shell = parts[6] if len(parts) > 6 else ""
                                users.append({
                                    "username": username,
                                    "uid": uid,
                                    "shell": shell
                                })
            except Exception:
                pass
        
        # Also try getent as fallback
        if not users:
            try:
                result = subprocess.run(
                    ["getent", "passwd"],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                for line in result.stdout.split('\n'):
                    if line:
                        parts = line.split(':')
                        if len(parts) >= 3:
                            username = parts[0]
                            uid = parts[2]
                            users.append({"username": username, "uid": uid})
            except Exception:
                pass
        
        return users
    
    def _get_packages(self) -> Dict[str, List[str]]:
        """Get installed packages."""
        packages = {}
        
        if self.system == "Windows":
            packages = self._get_packages_windows()
        elif self.system == "Darwin":
            packages = self._get_packages_darwin()
        elif self.system == "FreeBSD":
            packages = self._get_packages_freebsd()
        else:
            packages = self._get_packages_linux()
        
        return packages
    
    def _get_packages_windows(self) -> Dict[str, List[str]]:
        """Get installed packages on Windows."""
        packages = {}
        try:
            result = subprocess.run(
                ["powershell", "-Command", "Get-WmiObject -Class Win32_Product | Select-Object Name"],
                capture_output=True,
                text=True,
                timeout=30
            )
            installed = []
            for line in result.stdout.split('\n'):
                line = line.strip()
                if line and line != "Name" and not line.startswith("--"):
                    installed.append(line)
            packages["installed"] = installed[:100]  # Limit to 100 for readability
        except Exception:
            pass
        
        return packages

    def _get_packages_darwin(self) -> Dict[str, List[str]]:
        packages: Dict[str, List[str]] = {}
        try:
            if shutil.which("brew"):
                result = subprocess.run(
                    ["brew", "list"],
                    capture_output=True,
                    text=True,
                    timeout=20
                )
                pkgs = [l.strip() for l in result.stdout.split('\n') if l.strip()]
                if pkgs:
                    packages["brew"] = pkgs
        except Exception:
            pass

        try:
            result = subprocess.run(
                ["pkgutil", "--pkgs"],
                capture_output=True,
                text=True,
                timeout=20
            )
            pkgs = [l.strip() for l in result.stdout.split('\n') if l.strip()]
            if pkgs:
                packages["pkgutil"] = pkgs
        except Exception:
            pass

        return packages

    def _get_packages_freebsd(self) -> Dict[str, List[str]]:
        packages: Dict[str, List[str]] = {}
        try:
            result = subprocess.run(
                ["pkg", "info"],
                capture_output=True,
                text=True,
                timeout=30
            )
            pkgs = [l.split()[0] for l in result.stdout.split('\n') if l]
            if pkgs:
                packages["pkg"] = pkgs
        except Exception:
            pass
        return packages
    
    def _get_packages_linux(self) -> Dict[str, List[str]]:
        """Get installed packages on Linux."""
        packages = {}
        
        # Try dpkg (Debian/Ubuntu)
        try:
            result = subprocess.run(
                ["dpkg", "-l"],
                capture_output=True,
                text=True,
                timeout=30
            )
            installed = []
            for line in result.stdout.split('\n'):
                if line.startswith('ii'):
                    parts = line.split()
                    if len(parts) >= 3:
                        pkg_name = parts[1]
                        installed.append(pkg_name)
            if installed:
                packages["apt"] = installed
                packages["apt_count"] = len(installed)
        except Exception:
            pass
        
        # Try rpm (RHEL/CentOS/Fedora)
        try:
            result = subprocess.run(
                ["rpm", "-qa"],
                capture_output=True,
                text=True,
                timeout=30
            )
            installed = [line for line in result.stdout.strip().split('\n') if line]
            if installed:
                packages["rpm"] = installed
                packages["rpm_count"] = len(installed)
        except Exception:
            pass

        # Try dnf
        try:
            result = subprocess.run(
                ["dnf", "list", "installed"],
                capture_output=True,
                text=True,
                timeout=30
            )
            names = []
            for line in result.stdout.split('\n'):
                if line.startswith("Installed") or line.startswith("Available"):
                    continue
                parts = line.split()
                if len(parts) >= 1 and '.' in parts[0]:
                    names.append(parts[0].split('.')[0])
            if names:
                packages["dnf"] = names[:200]
                packages["dnf_count"] = len(names)
        except Exception:
            pass

        # Try yum
        try:
            result = subprocess.run(
                ["yum", "list", "installed"],
                capture_output=True,
                text=True,
                timeout=30
            )
            names = []
            started = False
            for line in result.stdout.split('\n'):
                if line.startswith("Installed Packages"):
                    started = True
                    continue
                if not started:
                    continue
                parts = line.split()
                if len(parts) >= 1 and '.' in parts[0]:
                    names.append(parts[0].split('.')[0])
            if names:
                packages["yum"] = names[:200]
                packages["yum_count"] = len(names)
        except Exception:
            pass
        
        # Try apk (Alpine)
        try:
            result = subprocess.run(
                ["apk", "list", "--installed"],
                capture_output=True,
                text=True,
                timeout=30
            )
            installed = [line for line in result.stdout.strip().split('\n') if line]
            if installed:
                packages["apk"] = installed
                packages["apk_count"] = len(installed)
        except Exception:
            pass
        
        # Try pacman (Arch)
        try:
            result = subprocess.run(
                ["pacman", "-Q"],
                capture_output=True,
                text=True,
                timeout=30
            )
            installed = [line for line in result.stdout.strip().split('\n') if line]
            if installed:
                packages["pacman"] = installed
                packages["pacman_count"] = len(installed)
        except Exception:
            pass
        
        return packages
    
    def _get_services(self) -> Dict[str, Any]:
        """Get running and stopped services."""
        services = {
            "running": [],
            "stopped": []
        }
        
        if self.system == "Windows":
            services = self._get_services_windows()
        elif self.system == "Darwin":
            services = self._get_services_darwin()
        elif self.system == "FreeBSD":
            services = self._get_services_freebsd()
        else:
            services = self._get_services_linux()
        
        return services
    
    def _get_services_windows(self) -> Dict[str, List[Dict[str, str]]]:
        """Get services on Windows."""
        services = {
            "running": [],
            "stopped": []
        }
        try:
            result = subprocess.run(
                ["powershell", "-Command", "Get-Service | Select-Object Name,Status"],
                capture_output=True,
                text=True,
                timeout=30
            )
            for line in result.stdout.split('\n'):
                line = line.strip()
                if "Running" in line or "Stopped" in line:
                    parts = line.rsplit(None, 1)
                    if len(parts) == 2:
                        name, status = parts
                        service = {"name": name.strip()}
                        if "Running" in status:
                            services["running"].append(service)
                        elif "Stopped" in status:
                            services["stopped"].append(service)
        except Exception:
            pass
        
        return services
    
    def _get_services_linux(self) -> Dict[str, List[Dict[str, str]]]:
        """Get services on Linux."""
        services = {
            "running": [],
            "stopped": []
        }
        
        # Try systemctl
        try:
            result = subprocess.run(
                ["systemctl", "list-units", "--type=service", "--all"],
                capture_output=True,
                text=True,
                timeout=30
            )
            for line in result.stdout.split('\n'):
                if '.service' in line:
                    parts = line.split()
                    if len(parts) >= 3:
                        name = parts[0].replace('.service', '')
                        status = parts[2]
                        service = {"name": name}
                        if status == "running":
                            services["running"].append(service)
                        elif status == "stopped" or status == "inactive":
                            services["stopped"].append(service)
        except Exception:
            pass
        
        # Try sysvinit service --status-all
        if not services["running"] and not services["stopped"]:
            try:
                result = subprocess.run(
                    ["service", "--status-all"],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                for line in result.stdout.split('\n'):
                    line = line.strip()
                    if not line:
                        continue
                    parts = line.split()
                    name = parts[-1]
                    if line.startswith('[ + ]') or line.startswith('+'):
                        services["running"].append({"name": name})
                    elif line.startswith('[ - ]') or line.startswith('-'):
                        services["stopped"].append({"name": name})
            except Exception:
                pass

        # Try OpenRC rc-status
        if not services["running"]:
            try:
                result = subprocess.run(
                    ["rc-status", "-s"],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                for line in result.stdout.split('\n'):
                    if not line.strip():
                        continue
                    parts = line.split()
                    name = parts[0]
                    state = parts[1] if len(parts) > 1 else "unknown"
                    entry = {"name": name}
                    if state in ("started", "running"):
                        services["running"].append(entry)
                    else:
                        services["stopped"].append(entry)
            except Exception:
                pass

        # Fallback to ps
        if not services["running"]:
            try:
                result = subprocess.run(
                    ["ps", "aux"],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                processes = []
                for line in result.stdout.split('\n')[1:]:
                    parts = line.split()
                    if len(parts) >= 11:
                        processes.append({"name": parts[10].split('/')[-1]})
                services["running"] = processes[:50]  # Limit to 50
            except Exception:
                pass
        
        return services

    def _get_services_freebsd(self) -> Dict[str, List[Dict[str, str]]]:
        services = {"running": [], "stopped": []}
        try:
            enabled = subprocess.run(
                ["service", "-e"],
                capture_output=True,
                text=True,
                timeout=10
            )
            for line in enabled.stdout.split('\n'):
                name = Path(line.strip()).name if line.strip() else None
                if name:
                    services["running"].append({"name": name})
        except Exception:
            pass

        try:
            listed = subprocess.run(
                ["service", "-l"],
                capture_output=True,
                text=True,
                timeout=10
            )
            all_svcs = [Path(l.strip()).name for l in listed.stdout.split('\n') if l.strip()]
            for svc in all_svcs:
                if not any(s.get("name") == svc for s in services["running"]):
                    services["stopped"].append({"name": svc})
        except Exception:
            pass

        return services

    def _get_services_darwin(self) -> Dict[str, List[Dict[str, str]]]:
        services = {"running": [], "stopped": []}
        try:
            result = subprocess.run(
                ["launchctl", "list"],
                capture_output=True,
                text=True,
                timeout=15
            )
            for line in result.stdout.split('\n')[1:]:
                if not line.strip():
                    continue
                parts = line.split()
                if len(parts) >= 3:
                    status = parts[0]
                    name = parts[2]
                    entry = {"name": name}
                    if status == "-":
                        services["stopped"].append(entry)
                    else:
                        services["running"].append(entry)
        except Exception:
            pass
        return services

    def _get_processes(self) -> List[Dict[str, Any]]:
        """Get running processes (lightweight snapshot)."""
        processes: List[Dict[str, Any]] = []

        try:
            import psutil

            for proc in psutil.process_iter(attrs=["pid", "name", "username", "cpu_percent", "memory_percent"]):
                info = proc.info
                processes.append({
                    "pid": info.get("pid"),
                    "name": info.get("name"),
                    "user": info.get("username"),
                    "cpu_percent": info.get("cpu_percent"),
                    "mem_percent": round(info.get("memory_percent", 0.0), 2) if info.get("memory_percent") is not None else None
                })

            processes = sorted(
                processes,
                key=lambda p: (p.get("cpu_percent") or 0),
                reverse=True
            )[:50]
        except Exception:
            try:
                if self.system == "Windows":
                    result = subprocess.run(
                        ["tasklist"],
                        capture_output=True,
                        text=True,
                        timeout=10
                    )
                    for line in result.stdout.split('\n')[3:]:
                        parts = line.split()
                        if len(parts) >= 2:
                            processes.append({
                                "name": parts[0],
                                "pid": parts[1]
                            })
                else:
                    result = subprocess.run(
                        ["ps", "-eo", "pid,comm,user,%cpu,%mem", "--sort=-%cpu"],
                        capture_output=True,
                        text=True,
                        timeout=10
                    )
                    for line in result.stdout.split('\n')[1:51]:
                        parts = line.split()
                        if len(parts) >= 5:
                            processes.append({
                                "pid": parts[0],
                                "name": parts[1],
                                "user": parts[2],
                                "cpu_percent": parts[3],
                                "mem_percent": parts[4]
                            })
            except Exception:
                pass

        return processes

    def _get_firewall_status(self) -> Dict[str, Any]:
        """Get firewall status per OS."""
        if self.system == "Windows":
            return self._get_firewall_status_windows()
        if self.system == "Darwin":
            return self._get_firewall_status_darwin()
        if self.system == "FreeBSD":
            return self._get_firewall_status_freebsd()
        return self._get_firewall_status_linux()

    def dump_firewall_rules(self, filepath: str = "firewall_rules.txt") -> None:
        """Dump collected firewall rules/details to a separate text file."""
        fw = self.info.get("firewall", {})
        lines: List[str] = []

        def emit_block(block: Dict[str, Any]) -> None:
            if not block:
                return
            if block.get('tool'):
                lines.append(f"Tool: {block.get('tool', 'unknown')}")
            if block.get('status'):
                lines.append(f"Status: {block.get('status', 'unknown')}")
            
            # Handle Windows profiles
            if block.get("profiles"):
                lines.append("Profiles:")
                for profile in block["profiles"]:
                    profile_name = profile.get("profile", "unknown")
                    profile_state = profile.get("state", "unknown")
                    lines.append(f"  {profile_name}: {profile_state}")
            
            if block.get("rules_full"):
                lines.append("Rules (full):")
                lines.extend(block["rules_full"])
            elif block.get("rules_save_sample"):
                lines.append("Rules (save sample):")
                lines.extend(block["rules_save_sample"])
            elif block.get("rules_sample"):
                lines.append("Rules (sample):")
                lines.extend(block["rules_sample"])
            if block.get("notes"):
                lines.append("Notes:")
                lines.extend([f"- {n}" for n in block["notes"]])
            lines.append("")

        emit_block(fw)
        for extra in fw.get("additional", []):
            lines.append("----")
            emit_block(extra)

        try:
            Path(filepath).write_text("\n".join(lines))
        except Exception:
            pass

    def _get_firewall_status_windows(self) -> Dict[str, Any]:
        status: Dict[str, Any] = {"tool": "Windows Defender Firewall", "profiles": []}
        try:
            result = subprocess.run(
                ["netsh", "advfirewall", "show", "allprofiles"],
                capture_output=True,
                text=True,
                timeout=10
            )
            current_profile = None
            for line in result.stdout.split('\n'):
                line_stripped = line.strip()
                # Look for lines like "Domain Profile Settings:" or "Private Profile Settings:"
                if "Profile Settings:" in line_stripped:
                    profile_name = line_stripped.replace("Profile Settings:", "").strip()
                    current_profile = {"profile": profile_name}
                    status["profiles"].append(current_profile)
                elif line_stripped.startswith("State") and current_profile is not None:
                    # Extract the state value (usually "ON" or "OFF")
                    parts = line_stripped.split()
                    if len(parts) >= 2:
                        current_profile["state"] = parts[-1]
        except Exception:
            pass

        # Get firewall rules using PowerShell (better output handling than netsh alone)
        try:
            ps_cmd = """netsh advfirewall firewall show rule name=all verbose"""
            result = subprocess.run(
                ["powershell", "-NoProfile", "-Command", ps_cmd],
                capture_output=True,
                text=True,
                timeout=60
            )
            lines = [l for l in result.stdout.split('\n') if l.strip()]
            if lines and len(lines) > 10:  # Ensure we got actual rule data
                status["rules_full"] = lines
                status["status"] = f"rules_present ({len(lines)} lines)"
            elif lines:
                status["rules_full"] = lines
                status["status"] = "partial_rules"
            else:
                status["status"] = "no_rules_found"
        except Exception as e:
            status["status"] = f"error_fetching_rules: {str(e)}"

        return status

    def _get_firewall_status_linux(self) -> Dict[str, Any]:
        status: Dict[str, Any] = {}

        def _merge_fw(current: Dict[str, Any], info: Dict[str, Any]) -> Dict[str, Any]:
            if not current:
                return info
            current.setdefault("additional", []).append(info)
            return current

        if shutil.which("ufw"):
            try:
                result = subprocess.run(
                    ["ufw", "status"],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                # Use both stdout and stderr; ufw may emit to stderr when not root
                combined = f"{result.stdout}\n{result.stderr}"
                lines = [l for l in combined.split('\n') if l]
                status["tool"] = "ufw"
                if lines:
                    first = lines[0].strip()
                    if first.lower().startswith("status:"):
                        status["status"] = first.split(":", 1)[1].strip()
                    else:
                        status["status"] = first
                    # If we have access, fetch numbered rules for file dump (but don't store in JSON)
                    if result.returncode in (0, 1):
                        try:
                            detailed = subprocess.run(
                                ["ufw", "status", "numbered"],
                                capture_output=True,
                                text=True,
                                timeout=10
                            )
                            d_lines = [l for l in detailed.stdout.split('\n') if l]
                            if d_lines:
                                status["rules_full"] = d_lines
                        except Exception:
                            pass
                else:
                    status["status"] = "unknown"
                if result.returncode not in (0, 1):  # ufw often returns 0 or 1 for inactive
                    status["error"] = result.stderr.strip()
                    status.setdefault("notes", []).append("ufw command failed; try running as root")
                elif "root" in (result.stderr or "").lower():
                    status.setdefault("notes", []).append("ufw reported root privileges required")
            except Exception:
                pass

        if shutil.which("firewall-cmd"):
            try:
                result = subprocess.run(
                    ["firewall-cmd", "--state"],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                info = {
                    "tool": "firewalld",
                    "status": result.stdout.strip() or "unknown"
                }
                try:
                    detail = subprocess.run(
                        ["firewall-cmd", "--list-all"],
                        capture_output=True,
                        text=True,
                        timeout=8
                    )
                    lines = [l for l in detail.stdout.split('\n') if l]
                    if lines:
                        info["rules_full"] = lines
                except Exception:
                    pass
                status = _merge_fw(status, info)
            except Exception:
                pass

        if shutil.which("iptables"):
            try:
                info = {"tool": "iptables"}
                result = subprocess.run(
                    ["iptables", "-L"],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                lines = [l for l in result.stdout.split('\n') if l]
                info["status"] = "rules_present" if len(lines) > 2 else "empty"
                # Try iptables-save for dump (but don't store in JSON)
                try:
                    saved = subprocess.run(
                        ["iptables-save"],
                        capture_output=True,
                        text=True,
                        timeout=10
                    )
                    s_lines = [l for l in saved.stdout.split('\n') if l]
                    if s_lines:
                        info["rules_full"] = s_lines
                except Exception:
                    pass
                status = _merge_fw(status, info)
            except Exception:
                pass

        if shutil.which("nft"):
            try:
                info = {"tool": "nftables"}
                result = subprocess.run(
                    ["nft", "list", "ruleset"],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                lines = [l for l in result.stdout.split('\n') if l]
                info["status"] = "rules_present" if lines else "empty"
                info["rules_full"] = lines
                status = _merge_fw(status, info)
            except Exception:
                pass

        if not status:
            status["status"] = "unknown"
        return status

    def _get_firewall_status_freebsd(self) -> Dict[str, Any]:
        status: Dict[str, Any] = {}
        try:
            result = subprocess.run(
                ["pfctl", "-s", "info"],
                capture_output=True,
                text=True,
                timeout=5
            )
            status["tool"] = "pfctl"
            status["status"] = "active" if "Status: Enabled" in result.stdout else "disabled"
        except Exception:
            pass

        if not status:
            status["status"] = "unknown"
        return status

    def _get_firewall_status_darwin(self) -> Dict[str, Any]:
        status: Dict[str, Any] = {}
        try:
            result = subprocess.run(
                ["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate"],
                capture_output=True,
                text=True,
                timeout=5
            )
            state_line = result.stdout.strip()
            status["tool"] = "socketfilterfw"
            status["status"] = state_line
        except Exception:
            pass

        if not status:
            try:
                result = subprocess.run(
                    ["pfctl", "-s", "info"],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                status["tool"] = "pfctl"
                status["status"] = "active" if "Status: Enabled" in result.stdout else "disabled"
            except Exception:
                pass

        if not status:
            status["status"] = "unknown"
        return status
    
    def _get_system_resources(self) -> Dict[str, Any]:
        """Get system resources (CPU, memory, disk)."""
        resources = {}
        
        try:
            import psutil
            resources = {
                "cpu_count": psutil.cpu_count(logical=False),
                "cpu_count_logical": psutil.cpu_count(logical=True),
                "cpu_percent": psutil.cpu_percent(interval=1),
                "memory": {
                    "total_gb": round(psutil.virtual_memory().total / (1024**3), 2),
                    "available_gb": round(psutil.virtual_memory().available / (1024**3), 2),
                    "percent": psutil.virtual_memory().percent
                }
            }
            
            # Disk usage
            disk_usage = {}
            for partition in psutil.disk_partitions():
                try:
                    usage = psutil.disk_usage(partition.mountpoint)
                    disk_usage[partition.mountpoint] = {
                        "total_gb": round(usage.total / (1024**3), 2),
                        "used_gb": round(usage.used / (1024**3), 2),
                        "percent": usage.percent
                    }
                except Exception:
                    pass
            resources["disk"] = disk_usage
        except ImportError:
            # psutil not available, try alternative methods
            if self.system == "Linux":
                try:
                    # CPU count from /proc/cpuinfo
                    with open('/proc/cpuinfo', 'r') as f:
                        cpu_count = len([l for l in f if l.startswith('processor')])
                    resources['cpu_count'] = cpu_count if cpu_count > 0 else "N/A"
                    
                    # Memory from /proc/meminfo
                    with open('/proc/meminfo', 'r') as f:
                        for line in f:
                            if line.startswith('MemTotal:'):
                                total_kb = int(line.split()[1])
                                resources['memory_total_gb'] = round(total_kb / (1024**2), 2)
                            elif line.startswith('MemAvailable:'):
                                avail_kb = int(line.split()[1])
                                resources['memory_available_gb'] = round(avail_kb / (1024**2), 2)
                except Exception:
                    pass
        except Exception:
            pass
        
        return resources
    
    def to_json(self, indent: int = 2) -> str:
        """Convert collected info to JSON string, excluding firewall rules."""
        # Deep copy to avoid modifying original
        import copy
        json_info = copy.deepcopy(self.info)
        
        # Strip all rule data from firewall section
        if "firewall" in json_info:
            self._strip_firewall_rules(json_info["firewall"])
        
        return json.dumps(json_info, indent=indent, default=str)
    
    def _strip_firewall_rules(self, fw_block: Dict[str, Any]) -> None:
        """Recursively strip rules_full, rules_sample, rules_save_sample from firewall data."""
        for key in ["rules_full", "rules_sample", "rules_save_sample"]:
            fw_block.pop(key, None)
        for extra in fw_block.get("additional", []):
            self._strip_firewall_rules(extra)
    
    def print_summary(self) -> None:
        """Print a human-readable summary."""
        print("\n" + "="*60)
        print("SYSTEM INFORMATION SUMMARY")
        print("="*60)
        
        if "os" in self.info:
            print("\n[OS INFO]")
            for key, value in self.info["os"].items():
                print(f"  {key}: {value}")
        
        if "hostname" in self.info:
            print(f"\n[HOSTNAME]")
            print(f"  {self.info['hostname']}")
        
        if "ip_addresses" in self.info:
            print(f"\n[IP ADDRESSES]")
            for iface in self.info["ip_addresses"]:
                for key, value in iface.items():
                    print(f"  {key}: {value}")

        if "dns_servers" in self.info:
            print(f"\n[DNS SERVERS]")
            for dns in self.info["dns_servers"]:
                print(f"  {dns}")

        if "network_config" in self.info:
            print(f"\n[NETWORK CONFIG]")
            for cfg in self.info["network_config"]:
                iface_name = cfg.get("interface", "unknown")
                print(f"  Interface: {iface_name}")
                if cfg.get("ipv4"):
                    print(f"    IPv4: {cfg['ipv4']}")
                if cfg.get("ipv6"):
                    print(f"    IPv6: {cfg['ipv6']}")
                if cfg.get("gateway"):
                    print(f"    Gateway: {cfg['gateway']}")
                if "dhcp" in cfg:
                    print(f"    DHCP: {cfg['dhcp']}")
        
        if "users" in self.info:
            print(f"\n[USERS] ({len(self.info['users'])} total)")
            for user in self.info["users"][:10]:
                print(f"  {user.get('username', 'N/A')}")
            if len(self.info["users"]) > 10:
                print(f"  ... and {len(self.info['users']) - 10} more")
        
        if "packages" in self.info:
            print(f"\n[PACKAGES]")
            for pkg_mgr, pkgs in self.info["packages"].items():
                if isinstance(pkgs, int):
                    print(f"  {pkg_mgr}: {pkgs}")
                elif isinstance(pkgs, list):
                    print(f"  {pkg_mgr}: {len(pkgs)} packages")
                else:
                    print(f"  {pkg_mgr}: {pkgs}")
        
        if "services" in self.info:
            print(f"\n[SERVICES]")
            print(f"  Running: {len(self.info['services'].get('running', []))}")
            print(f"  Stopped: {len(self.info['services'].get('stopped', []))}")

        if "processes" in self.info:
            print(f"\n[PROCESSES]")
            for proc in self.info["processes"][:10]:
                print(f"  {proc.get('name', 'unknown')} (pid: {proc.get('pid', 'n/a')})")
            if len(self.info["processes"]) > 10:
                print(f"  ... and {len(self.info['processes']) - 10} more")

        if "firewall" in self.info:
            print(f"\n[FIREWALL]")
            fw = self.info["firewall"]
            if "profiles" in fw:
                for profile in fw["profiles"]:
                    print(f"  {profile.get('profile', 'profile')}: {profile.get('state', 'unknown')}")
            else:
                def _print_fw_block(block: Dict[str, Any], indent: str = "  "):
                    status = block.get("status", "unknown")
                    tool = block.get("tool")
                    if tool:
                        print(f"{indent}Tool: {tool}")
                    print(f"{indent}Status: {status}")
                    if block.get("rules_sample"):
                        print(f"{indent}Rules sample:")
                        for line in block["rules_sample"][:10]:
                            print(f"{indent}  {line}")
                    if block.get("rules_save_sample"):
                        print(f"{indent}Rules save sample:")
                        for line in block["rules_save_sample"][:10]:
                            print(f"{indent}  {line}")
                    if block.get("notes"):
                        print(f"{indent}Notes:")
                        for note in block["notes"]:
                            print(f"{indent}  {note}")

                _print_fw_block(fw)
                for extra in fw.get("additional", []):
                    print("  ---")
                    _print_fw_block(extra)
        
        if "system_resources" in self.info:
            print(f"\n[SYSTEM RESOURCES]")
            for key, value in self.info["system_resources"].items():
                if isinstance(value, dict):
                    print(f"  {key}:")
                    for k, v in value.items():
                        print(f"    {k}: {v}")
                else:
                    print(f"  {key}: {value}")
        
        print("\n" + "="*60 + "\n")


def main():
    """Main function."""
    collector = SystemInfoCollector()
    collector.collect_all()
    
    # Print summary
    collector.print_summary()
    
    # Dump firewall rules (if available) to a separate file
    collector.dump_firewall_rules()
    
    # Save to JSON file
    output_file = "system_info.json"
    with open(output_file, 'w') as f:
        f.write(collector.to_json())
    print(f"Full details saved to: {output_file}")


if __name__ == "__main__":
    main()
