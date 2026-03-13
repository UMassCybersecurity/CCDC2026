#!/bin/sh
#===============================================================================
#  gitea-backup.sh — Dynamic discovery + archive backup of Gitea (systemd)
#
#  POSIX-compliant shell version  (requires GNU tar for --acls/--xattrs)
#
#  1. Reads all paths from the gitea.service unit file
#  2. Scans for every known file/directory inside the working directory
#  3. Backs up ONLY what actually exists
#  4. Preserves ownership, permissions, ACLs, xattrs
#
#  Requires: root, GNU tar
#===============================================================================
set -eu

# ─── CONFIGURATION ───────────────────────────────────────────────────────────

GITEA_SERVICE="gitea.service"
UNIT_FILE="/etc/systemd/system/${GITEA_SERVICE}"
BACKUP_ROOT="/home/semaphore/gitea-backups"
RETENTION_DAYS=30
BACKUP_LOGS="no"

# ─── END CONFIGURATION ──────────────────────────────────────────────────────

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
ARCHIVE_NAME="gitea-backup-${TIMESTAMP}.tar.gz"

# Temp files for collecting discovered paths (replace bash arrays)
FOUND_FILES_LIST="$(mktemp)"
FOUND_DIRS_LIST="$(mktemp)"

cleanup_temp() {
    rm -f "$FOUND_FILES_LIST" "$FOUND_DIRS_LIST"
}

# Clean up temp files on ANY exit (overridden later to also restart Gitea)
trap 'cleanup_temp' EXIT

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date +%T)" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

# Check a path, print status, return 0 (found) or 1 (missing)
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

# ─── Preflight ───────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ]                || die "Must be run as root."
command -v systemctl >/dev/null 2>&1 || die "'systemctl' not found."
command -v tar       >/dev/null 2>&1 || die "'tar' not found."
[ -f "$UNIT_FILE" ]                  || die "Unit file not found: ${UNIT_FILE}"

#===============================================================================
#  PHASE 1 — DISCOVERY  (read-only, nothing is touched)
#===============================================================================
echo ""
echo "=========================================="
echo "  Phase 1: Discovery"
echo "=========================================="
echo ""

# ─── Parse systemd unit ─────────────────────────────────────────────────────
GITEA_WORK_DIR="$(sed -n \
    's/^[[:space:]]*WorkingDirectory[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' \
    "$UNIT_FILE" | head -1)"
[ -n "$GITEA_WORK_DIR" ] || die "WorkingDirectory= not found in ${UNIT_FILE}"

EXEC_LINE="$(sed -n \
    's/^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*//p' \
    "$UNIT_FILE" | head -1)" || EXEC_LINE=""
RUN_USER="$(sed -n \
    's/^[[:space:]]*User[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' \
    "$UNIT_FILE" | head -1)" || RUN_USER=""
RUN_GROUP="$(sed -n \
    's/^[[:space:]]*Group[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' \
    "$UNIT_FILE" | head -1)" || RUN_GROUP=""

# Config path: try ExecStart flags, then fallbacks
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
[ -n "$GITEA_CONF" ] && [ -f "$GITEA_CONF" ] \
    || die "Could not locate app.ini anywhere."

# Print unit info
echo "── Systemd Unit ──────────────────────────"
check_file "Unit file"   "$UNIT_FILE" || true
echo "  ExecStart:            ${EXEC_LINE:-(not found)}"
echo "  User:                 ${RUN_USER:-(not set)}"
echo "  Group:                ${RUN_GROUP:-(not set)}"
echo ""

# ─── Scan all known paths ────────────────────────────────────────────────────
# Helpers: register a found path into the temp-file lists

register_file() {
    if check_file "$1" "$2"; then
        printf '%s\n' "$2" >> "$FOUND_FILES_LIST"
    fi
}
register_dir() {
    if check_dir "$1" "$2"; then
        printf '%s\n' "$2" >> "$FOUND_DIRS_LIST"
    fi
}

count_lines() {
    if [ -s "$1" ]; then
        wc -l < "$1" | tr -d '[:space:]'
    else
        printf '0'
    fi
}

# --- Working directory ---
echo "── Working Directory ─────────────────────"
check_dir "WorkingDirectory" "$GITEA_WORK_DIR" \
    || die "WorkingDirectory missing: ${GITEA_WORK_DIR}"
echo ""

# --- Config file ---
echo "── Config File ───────────────────────────"
register_file "app.ini" "$GITEA_CONF"
echo ""

# --- Top-level subdirectories ---
echo "── Standard Subdirectories ───────────────"
register_dir "custom/"        "${GITEA_WORK_DIR}/custom"
register_dir "data/"          "${GITEA_WORK_DIR}/data"
register_dir "repositories/"  "${GITEA_WORK_DIR}/repositories"

case "$BACKUP_LOGS" in
    [Yy][Ee][Ss]|[Yy])
        register_dir "log/" "${GITEA_WORK_DIR}/log"
        ;;
    *)
        check_dir "log/ (skip)" "${GITEA_WORK_DIR}/log" || true
        ;;
esac
echo ""

# --- Inside data/ ---
echo "── Inside data/ ──────────────────────────"
if [ -d "${GITEA_WORK_DIR}/data" ]; then
    for sub in attachments avatars repo-avatars lfs packages indexers \
               queues sessions tmp; do
        check_dir "${sub}/" "${GITEA_WORK_DIR}/data/${sub}" || true
    done
    for db in gitea.db gitea.db-wal gitea.db-shm; do
        check_file "${db}" "${GITEA_WORK_DIR}/data/${db}" || true
    done
else
    echo "  (data/ not found — skipping scan)"
fi
echo ""

# --- Inside custom/ ---
echo "── Inside custom/ ────────────────────────"
if [ -d "${GITEA_WORK_DIR}/custom" ]; then
    for sub in conf templates public options options/label options/locale; do
        check_dir "${sub}/" "${GITEA_WORK_DIR}/custom/${sub}" || true
    done
    check_file "conf/app.ini" "${GITEA_WORK_DIR}/custom/conf/app.ini" || true
else
    echo "  (custom/ not found — skipping scan)"
fi
echo ""

# --- Service status ---
echo "── Service Status ────────────────────────"
if systemctl is-active --quiet "${GITEA_SERVICE}" 2>/dev/null; then
    echo "  ${GITEA_SERVICE} is RUNNING"
else
    echo "  ${GITEA_SERVICE} is STOPPED"
fi
echo ""

# ─── Summary of what will be backed up ───────────────────────────────────────
FILE_COUNT="$(count_lines "$FOUND_FILES_LIST")"
DIR_COUNT="$(count_lines "$FOUND_DIRS_LIST")"

echo "── Backup Plan ─────────────────────────"
echo "  Files to copy : ${FILE_COUNT}"
echo "  Dirs to copy  : ${DIR_COUNT}"
echo "  Archive dest  : ${BACKUP_ROOT}/${ARCHIVE_NAME}"
echo "  Retention     : ${RETENTION_DAYS} days"
echo ""

if [ "$FILE_COUNT" -eq 0 ] && [ "$DIR_COUNT" -eq 0 ]; then
    die "Nothing found to back up!"
fi

#===============================================================================
#  PHASE 2 — BACKUP  (stops service, copies, archives, restarts)
#===============================================================================
echo "=========================================="
echo "  Phase 2: Backup"
echo "=========================================="
echo ""

# ─── Stop Gitea ──────────────────────────────────────────────────────────────
log "Stopping ${GITEA_SERVICE} …"
systemctl stop "${GITEA_SERVICE}"

# Override trap: always restart the service AND clean temp files on exit
trap 'log "Restarting ${GITEA_SERVICE} …"; systemctl start "${GITEA_SERVICE}"; log "Service started."; cleanup_temp' EXIT

# ─── Create staging directory ────────────────────────────────────────────────
mkdir -p "${BACKUP_DIR}"
log "Staging directory: ${BACKUP_DIR}"

# ─── Copy discovered files ───────────────────────────────────────────────────
while IFS= read -r f; do
    log "Copying file: ${f}"
    cp -p "$f" "${BACKUP_DIR}/"
done < "$FOUND_FILES_LIST"

# ─── Copy discovered directories ─────────────────────────────────────────────
while IFS= read -r d; do
    dir_name="$(basename "$d")"
    log "Copying dir:  ${d}  →  ${BACKUP_DIR}/${dir_name}/"
    cp -pR "$d" "${BACKUP_DIR}/${dir_name}"
done < "$FOUND_DIRS_LIST"

# ─── Create compressed archive ───────────────────────────────────────────────
# NOTE: --same-owner, --acls, --xattrs are GNU tar extensions
log "Creating archive: ${BACKUP_ROOT}/${ARCHIVE_NAME}"
tar -czf "${BACKUP_ROOT}/${ARCHIVE_NAME}" \
    -C "${BACKUP_ROOT}" \
    --same-owner \
    --preserve-permissions \
    --acls \
    --xattrs \
    "${TIMESTAMP}"

# Clean up staging
rm -rf "${BACKUP_DIR}"
log "Staging directory removed."

# ─── Prune old backups ───────────────────────────────────────────────────────
if [ "${RETENTION_DAYS}" -gt 0 ]; then
    log "Pruning backups older than ${RETENTION_DAYS} days …"
    find "${BACKUP_ROOT}" -maxdepth 1 -name 'gitea-backup-*.tar.gz' \
         -type f -mtime +"${RETENTION_DAYS}" -exec rm -f {} \; -print \
    | while IFS= read -r old; do log "  deleted: ${old}"; done
fi

echo ""
echo "=========================================="
log "Backup complete → ${BACKUP_ROOT}/${ARCHIVE_NAME}"
echo "=========================================="
echo ""
