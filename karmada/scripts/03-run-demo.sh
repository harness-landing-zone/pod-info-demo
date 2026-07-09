#!/usr/bin/env bash
# Apply the Divided-scheduling demo and show where replicas land.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KCFG="$BASE_DIR/.run/karmada-apiserver.config"

[[ -f "$KCFG" ]] || { echo "ERROR: run 01-install-control-plane.sh first"; exit 1; }
kubectl --kubeconfig "$KCFG" get clusters >/dev/null 2>&1 \
  || { echo "Karmada API unreachable — restarting port-forward"; "$SCRIPT_DIR/01-install-control-plane.sh"; }

echo "== Applying demo app (region-total replicas) + PropagationPolicy (Divided)"
kubectl --kubeconfig "$KCFG" apply -f "$BASE_DIR/manifests/demo-app.yaml"
kubectl --kubeconfig "$KCFG" apply -f "$BASE_DIR/manifests/demo-propagationpolicy.yaml"

echo "== Waiting for scheduling..."
sleep 10

echo "== Deployment as seen on the Karmada control plane (aggregated status):"
kubectl --kubeconfig "$KCFG" -n karmada-demo get deploy podinfo-demo

echo
echo "== ResourceBinding (how Karmada divided the replicas):"
kubectl --kubeconfig "$KCFG" -n karmada-demo get resourcebinding \
  podinfo-demo-deployment -o jsonpath='{range .spec.clusters[*]}{.name}{": "}{.replicas}{" replicas\n"}{end}' 2>/dev/null || true

echo
echo "== Pods per member cluster:"
karmadactl --kubeconfig "$KCFG" get pods -n karmada-demo --operation-scope members || \
  for c in dev staging prod; do echo "-- k3d-${c}"; kubectl --context "k3d-${c}" -n karmada-demo get pods 2>/dev/null; done

cat <<'EOF'

Failover test:
  k3d cluster stop prod
  watch karmadactl --kubeconfig .run/karmada-apiserver.config get pods -n karmada-demo --operation-scope members
  # after failure detection + 30s toleration: expect 3/3 on dev/staging
  k3d cluster start prod   # rebalances back toward 2/2/2
EOF
