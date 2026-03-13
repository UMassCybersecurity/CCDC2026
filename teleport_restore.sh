#!/bin/bash
# =============================================================================
# teleport_restore.sh
# Rebuilds a Teleport service from a backup archive produced by teleport_backup.sh
# Run as root on the target VM.
# Usage: sudo bash teleport_restore.sh <backup_archive.tar.gz>
# =============================================================================

set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
log()     { echo "[$(date '+%H:%M:%S')] $*"; }
warn()    { echo "[$(date '+%H:%M:%S')] WARNING: $*" >&2; }
die()     { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }
confirm() {
  read -rp "[$(date '+%H:%M:%S')] $* [y/N] " ans
  [[ "${ans,,}" == "y" ]]
}

require_root() {
  [[ $EUID -eq 0 ]] || die "This script must be run as root (sudo)."
}

yaml_get() {
  local key="$1"
  local file="$2"
  grep -m1 "${key}:" "$file" 2>/dev/null \
    | sed 's/.*:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs
}

# ── Preflight ─────────────────────────────────────────────────────────────────
require_root

ARCHIVE="${1:-}"
[[ -n "$ARCHIVE" ]] || die "Usage: sudo bash teleport_restore.sh <backup_archive.tar.gz>"
[[ -f "$ARCHIVE"  ]] || die "Archive not found: $ARCHIVE"

# Verify checksum if present
SHA256_FILE="${ARCHIVE}.sha256"
if [[ -f "$SHA256_FILE" ]]; then
  log "Verifying archive integrity..."
  sha256sum -c "$SHA256_FILE" || die "Checksum mismatch — archive may be corrupted or tampered."
  log "  Checksum OK"
else
  warn "No .sha256 file found alongside archive — skipping integrity check."
fi

# ── Extract ───────────────────────────────────────────────────────────────────
STAGING_DIR="/tmp/teleport_restore_$$"
mkdir -p "$STAGING_DIR"
log "Extracting archive..."
# --numeric-owner restores original UID/GID rather than mapping by name
tar --numeric-owner -xzf "$ARCHIVE" -C "$STAGING_DIR"

BACKUP_ROOT=$(find "$STAGING_DIR" -maxdepth 1 -mindepth 1 -type d | head -n1)
[[ -d "$BACKUP_ROOT" ]] || die "Could not find backup root inside archive."
log "Backup root: $BACKUP_ROOT"

FILES_ROOT="$BACKUP_ROOT/files"
[[ -d "$FILES_ROOT" ]] || die "No 'files/' directory found in archive — is this a valid backup?"

# ── Show metadata ─────────────────────────────────────────────────────────────
if [[ -f "$BACKUP_ROOT/metadata.txt" ]]; then
  log "--- Backup Info ---"
  grep -E "Date|Hostname|Data Dir" "$BACKUP_ROOT/metadata.txt" | sed 's/^/  /'
  echo ""
fi

# ── Detect Teleport version from backup ───────────────────────────────────────
BACKUP_VERSION=$(grep -A1 "Teleport Version" "$BACKUP_ROOT/metadata.txt" 2>/dev/null \
  | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)

# ── Install Teleport if needed ────────────────────────────────────────────────
log "--- Checking Teleport installation ---"
if command -v teleport &>/dev/null; then
  INSTALLED_VERSION=$(teleport version 2>/dev/null \
    | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
  log "  Installed: v${INSTALLED_VERSION}"
  if [[ -n "$BACKUP_VERSION" && "$INSTALLED_VERSION" != "$BACKUP_VERSION" ]]; then
    warn "Installed version (v${INSTALLED_VERSION}) differs from backup version (v${BACKUP_VERSION})."
    confirm "Continue anyway?" || die "Aborted by user."
  fi
else
  if [[ -n "$BACKUP_VERSION" ]]; then
    log "  Installing Teleport v${BACKUP_VERSION}..."
    curl -fsSL https://goteleport.com/static/install.sh | bash -s "${BACKUP_VERSION}"
  else
    warn "Could not determine backup version from metadata.txt."
    die "Install Teleport manually then re-run this script."
  fi
fi

# ── Stop running Teleport ─────────────────────────────────────────────────────
log "--- Stopping Teleport service ---"
if systemctl is-active --quiet teleport 2>/dev/null; then
  systemctl stop teleport
  log "  Stopped"
else
  log "  Not running"
fi

# ── Safety snapshot of existing data ─────────────────────────────────────────
# Read the data_dir from the backed-up config so we know what to move aside
BACKED_UP_CONFIG="${FILES_ROOT}/etc/teleport.yaml"
if [[ -f "$BACKED_UP_CONFIG" ]]; then
  DATA_DIR=$(yaml_get "data_dir" "$BACKED_UP_CONFIG")
fi
DATA_DIR="${DATA_DIR:-/var/lib/teleport}"

if [[ -d "$DATA_DIR" ]]; then
  SNAPSHOT="${DATA_DIR}.pre-restore.$$"
  warn "Existing data dir found at $DATA_DIR — moving to $SNAPSHOT before restore."
  confirm "Proceed?" || die "Aborted by user."
  mv "$DATA_DIR" "$SNAPSHOT"
  log "  Existing data dir saved to: $SNAPSHOT"
fi

# ── Restore all files ─────────────────────────────────────────────────────────
# The backup mirrors absolute paths under files/, so we copy straight to /.
# cp -a preserves permissions, owner, group, symlinks, and timestamps.
# --numeric-owner on the tar extract already restored original UID/GID,
# so no chown step is needed.
log "--- Restoring all files to / ---"
cp -a "${FILES_ROOT}/." /
log "  Done"

# ── Reload systemd ────────────────────────────────────────────────────────────
log "--- Reloading systemd ---"
systemctl daemon-reload

# ── Start Teleport ────────────────────────────────────────────────────────────
log "--- Starting Teleport ---"
systemctl enable teleport
systemctl start teleport
sleep 3

if systemctl is-active --quiet teleport; then
  log "  Teleport is running"
else
  warn "Teleport failed to start. Check: journalctl -u teleport -n 50"
fi

# ── Re-import cluster resources ───────────────────────────────────────────────
log "--- Re-importing cluster resources ---"
TCTL_DIR="$BACKUP_ROOT/tctl_exports"

if [[ -d "$TCTL_DIR" ]] && command -v tctl &>/dev/null; then
  # Import in dependency order: roles before users, resources last
  IMPORT_ORDER=(roles users tokens apps nodes db kube_cluster windows_desktop)
  for resource in "${IMPORT_ORDER[@]}"; do
    FILE="$TCTL_DIR/${resource}.yaml"
    if [[ -f "$FILE" && -s "$FILE" ]]; then
      if tctl create -f "$FILE" 2>/dev/null; then
        log "  Imported: $resource"
      else
        warn "  Could not import $resource (may already exist or token expired)"
      fi
    fi
  done
else
  warn "No tctl_exports found or tctl unavailable — skipping resource import."
fi

# ── Verify ────────────────────────────────────────────────────────────────────
log "--- Verification ---"
if command -v tctl &>/dev/null; then
  tctl status 2>/dev/null || warn "tctl status failed"
  echo ""
  log "Users:"
  tctl users ls 2>/dev/null | sed 's/^/  /' || warn "Could not list users"
  log "Apps:"
  tctl apps ls  2>/dev/null | sed 's/^/  /' || warn "Could not list apps"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -rf "$STAGING_DIR"

log ""
log "=== Restore Complete ==="
log "Users will need to re-authenticate:"
log "  tsh login --proxy=<this-host>"
log ""
log "If join tokens expired, regenerate:"
log "  tctl tokens add --type=node,app --ttl=1h"
log ""
log "Check logs if anything looks wrong:"
log "  journalctl -u teleport -f"
