#!/bin/bash
## run as sudo ./siem2.sh
## Script to setup box siem

## Second Half of Siem Script (to add extra prometheus jobs)


if [[ $EUID -ne 0 ]]; then
    echo "$0 is not running as root. Try using sudo."
    exit 2
fi


cp env.comp sib/.env
cd sib
make install
./scripts/test-pipeline.sh
