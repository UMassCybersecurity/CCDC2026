#!/usr/bin/env python3

import subprocess
import shutil
import sys
import json

import ccdc_script


class PackageSigCheck(ccdc_script.CCDCScript):

    def create_format(self) -> dict:
        return {"package_sig": {}}

    def apt_check_integrity(self, format: dict):
        program = ["debsums", "-s"]
        if not shutil.which(program[0]) and not self.install(program[0]):
            return

        debsums_proc = subprocess.run(program, capture_output=True)
        self.print_err(
            "starting package integrity check with apt, this will take some time")
        for lines in debsums_proc.stderr.splitlines():

            # could use regex here, but the output is predictable
            # enough where we can split on whitespace
            tokens = lines.split()
            path = tokens[3].decode()
            package = tokens[5].decode()

            # padding the rightmost entry with periods for parity with rpms verify output
            format["package_sig"][package] = {"path": path, "changed": '.' * 9}

    def dnf_check_integrity(self, format: dict) -> bool:
        # RHEL system; query files that were installed from rpm packages
        program = ["rpm", "-Va"]
        self.print_err(
            "starting package integrity check with dnf, this will take some time")
        rpm_proc = subprocess.run(program, capture_output=True)

        # process each row in the output
        for line in rpm_proc.stdout.splitlines():

            # dirty solution, could use regex capture groups instead
            line = line.split()
            changed = line[0].decode()
            path = line[2].decode() if len(line) == 3 else line[1].decode()
            # output of 'rpm -Va' doesn't specify the origin packages
            # need to query
            package_proc = subprocess.run(
                ["rpm", "-qf", path, "--qf", '%{NAME}'], capture_output=True)
            package = package_proc.stdout.decode().strip()
            format["package_sig"][package] = {"path": path, "changed": changed}

        return True

    def produce_json(self) -> dict:
        format = self.create_format()
        if self.distro == ccdc_script.Distro.CCDC_RHEL:
            self.dnf_check_integrity(format)
        elif self.distro == ccdc_script.Distro.CCDC_DEBIAN:
            self.apt_check_integrity(format)
        return format

if __name__ == "__main__":
    program = PackageSigCheck()
    json.dump(program.produce_json(), sys.stdout, indent=2)
