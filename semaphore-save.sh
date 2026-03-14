#!/usr/bin/env bash
# =============================================================================
# semaphore_backup.sh
# Archives Semaphore UI configs, playbooks, and backend database.
# Supports: BoltDB (embedded), SQLite, MySQL, PostgreSQL
# Usage: sudo ./semaphore_backup.sh [--output-dir /path/to/backups]
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults — override via environment variables or --output-dir flag
# ---------------------------------------------------------------------------
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/semaphore}"
SEMAPHORE_CONFIG_PATHS=(
	"/etc/semaphore"
	"$HOME/.semaphore"
	"/opt/semaphore"
	"/usr/local/etc/semaphore"
)
SEMAPHORE_CONFIG_FILE="" # resolved below
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
ARCHIVE_NAME="semaphore_backup_${TIMESTAMP}.tar.gz"
STAGING_DIR="$(mktemp -d /tmp/semaphore_backup_XXXXXX)"
LOG_FILE="${STAGING_DIR}/backup.log"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log() { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
ok() { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOG_FILE"; }
die() {
	echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE" >&2
	cleanup
	exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
	case "$1" in
	--output-dir | -o)
		BACKUP_ROOT="$2"
		shift 2
		;;
	--help | -h)
		echo "Usage: $0 [--output-dir /path/to/backups]"
		echo "  Env vars: BACKUP_ROOT, SEMAPHORE_DB_PASSWORD (for MySQL/Postgres)"
		exit 0
		;;
	*) die "Unknown argument: $1" ;;
	esac
done

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
cleanup() {
	log "Cleaning up staging directory..."
	rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
require_cmd() {
	command -v "$1" &>/dev/null || die "Required command not found: $1. Please install it and retry."
}

find_config_file() {
	# Prefer config.json or config.yaml under known paths
	for dir in "${SEMAPHORE_CONFIG_PATHS[@]}"; do
		for f in "$dir/config.json" "$dir/config.yaml" "$dir/config.yml"; do
			[[ -f "$f" ]] && {
				echo "$f"
				return
			}
		done
	done
	# Fallback: ask systemd for the working directory
	if command -v systemctl &>/dev/null; then
		local svc_dir
		svc_dir="$(systemctl show -p WorkingDirectory semaphore 2>/dev/null | cut -d= -f2 || true)"
		for f in "$svc_dir/config.json" "$svc_dir/config.yaml"; do
			[[ -f "$f" ]] && {
				echo "$f"
				return
			}
		done
	fi
	echo ""
}

json_field() {
	# Minimal JSON field extractor (no jq dependency)
	local file="$1" field="$2"
	grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null |
		head -1 | sed 's/.*: *"\(.*\)"/\1/' || true
}

# ---------------------------------------------------------------------------
# 0. Pre-flight
# ---------------------------------------------------------------------------
log "=== Semaphore UI Backup — ${TIMESTAMP} ==="
require_cmd tar

mkdir -p "$STAGING_DIR/configs"
mkdir -p "$STAGING_DIR/playbooks"
mkdir -p "$STAGING_DIR/database"
mkdir -p "$BACKUP_ROOT"

# ---------------------------------------------------------------------------
# 1. Locate and read config file
# ---------------------------------------------------------------------------
log "Locating Semaphore config file..."
SEMAPHORE_CONFIG_FILE="$(find_config_file)"

if [[ -z "$SEMAPHORE_CONFIG_FILE" ]]; then
	die "Could not locate a Semaphore config file. Set SEMAPHORE_CONFIG_PATHS or pass --output-dir."
fi
ok "Found config: ${SEMAPHORE_CONFIG_FILE}"

# Parse key fields from config.json (YAML support is limited without yq)
DB_DIALECT="$(json_field "$SEMAPHORE_CONFIG_FILE" "dialect" || true)"
DB_HOST="$(json_field "$SEMAPHORE_CONFIG_FILE" "host" || true)"
DB_PORT="$(json_field "$SEMAPHORE_CONFIG_FILE" "port" || true)"
DB_USER="$(json_field "$SEMAPHORE_CONFIG_FILE" "user" || true)"
DB_NAME="$(json_field "$SEMAPHORE_CONFIG_FILE" "name" || true)"
DB_PATH="$(json_field "$SEMAPHORE_CONFIG_FILE" "path" || true)"       # BoltDB
REPOS_DIR="$(json_field "$SEMAPHORE_CONFIG_FILE" "tmp_path" || true)" # repo checkout dir

[[ -z "$DB_DIALECT" ]] && DB_DIALECT="bolt" # default embedded DB
[[ -z "$DB_HOST" ]] && DB_HOST="127.0.0.1"
[[ -z "$DB_PORT" ]] && DB_PORT="3306"
[[ -z "$DB_NAME" ]] && DB_NAME="semaphore"
[[ -z "$REPOS_DIR" ]] && REPOS_DIR="/tmp/semaphore"

log "DB dialect: ${DB_DIALECT}"

# ---------------------------------------------------------------------------
# 2. Archive config files
# ---------------------------------------------------------------------------
log "Archiving configuration files..."

CONFIG_DIR="$(dirname "$SEMAPHORE_CONFIG_FILE")"
cp -a "$CONFIG_DIR"/. "$STAGING_DIR/configs/" 2>/dev/null ||
	warn "Some config files could not be copied (permission issue?)"

# Also grab any systemd unit file if present
UNIT_FILE=""
for f in /etc/systemd/system/semaphore.service \
	/lib/systemd/system/semaphore.service \
	/usr/lib/systemd/system/semaphore.service; do
	if [[ -f "$f" ]]; then
		cp "$f" "$STAGING_DIR/configs/"
		UNIT_FILE="$f"
		ok "Copied systemd unit: $f"
		break
	fi
done

ok "Configuration files archived."

# ---------------------------------------------------------------------------
# 3. Archive playbooks / repos
# ---------------------------------------------------------------------------
log "Archiving playbooks and repository checkouts from: ${REPOS_DIR}"

if [[ -d "$REPOS_DIR" ]]; then
	cp -a "$REPOS_DIR"/. "$STAGING_DIR/playbooks/" 2>/dev/null ||
		warn "Some playbook files could not be copied."
	ok "Playbooks archived."
else
	warn "Playbooks directory '${REPOS_DIR}' not found — skipping."
fi

# ---------------------------------------------------------------------------
# 4. Database backup
# ---------------------------------------------------------------------------
log "Backing up database (dialect: ${DB_DIALECT})..."

case "${DB_DIALECT,,}" in

# ---- BoltDB (embedded, default) ----------------------------------------
bolt | boltdb)
	BOLT_FILE="${DB_PATH:-/var/lib/semaphore/database.boltdb}"
	[[ -z "$DB_PATH" ]] && warn "BoltDB path not in config; trying default: ${BOLT_FILE}"
	if [[ -f "$BOLT_FILE" ]]; then
		cp "$BOLT_FILE" "$STAGING_DIR/database/database.boltdb"
		ok "BoltDB file copied."
	else
		# Try common alternative locations
		for candidate in \
			/opt/semaphore/database.boltdb \
			"$HOME/.semaphore/database.boltdb" \
			/var/lib/semaphore/database.boltdb; do
			if [[ -f "$candidate" ]]; then
				cp "$candidate" "$STAGING_DIR/database/database.boltdb"
				ok "BoltDB found at ${candidate} and copied."
				break
			fi
		done
		[[ -f "$STAGING_DIR/database/database.boltdb" ]] ||
			warn "BoltDB file not found. Skipping database backup."
	fi
	;;

# ---- MySQL / MariaDB ----------------------------------------------------
mysql | mariadb)
	require_cmd mysqldump
	DB_PORT="${DB_PORT:-3306}"
	DUMP_FILE="$STAGING_DIR/database/${DB_NAME}_${TIMESTAMP}.sql"

	log "Running mysqldump for database '${DB_NAME}' on ${DB_HOST}:${DB_PORT}..."

	MYSQL_PASS="${SEMAPHORE_DB_PASSWORD:-}"
	if [[ -z "$MYSQL_PASS" ]]; then
		warn "SEMAPHORE_DB_PASSWORD not set. Attempting passwordless dump or reading ~/.my.cnf."
	fi

	MYSQL_PWD="$MYSQL_PASS" mysqldump \
		--host="$DB_HOST" \
		--port="$DB_PORT" \
		--user="${DB_USER:-semaphore}" \
		--single-transaction \
		--routines \
		--triggers \
		--add-drop-table \
		"$DB_NAME" >"$DUMP_FILE" ||
		die "mysqldump failed. Ensure credentials are correct (set SEMAPHORE_DB_PASSWORD)."

	ok "MySQL dump written to: ${DUMP_FILE}"
	;;

# ---- PostgreSQL ---------------------------------------------------------
postgres | postgresql)
	require_cmd pg_dump
	DB_PORT="${DB_PORT:-5432}"
	DUMP_FILE="$STAGING_DIR/database/${DB_NAME}_${TIMESTAMP}.sql"

	log "Running pg_dump for database '${DB_NAME}' on ${DB_HOST}:${DB_PORT}..."

	PGPASSWORD="${SEMAPHORE_DB_PASSWORD:-}" pg_dump \
		--host="$DB_HOST" \
		--port="$DB_PORT" \
		--username="${DB_USER:-semaphore}" \
		--format=plain \
		--no-password \
		"$DB_NAME" >"$DUMP_FILE" ||
		die "pg_dump failed. Ensure credentials are correct (set SEMAPHORE_DB_PASSWORD)."

	ok "PostgreSQL dump written to: ${DUMP_FILE}"
	;;

# ---- SQLite -------------------------------------------------------------
sqlite | sqlite3)
	SQLITE_FILE="${DB_PATH:-}"
	if [[ -z "$SQLITE_FILE" ]]; then
		# Fallback: probe common locations
		for candidate in \
			/var/lib/semaphore/semaphore.db \
			/opt/semaphore/semaphore.db \
			"$HOME/.semaphore/semaphore.db"; do
			if [[ -f "$candidate" ]]; then
				SQLITE_FILE="$candidate"
				break
			fi
		done
	fi

	if [[ -z "$SQLITE_FILE" || ! -f "$SQLITE_FILE" ]]; then
		warn "SQLite database file not found. Skipping database backup."
	else
		DUMP_FILE="$STAGING_DIR/database/$(basename "${SQLITE_FILE%.*}")_${TIMESTAMP}.sql"

		# Prefer sqlite3 CLI for a portable SQL dump; fall back to raw file copy
		if command -v sqlite3 &>/dev/null; then
			log "Dumping SQLite database via sqlite3: ${SQLITE_FILE}"
			sqlite3 "$SQLITE_FILE" .dump >"$DUMP_FILE" ||
				die "sqlite3 dump failed for: ${SQLITE_FILE}"
			ok "SQLite SQL dump written to: ${DUMP_FILE}"
		else
			warn "sqlite3 CLI not found — falling back to raw file copy."
			cp -a "$SQLITE_FILE" "$STAGING_DIR/database/$(basename "$SQLITE_FILE")"
			ok "SQLite raw file copied from: ${SQLITE_FILE}"
		fi

		# Always include the raw binary alongside the dump for safety
		if [[ -f "$DUMP_FILE" ]]; then
			cp -a "$SQLITE_FILE" "$STAGING_DIR/database/$(basename "$SQLITE_FILE").bak"
			log "SQLite raw binary also copied as a safety fallback."
		fi
	fi
	;;

*)
	warn "Unrecognised DB dialect '${DB_DIALECT}'. Skipping database backup."
	;;
esac

# ---------------------------------------------------------------------------
# 5. Write a backup manifest
# ---------------------------------------------------------------------------
MANIFEST="$STAGING_DIR/MANIFEST.txt"
cat >"$MANIFEST" <<EOF
Semaphore UI Backup Manifest
=============================
Timestamp   : ${TIMESTAMP}
Hostname    : $(hostname)
Generated by: $(basename "$0")
Config file : ${SEMAPHORE_CONFIG_FILE}
DB dialect  : ${DB_DIALECT}
DB name     : ${DB_NAME}
Repos dir   : ${REPOS_DIR}
Systemd unit: ${UNIT_FILE:-not found}

Contents
--------
configs/    — Semaphore configuration files (and systemd unit if present)
playbooks/  — Repository / playbook checkout directory
database/   — DB dump (.sql) and/or raw binary file (BoltDB / SQLite)

Restore notes
-------------
Permissions, timestamps, ownership, and xattrs are preserved in this archive.
Use 'tar --extract --gzip --preserve-permissions --same-owner --xattrs' when restoring.
EOF

ok "Manifest written."

# ---------------------------------------------------------------------------
# 6. Create final compressed archive
# ---------------------------------------------------------------------------
FINAL_ARCHIVE="${BACKUP_ROOT}/${ARCHIVE_NAME}"
log "Creating archive: ${FINAL_ARCHIVE} ..."

tar \
	--create \
	--gzip \
	--preserve-permissions \
	--same-owner \
	--xattrs \
	--file="$FINAL_ARCHIVE" \
	--directory="$STAGING_DIR" \
	.

ARCHIVE_SIZE="$(du -sh "$FINAL_ARCHIVE" | cut -f1)"
ok "Archive created: ${FINAL_ARCHIVE} (${ARCHIVE_SIZE})"

# ---------------------------------------------------------------------------
# 7. Verify archive integrity
# ---------------------------------------------------------------------------
log "Verifying archive integrity..."
tar -tzf "$FINAL_ARCHIVE" >/dev/null &&
	ok "Archive integrity check passed." ||
	die "Archive integrity check FAILED."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}✔ Semaphore UI backup complete!${RESET}"
echo -e "  Archive : ${BOLD}${FINAL_ARCHIVE}${RESET}"
echo -e "  Size    : ${ARCHIVE_SIZE}"
echo -e "  To restore configs  : sudo tar --extract --gzip --preserve-permissions --same-owner --xattrs --file=${ARCHIVE_NAME} --directory=/etc/semaphore/ configs/"
echo -e "  To restore playbooks: sudo tar --extract --gzip --preserve-permissions --same-owner --xattrs --file=${ARCHIVE_NAME} --directory=${REPOS_DIR}/ playbooks/"
echo ""
