#!/bin/sh
# =============================================================================
# install-alloy-freebsd.sh
# Installs Grafana Alloy on FreeBSD as a standalone binary with an RC service.
#
# Alloy is not in the official FreeBSD ports/packages tree. This script
# downloads the pre-built binary from GitHub Releases and wires it up as a
# proper RC service so that it starts automatically on boot.
#
# Requirements: fetch or curl, unzip, shasum or sha256
#
# Usage:
#   sudo sh install-alloy-freebsd.sh [OPTIONS]
#
# Options:
#   -v, --version <tag>   Install a specific version (e.g. v1.13.1)
#                         Default: latest stable release
#   -c, --config  <path>  Path to an existing config file to deploy
#   --arch <amd64|arm64>  Override architecture detection
#   --no-service          Install binary only; do not configure RC service
#   -h, --help            Show this help message
# =============================================================================

set -eu

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

step() { printf "\n${CYAN}==> ${BOLD}%s${RESET}\n" "$*"; }
ok()   { printf "    ${GREEN}[OK]${RESET}  %s\n" "$*"; }
warn() { printf "    ${YELLOW}[WARN]${RESET} %s\n" "$*"; }
fail() { printf "    ${RED}[FAIL]${RESET} %s\n" "$*" >&2; exit 1; }

# ── Argument parsing ───────────────────────────────────────────────────────────
ALLOY_VERSION=""
USER_CONFIG=""
ARCH_OVERRIDE=""
NO_SERVICE=0

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version)  ALLOY_VERSION="$2"; shift 2 ;;
        -c|--config)   USER_CONFIG="$2";   shift 2 ;;
        --arch)        ARCH_OVERRIDE="$2"; shift 2 ;;
        --no-service)  NO_SERVICE=1;       shift   ;;
        -h|--help)
            head -30 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

# ── Root check ─────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || fail "This script must be run as root (use sudo)."

# ── Verify FreeBSD ────────────────────────────────────────────────────────────
step "Verifying FreeBSD"

OS=$(uname -s)
[ "$OS" = "FreeBSD" ] || fail "This script is intended for FreeBSD only (detected: $OS)."
FBSD_VERSION=$(uname -r)
ok "FreeBSD version: $FBSD_VERSION"

# ── Detect architecture ────────────────────────────────────────────────────────
step "Detecting architecture"

if [ -n "$ARCH_OVERRIDE" ]; then
    ARCH="$ARCH_OVERRIDE"
    ok "Using specified architecture: $ARCH"
else
    MACHINE=$(uname -m)
    case "$MACHINE" in
        amd64|x86_64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) fail "Unsupported architecture: $MACHINE (supported: amd64, arm64)" ;;
    esac
    ok "Detected architecture: $ARCH"
fi

# ── Detect download tool ───────────────────────────────────────────────────────
step "Detecting download utility"

if command -v curl >/dev/null 2>&1; then
    FETCH_CMD="curl"
    ok "Using curl"
elif command -v fetch >/dev/null 2>&1; then
    FETCH_CMD="fetch"
    ok "Using fetch (FreeBSD built-in)"
else
    fail "Neither curl nor fetch is available. Install curl: pkg install curl"
fi

download() {
    URL="$1"; DEST="$2"
    if [ "$FETCH_CMD" = "curl" ]; then
        curl -fsSL "$URL" -o "$DEST"
    else
        fetch -q -o "$DEST" "$URL"
    fi
}

# ── Resolve version ────────────────────────────────────────────────────────────
step "Resolving Grafana Alloy version"

if [ -z "$ALLOY_VERSION" ]; then
    API_URL="https://api.github.com/repos/grafana/alloy/releases/latest"
    TMP_JSON="/tmp/alloy-release.json"

    download "$API_URL" "$TMP_JSON"
    # Extract tag_name with grep/sed (no jq dependency)
    ALLOY_VERSION=$(grep '"tag_name"' "$TMP_JSON" | head -1 | sed 's/.*"tag_name": "\([^"]*\)".*/\1/')
    rm -f "$TMP_JSON"

    [ -n "$ALLOY_VERSION" ] || fail "Could not parse version from GitHub API response."
    ok "Latest stable version: $ALLOY_VERSION"
else
    # Ensure leading 'v'
    case "$ALLOY_VERSION" in v*) ;; *) ALLOY_VERSION="v${ALLOY_VERSION}" ;; esac
    ok "Using specified version: $ALLOY_VERSION"
fi

# ── Download binary ────────────────────────────────────────────────────────────
step "Downloading Alloy binary"

BINARY_NAME="alloy-freebsd-${ARCH}"
ZIP_NAME="${BINARY_NAME}.zip"
DOWNLOAD_URL="https://github.com/grafana/alloy/releases/download/${ALLOY_VERSION}/${ZIP_NAME}"
CHECKSUM_URL="https://github.com/grafana/alloy/releases/download/${ALLOY_VERSION}/alloy-freebsd-${ARCH}.zip.sha256"

TMP_DIR=$(mktemp -d /tmp/alloy-install-XXXXXX)
ZIP_PATH="${TMP_DIR}/${ZIP_NAME}"
CHECKSUM_PATH="${TMP_DIR}/${ZIP_NAME}.sha256"

printf "    Downloading from: %s\n" "$DOWNLOAD_URL"
download "$DOWNLOAD_URL" "$ZIP_PATH"
ok "Binary archive downloaded"

# ── Verify checksum ────────────────────────────────────────────────────────────
step "Verifying checksum"

if download "$CHECKSUM_URL" "$CHECKSUM_PATH" 2>/dev/null; then
    EXPECTED=$(awk '{print $1}' "$CHECKSUM_PATH")
    if command -v sha256 >/dev/null 2>&1; then
        ACTUAL=$(sha256 -q "$ZIP_PATH")
    elif command -v shasum >/dev/null 2>&1; then
        ACTUAL=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
    else
        warn "No sha256/shasum found; skipping checksum verification."
        ACTUAL="$EXPECTED"
    fi

    if [ "$ACTUAL" = "$EXPECTED" ]; then
        ok "Checksum verified: $ACTUAL"
    else
        fail "Checksum mismatch!\n  Expected: $EXPECTED\n  Actual:   $ACTUAL"
    fi
else
    warn "Could not download checksum file; skipping verification."
fi

# ── Extract and install binary ─────────────────────────────────────────────────
step "Installing Alloy binary"

# Ensure unzip is available
if ! command -v unzip >/dev/null 2>&1; then
    pkg install -y unzip || fail "unzip not found and pkg install failed. Install manually: pkg install unzip"
fi

unzip -q "$ZIP_PATH" -d "$TMP_DIR"

INSTALL_DIR="/usr/local/bin"
BINARY_PATH="${INSTALL_DIR}/alloy"

install -m 0755 "${TMP_DIR}/${BINARY_NAME}" "$BINARY_PATH"
rm -rf "$TMP_DIR"

ok "Binary installed to: $BINARY_PATH"

# ── Create alloy user/group ────────────────────────────────────────────────────
step "Creating alloy system user"

if ! pw group show alloy >/dev/null 2>&1; then
    pw groupadd alloy -g 5000
    ok "Group 'alloy' created"
else
    ok "Group 'alloy' already exists"
fi

if ! pw user show alloy >/dev/null 2>&1; then
    pw useradd alloy -u 5000 -g alloy \
        -d /var/lib/alloy \
        -s /usr/sbin/nologin \
        -c "Grafana Alloy"
    ok "User 'alloy' created"
else
    ok "User 'alloy' already exists"
fi

# ── Create directories ─────────────────────────────────────────────────────────
step "Creating directories"

CONFIG_DIR="/usr/local/etc/alloy"
STORAGE_DIR="/var/lib/alloy"
LOG_DIR="/var/log/alloy"

mkdir -p "$CONFIG_DIR" "$STORAGE_DIR" "$LOG_DIR"
chown alloy:alloy "$STORAGE_DIR" "$LOG_DIR"
ok "Directories created"

# ── Deploy configuration ───────────────────────────────────────────────────────
step "Configuring Alloy"

CONFIG_FILE="${CONFIG_DIR}/config.alloy"

if [ -n "$USER_CONFIG" ]; then
    if [ -f "$USER_CONFIG" ]; then
        cp "$USER_CONFIG" "$CONFIG_FILE"
        ok "Deployed config from: $USER_CONFIG"
    else
        warn "Config file not found at '$USER_CONFIG'. Writing placeholder."
        USER_CONFIG=""
    fi
fi

if [ -z "$USER_CONFIG" ] && [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<'EOF'
// Grafana Alloy configuration
// Reference: https://grafana.com/docs/alloy/latest/
//
// Replace this placeholder with your actual pipeline configuration.

logging {
  level  = "info"
  format = "logfmt"
}
EOF
    ok "Placeholder config written to: $CONFIG_FILE"
else
    ok "Existing config retained at: $CONFIG_FILE"
fi

chown -R alloy:alloy "$CONFIG_DIR"

# ── Install RC script ──────────────────────────────────────────────────────────
if [ "$NO_SERVICE" -eq 0 ]; then
    step "Installing RC service script"

    RC_SCRIPT="/usr/local/etc/rc.d/alloy"

    cat > "$RC_SCRIPT" <<'RCEOF'
#!/bin/sh
# PROVIDE: alloy
# REQUIRE: NETWORK DAEMON
# KEYWORD: shutdown

. /etc/rc.subr

name="alloy"
rcvar="${name}_enable"
desc="Grafana Alloy - OpenTelemetry Collector"

load_rc_config "${name}"

: ${alloy_enable:="NO"}
: ${alloy_user:="alloy"}
: ${alloy_group:="alloy"}
: ${alloy_config:="/usr/local/etc/alloy/config.alloy"}
: ${alloy_storage:="/var/lib/alloy"}
: ${alloy_flags:=""}
: ${alloy_logfile:="/var/log/alloy/alloy.log"}

command="/usr/local/bin/alloy"
command_args="run --storage.path=${alloy_storage} ${alloy_flags} ${alloy_config}"
pidfile="/var/run/${name}.pid"
start_precmd="${name}_precmd"

alloy_precmd()
{
    install -d -o ${alloy_user} -g ${alloy_group} -m 750 ${alloy_storage}
    install -d -o ${alloy_user} -g ${alloy_group} -m 750 /var/log/alloy
}

run_rc_command "$1"
RCEOF

    chmod 0555 "$RC_SCRIPT"
    ok "RC script installed: $RC_SCRIPT"

    # Enable in /etc/rc.conf
    step "Enabling and starting Alloy RC service"

    if grep -q '^alloy_enable=' /etc/rc.conf 2>/dev/null; then
        sed -i '' 's/^alloy_enable=.*/alloy_enable="YES"/' /etc/rc.conf
    else
        echo 'alloy_enable="YES"' >> /etc/rc.conf
    fi
    ok "alloy_enable=\"YES\" written to /etc/rc.conf"

    service alloy start

    sleep 2

    if service alloy status | grep -q "running"; then
        ok "Alloy service is running"
    else
        warn "Alloy may not be running. Check: service alloy status"
        warn "Logs: tail -f /var/log/alloy/alloy.log"
    fi
else
    step "Skipping service setup (--no-service specified)"
    ok "Run manually: alloy run --storage.path=${STORAGE_DIR} ${CONFIG_FILE}"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
INSTALLED_VERSION=$(alloy --version 2>/dev/null | awk '{print $NF}' || echo "$ALLOY_VERSION")

printf "\n"
printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf " ${GREEN}Grafana Alloy ${INSTALLED_VERSION} installed on FreeBSD${RESET}\n"
printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf " Binary      : %s\n" "$BINARY_PATH"
printf " Config file : %s\n" "$CONFIG_FILE"
printf " Storage     : %s\n" "$STORAGE_DIR"
printf " UI (local)  : http://localhost:12345\n"
printf "\n"
if [ "$NO_SERVICE" -eq 0 ]; then
    printf " Service management (RC):\n"
    printf "   Status  -> service alloy status\n"
    printf "   Restart -> service alloy restart\n"
    printf "   Stop    -> service alloy stop\n"
    printf "   Logs    -> tail -f /var/log/alloy/alloy.log\n"
fi
printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
