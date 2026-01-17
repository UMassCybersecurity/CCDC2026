#!/usr/bin/env python3

import subprocess
import json
import ccdc_script
import sys


class User:
    def __init__(self, passwd_entry: str):
        self.name = passwd_entry[:passwd_entry.find(':')]
        self.shell = passwd_entry[passwd_entry.rfind(':')+1:].rstrip()

        sudo_proc = subprocess.run(
            ['sudo', '-l', '-U', self.name], capture_output=True)
        self.privilege = b"not allowed" not in sudo_proc.stdout
        self.interactive = False
        for shell in ("/bash", "/sh", "/zsh", "/ksh", "/csh", "/dash"):
            if self.shell.rfind(shell) != -1:
                self.interactive = True
                break


def get_users():
    result = []
    with open("/etc/passwd", "r") as file:
        for line in file.readlines():
            result.append(User(line))
    return result


class ProfileAudit(ccdc_script.CCDCScript):

    def __init__(self, err_fd=None) -> None:
        super().__init__(err_fd)

    def create_format(self) -> dict:
        return {"users": {"all": [], "privilege": [], "interactive": []}}

    def produce_json(self) -> dict:
        if not self.is_priv():
            return {}

        self.print_err("Starting to get user info")
        users = get_users()
        format = self.create_format()
        for user in users:
            user_dict = user.__dict__
            format["users"]["all"].append(user_dict)
            if user.privilege:
                format["users"]["privilege"].append(user_dict)
            if user.interactive:
                format["users"]["interactive"].append(user_dict)
        return format


if __name__ == "__main__":
    json.dump(ProfileAudit().produce_json(), sys.stdout, indent=2)
