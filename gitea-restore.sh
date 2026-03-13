#!/bin/sh
#===============================================================================
#  gitea-restore.sh — Automatically restore the latest Gitea backup
#
#  POSIX-compliant shell version  (requires GNU tar for --acls/--xattrs)
#
#  1. Finds the newest .tar.gz in the backup directory
#  2. Reads all paths from the gitea.service unit file
#  3. Extracts and restores preserving ownership, permissions, ACLs, xattrs
#  4. Saves a pre-restore snapshot before overwriting anything
#
#  Usage:  sudo ./gitea-restore.sh
#
#  Requires: root, GNU tar
#===============================================================================
set -eu

# ─── CONFIGURATION ───────────────────────────────────────────────────────────

GITEA_SERVICE="gitea.service"
UNIT_FILE="/etc/systemd/system/${GITEA_SERVICE}"
BACKUP_ROOT="/home/semaphore/gitea-backups"
EXTRACT_DIR="/tmp/gitea-restore-$$"

# ─── END CONFIGURATION ──────────────────────────────────────────────────────

# Temp files for restore maps (replace bash arrays)
# Each line: source<TAB>destination
RESTORE_FILE_MAP="$(mktemp)"
RESTORE_DIR_MAP="$(mktemp)"

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date +%T)" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

check_file() {
    _cf_label="$1"; _cf_path="$2"
    if [ -f "$_cf_path" ]; then
        printf '  %-22s %-50s [FOUND]\n' "$_cf_label" "$_cf_path"
        return 0
    else
        printf '  %-22s %-50s [MISSING]\n' "$_cf_label" "$_cf_path"
        return 1
    fi
}
check_dir() {
    _cd_label="$1"; _cd_path="$2"
    if [ -d "$_cd_path" ]; then
        printf '  %-22s %-50s [FOUND]\n' "$_cd_label" "$_cd_path"
        return 0
    else
        printf '  %-22s %-50s [MISSING]\n' "$_cd_label" "$_cd_path"
        return 1
    fi
}

count_lines() {
    if [ -s "$1" ]; then
        wc -l < "$1" | tr -d '[:space:]'
    else
        printf '0'
    fi
}

cleanup_temp() {
    rm -f "$RESTORE_FILE_MAP" "$RESTORE_DIR_MAP"
    if [ -d "$EXTRACT_DIR" ]; then
        log "Cleaning up temp directory: ${EXTRACT_DIR}"
        rm -rf "$EXTRACT_DIR"
    fi
}

# Clean up temp files on ANY exit (overridden later to also restart Gitea)
trap 'cleanup_temp' EXIT

# ─── Preflight ───────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ]                || die "Must be run as root."
command -v systemctl >/dev/null 2>&1 || die "'systemctl' not found."
command -v tar       >/dev/null 2>&1 || die "'tar' not found."
[ -f "$UNIT_FILE" ]                  || die "Unit file not found: ${UNIT_FILE}"
[ -d "$BACKUP_ROOT" ]               || die "Backup directory not found: ${BACKUP_ROOT}"

#===============================================================================
#  PHASE 0 — FIND THE LATEST BACKUP
#===============================================================================
echo ""
echo "=========================================="
echo "  Phase 0: Find Latest Backup"
echo "=========================================="
echo ""

log "Scanning: ${BACKUP_ROOT}"

# Filenames embed YYYYMMDD-HHMMSS, so reverse lexical sort = newest first
ARCHIVE_PATH="$(find "$BACKUP_ROOT" -maxdepth 1 -name 'gitea-backup-*.tar.gz' \
    -type f | sort -r | head -1)"

[ -n "$ARCHIVE_PATH" ] && [ -f "$ARCHIVE_PATH" ] \
    || die "No gitea-backup-*.tar.gz files found in ${BACKUP_ROOT}"

BACKUP_COUNT="$(find "$BACKUP_ROOT" -maxdepth 1 -name 'gitea-backup-*.tar.gz' \
    -type f | wc -l | tr -d '[:space:]')"
ARCHIVE_FILENAME="$(basename "$ARCHIVE_PATH")"
ARCHIVE_DATE="$(printf '%s\n' "$ARCHIVE_FILENAME" \
    | sed -n 's/.*\([0-9]\{8\}-[0-9]\{6\}\).*/\1/p' \
    | head -1)" || ARCHIVE_DATE=""
ARCHIVE_SIZE="$(du -h "$ARCHIVE_PATH" | cut -f1)"

echo "── Available Backups ─────────────────────"
echo "  Total backups found : ${BACKUP_COUNT}"
echo ""
echo "  Most recent 5:"
find "$BACKUP_ROOT" -maxdepth 1 -name 'gitea-backup-*.tar.gz' \
    -type f | sort -r | head -5 \
    | while IFS= read -r f; do
        fname="$(basename "$f")"
        fsize="$(du -h "$f" | cut -f1)"
        if [ "$f" = "$ARCHIVE_PATH" ]; then
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
GITEA_WORK_DIR="$(sed -n \
    's/^[[:space:]]*WorkingDirectory[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' \
    "$UNIT_FILE" | head -1)"
[ -n "$GITEA_WORK_DIR" ] || die "WorkingDirectory= not found in ${UNIT_FILE}"

GITEA_WORK_DIR="${GITEA_WORK_DIR%/}"    # strip trailing slash

EXEC_LINE="$(sed -n \
    's/^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*//p' \
    "$UNIT_FILE" | head -1)" || EXEC_LINE=""
RUN_USER="$(sed -n \
    's/^[[:space:]]*User[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' \
    "$UNIT_FILE" | head -1)" || RUN_USER=""
RUN_GROUP="$(sed -n \
    's/^[[:space:]]*Group[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' \
    "$UNIT_FILE" | head -1)" || RUN_GROUP=""

GITEA_CONF=""
if [ -n "$EXEC_LINE" ]; then
    GITEA_CONF="$(printf '%s\n' "$EXEC_LINE" | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "--config" || $i == "-c") {
                print $(i+1)
                exit
            }
        }
    }')" || GITEA_CONF=""
fi
if [ -z "$GITEA_CONF" ] || [ ! -f "$GITEA_CONF" ]; then
    for candidate in \
        "${GITEA_WORK_DIR}/custom/conf/app.ini" \
        "/etc/gitea/app.ini"; do
        if [ -f "$candidate" ]; then
            GITEA_CONF="$candidate"
            break
        fi
    done
fi

if [ -z "$GITEA_CONF" ]; then
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

mkdir -p "$EXTRACT_DIR"
log "Extracting to: ${EXTRACT_DIR}"

# NOTE: --same-owner, --acls, --xattrs are GNU tar extensions
tar -xzf "$ARCHIVE_PATH" \
    -C "$EXTRACT_DIR" \
    --same-owner \
    --preserve-permissions \
    --acls \
    --xattrs

# Find inner directory via POSIX glob (replaces find -mindepth/-maxdepth)
INNER_DIR=""
for _entry in "$EXTRACT_DIR"/*; do
    if [ -d "$_entry" ]; then
        INNER_DIR="$_entry"
        break
    fi
done

[ -n "$INNER_DIR" ] && [ -d "$INNER_DIR" ] \
    || die "Could not find inner directory in extracted archive."
log "Extracted contents in: ${INNER_DIR}"
echo ""

# ─── Build restore map ──────────────────────────────────────────────────────
echo "── Archive Contents ──────────────────────"

if [ -f "${INNER_DIR}/app.ini" ]; then
    check_file "app.ini" "${INNER_DIR}/app.ini" || true
    printf '%s\t%s\n' "${INNER_DIR}/app.ini" "${GITEA_CONF}" >> "$RESTORE_FILE_MAP"
fi

for dir_name in custom data repositories log; do
    if [ -d "${INNER_DIR}/${dir_name}" ]; then
        check_dir "${dir_name}/" "${INNER_DIR}/${dir_name}" || true
        printf '%s\t%s\n' "${INNER_DIR}/${dir_name}" "${GITEA_WORK_DIR}/${dir_name}" \
            >> "$RESTORE_DIR_MAP"
    fi
done
echo ""

FILE_RESTORE_COUNT="$(count_lines "$RESTORE_FILE_MAP")"
DIR_RESTORE_COUNT="$(count_lines "$RESTORE_DIR_MAP")"

if [ "$FILE_RESTORE_COUNT" -eq 0 ] && [ "$DIR_RESTORE_COUNT" -eq 0 ]; then
    die "Archive appears empty — nothing to restore!"
fi

# ─── Show restore plan ───────────────────────────────────────────────────────
echo "── Restore Plan ────────────────────────"
echo ""

if [ "$FILE_RESTORE_COUNT" -gt 0 ]; then
    echo "  Files:"
    while IFS="	" read -r src dest; do
        fname="$(basename "$src")"
        echo "    ${fname}  →  ${dest}"
    done < "$RESTORE_FILE_MAP"
fi

if [ "$DIR_RESTORE_COUNT" -gt 0 ]; then
    echo "  Directories:"
    while IFS="	" read -r src dest; do
        dname="$(basename "$src")"
        echo "    ${dname}/  →  ${dest}"
    done < "$RESTORE_DIR_MAP"
fi
echo ""

echo "  ⚠  WARNING: This will OVERWRITE existing Gitea files."
echo "     A pre-restore snapshot will be saved first."
echo ""
printf '  Proceed with restore? (yes/no): '
read -r CONFIRM
case "$CONFIRM" in
    [Yy][Ee][Ss])
        ;;
    *)
        log "Restore cancelled by user."
        exit 0
        ;;
esac
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

# Override trap: always restart the service AND clean temp files on exit
trap 'log "Restarting ${GITEA_SERVICE} …"; systemctl start "${GITEA_SERVICE}"; log "Service started."; cleanup_temp' EXIT

# ─── Pre-restore snapshot ────────────────────────────────────────────────────
PRE_RESTORE_DIR="${GITEA_WORK_DIR}/.pre-restore-$(date +%Y%m%d-%H%M%S)"
log "Saving pre-restore snapshot: ${PRE_RESTORE_DIR}"
mkdir -p "$PRE_RESTORE_DIR"

if [ -f "$GITEA_CONF" ]; then
    log "  Snapshotting: ${GITEA_CONF}"
    cp -p "$GITEA_CONF" "${PRE_RESTORE_DIR}/app.ini"
fi

for dir_name in custom data repositories; do
    src="${GITEA_WORK_DIR}/${dir_name}"
    if [ -d "$src" ]; then
        log "  Snapshotting: ${src}"
        cp -pR "$src" "${PRE_RESTORE_DIR}/${dir_name}"
    fi
done
log "Pre-restore snapshot saved."
echo ""

# ─── Restore files ───────────────────────────────────────────────────────────
while IFS="	" read -r src dest; do
    dest_dir="$(dirname "$dest")"

    if [ ! -d "$dest_dir" ]; then
        log "Creating directory: ${dest_dir}"
        mkdir -p "$dest_dir"
    fi

    log "Restoring file: $(basename "$src")  →  ${dest}"
    cp -p "$src" "$dest"
done < "$RESTORE_FILE_MAP"

# ─── Restore directories ─────────────────────────────────────────────────────
while IFS="	" read -r src dest; do
    dir_name="$(basename "$src")"

    if [ -d "$dest" ]; then
        log "Removing old: ${dest}"
        rm -rf "$dest"
    fi

    log "Restoring dir:  ${dir_name}/  →  ${dest}"
    cp -pR "$src" "$dest"
done < "$RESTORE_DIR_MAP"
echo ""

# ─── Fix ownership ───────────────────────────────────────────────────────────
if [ -n "$RUN_USER" ] && [ -n "$RUN_GROUP" ]; then
    log "Ensuring ownership: ${RUN_USER}:${RUN_GROUP}"
    chown -R "${RUN_USER}:${RUN_GROUP}" "${GITEA_WORK_DIR}"
    chown -R "${RUN_USER}:${RUN_GROUP}" "$(dirname "$GITEA_CONF")"
    log "Ownership set."
elif [ -n "$RUN_USER" ]; then
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
