#!/bin/sh
# =============================================================================
# pfsense_revert_config.sh  (STANDALONE / MANUAL REVERT VERSION)
#
# PURPOSE:
#   Immediately revert pfSense config to the most recent safe_apply backup
#   WITHOUT waiting for the timer. Use this if you know changes are broken
#   and don't want to wait 5 minutes.
#
# USAGE:
#   sh pfsense_revert_config.sh              # revert to most recent backup
#   sh pfsense_revert_config.sh <file.xml>   # revert to a specific backup
#
# NOTE:
#   pfsense_safe_apply.sh also generates a session-specific version of this
#   script at /tmp/pfsense_revert_config.sh -- that version has the exact
#   backup path baked in. Use this standalone version if you need to manually
#   pick a backup or if the session-specific version is unavailable.
# =============================================================================

PFSENSE_CONFIG="/cf/conf/config.xml"
BACKUP_DIR="/cf/conf/safe_apply_backups"
STATE_FILE="/tmp/safe_apply_state"

# If a specific backup file was provided as argument, use it
if [ -n "$1" ]; then
    BACKUP_FILE="$1"
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "[ERROR] Specified backup file not found: $BACKUP_FILE"
        exit 1
    fi
else
    # Otherwise, read from state file if a session is active
    if [ -f "$STATE_FILE" ]; then
        BACKUP_FILE=$(grep '^BACKUP=' "$STATE_FILE" | cut -d= -f2)
        echo "[INFO] Using backup from active session: $BACKUP_FILE"
    else
        # Fall back to the most recent backup in the backup directory
        if [ ! -d "$BACKUP_DIR" ]; then
            echo "[ERROR] No backup directory found at $BACKUP_DIR"
            echo "        Has pfsense_safe_apply.sh been run before?"
            exit 1
        fi
        BACKUP_FILE=$(ls -t "${BACKUP_DIR}"/config_backup_*.xml 2>/dev/null | head -1)
        if [ -z "$BACKUP_FILE" ]; then
            echo "[ERROR] No backup files found in $BACKUP_DIR"
            exit 1
        fi
        echo "[INFO] No active session. Using most recent backup: $BACKUP_FILE"
    fi
fi

# Cancel any running timer so we don't double-revert
if [ -f "$STATE_FILE" ]; then
    PID=$(grep '^PID=' "$STATE_FILE" | cut -d= -f2)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null
        echo "[OK] Cancelled running revert timer (PID $PID)."
    fi
fi

echo ""
echo "============================================"
echo "  SAFE APPLY: MANUAL REVERT"
echo "============================================"
echo "  Restoring:  $BACKUP_FILE"
echo "  Time:       $(date)"
echo ""

# Restore the config
cp "$BACKUP_FILE" "$PFSENSE_CONFIG"
if [ $? -eq 0 ]; then
    echo "[OK] config.xml restored successfully."
else
    echo "[ERROR] Failed to restore config.xml!"
    exit 1
fi

# Reload all pfSense services
echo "[INFO] Reloading pfSense services (this may take ~15-30 seconds)..."
/etc/rc.reload_all start 2>&1

echo ""
echo "[DONE] Revert complete. pfSense is running the previous configuration."
echo "       You can now safely log back into the web UI."

# List all available backups for reference
echo ""
echo "Available backups in $BACKUP_DIR:"
ls -lt "${BACKUP_DIR}"/config_backup_*.xml 2>/dev/null | awk '{print "  " $6, $7, $8, $NF}' || echo "  (none)"

rm -f "$STATE_FILE"
