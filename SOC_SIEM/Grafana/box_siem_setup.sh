#!/bin/bash
## run as sudo ./box_siem_setup.sh
## Script to setup box siem

## Likely will be run on a RHEL/APT machine


if [[ $EUID -ne 0 ]]; then
    echo "$0 is not running as root. Try using sudo."
    exit 2
fi

printf "%s" "What is your package manager? (1: APT, 2: DNF): "
read pm


## Install Git

case $pm in
    1)
        apt-get install git jq
        ;;
    2)
        dnf install git-all jq
        ;;
esac


git clone https://github.com/matijazezelj/sib.git
cp env.comp sib/.env
cd sib
make install
./scripts/test-pipeline.sh
