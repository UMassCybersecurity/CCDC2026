#!/bin/sh
# =============================================================================
# pfsense_confirm_config.sh  (STANDALONE VERSION)
#
# PURPOSE:
#   Run this after making pfSense changes to ACCEPT them and cancel the
#   auto-revert timer started by pfsense_safe_apply.sh.
#
# NOTE:
#   pfsense_safe_apply.sh also generates a session-specific version of this
#   script at /tmp/pfsense_confirm_config.sh with exact paths baked in.
#   This standalone version reads from the state file for convenience.
#
# USAGE:
#   sh pfsense_confirm_config.sh
# =============================================================================

STATE_FILE="/tmp/safe_apply_state"

if [ ! -f "$STATE_FILE" ]; then
    echo "[INFO] No active safe_apply session found. Nothing to confirm."
    exit 0
fi

PID=$(grep '^PID=' "$STATE_FILE" | cut -d= -f2)
BACKUP=$(grep '^BACKUP=' "$STATE_FILE" | cut -d= -f2)
STARTED=$(grep '^STARTED=' "$STATE_FILE" | cut -d= -f2)

echo ""
echo "============================================"
echo "  SAFE APPLY: CONFIRMING NEW CONFIG"
echo "============================================"
echo "  Session started: $STARTED"
echo "  Backup file:     $BACKUP"
echo ""

if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null
    echo "[OK] Revert timer cancelled (killed PID $PID)."
else
    echo "[WARNING] Revert timer PID $PID is no longer running."
    echo "          The revert may have already executed!"
    echo "          Check your pfSense config to confirm which version is active."
fi

echo "[OK] Current pfSense configuration accepted as permanent."
echo "     Backup retained at: $BACKUP"
echo ""
rm -f "$STATE_FILE"
