#!/bin/sh
# =============================================================================
# install-alloy-alpine.sh
# Installs Grafana Alloy on Alpine Linux using the official Alpine package.
#
# Alloy is available in the Alpine Linux community repository (edge and
# recent stable branches). The standard Grafana Linux binary will NOT
# work on Alpine because Alpine uses musl libc rather than glibc.
# This script uses the native Alpine package instead.
#
# Supported Alpine versions: 3.19+ (community repo required)
#
# Usage:
#   sudo sh install-alloy-alpine.sh [OPTIONS]
#
# Options:
#   -c, --config <path>   Path to an existing config file to deploy
#   --no-service          Install binary only; do not enable OpenRC service
#   -h, --help            Show this help message
# =============================================================================

set -eu

# ── Colour helpers (POSIX sh compatible) ──────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

step() { printf "\n${CYAN}==> ${BOLD}%s${RESET}\n" "$*"; }
ok()   { printf "    ${GREEN}[OK]${RESET}  %s\n" "$*"; }
warn() { printf "    ${YELLOW}[WARN]${RESET} %s\n" "$*"; }
fail() { printf "    ${RED}[FAIL]${RESET} %s\n" "$*" >&2; exit 1; }

# ── Argument parsing ───────────────────────────────────────────────────────────
USER_CONFIG=""
NO_SERVICE=0

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config)   USER_CONFIG="$2"; shift 2 ;;
        --no-service)  NO_SERVICE=1;     shift   ;;
        -h|--help)
            head -30 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

# ── Root check ─────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || fail "This script must be run as root (use sudo or doas)."

# ── Verify we are on Alpine ────────────────────────────────────────────────────
step "Verifying Alpine Linux"

if [ ! -f /etc/alpine-release ]; then
    fail "This script is intended for Alpine Linux only."
fi

ALPINE_VERSION=$(cat /etc/alpine-release)
ok "Alpine version: $ALPINE_VERSION"

# ── Ensure community repository is enabled ────────────────────────────────────
step "Enabling Alpine community repository"

REPOS_FILE="/etc/apk/repositories"

# Detect the active mirror and append community repo if not already present
if grep -q "^[^#].*community" "$REPOS_FILE" 2>/dev/null; then
    ok "Community repository already enabled"
else
    # Try to uncomment an existing commented community line first
    if grep -q "#.*community" "$REPOS_FILE" 2>/dev/null; then
        sed -i 's|^#\(.*community\)|\1|' "$REPOS_FILE"
        ok "Uncommented community repository"
    else
        # Derive mirror from the first active repo line
        MIRROR=$(grep "^http" "$REPOS_FILE" | head -1 | sed 's|/[^/]*$||')
        if [ -z "$MIRROR" ]; then
            # Fall back to the official CDN
            MIRROR="https://dl-cdn.alpinelinux.org/alpine/latest-stable"
        fi
        echo "${MIRROR}/community" >> "$REPOS_FILE"
        ok "Added community repository: ${MIRROR}/community"
    fi
fi

# ── Update package index ───────────────────────────────────────────────────────
step "Updating package index"
apk update -q
ok "Package index updated"

# ── Install Alloy ──────────────────────────────────────────────────────────────
step "Installing Grafana Alloy"

# 'alloy' is in the community repo; 'alloy-openrc' provides the OpenRC init script
if apk info -e alloy >/dev/null 2>&1; then
    warn "Alloy is already installed. Upgrading if a newer version is available."
    apk upgrade -q alloy alloy-openrc 2>/dev/null || apk upgrade -q alloy
else
    apk add -q alloy alloy-openrc 2>/dev/null || apk add -q alloy
fi
ok "Alloy package installed"

# ── Deploy configuration ───────────────────────────────────────────────────────
step "Configuring Alloy"

CONFIG_DIR="/etc/alloy"
CONFIG_FILE="${CONFIG_DIR}/config.alloy"

mkdir -p "$CONFIG_DIR"

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

# Ensure correct ownership (alloy user is created by the package)
if id alloy >/dev/null 2>&1; then
    chown -R alloy:alloy "$CONFIG_DIR"
fi

# ── OpenRC service setup ───────────────────────────────────────────────────────
if [ "$NO_SERVICE" -eq 0 ]; then
    step "Enabling and starting Alloy via OpenRC"

    # Verify OpenRC init script exists (provided by alloy-openrc sub-package or
    # the main package depending on Alpine version)
    if [ ! -f /etc/init.d/alloy ]; then
        # Write a minimal OpenRC init script as a fallback
        warn "alloy-openrc not found; writing a fallback OpenRC init script"
        cat > /etc/init.d/alloy <<'INITEOF'
#!/sbin/openrc-run
name="alloy"
description="Grafana Alloy"
command="/usr/bin/alloy"
command_args="run --storage.path=/var/lib/alloy /etc/alloy/config.alloy"
command_user="alloy"
pidfile="/run/${RC_SVCNAME}.pid"
command_background=true
output_log="/var/log/alloy.log"
error_log="/var/log/alloy.log"

depend() {
    need net
    after firewall
}
INITEOF
        chmod 755 /etc/init.d/alloy
    fi

    rc-update add alloy default
    rc-service alloy start

    sleep 2

    if rc-service alloy status | grep -q "started"; then
        ok "Alloy service is running"
    else
        warn "Alloy service may not have started. Check: rc-service alloy status"
        warn "Logs: tail -f /var/log/alloy.log"
    fi
else
    step "Skipping service setup (--no-service specified)"
    ok "Run manually: alloy run --storage.path=/var/lib/alloy /etc/alloy/config.alloy"
fi

# ── Determine installed version ────────────────────────────────────────────────
INSTALLED_VERSION=$(alloy --version 2>/dev/null | awk '{print $NF}' || echo "unknown")

# ── Summary ────────────────────────────────────────────────────────────────────
printf "\n"
printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf " ${GREEN}Grafana Alloy ${INSTALLED_VERSION} installed on Alpine Linux${RESET}\n"
printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf " Config file : %s\n" "$CONFIG_FILE"
printf " Binary      : %s\n" "$(command -v alloy)"
printf " UI (local)  : http://localhost:12345\n"
printf "\n"
if [ "$NO_SERVICE" -eq 0 ]; then
    printf " Service management (OpenRC):\n"
    printf "   Status  -> rc-service alloy status\n"
    printf "   Restart -> rc-service alloy restart\n"
    printf "   Stop    -> rc-service alloy stop\n"
    printf "   Logs    -> tail -f /var/log/alloy.log\n"
fi
printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
