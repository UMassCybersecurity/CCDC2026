#!/bin/bash
#   sudo ./enum_concise.sh
#   VERBOSE=1 sudo ./enum_concise.sh
#   AD_BIND="teleport-bind@placebo-pharma3.local" AD_PASS='StrongPassword123!' sudo ./enum_concise.sh
#

set -euo pipefail

VERBOSE="${VERBOSE:-0}"

AD_HOST="${AD_HOST:-10.37.33.39}"   # change Domain Controller IP / hostname
AD_PORT="${AD_PORT:-389}" # teleport listening port
AD_URL="ldap://${AD_HOST}:${AD_PORT}"

# Bind defaults (override via env)
AD_REALM="${AD_REALM:-placebo-pharma3.local}" #change domain name
AD_BIND="${AD_BIND:-teleport-bind@${AD_REALM}}" #change teleport user
AD_PASS="${AD_PASS:-}" #change teleport password

TCTL="sudo tctl"
TPBIN="teleport"

# Teleport config path varies by install.
# Common paths:
#  - /etc/teleport.yaml
#  - /etc/teleport/teleport.yaml
TELEPORT_CONFIG_PRIMARY="/etc/teleport.yaml"
TELEPORT_CONFIG_FALLBACK="/etc/teleport/teleport.yaml"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

REPORT_FILE="teleport_enum_$(date +%Y%m%d_%H%M%S).json" #change to txt if needed

log() { echo -e "$1" >> "$REPORT_FILE"; }

say() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo -e "$1"
  else
    # strip ANSI
    echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g'
  fi
}

run_cmd() {
  local cmd="$1"
  local description="$2"

  log "\n${BLUE}[*]${NC} $description"
  if eval "$cmd" >> "$REPORT_FILE" 2>&1; then
    log "${GREEN}[✓]${NC} Command completed"
    say "[OK] $description"
  else
    log "${RED}[!]${NC} Command failed or not available"
    say "[WARN] $description (failed/unavailable)"
  fi
}


echo "Report: $REPORT_FILE"
echo "(Set VERBOSE=1 for more terminal output.)"
echo ""

log "=== TELEPORT ENUMERATION REPORT ==="
log "Date: $(date)"
log "Hostname: $(hostname)"
log "Mode: local (non-docker)"
log ""

if ! command -v teleport >/dev/null 2>&1; then
  say "[WARN] teleport binary not found on PATH (Teleport not installed locally?)"
  log "${YELLOW}[!]${NC} teleport binary not found on PATH"
fi

if ! command -v tctl >/dev/null 2>&1; then
  say "[WARN] tctl binary not found on PATH (Teleport not installed locally?)"
  log "${YELLOW}[!]${NC} tctl binary not found on PATH"
fi

# AD base DN discovery (optional). Do not fail the whole script if AD is unreachable.
BASE_DN=""
if command -v ldapsearch >/dev/null 2>&1; then
  # RootDSE discovery (works on AD). Some environments block anonymous rootdse; if so, we try authenticated.
  # Prefer the namingContexts output to match common AD behavior.
  BASE_DN=$(ldapsearch -x -H "$AD_URL" -s base -b "" namingContexts 2>/dev/null \
    | awk -F': ' '/^namingContexts: DC=/{print $2; exit}' || true)

  if [[ -z "$BASE_DN" && -n "$AD_PASS" ]]; then
    BASE_DN=$(ldapsearch -x -H "$AD_URL" -s base -b "" -D "$AD_BIND" -w "$AD_PASS" namingContexts 2>/dev/null \
      | awk -F': ' '/^namingContexts: DC=/{print $2; exit}' || true)
  fi

  if [[ -n "$BASE_DN" ]]; then
    echo "AD base DN discovered: $BASE_DN"
    log "AD base DN discovered: $BASE_DN"
  else
    say "[WARN] AD base DN discovery failed (AD checks will be skipped unless BASE_DN is set)"
    log "${YELLOW}[!]${NC} AD base DN discovery failed for $AD_URL"
  fi
else
  say "[WARN] ldapsearch not found (install: sudo apt install -y ldap-utils). AD checks will be skipped."
  log "${YELLOW}[!]${NC} ldapsearch not found; skipping AD checks"
fi

# ==========================================================================
# 1. TELEPORT SERVICE STATUS & VERSION
# ==========================================================================
log "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log "${YELLOW}1. TELEPORT SERVICE STATUS & VERSION${NC}"
log "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_cmd "$TPBIN version" "Teleport version (local)"
run_cmd "systemctl is-active teleport && systemctl status teleport --no-pager -l" "Teleport systemd service status"
run_cmd "journalctl -u teleport -n 80 --no-pager" "Recent Teleport service logs (tail)"
run_cmd "$TCTL status" "Teleport cluster status"
run_cmd "$TCTL get cluster" "Cluster configuration"

# ==========================================================================
# 2. USER ENUMERATION
# ==========================================================================
log "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log "${YELLOW}2. USER ENUMERATION${NC}"
log "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_cmd "$TCTL users ls" "List all Teleport users"
run_cmd "$TCTL get users --format=yaml" "Detailed user information (YAML)"

log "\n${BLUE}[*]${NC} Checking for users with admin/root privileges..."
if $TCTL get users --format=yaml 2>/dev/null | grep -E "(roles?:.*admin|roles?:.*root|\\- admin|\\- root)" >> "$REPORT_FILE"; then
  log "${YELLOW}[!]${NC} Found users with elevated privileges - review carefully"
fi

# ==========================================================================
# 3. ROLE ENUMERATION & ANALYSIS
# ==========================================================================

ROLE_JSON="$($TCTL get roles --format=json 2>/dev/null || true)"

if echo "$ROLE_JSON" | jq -e . >/dev/null 2>&1; then
  # Write compact summary to report (always)
  {
    echo "[*] Role privilege summary (compact)"
    echo "$ROLE_JSON" | jq -r '
      .[]? |
      .metadata.name as $name |
      ((.spec.allow.logins // []) | join(",")) as $logins |
      (.spec.allow.node_labels // {}) as $node_labels |
      (
        ($node_labels | has("*")) or
        ($node_labels | to_entries | any(.value == "*"))
      ) as $node_wild |
      (.spec.allow.rules // []) as $rules |
      (
        ($rules | any(((.resources // []) | index("*")) != null)) or
        ($rules | any(((.verbs // []) | index("*")) != null))
      ) as $rule_wild |
      [
        "Role: \($name)",
        (if $logins != "" then "  logins: \($logins)" else "  logins: (none listed)" end),
        (if $node_wild then "wildcard node_labels" else empty end),
        (if $rule_wild then "wildcard rules (* verbs/resources)" else empty end),
        ""
      ] | .[]'
  } >> "$REPORT_FILE"

  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "[OK] Role summary written to report (showing top roles):"
    # show only first ~25 lines of the summary in verbose mode
    sed -n '/\[\*\] Role privilege summary (compact)/,$p' "$REPORT_FILE" | head -n 25
  else
    echo "[OK] Roles summarized (see report for details)"
  fi

else
  log "[WARN] Roles JSON not available; falling back to short text list"
  run_cmd "$TCTL get roles" "List all roles (fallback)"
fi

# ==========================================================================
# 4. ACTIVE SESSIONS & NODES
# ==========================================================================
log "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log "${YELLOW}4. ACTIVE SESSIONS${NC}"
log "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Active sessions are not available via tctl in teleport v18.
# tsh requires an interactive login + proxy content
if command -v tsh >/dev/null 2>&1; then
  if tsh status >/dev/null 2>&1; then
    run_cmd "tsh sessions ls" "List active sessions (tsh)"
  else
    log "[WARN] tsh present but not logged in; skipping active session listing"
    echo "[WARN] Active sessions skipped (no tsh login context)"
  fi
else
  log "[WARN] tsh not available; skipping active session listing"
  echo "[WARN] Active sessions skipped (tsh not available)"
fi

# Nodes
run_cmd "$TCTL nodes ls" "List nodes (admin view)"

# ==========================================================================
# 5. TRUSTED CLUSTERS & FEDERATION
# ==========================================================================
log "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log "${YELLOW}5. TRUSTED CLUSTERS & FEDERATION${NC}"
log "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_cmd "$TCTL get trusted_cluster" "List trusted clusters"
run_cmd "$TCTL get trusted_cluster --format=yaml" "Detailed trusted cluster config"

log "\n${BLUE}[*]${NC} Checking for unexpected trusted clusters..."
TRUSTED_COUNT=$($TCTL get trusted_cluster 2>/dev/null | wc -l | tr -d ' ')
log "Total trusted clusters (lines): $TRUSTED_COUNT"
if [[ "$TRUSTED_COUNT" -gt 0 ]]; then
  log "${YELLOW}[!]${NC} Review trusted clusters for unauthorized connections"
fi

# ==========================================================================
# 6. AUTHENTICATION CONNECTORS (SSO)
# ==========================================================================
log "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log "${YELLOW}6. AUTHENTICATION CONNECTORS (SSO/AD INTEGRATION)${NC}"
log "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Auth preference: v18 uses `tctl auth preference`
run_cmd "$TCTL get cluster_auth_preference" "Auth preferences (local vs SSO settings)"

# Connectors: these are resources and SHOULD work with `tctl get`
run_cmd "$TCTL get saml --format=yaml" "SAML connectors"
run_cmd "$TCTL get oidc --format=yaml" "OIDC connectors"
run_cmd "$TCTL get github --format=yaml" "GitHub SSO connectors"

# ==========================================================================
# 7. NODES & RESOURCES
# ==========================================================================
log "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log "${YELLOW}7. REGISTERED NODES & RESOURCES${NC}"
log "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_cmd "$TCTL nodes ls" "List all nodes"
run_cmd "$TCTL get nodes" "Detailed node information"
run_cmd "$TCTL apps ls" "List application access resources"
run_cmd "$TCTL db ls" "List database access resources"
run_cmd "$TCTL kube ls" "List Kubernetes clusters"

log "\n${BLUE}[*]${NC} Checking for unauthorized or unknown nodes..."
NODE_COUNT=$($TCTL nodes ls 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
log "Total registered nodes: $NODE_COUNT"


