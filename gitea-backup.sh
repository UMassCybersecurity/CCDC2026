#!/usr/bin/env bash
#===============================================================================
#  gitea-backup.sh — Dynamic discovery + archive backup of Gitea (systemd)
#
#  1. Reads all paths from the gitea.service unit file
#  2. Scans for every known file/directory inside the working directory
#  3. Backs up ONLY what actually exists
#  4. Preserves ownership, permissions, ACLs, xattrs
#
#  Requires: root
#===============================================================================
set -euo pipefail

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

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date +%T)" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

# Check a path, print status, return 0 (found) or 1 (missing)
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
[[ $EUID -eq 0 ]]             || die "Must be run as root."
command -v systemctl &>/dev/null || die "'systemctl' not found."
command -v tar       &>/dev/null || die "'tar' not found."
[[ -f "$UNIT_FILE" ]]         || die "Unit file not found: ${UNIT_FILE}"

#===============================================================================
#  PHASE 1 — DISCOVERY  (read-only, nothing is touched)
#===============================================================================
echo ""
echo "=========================================="
echo "  Phase 1: Discovery"
echo "=========================================="
echo ""

# ─── Parse systemd unit ─────────────────────────────────────────────────────
GITEA_WORK_DIR="$(grep -Po '^\s*WorkingDirectory\s*=\s*\K\S+' "$UNIT_FILE" | head -1)"
[[ -n "$GITEA_WORK_DIR" ]] || die "WorkingDirectory= not found in ${UNIT_FILE}"

EXEC_LINE="$(grep -Po '^\s*ExecStart\s*=\s*\K.*' "$UNIT_FILE" | head -1)" || true
RUN_USER="$(grep -Po '^\s*User\s*=\s*\K\S+'  "$UNIT_FILE" | head -1)" || true
RUN_GROUP="$(grep -Po '^\s*Group\s*=\s*\K\S+' "$UNIT_FILE" | head -1)" || true

# Config path: try ExecStart flags, then fallbacks
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
[[ -n "$GITEA_CONF" && -f "$GITEA_CONF" ]] \
    || die "Could not locate app.ini anywhere."

# Print unit info
echo "── Systemd Unit ──────────────────────────"
check_file "Unit file"   "$UNIT_FILE" || true
echo "  ExecStart:            ${EXEC_LINE:-(not found)}"
echo "  User:                 ${RUN_USER:-(not set)}"
echo "  Group:                ${RUN_GROUP:-(not set)}"
echo ""

# ─── Scan all known paths ────────────────────────────────────────────────────
# We'll collect every FOUND path into arrays so Phase 2 knows exactly what to copy

FOUND_FILES=()     # individual files to back up
FOUND_DIRS=()      # directories to back up
FOUND_LABELS=()    # human label for each (used in logs)
FOUND_TYPES=()     # "file" or "dir" for each entry

# Helper: register a found path
register_file() {
    local label="$1" path="$2"
    if check_file "$label" "$path"; then
        FOUND_FILES+=("$path")
        FOUND_LABELS+=("$label")
        FOUND_TYPES+=("file")
    fi
}
register_dir() {
    local label="$1" path="$2"
    if check_dir "$label" "$path"; then
        FOUND_DIRS+=("$path")
        FOUND_LABELS+=("$label")
        FOUND_TYPES+=("dir")
    fi
}

# --- Working directory ---
echo "── Working Directory ─────────────────────"
check_dir "WorkingDirectory" "$GITEA_WORK_DIR" || die "WorkingDirectory missing: ${GITEA_WORK_DIR}"
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
if [[ "${BACKUP_LOGS,,}" == "yes" ]]; then
    register_dir "log/"       "${GITEA_WORK_DIR}/log"
else
    check_dir    "log/ (skip)" "${GITEA_WORK_DIR}/log" || true
fi
echo ""

# --- Inside data/ ---
echo "── Inside data/ ──────────────────────────"
if [[ -d "${GITEA_WORK_DIR}/data" ]]; then
    for sub in attachments avatars repo-avatars lfs packages indexers queues sessions tmp; do
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
if [[ -d "${GITEA_WORK_DIR}/custom" ]]; then
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
echo "── Backup Plan ─────────────────────────"
echo "  Files to copy : ${#FOUND_FILES[@]}"
echo "  Dirs to copy  : ${#FOUND_DIRS[@]}"
echo "  Archive dest  : ${BACKUP_ROOT}/${ARCHIVE_NAME}"
echo "  Retention     : ${RETENTION_DAYS} days"
echo ""

if [[ ${#FOUND_FILES[@]} -eq 0 && ${#FOUND_DIRS[@]} -eq 0 ]]; then
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

# Always restart on exit
trap 'log "Restarting ${GITEA_SERVICE} …"; systemctl start "${GITEA_SERVICE}"; log "Service started."' EXIT

# ─── Create staging directory ────────────────────────────────────────────────
mkdir -p "${BACKUP_DIR}"
log "Staging directory: ${BACKUP_DIR}"

# ─── Copy discovered files ───────────────────────────────────────────────────
for f in "${FOUND_FILES[@]}"; do
    log "Copying file: ${f}"
    cp -a "$f" "${BACKUP_DIR}/"
done

# ─── Copy discovered directories ─────────────────────────────────────────────
for d in "${FOUND_DIRS[@]}"; do
    # Get just the directory name to use as the destination folder name
    dir_name="$(basename "$d")"
    log "Copying dir:  ${d}  →  ${BACKUP_DIR}/${dir_name}/"
    cp -a "$d" "${BACKUP_DIR}/${dir_name}"
done

# ─── Create compressed archive ───────────────────────────────────────────────
log "Creating archive: ${BACKUP_ROOT}/${ARCHIVE_NAME}"
tar \
    --create \
    --gzip \
    --file="${BACKUP_ROOT}/${ARCHIVE_NAME}" \
    --directory="${BACKUP_ROOT}" \
    --same-owner \
    --preserve-permissions \
    --acls \
    --xattrs \
    "${TIMESTAMP}"

# Clean up staging
rm -rf "${BACKUP_DIR}"
log "Staging directory removed."

# ─── Prune old backups ───────────────────────────────────────────────────────
if [[ "${RETENTION_DAYS}" -gt 0 ]]; then
    log "Pruning backups older than ${RETENTION_DAYS} days …"
    find "${BACKUP_ROOT}" -maxdepth 1 -name 'gitea-backup-*.tar.gz' \
         -type f -mtime +"${RETENTION_DAYS}" -delete -print \
    | while read -r f; do log "  deleted: ${f}"; done
fi

echo ""
echo "=========================================="
log "Backup complete → ${BACKUP_ROOT}/${ARCHIVE_NAME}"
echo "=========================================="
echo ""