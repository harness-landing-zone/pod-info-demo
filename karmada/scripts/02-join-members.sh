#!/usr/bin/env bash
# Join the k3d spoke clusters (dev/staging/prod) to Karmada in push mode,
# using the same addressing the Argo CD spoke secrets already use:
#   https://<mac-lan-ip>:<k3d published port>, TLS verification disabled.
# Usage:
#   ./02-join-members.sh            join + label all three
#   ./02-join-members.sh --unjoin   remove all three from Karmada
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/.run"
KCFG="$RUN_DIR/karmada-apiserver.config"
CLUSTERS=(dev staging prod)
REGION_LABEL="${REGION_LABEL:-local1}"

[[ -f "$KCFG" ]] || { echo "ERROR: run 01-install-control-plane.sh first ($KCFG missing)"; exit 1; }

# Karmada API reachable? (port-forward may have died since install)
kubectl --kubeconfig "$KCFG" get clusters >/dev/null 2>&1 \
  || { echo "Karmada API unreachable — restarting port-forward via 01 script"; "$SCRIPT_DIR/01-install-control-plane.sh"; }

if [[ "${1:-}" == "--unjoin" ]]; then
  for c in "${CLUSTERS[@]}"; do
    echo "== unjoin k3d-${c}"
    karmadactl unjoin "k3d-${c}" --kubeconfig "$KCFG" || true
  done
  exit 0
fi

# Mac LAN IP — same assumption as the existing Argo CD spoke secrets.
MAC_IP="${MAC_IP:-$(ipconfig getifaddr en0 || ipconfig getifaddr en1)}"
[[ -n "$MAC_IP" ]] || { echo "ERROR: could not determine Mac LAN IP (set MAC_IP=...)"; exit 1; }
echo "== Using Mac LAN IP: $MAC_IP"

for c in "${CLUSTERS[@]}"; do
  echo "== Joining k3d-${c}"
  PORT=$(docker port "k3d-${c}-serverlb" 6443/tcp | head -1 | awk -F: '{print $NF}')
  [[ -n "$PORT" ]] || { echo "ERROR: no published port for k3d-${c}-serverlb (cluster stopped?)"; exit 1; }

  # Member kubeconfig: flatten the k3d admin context, rewrite the server to the
  # LAN IP, drop the CA and skip TLS verify (LAN IP is not in the k3s cert SANs
  # — mirrors the Argo CD spoke secret config).
  MEMBER_CFG="$RUN_DIR/member-${c}.kubeconfig"
  kubectl config view --context "k3d-${c}" --minify --flatten > "$MEMBER_CFG"
  MEMBER_CLUSTER=$(kubectl --kubeconfig "$MEMBER_CFG" config view -o jsonpath='{.clusters[0].name}')
  kubectl --kubeconfig "$MEMBER_CFG" config unset "clusters.${MEMBER_CLUSTER}.certificate-authority-data" >/dev/null
  kubectl --kubeconfig "$MEMBER_CFG" config set-cluster "$MEMBER_CLUSTER" \
    --server="https://${MAC_IP}:${PORT}" --insecure-skip-tls-verify=true >/dev/null

  karmadactl join "k3d-${c}" \
    --kubeconfig "$KCFG" \
    --cluster-kubeconfig "$MEMBER_CFG" \
    --cluster-context "k3d-${c}"

  # Grouping layer: one region group + the environment label for later AppSet use
  kubectl --kubeconfig "$KCFG" label cluster "k3d-${c}" \
    "infra_region=${REGION_LABEL}" "environment=${c}" --overwrite
done

echo
echo "== Member clusters:"
kubectl --kubeconfig "$KCFG" get clusters --show-labels
