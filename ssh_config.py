#!/usr/bin/env python3

import ccdc_script
import os
import shutil
import fileinput
import re
import subprocess

MAIN_CONFIG = "/etc/ssh/sshd_config"
TARGET = "9999-ccdc-override.conf"
DROP_IN_CONFIGS = "/etc/ssh/sshd_config.d/"


class SSHConfiguration(ccdc_script.CCDCScript):
    def __init__(self, err_fd=None) -> None:
        super().__init__(err_fd)

        # install openssh if not present
        if self.distro == ccdc_script.Distro.CCDC_ALPINE:
            self.install("openssh")
        else:
            self.install("openssh-server")

    def _enumerate_configs(self, config_paths: list[str]) -> None:
        for path in config_paths:
            try:
                self.print_err_label(path)
                with open(path, 'r') as f:
                    for line in f.readlines():
                        if line.isspace() or line.lstrip().startswith('#'):
                            continue
                        self.print_err(line.strip())
                os.chmod(path, 0o0644)
                os.chown(path, 0, 0)
            except Exception as e:
                self.print_err("ERROR:", e)

        # put drop-in if it exists
        if os.path.isdir(DROP_IN_CONFIGS):
            os.chmod(DROP_IN_CONFIGS, 0o0644)
            drop_in = shutil.copy(TARGET, DROP_IN_CONFIGS)
            os.chmod(drop_in, 0o0644)
            os.chown(drop_in, 0, 0)
        else:
            #TODO test this branch, most have installations support drop_in
            #meaning I have never seen the drop in not qualify 
            # need to read the config in the main directory
            config: dict[str, str] = {}
            with open(TARGET, "r") as f:
                for line in f.readlines():
                    if line.isspace():
                        continue
                    l = line.split(" ", maxsplit=1)
                    config[l[0]] = l[1]

            # write the file using FileInput in place
            with fileinput.FileInput(MAIN_CONFIG, inplace=True) as f:
                pattern = re.compile(r"^\s*([A-Za-z]+)\b")
                for line in f:
                    m = pattern.match(line)
                    if m and m.group(1) in config:
                        print(config[m.group(1)])

    def _get_configs(self) -> list[str]:
        if not os.path.isfile(MAIN_CONFIG):
            self.print_err(f"Exiting SSH Script: {MAIN_CONFIG} does not exist")
            return []

        result = [MAIN_CONFIG]
        for root, _, files in os.walk(DROP_IN_CONFIGS):
            result.extend(os.path.join(root, file) for file in files)
        return result

    def produce_json(self) -> dict:

        format = {}
        configs = self._get_configs()
        if not configs:
            return format
        self._enumerate_configs(configs)
        if self.distro == ccdc_script.Distro.CCDC_RHEL:
            # NOTE: hardcoded 4444, TODO: get the Port key from the override file and add it
            self.print_err(
                "RHEL System: setting port label for SELINUX policy")
            semanage_proc = subprocess.run(
                ['semanage', 'port', '-a',  '-t', 'ssh_port_t', '-p', 'tcp', '4444'], capture_output=True)
            if semanage_proc.returncode != 0:
                self.print_err(
                    f"Failed to set port label: {semanage_proc.stderr.decode().rstrip()}")

        self.restart_service("sshd.service")
        self.enable_service("sshd.service")
        return format


if __name__ == "__main__":
    SSHConfiguration().produce_json()
