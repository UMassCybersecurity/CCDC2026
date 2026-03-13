#!/bin/bash
## run as sudo ./alloy_setup.sh
## Script to setup Grafana Alloy instances

## NOTE: Important Ports
## - LOKI: 3100
## - PROMETHEUS: 9090
## - FALCOSIDEKICK: 2801
## - GRAFANA: 3000
set -x

if [[ $EUID -ne 0 ]]; then
    echo "$0 is not running as root. Try using sudo."
    exit 2
fi

printf "%s" "What is your package manager? (1: APT, 2: DNF, 3: SUSE/Zypper): "
read pm

printf "%s" "What is your Grafana IP or host name?: "
read WAZUH_MAN

## Install and deploy step 1

case $pm in
    1)
        mkdir -p /etc/apt/keyrings
        apt-get update
        apt-get install wget
        wget -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
        chmod 644 /etc/apt/keyrings/grafana.asc
        echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
        apt-get update
        apt-get install alloy
        ;;
    2)
        yum update
        dnf install wget
        wget -q -O gpg.key https://rpm.grafana.com/gpg.key
        rpm --import gpg.key
        echo -e '[grafana]\nname=grafana\nbaseurl=https://rpm.grafana.com\nrepo_gpgcheck=1\nenabled=1\ngpgcheck=1\ngpgkey=https://rpm.grafana.com/gpg.key\nsslverify=1\nsslcacert=/etc/pki/tls/certs/ca-bundle.crt' | sudo tee /etc/yum.repos.d/grafana.repo
        yum update
        dnf install alloy
        ;;
    3)
        zypper update
        zypper install wget
        wget -q -O gpg.key https://rpm.grafana.com/gpg.key
        rpm --import gpg.key
        zypper addrepo https://rpm.grafana.com grafana
        zypper update
        zypper install alloy
        ;;


esac

## Deploy Step 2
systemctl start alloy
systemctl status alloy
