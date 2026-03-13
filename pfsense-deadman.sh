#!/bin/sh
#
# pfSense Dead Man's Switch — Config Rollback
# --------------------------------------------
# 1. Backs up config.xml
# 2. You make changes via the web UI
# 3. Come back and press ENTER to KEEP changes
# 4. If you don't confirm in time, config is restored and system reboots
#
# Usage:  sh /root/deadman.sh [timeout_in_seconds]
# Example: sh /root/deadman.sh 90

# ── Settings ──────────────────────────────────────────────
TIMEOUT="${1:-90}"                          # Default 90 seconds, or pass as arg
CONFIG="/cf/conf/config.xml"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/cf/conf/config-deadman-${TIMESTAMP}.xml"
CACHE="/tmp/config.cache"

# ── Colors / Formatting ──────────────────────────────────
RED='\033[1;31m'
GRN='\033[1;32m'
YEL='\033[1;33m'
CYN='\033[1;36m'
RST='\033[0m'

# ── Preflight checks ─────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    printf "${RED}[ERROR]${RST} This script must be run as root.\n"
    exit 1
fi

if [ ! -f "$CONFIG" ]; then
    printf "${RED}[ERROR]${RST} Config file not found at %s\n" "$CONFIG"
    exit 1
fi

# ── Step 1: Back up current config ───────────────────────
printf "\n${CYN}══════════════════════════════════════════════════${RST}\n"
printf "${CYN}   pfSense Dead Man's Switch — Config Rollback${RST}\n"
printf "${CYN}══════════════════════════════════════════════════${RST}\n\n"

cp -p "$CONFIG" "$BACKUP"
if [ $? -ne 0 ]; then
    printf "${RED}[ERROR]${RST} Failed to back up config. Aborting.\n"
    exit 1
fi

BACKUP_SIZE="$(ls -lh "$BACKUP" | awk '{print $5}')"
printf "${GRN}[BACKUP OK]${RST} Saved to: %s (%s)\n" "$BACKUP" "$BACKUP_SIZE"
printf "\n"
printf "${YEL}┌─────────────────────────────────────────────────────────┐${RST}\n"
printf "${YEL}│  You have ${CYN}%3d seconds${YEL} to make changes in the web UI.    │${RST}\n" "$TIMEOUT"
printf "${YEL}│                                                         │${RST}\n"
printf "${YEL}│  ${GRN}Changes OK?${YEL}   → Come back here and press ${CYN}ENTER${YEL}         │${RST}\n"
printf "${YEL}│  ${RED}Locked out?${YEL}   → Config auto-restores + reboots        │${RST}\n"
printf "${YEL}└─────────────────────────────────────────────────────────┘${RST}\n"
printf "\n"

# ── Step 2: Countdown with ENTER to confirm ──────────────
SECONDS_LEFT="$TIMEOUT"

while [ "$SECONDS_LEFT" -gt 0 ]; do
    # Color changes as time runs low
    if [ "$SECONDS_LEFT" -le 10 ]; then
        CLR="$RED"
    elif [ "$SECONDS_LEFT" -le 30 ]; then
        CLR="$YEL"
    else
        CLR="$GRN"
    fi

    printf "\r  ${CLR}[%3d sec]${RST}  Auto-rollback countdown — press ${CYN}ENTER${RST} to KEEP changes...  " "$SECONDS_LEFT"

    # read -t 1: wait 1 second for input
    if read -t 1 _confirm 2>/dev/null; then
        printf "\n\n"
        printf "${GRN}════════════════════════════════════════════════════${RST}\n"
        printf "${GRN}  ✓  CONFIRMED — Your new configuration is KEPT.  ${RST}\n"
        printf "${GRN}════════════════════════════════════════════════════${RST}\n"
        printf "\n"
        printf "Backup preserved at: %s\n" "$BACKUP"
        printf "You can manually restore it later if needed with:\n"
        printf "  ${CYN}cp %s %s && rm /tmp/config.cache && reboot${RST}\n\n" "$BACKUP" "$CONFIG"
        exit 0
    fi

    SECONDS_LEFT=$((SECONDS_LEFT - 1))
done

# ── Step 3: TIMEOUT — Restore backup ─────────────────────
printf "\n\n"
printf "${RED}════════════════════════════════════════════════════${RST}\n"
printf "${RED}  ✗  TIMEOUT — No confirmation received!           ${RST}\n"
printf "${RED}     Rolling back to pre-change config...          ${RST}\n"
printf "${RED}════════════════════════════════════════════════════${RST}\n"
printf "\n"

# Restore the backup
cp -p "$BACKUP" "$CONFIG"
if [ $? -ne 0 ]; then
    printf "${RED}[ERROR]${RST} Failed to copy backup over config! Manual intervention needed.\n"
    printf "  Backup is at: %s\n" "$BACKUP"
    exit 1
fi
printf "${GRN}[OK]${RST} config.xml restored from backup.\n"

# Clear config cache so pfSense re-reads from disk
rm -f "$CACHE"
printf "${GRN}[OK]${RST} Config cache cleared.\n"

# ── Step 4: Reload or reboot ─────────────────────────────
#
# A reboot is the most reliable way to fully apply the restored config,
# especially for interface, VLAN, gateway, or DHCP changes.
# A filter-only reload is faster but may not cover all change types.
#
# Uncomment the "Soft Reload" block below and comment out the reboot
# block if you prefer a fast reload without full reboot.
#

# ── Option A: Full reboot (SAFEST — enabled by default) ──
printf "${YEL}[REBOOT]${RST} Rebooting in 5 seconds to apply restored config...\n"
sleep 5
/etc/rc.reboot

# ── Option B: Soft reload (FASTER — uncomment to use instead) ──
# printf "${YEL}[RELOAD]${RST} Reloading all services...\n"
# /usr/local/bin/php -r '
# require_once("config.inc");
# require_once("interfaces.inc");
# require_once("filter.inc");
# require_once("shaper.inc");
# require_once("gwlb.inc");
#
# $config = parse_config(true);
# interfaces_configure();
# filter_configure();
# system_routing_configure();
# setup_gateways_monitor();
# ' 2>/dev/null
# printf "${GRN}[OK]${RST} All services reloaded. Config rollback complete.\n"