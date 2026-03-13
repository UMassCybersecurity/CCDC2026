#!/usr/bin/env bash
#===============================================================================
#  gitea-restore.sh — Automatically restore the latest Gitea backup
#
#  1. Finds the newest .tar.gz in the backup directory
#  2. Reads all paths from the gitea.service unit file
#  3. Extracts and restores preserving ownership, permissions, ACLs, xattrs
#  4. Saves a pre-restore snapshot before overwriting anything
#
#  Usage:  sudo ./gitea-restore.sh
#
#  Requires: root
#===============================================================================
set -euo pipefail

# ─── CONFIGURATION ───────────────────────────────────────────────────────────

GITEA_SERVICE="gitea.service"
UNIT_FILE="/etc/systemd/system/${GITEA_SERVICE}"
BACKUP_ROOT="/home/semaphore/gitea-backups"
EXTRACT_DIR="/tmp/gitea-restore-$$"

# ─── END CONFIGURATION ──────────────────────────────────────────────────────

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date +%T)" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

check_file() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        printf '  %-22s %-50s [FOUND]\n' "$label" "$path"
        return 0
    else
        printf '  %-22s %-50s [MISSING]\n' "$label" "$path"
        return 1
    fi
}
check_dir() {
    local label="$1" path="$2"
    if [[ -d "$path" ]]; then
        printf '  %-22s %-50s [FOUND]\n' "$label" "$path"
        return 0
    else
        printf '  %-22s %-50s [MISSING]\n' "$label" "$path"
        return 1
    fi
}

# ─── Preflight ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]]               || die "Must be run as root."
command -v systemctl &>/dev/null || die "'systemctl' not found."
command -v tar       &>/dev/null || die "'tar' not found."
[[ -f "$UNIT_FILE" ]]           || die "Unit file not found: ${UNIT_FILE}"
[[ -d "$BACKUP_ROOT" ]]         || die "Backup directory not found: ${BACKUP_ROOT}"

#===============================================================================
#  PHASE 0 — FIND THE LATEST BACKUP
#===============================================================================
echo ""
echo "=========================================="
echo "  Phase 0: Find Latest Backup"
echo "=========================================="
echo ""

log "Scanning: ${BACKUP_ROOT}"

ARCHIVE_PATH="$(find "$BACKUP_ROOT" -maxdepth 1 -name 'gitea-backup-*.tar.gz' \
    -type f -printf '%T@\t%p\n' \
    | sort -rn \
    | head -1 \
    | cut -f2)"

[[ -n "$ARCHIVE_PATH" && -f "$ARCHIVE_PATH" ]] \
    || die "No gitea-backup-*.tar.gz files found in ${BACKUP_ROOT}"

BACKUP_COUNT="$(find "$BACKUP_ROOT" -maxdepth 1 -name 'gitea-backup-*.tar.gz' -type f | wc -l)"
ARCHIVE_FILENAME="$(basename "$ARCHIVE_PATH")"
ARCHIVE_DATE="$(echo "$ARCHIVE_FILENAME" \
    | grep -Po '\d{8}-\d{6}' \
    | head -1)" || true
ARCHIVE_SIZE="$(du -h "$ARCHIVE_PATH" | cut -f1)"

echo "── Available Backups ─────────────────────"
echo "  Total backups found : ${BACKUP_COUNT}"
echo ""
echo "  Most recent 5:"
find "$BACKUP_ROOT" -maxdepth 1 -name 'gitea-backup-*.tar.gz' \
    -type f -printf '%T@\t%p\n' \
    | sort -rn \
    | head -5 \
    | cut -f2 \
    | while read -r f; do
        fname="$(basename "$f")"
        fsize="$(du -h "$f" | cut -f1)"
        if [[ "$f" == "$ARCHIVE_PATH" ]]; then
            echo "    → ${fname}  (${fsize})  ← SELECTED"
        else
            echo "      ${fname}  (${fsize})"
        fi
    done
echo ""

log "Selected: ${ARCHIVE_FILENAME}"
log "Date:     ${ARCHIVE_DATE:-(unknown)}"
log "Size:     ${ARCHIVE_SIZE}"
echo ""

#===============================================================================
#  PHASE 1 — DISCOVERY
#===============================================================================
echo "=========================================="
echo "  Phase 1: Discovery"
echo "=========================================="
echo ""

# ─── Parse systemd unit ─────────────────────────────────────────────────────
GITEA_WORK_DIR="$(grep -Po '^\s*WorkingDirectory\s*=\s*\K\S+' "$UNIT_FILE" | head -1)"
[[ -n "$GITEA_WORK_DIR" ]] || die "WorkingDirectory= not found in ${UNIT_FILE}"

GITEA_WORK_DIR="${GITEA_WORK_DIR%/}"    # ← FIX: strip trailing slash

EXEC_LINE="$(grep -Po '^\s*ExecStart\s*=\s*\K.*' "$UNIT_FILE" | head -1)" || true
RUN_USER="$(grep -Po  '^\s*User\s*=\s*\K\S+'     "$UNIT_FILE" | head -1)" || true
RUN_GROUP="$(grep -Po '^\s*Group\s*=\s*\K\S+'     "$UNIT_FILE" | head -1)" || true

GITEA_CONF=""
if [[ -n "$EXEC_LINE" ]]; then
    GITEA_CONF="$(echo "$EXEC_LINE" \
        | grep -Po '(--config|-c)\s+\K\S+' \
        | head -1)" || true
fi
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

if [[ -z "$GITEA_CONF" ]]; then
    GITEA_CONF="${GITEA_WORK_DIR}/custom/conf/app.ini"
    log "Config not found on disk — will restore to: ${GITEA_CONF}"
fi

echo "── Systemd Unit ──────────────────────────"
check_file "Unit file"   "$UNIT_FILE" || true
echo "  ExecStart:            ${EXEC_LINE:-(not found)}"
echo "  User:                 ${RUN_USER:-(not set)}"
echo "  Group:                ${RUN_GROUP:-(not set)}"
echo ""

echo "── Target Paths ────────────────────────"
check_dir  "WorkingDirectory"  "$GITEA_WORK_DIR"               || true
check_file "app.ini"           "$GITEA_CONF"                    || true
check_dir  "custom/"           "${GITEA_WORK_DIR}/custom"       || true
check_dir  "data/"             "${GITEA_WORK_DIR}/data"         || true
check_dir  "repositories/"     "${GITEA_WORK_DIR}/repositories" || true
check_dir  "log/"              "${GITEA_WORK_DIR}/log"          || true
echo ""

#===============================================================================
#  PHASE 2 — EXTRACT ARCHIVE
#===============================================================================
echo "=========================================="
echo "  Phase 2: Extract Archive"
echo "=========================================="
echo ""

cleanup() {
    if [[ -d "$EXTRACT_DIR" ]]; then
        log "Cleaning up temp directory: ${EXTRACT_DIR}"
        rm -rf "$EXTRACT_DIR"
    fi
}

mkdir -p "$EXTRACT_DIR"
log "Extracting to: ${EXTRACT_DIR}"

tar \
    --extract \
    --gzip \
    --file="$ARCHIVE_PATH" \
    --directory="$EXTRACT_DIR" \
    --same-owner \
    --preserve-permissions \
    --acls \
    --xattrs

INNER_DIR="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -n "$INNER_DIR" && -d "$INNER_DIR" ]] \
    || die "Could not find inner directory in extracted archive."
log "Extracted contents in: ${INNER_DIR}"
echo ""

# ─── Build restore map ──────────────────────────────────────────────────────
echo "── Archive Contents ──────────────────────"
RESTORE_FILES=()
RESTORE_DIRS=()
RESTORE_DESTS=()

if [[ -f "${INNER_DIR}/app.ini" ]]; then
    check_file "app.ini" "${INNER_DIR}/app.ini" || true
    RESTORE_FILES+=("${INNER_DIR}/app.ini")
    RESTORE_DESTS+=("${GITEA_CONF}")
fi

for dir_name in custom data repositories log; do
    if [[ -d "${INNER_DIR}/${dir_name}" ]]; then
        check_dir "${dir_name}/" "${INNER_DIR}/${dir_name}" || true
        RESTORE_DIRS+=("${INNER_DIR}/${dir_name}")
        RESTORE_DESTS+=("${GITEA_WORK_DIR}/${dir_name}")
    fi
done
echo ""

if [[ ${#RESTORE_FILES[@]} -eq 0 && ${#RESTORE_DIRS[@]} -eq 0 ]]; then
    cleanup
    die "Archive appears empty — nothing to restore!"
fi

# ─── Show restore plan ───────────────────────────────────────────────────────
echo "── Restore Plan ────────────────────────"
echo ""
DEST_INDEX=0

if [[ ${#RESTORE_FILES[@]} -gt 0 ]]; then
    echo "  Files:"
    for f in "${RESTORE_FILES[@]}"; do
        fname="$(basename "$f")"
        echo "    ${fname}  →  ${RESTORE_DESTS[$DEST_INDEX]}"
        DEST_INDEX=$((DEST_INDEX + 1))    # ← FIX: safe increment
    done
fi

if [[ ${#RESTORE_DIRS[@]} -gt 0 ]]; then
    echo "  Directories:"
    for d in "${RESTORE_DIRS[@]}"; do
        dname="$(basename "$d")"
        echo "    ${dname}/  →  ${RESTORE_DESTS[$DEST_INDEX]}"
        DEST_INDEX=$((DEST_INDEX + 1))    # ← FIX: safe increment
    done
fi
echo ""

echo "  ⚠  WARNING: This will OVERWRITE existing Gitea files."
echo "     A pre-restore snapshot will be saved first."
echo ""
read -rp "  Proceed with restore? (yes/no): " CONFIRM
if [[ "${CONFIRM,,}" != "yes" ]]; then
    log "Restore cancelled by user."
    cleanup
    exit 0
fi
echo ""

#===============================================================================
#  PHASE 3 — RESTORE
#===============================================================================
echo "=========================================="
echo "  Phase 3: Restore"
echo "=========================================="
echo ""

log "Stopping ${GITEA_SERVICE} …"
systemctl stop "${GITEA_SERVICE}" 2>/dev/null || log "Service was already stopped."

trap 'log "Restarting ${GITEA_SERVICE} …"; systemctl start "${GITEA_SERVICE}"; log "Service started."; cleanup' EXIT

# ─── Pre-restore snapshot ────────────────────────────────────────────────────
PRE_RESTORE_DIR="${GITEA_WORK_DIR}/.pre-restore-$(date +%Y%m%d-%H%M%S)"
log "Saving pre-restore snapshot: ${PRE_RESTORE_DIR}"
mkdir -p "$PRE_RESTORE_DIR"

if [[ -f "$GITEA_CONF" ]]; then
    log "  Snapshotting: ${GITEA_CONF}"
    cp -a "$GITEA_CONF" "${PRE_RESTORE_DIR}/app.ini"
fi

for dir_name in custom data repositories; do
    src="${GITEA_WORK_DIR}/${dir_name}"
    if [[ -d "$src" ]]; then
        log "  Snapshotting: ${src}"
        cp -a "$src" "${PRE_RESTORE_DIR}/${dir_name}"
    fi
done
log "Pre-restore snapshot saved."
echo ""

# ─── Restore files ───────────────────────────────────────────────────────────
DEST_INDEX=0

for f in "${RESTORE_FILES[@]}"; do
    dest="${RESTORE_DESTS[$DEST_INDEX]}"
    dest_dir="$(dirname "$dest")"

    if [[ ! -d "$dest_dir" ]]; then
        log "Creating directory: ${dest_dir}"
        mkdir -p "$dest_dir"
    fi

    log "Restoring file: $(basename "$f")  →  ${dest}"
    cp -a "$f" "$dest"
    DEST_INDEX=$((DEST_INDEX + 1))    # ← FIX: safe increment
done

# ─── Restore directories ─────────────────────────────────────────────────────
for d in "${RESTORE_DIRS[@]}"; do
    dest="${RESTORE_DESTS[$DEST_INDEX]}"
    dir_name="$(basename "$d")"

    if [[ -d "$dest" ]]; then
        log "Removing old: ${dest}"
        rm -rf "$dest"
    fi

    log "Restoring dir:  ${dir_name}/  →  ${dest}"
    cp -a "$d" "$dest"
    DEST_INDEX=$((DEST_INDEX + 1))    # ← FIX: safe increment
done
echo ""

# ─── Fix ownership ───────────────────────────────────────────────────────────
if [[ -n "$RUN_USER" && -n "$RUN_GROUP" ]]; then
    log "Ensuring ownership: ${RUN_USER}:${RUN_GROUP}"
    chown -R "${RUN_USER}:${RUN_GROUP}" "${GITEA_WORK_DIR}"
    chown -R "${RUN_USER}:${RUN_GROUP}" "$(dirname "$GITEA_CONF")"
    log "Ownership set."
elif [[ -n "$RUN_USER" ]]; then
    log "Ensuring ownership: ${RUN_USER}"
    chown -R "${RUN_USER}" "${GITEA_WORK_DIR}"
    chown -R "${RUN_USER}" "$(dirname "$GITEA_CONF")"
    log "Ownership set."
else
    log "WARNING: User/Group not found in unit file — skipping chown."
    log "         You may need to fix ownership manually."
fi
echo ""

echo "=========================================="
log "Restore complete."
log "Restored from  : ${ARCHIVE_FILENAME}"
log "Backup date    : ${ARCHIVE_DATE:-(unknown)}"
log "Pre-restore at : ${PRE_RESTORE_DIR}"
echo "=========================================="
echo ""