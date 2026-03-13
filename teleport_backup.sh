#!/bin/bash
# =============================================================================
# teleport_backup.sh
# Backs up all Teleport data needed to fully rebuild the service.
# Run as root on the Teleport VM.
# Usage: sudo bash teleport_backup.sh [output_dir]
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_NAME="teleport_backup_${TIMESTAMP}"
OUTPUT_DIR="${1:-/tmp}"
STAGING_DIR="/tmp/${BACKUP_NAME}"
FINAL_ARCHIVE="${OUTPUT_DIR}/${BACKUP_NAME}.tar.gz"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARNING: $*" >&2; }
die()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "This script must be run as root (sudo)."
}

# Copy a file or directory into staging, mirroring its absolute path.
# Preserves permissions, owner, and group via cp -a.
safe_copy() {
  local src="$1"
  local dst="${STAGING_DIR}/files${src}"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    log "  Backed up: $src"
  else
    warn "Not found, skipping: $src"
  fi
}

# Parse a scalar value from teleport.yaml (no yq dependency).
yaml_get() {
  local key="$1"
  local file="${2:-/etc/teleport.yaml}"
  grep -m1 "${key}:" "$file" 2>/dev/null \
    | sed 's/.*:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs
}

# ── Preflight ─────────────────────────────────────────────────────────────────
require_root
[[ -f /etc/teleport.yaml ]] || die "/etc/teleport.yaml not found."
mkdir -p "$STAGING_DIR"
log "=== Teleport Backup Started ==="
log "Staging dir : $STAGING_DIR"
log "Output file : $FINAL_ARCHIVE"

# ── 1. Config ─────────────────────────────────────────────────────────────────
log "--- Backing up config ---"
safe_copy /etc/teleport.yaml
[[ -d /etc/teleport.d ]] && safe_copy /etc/teleport.d

# ── 2. Data directory ─────────────────────────────────────────────────────────
log "--- Backing up data dir ---"
DATA_DIR=$(yaml_get "data_dir")
DATA_DIR="${DATA_DIR:-/var/lib/teleport}"

if [[ -d "$DATA_DIR" ]]; then
  mkdir -p "${STAGING_DIR}/files${DATA_DIR}"
  # rsync -a preserves permissions, owner, group, symlinks, timestamps
  # Exclude audit logs to keep archive size manageable
  rsync -a --exclude='log/' --exclude='*.log' \
    "${DATA_DIR}/" "${STAGING_DIR}/files${DATA_DIR}/" \
    2>/dev/null || cp -a "${DATA_DIR}/." "${STAGING_DIR}/files${DATA_DIR}/"
  log "  Backed up: $DATA_DIR (audit logs excluded)"
else
  warn "Data directory not found: $DATA_DIR"
fi

# ── 3. TLS certificates (paths read directly from teleport.yaml) ──────────────
log "--- Backing up TLS certificates ---"

# Extract every key_file and cert_file value — works regardless of filename
mapfile -t CERT_FILES < <(
  grep -E '^\s*(key_file|cert_file):' /etc/teleport.yaml \
    | sed 's/.*:[[:space:]]*//' \
    | tr -d '"' | tr -d "'" \
    | xargs -I{} realpath -m {} 2>/dev/null \
  || true
)

if [[ ${#CERT_FILES[@]} -eq 0 ]]; then
  warn "No key_file/cert_file entries found in teleport.yaml — skipping cert backup."
else
  for cert in "${CERT_FILES[@]}"; do
    safe_copy "$cert"
  done
fi

# Check common cert dirs that may sit outside the data dir
for dir in /etc/letsencrypt/live /etc/ssl/teleport /opt/teleport/certs; do
  [[ -d "$dir" ]] && safe_copy "$dir"
done

# ── 4. Cluster resource export via tctl ───────────────────────────────────────
log "--- Exporting cluster resources via tctl ---"
TCTL_DIR="$STAGING_DIR/tctl_exports"
mkdir -p "$TCTL_DIR"

if command -v tctl &>/dev/null; then
  RESOURCES=(users roles tokens apps nodes db kube_cluster windows_desktop)
  for resource in "${RESOURCES[@]}"; do
    OUTPUT_FILE="$TCTL_DIR/${resource}.yaml"
    if tctl get "$resource" > "$OUTPUT_FILE" 2>/dev/null; then
      [[ -s "$OUTPUT_FILE" ]] && log "  Exported: $resource" || rm -f "$OUTPUT_FILE"
    else
      warn "  Could not export: $resource (may not exist or insufficient perms)"
      rm -f "$OUTPUT_FILE"
    fi
  done
else
  warn "tctl not found in PATH — skipping cluster resource export."
fi

# ── 5. Systemd unit ───────────────────────────────────────────────────────────
log "--- Backing up systemd unit ---"
[[ -f /lib/systemd/system/teleport.service ]]  && safe_copy /lib/systemd/system/teleport.service
[[ -f /etc/systemd/system/teleport.service ]]  && safe_copy /etc/systemd/system/teleport.service

# ── 6. System metadata ────────────────────────────────────────────────────────
log "--- Capturing system metadata ---"
META_FILE="$STAGING_DIR/metadata.txt"
{
  echo "=== Backup Metadata ==="
  echo "Date        : $(date)"
  echo "Hostname    : $(hostname)"
  echo "Uptime      : $(uptime)"
  echo "Data Dir    : ${DATA_DIR}"
  echo ""
  echo "=== TLS Cert Paths (from teleport.yaml) ==="
  grep -E '(key_file|cert_file):' /etc/teleport.yaml || echo "none found"
  echo ""
  echo "=== Teleport Version ==="
  teleport version 2>/dev/null || echo "teleport binary not in PATH"
  echo ""
  echo "=== Teleport Service Status ==="
  systemctl status teleport --no-pager 2>/dev/null || echo "systemctl unavailable"
  echo ""
  echo "=== Listening Ports ==="
  ss -tlnp | grep -E '443|3025|3080|3022|3024' || true
  echo ""
  echo "=== Network Interfaces ==="
  ip addr show
  echo ""
  echo "=== WireGuard Status ==="
  wg show 2>/dev/null || echo "wireguard not available"
} > "$META_FILE"
log "  Written: $META_FILE"

# ── 7. Restore instructions ───────────────────────────────────────────────────
CERT_PATHS_SNAPSHOT=$(grep -E '(key_file|cert_file):' /etc/teleport.yaml 2>/dev/null || echo "  (see teleport.yaml)")

cat > "$STAGING_DIR/RESTORE.md" << EOF
# Teleport Restore Instructions

## Archive Layout
All backed-up system files are stored under \`files/\` mirroring their absolute
paths on disk. For example, \`/etc/teleport.yaml\` lives at
\`files/etc/teleport.yaml\` inside this archive.

Restoring is therefore a single recursive copy back to \`/\`.

## TLS Cert Paths at Backup Time
${CERT_PATHS_SNAPSHOT}

## Data Directory at Backup Time
${DATA_DIR}

## Steps

### 1. Install Teleport (match version in metadata.txt)
\`\`\`bash
curl https://goteleport.com/static/install.sh | bash -s <version>
\`\`\`

### 2. Stop any running Teleport instance
\`\`\`bash
systemctl stop teleport
\`\`\`

### 3. Restore all files — permissions, owner, and group are preserved automatically
\`\`\`bash
cp -a files/. /
\`\`\`

### 4. Reload systemd and start Teleport
\`\`\`bash
systemctl daemon-reload
systemctl enable teleport
systemctl start teleport
systemctl status teleport
\`\`\`

### 5. Re-import cluster resources
\`\`\`bash
for f in tctl_exports/*.yaml; do
  tctl create -f "\$f" && echo "Imported: \$f"
done
\`\`\`

### 6. Verify
\`\`\`bash
tctl status
tctl users ls
tctl apps ls
\`\`\`

## Notes
- Users will need to re-authenticate after restore (new session certs will be issued)
- Join tokens in tctl_exports/tokens.yaml are time-limited — regenerate with:
    tctl tokens add --type=node,app --ttl=1h
- If CA keys are suspected compromised, do NOT restore the data dir;
  let Teleport generate a fresh CA and re-enroll all users manually
EOF

log "  Written: RESTORE.md"

# ── 8. Package ────────────────────────────────────────────────────────────────
log "--- Creating archive ---"
mkdir -p "$OUTPUT_DIR"
# --numeric-owner stores numeric UID/GID so ownership survives across systems
tar --numeric-owner -czf "$FINAL_ARCHIVE" -C /tmp "$BACKUP_NAME"
rm -rf "$STAGING_DIR"

sha256sum "$FINAL_ARCHIVE" > "${FINAL_ARCHIVE}.sha256"

log "=== Backup Complete ==="
log "Archive : $FINAL_ARCHIVE"
log "SHA256  : $(cat ${FINAL_ARCHIVE}.sha256)"
log ""
log "To copy off this machine (run from your machine):"
log "  scp root@<teleport-vm-ip>:${FINAL_ARCHIVE} ./"
log "  scp root@<teleport-vm-ip>:${FINAL_ARCHIVE}.sha256 ./"
