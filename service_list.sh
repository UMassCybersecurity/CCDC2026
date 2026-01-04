#!/bin/sh
## Usage: ./service_list.sh

manager=$(
    ## SystemCTL
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-units --type=mount 2>/dev/null | grep -q "\.mount"; then echo 1;
        fi

    ## SysVInit
    elif [ -f /etc/init.d/cron ] && [ ! -h /etc/init.d/cron ]; then echo 2;

    # No system manager
    else echo 0;
    fi
)

if [ "$manager" -eq 1 ]; then
    systemctl --type=service --state=active list-units
elif [ "$manager" -eq 2 ]; then
    service --status-all
else
    ps aux
fi
