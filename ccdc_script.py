#!/usr/bin/env python3


from abc import ABC, abstractmethod
from enum import Enum
import sys
import os
import shutil
import subprocess
import syslog


class Distro(Enum):
    CCDC_DEBIAN = 0
    CCDC_RHEL = 1
    CCDC_ALPINE = 2
    CCDC_NONE = 3


INSTALL_COMMANDS = {
    Distro.CCDC_DEBIAN: (["apt-get", "install", "-y"], {"DEBIAN_FRONTEND": "noninteractive"}),
    Distro.CCDC_RHEL:   (["dnf", "install", "-y"], {}),
    Distro.CCDC_ALPINE: (["apk", "add"], {}),
}


def get_distro():
    if shutil.which("apt"):
        return Distro.CCDC_DEBIAN
    elif shutil.which("dnf"):
        return Distro.CCDC_RHEL
    elif shutil.which("apk"):
        return Distro.CCDC_ALPINE
    return Distro.CCDC_NONE


class CCDCScript(ABC):
    def __init__(self, err_fd=None) -> None:
        self.distro = get_distro()
        self.error_fd = sys.stderr if err_fd is None else err_fd
        self.has_syslog: bool = shutil.which("logger") is not None

    @abstractmethod
    def produce_json(self) -> dict:
        pass

    def log(self, priority: int,  message: str):
        if self.has_syslog:
            syslog.syslog(priority, message)
        else:
            self.print_err(f"[{priority}]: {message}")

    def install(self, *packages):
        if self.distro == Distro.CCDC_NONE or not packages:
            return False

        cmd, vars = INSTALL_COMMANDS.get(self.distro, (None, None))
        if not cmd:
            return False

        env = os.environ.copy()
        env.update(vars)

        result = subprocess.run(cmd + list(packages),
                                env=env, capture_output=True)
        return result.returncode == 0

    def print_err(self, *args, **awks):
        print(*args, **awks, file=self.error_fd)

    def print_err_label(self, label: str) -> None:
        seperator = '=' * 60
        self.print_err(f'{seperator}\n{label.center(60, "*")}\n{seperator}')

    def is_priv(self):
        return os.geteuid() == 0

    def enable_service(self, service: str) -> bool:
        if self.distro == Distro.CCDC_RHEL or self.distro == Distro.CCDC_DEBIAN:
            enabling = subprocess.run(
                ["systemctl", "enable", "--no-pager", "--now", service], capture_output=True)
            return enabling.returncode == 0
        elif self.distro == Distro.CCDC_ALPINE:
            enabling = subprocess.run(
                ["rc-update", "add", service], capture_output=True)
            return enabling.returncode == 0
        return False

    def restart_service(self, service: str) -> bool:
        if self.distro == Distro.CCDC_RHEL or self.distro == Distro.CCDC_DEBIAN:
            restart = subprocess.run(
                ["systemctl", "restart", "--no-pager",  service], capture_output=True)
            return restart.returncode == 0
        elif self.distro == Distro.CCDC_ALPINE:
            restart = subprocess.run(
                ["rc-service", "restart", service], capture_output=True)
            return restart.returncode == 0
        return False

    def check_service(self, service: str) -> bool:
        if self.distro == Distro.CCDC_RHEL or self.distro == Distro.CCDC_DEBIAN:
            return subprocess.run(['systemctl', 'is-active', '--quiet', service]).returncode == 0
        # TODO add alpine
        return False
