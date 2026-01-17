#!/usr/bin/env python3

import socket
import sys
import json

# script modules
import cronmon
import profile_audit
import package_sig_check
import ssh_config

if __name__ == "__main__":
    name = socket.gethostname()
    result = {name: {}}
    result[name].update(cronmon.CCDCCronScript().produce_json())
    result[name].update(profile_audit.ProfileAudit().produce_json())
    result[name].update(package_sig_check.PackageSigCheck().produce_json())
    json.dump(result, sys.stdout, indent=2)
