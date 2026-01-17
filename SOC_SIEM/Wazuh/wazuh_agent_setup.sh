#!/bin/bash
## run as sudo ./wazuh_agent_setup.sh
## Script to setup Wazuh Agent instances

## edited from this https://documentation.wazuh.com/current/installation-guide/wazuh-agent/wazuh-agent-package-linux.html
## NOTE: For Wazuh setup, make sure these ports are exposed before running script on manager box
#1514/TCP for agent communication.
#1515/TCP for enrollment via agent configuration.
#55000/TCP for enrollment via Wazuh server API.


if [[ $EUID -ne 0 ]]; then
    echo "$0 is not running as root. Try using sudo."
    exit 2
fi

printf "%s" "What is your package manager? (1: APT, 2: Yum, 3: DNF): "
read pm

printf "%s" "What is your service manager? (1: systemd, 2: SysV Init, 3: None): "
read sm

printf "%s" "What is your Wazuh Manager IP or host name?: "
read WAZUH_MAN

## Install and deploy step 1

case $pm in
    1)
        #apt-get update
        #apt-get upgrade
        apt-get install gnupg apt-transport-https
        curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import && chmod 644 /usr/share/keyrings/wazuh.gpg
        echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | tee -a /etc/apt/sources.list.d/wazuh.list
        apt-get update
        WAZUH_MANAGER="$WAZUH_MAN" apt-get install wazuh-agent
        ;;
    2)
        rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH
        cat > /etc/yum.repos.d/wazuh.repo << EOF
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=EL-\$releasever - Wazuh
baseurl=https://packages.wazuh.com/4.x/yum/
priority=1
EOF
        WAZUH_MANAGER="$WAZUH_MAN" yum install wazuh-agent
        ;;
    3)
        rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH
        cat > /etc/yum.repos.d/wazuh.repo << EOF
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=EL-\$releasever - Wazuh
baseurl=https://packages.wazuh.com/4.x/yum/
priority=1
EOF
        WAZUH_MANAGER="$WAZUH_MAN" dnf install wazuh-agent
        ;;


esac

## Deploy Step 2
case $sm in
    1)
        systemctl daemon-reload
        systemctl enable wazuh-agent
        systemctl start wazuh-agent
        ;;
    2)
         # For APT-based systems (Debian/Ubuntu)
        if [[ $pm -eq 1 ]]; then
            update-rc.d wazuh-agent defaults 95 10
            service wazuh-agent start
            #service wazuh-agent status
        # For YUM/DNF-based systems (RHEL/CentOS/Fedora)
        elif [[ $pm -eq 2 ]] || [[ $pm -eq 3 ]]; then
            chkconfig --add wazuh-agent
            #chkconfig wazuh-agent on
            service wazuh-agent start
            #service wazuh-agent status
        fi
        ;;
    3)
        ## NOTE: if you see something like "wazuh-execd: Process <number> not used by Wazuh, removing ..", youll need to install ps on your system
        /var/ossec/bin/wazuh-control start
        ;;

esac
