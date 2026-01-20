#!/bin/sh

unset PATH
PATH="/bin:/sbin:/usr/bin:/usr/sbin"
export PATH

set -f
set -u
umask 077

CONFIG_SRC="/conf/config.xml"
BASE_DIR="/root/pf_backup"

BACKUP_DIR="${BASE_DIR}/backups"
HASH_DIR="${BASE_DIR}/hashes"
LOG_DIR="${BASE_DIR}/logs"

DATE="$(date +%Y%m%d_%H%M%S)"
TMP_FILE="${BACKUP_DIR}/.${HOST}_${DATE}.tmp"
FINAL_FILE="${BACKUP_DIR}/${HOST}_${DATE}.xml"
HASH_FILE="${HASH_DIR}/${HOST}_${DATE}.sha256"
LOG_FILE="${LOG_DIR}/backup.log"

if [ "$(id -u)" -ne 0 ]; then
    exit 1
fi

if [ ! -f "$CONFIG_SRC" ]; then
    exit 1
fi

for d in "$BACKUP_DIR" "$HASH_DIR" "$LOG_DIR"; do
    if [ ! -d "$d" ]; then
        mkdir -p "$d" || exit 1
    fi
done

cp -p "$CONFIG_SRC" "$TMP_FILE" || exit 1

if ! /usr/local/bin/xmllint --noout "$TMP_FILE" >/dev/null 2>&1; then
    echo "$(date) XML validation failed" >> "$LOG_FILE"
    rm -f "$TMP_FILE"
    exit 1
fi

mv -f "$TMP_FILE" "$FINAL_FILE" || exit 1
gzip -9 "$FINAL_FILE" || exit 1
s
FINAL_FILE="${FINAL_FILE}.gz"
sha256 "$FINAL_FILE" > "$HASH_FILE" || exit 1
eixt0