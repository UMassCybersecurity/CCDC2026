#!/bin/bash

OUT="./k8s_hardening.log"

log() {
  echo -e "$@" | tee -a "$OUT"
}

mkdir -p "$(dirname "$OUT")"

log "[*] Starting Kubernetes hardening..."
date | tee -a "$OUT"
log "===================================="

#############################################
# 1. Detect privileged containers
#############################################
log "[1] Checking privileged containers..."

PRIV_PODS=$(
kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
  .items[] as $pod
  | $pod.spec.containers[]
  | select(.securityContext.privileged == true)
  | "\($pod.metadata.namespace)\t\($pod.metadata.name)\t\(.name)"
'
)

if [[ -z "$PRIV_PODS" ]]; then
  log "[-] No privileged containers found."
else
  log "[!] Privileged containers (namespace pod container):"
  log "$PRIV_PODS"
fi

#############################################
# 2. Ensure kubeaudit (local in /tmp)
#############################################
log ""
log "[2] Ensuring kubeaudit is installed (local /tmp)..."

KUBEAUDIT_BIN="/tmp/kubeaudit"

if ! command -v "$KUBEAUDIT_BIN" >/dev/null 2>&1; then
  log "[i] Installing kubeaudit into $KUBEAUDIT_BIN ..."
  curl -L https://github.com/Shopify/kubeaudit/releases/latest/download/kubeaudit_amd64 \
    -o "$KUBEAUDIT_BIN" 2>>"$OUT"
  chmod +x "$KUBEAUDIT_BIN"
else
  log "[i] kubeaudit already present at $KUBEAUDIT_BIN"
fi

#############################################
# 3. Run kubeaudit scan
#############################################
log ""
log "[3] Running kubeaudit (policy scan)..."

if [[ -x "$KUBEAUDIT_BIN" ]]; then
  "$KUBEAUDIT_BIN" all --minseverity warning 2>&1 | tee -a "$OUT"
else
  log "[!] kubeaudit binary missing or not executable."
fi

#############################################
# 4. Node version / outdated check
#############################################
log ""
log "[4] Checking node versions and readiness (outdated nodes)..."

NODES_JSON=$(kubectl get nodes -o json 2>/dev/null)

if [[ -z "$NODES_JSON" || "$NODES_JSON" == "null" ]]; then
  log "[!] Could not retrieve node information (kubectl get nodes failed)."
else
  # Find latest kubelet version among all nodes
  LATEST_VER=$(echo "$NODES_JSON" | jq -r '.items[].status.nodeInfo.kubeletVersion' \
               | sort -V | tail -n1)

  log "[i] Latest kubelet version in cluster: $LATEST_VER"
  log "NAME\tVERSION\tREADY\tOUTDATED"

  echo "$NODES_JSON" | jq -r --arg latest "$LATEST_VER" '
    .items[] |
    . as $n |
    {
      name: .metadata.name,
      version: .status.nodeInfo.kubeletVersion,
      ready: (.status.conditions[] | select(.type=="Ready") | .status),
      outdated: (.status.nodeInfo.kubeletVersion != $latest)
    } |
    "\(.name)\t\(.version)\t\(.ready)\t\(.outdated)"
  ' | tee -a "$OUT"

  log ""
  log "[i] Any node with OUTDATED=true is not on the latest kubelet version."
  log "    Those are good candidates to investigate / prioritize for patching."
fi

#############################################
# 5. Summary
#############################################
log ""
log "[5] Summary:"
log "------------------------------------"
log "✓ Privileged containers scanned"
log "✓ kubeaudit policy scan complete (if binary installed)"
log "✓ Node version / readiness check complete"
log "Log written to $OUT"
log "------------------------------------"
log "[*] Hardening script complete."

