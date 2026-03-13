#!/usr/bin/env bash
#===============================================================================
#  gitea-discover.sh — Discover and print all Gitea paths from systemd
#
#  Does NOT stop Gitea. Does NOT copy or back up anything.
#  Just reads the unit file and reports what it finds.
#===============================================================================
set -euo pipefail

# ─── CONFIGURATION ───────────────────────────────────────────────────────────

GITEA_SERVICE="gitea.service"
UNIT_FILE="/etc/systemd/system/${GITEA_SERVICE}"

# ─── END CONFIGURATION ──────────────────────────────────────────────────────

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date +%T)" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

# Prints a path with a status tag: FOUND / MISSING
check() {
    local label="$1"
    local path="$2"
    local type="$3"   # "file" or "dir"

    if [[ "$type" == "file" && -f "$path" ]]; then
        printf '  %-20s %-50s [FOUND]\n' "${label}" "${path}"
    elif [[ "$type" == "dir" && -d "$path" ]]; then
        printf '  %-20s %-50s [FOUND]\n' "${label}" "${path}"
    else
        printf '  %-20s %-50s [MISSING]\n' "${label}" "${path}"
    fi
}

# ─── Preflight ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "This script must be run as root (to read all paths)."
[[ -f "$UNIT_FILE" ]] || die "Unit file not found: ${UNIT_FILE}"

# ─── Parse WorkingDirectory ──────────────────────────────────────────────────
GITEA_WORK_DIR="$(grep -Po '^\s*WorkingDirectory\s*=\s*\K\S+' "$UNIT_FILE" | head -1)"
[[ -n "$GITEA_WORK_DIR" ]] || die "Could not find WorkingDirectory= in ${UNIT_FILE}"

# ─── Parse config path from ExecStart (--config / -c) ───────────────────────
EXEC_LINE="$(grep -Po '^\s*ExecStart\s*=\s*\K.*' "$UNIT_FILE" | head -1)"
GITEA_CONF=""
if [[ -n "$EXEC_LINE" ]]; then
    GITEA_CONF="$(echo "$EXEC_LINE" \
        | grep -Po '(--config|-c)\s+\K\S+' \
        | head -1)" || true
fi

# Fallbacks
if [[ -z "$GITEA_CONF" || ! -f "$GITEA_CONF" ]]; then
    for candidate in \
        "${GITEA_WORK_DIR}/custom/conf/app.ini" \
        "/etc/gitea/app.ini"; do
        if [[ -f "$candidate" ]]; then
            GITEA_CONF="$candidate"
            break
        fi
    done
fi
[[ -n "$GITEA_CONF" ]] || GITEA_CONF="(not found)"

# ─── Parse other useful fields from the unit file ────────────────────────────
EXEC_START="$(grep -Po '^\s*ExecStart\s*=\s*\K.*' "$UNIT_FILE" | head -1)" || true
RUN_USER="$(grep -Po '^\s*User\s*=\s*\K\S+' "$UNIT_FILE" | head -1)" || true
RUN_GROUP="$(grep -Po '^\s*Group\s*=\s*\K\S+' "$UNIT_FILE" | head -1)" || true
ENVIRONMENT="$(grep -Po '^\s*Environment\s*=\s*\K.*' "$UNIT_FILE")" || true

# ─── Derive subdirectories ──────────────────────────────────────────────────
GITEA_CUSTOM_DIR="${GITEA_WORK_DIR}/custom"
GITEA_DATA_DIR="${GITEA_WORK_DIR}/data"
GITEA_REPOS_DIR="${GITEA_WORK_DIR}/repositories"
GITEA_LOG_DIR="${GITEA_WORK_DIR}/log"

# ─── Print Everything ────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Gitea Path Discovery"
echo "=========================================="
echo ""

echo "── Systemd Unit ──────────────────────────"
check "Unit file"       "$UNIT_FILE"       "file"
echo "  ExecStart:        ${EXEC_START:-(not found)}"
echo "  User:             ${RUN_USER:-(not set)}"
echo "  Group:            ${RUN_GROUP:-(not set)}"
if [[ -n "$ENVIRONMENT" ]]; then
    echo "  Environment:"
    echo "$ENVIRONMENT" | while read -r line; do
        echo "                    ${line}"
    done
fi
echo ""

echo "── Working Directory ─────────────────────"
check "WorkingDirectory" "$GITEA_WORK_DIR"  "dir"
echo ""

echo "── Config File ─────────────────────────"
check "app.ini"          "$GITEA_CONF"      "file"
echo ""

echo "── Standard Subdirectories ───────────────"
check "custom/"          "$GITEA_CUSTOM_DIR" "dir"
check "data/"            "$GITEA_DATA_DIR"   "dir"
check "repositories/"    "$GITEA_REPOS_DIR"  "dir"
check "log/"             "$GITEA_LOG_DIR"    "dir"
echo ""

# ─── Scan inside data/ for notable sub-items ─────────────────────────────────
echo "── Inside data/ ──────────────────────────"
if [[ -d "$GITEA_DATA_DIR" ]]; then
    for item in \
        "attachments" \
        "avatars" \
        "repo-avatars" \
        "lfs" \
        "packages" \
        "indexers" \
        "queues" \
        "sessions" \
        "tmp"; do
        check "${item}/" "${GITEA_DATA_DIR}/${item}" "dir"
    done

    # Check for SQLite database files
    for db in "gitea.db" "gitea.db-wal" "gitea.db-shm"; do
        check "${db}" "${GITEA_DATA_DIR}/${db}" "file"
    done
else
    echo "  (data/ directory missing — skipping scan)"
fi
echo ""

# ─── Scan inside custom/ for notable sub-items ───────────────────────────────
echo "── Inside custom/ ────────────────────────"
if [[ -d "$GITEA_CUSTOM_DIR" ]]; then
    for item in \
        "conf" \
        "conf/app.ini" \
        "templates" \
        "public" \
        "options" \
        "options/label" \
        "options/locale"; do
        if [[ "$item" == *"."* ]]; then
            check "${item}" "${GITEA_CUSTOM_DIR}/${item}" "file"
        else
            check "${item}/" "${GITEA_CUSTOM_DIR}/${item}" "dir"
        fi
    done
else
    echo "  (custom/ directory missing — skipping scan)"
fi
echo ""

# ─── Service status (without touching it) ────────────────────────────────────
echo "── Service Status ────────────────────────"
if systemctl is-active --quiet "${GITEA_SERVICE}" 2>/dev/null; then
    echo "  ${GITEA_SERVICE} is RUNNING"
else
    echo "  ${GITEA_SERVICE} is STOPPED"
fi
echo ""

echo "=========================================="
echo "  Discovery complete. Nothing was modified."
echo "=========================================="
echo ""