#!/usr/bin/env bash
# Usage: ./upgrade-step.sh v1.31.14+k3s1
# Run from a machine with kubectl access (or on the NUC). Backs up, applies one
# pinned Plan, waits for the node to report the new version, then checks pods.
set -euo pipefail
ver=${1:?usage: $0 <k3s version, e.g. v1.31.14+k3s1>}
host=${NUC:-root@192.168.0.252}
cd "$(dirname "$0")"

echo ">> backup"
ssh "$host" /usr/local/sbin/k3s-backup.sh

echo ">> applying plan for $ver"
sed "s/__K3S_VERSION__/$ver/" plans/server-plan.yaml | ssh "$host" k3s kubectl apply -f -

echo ">> waiting for node to reach $ver (up to 20 min)"
for _ in $(seq 1 120); do
  now=$(ssh -o ConnectTimeout=5 "$host" k3s kubectl get node -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || true)
  [ "$now" = "$ver" ] && break
  sleep 10
done
[ "${now:-}" = "$ver" ] || { echo "node did not reach $ver (now: ${now:-unknown})"; exit 1; }

ssh "$host" k3s kubectl wait --for=condition=Ready node --all --timeout=300s
ssh "$host" k3s kubectl get pods -A | grep -v -E 'Running|Completed' || true
ssh "$host" k3s kubectl get applications -n argocd
