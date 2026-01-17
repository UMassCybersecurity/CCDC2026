#!/usr/bin/env python3

import ccdc_script
import sys
import syslog
import os
import hashlib
import json
import argparse

CHANGED = "changed"
NEW = "new"


class CCDCCronScript(ccdc_script.CCDCScript):
    def __init__(self, err_fd=None, compare: str = "") -> None:
        super().__init__(err_fd)
        self.crontabs: dict[str, dict] = {}
        self.compare = compare

    def get_cron_hash(self, path: str) -> None:
        if not os.path.isfile(path):
            return

        sha256hash = hashlib.sha256()
        try:
            with open(path, "rb") as f:
                self.print_err_label(path)
                for line in f.readlines():
                    sha256hash.update(line)
                    if not line.isspace() and not line.lstrip().startswith(b"#"):
                        self.print_err(line.decode().rstrip())
        except Exception as e:
            self.print_err(e)
            return

        hash_hex = sha256hash.hexdigest()
        if path not in self.crontabs:
            self.log(syslog.LOG_WARNING, f"New Crontab started: {path}")
            self.crontabs[path] = {"status": NEW, "hash": hash_hex}
        elif self.crontabs[path]["hash"] != hash_hex:
            self.log(syslog.LOG_WARNING,
                     f"Crontab sha256sum mismatch: {path}")
            self.crontabs[path] = {"status": CHANGED, "hash": hash_hex}

    def loop_cron(self) -> None:
        if not self.is_priv():
            return

        self.get_cron_hash("/etc/crontab")
        paths = ["/var/spool/cron", "/etc/cron.d", "/etc/cron.hourly",
                 "/etc/cron.daily", "/etc/cron.weekly", "/etc/cron.monthly"]
        for path in paths:
            for root, _, files in os.walk(path):
                for file in files:
                    self.get_cron_hash(os.path.join(root, file))

    def compare_cron(self) -> dict:
        format = {
            "new": [],
            "changed": []
        }
        if not self.compare:
            return {}
        with open(self.compare, "r") as f:
            previous = json.load(f)
            if "crontabs" not in previous:
                return {}

            previous = previous["crontabs"]
            for path in self.crontabs:
                if path not in previous:
                    format["new"].append(path)
                elif self.crontabs[path]["hash"] != previous[path]["hash"]:
                    format["changed"].append(path)
        return format

    def produce_json(self) -> dict:
        if not self.is_priv():
            self.print_err("Need root privileges")
            return {}

        self.loop_cron()
        if self.compare == "":
            return {"crontabs": self.crontabs}
        return self.compare_cron()


if __name__ == "__main__":
    parse = argparse.ArgumentParser()
    parse.add_argument("-f", "--file",  default="")
    args = parse.parse_args()
    data = CCDCCronScript(compare=args.file)
    json.dump(data.produce_json(), sys.stdout, indent=2)
