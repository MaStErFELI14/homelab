#!/usr/bin/env bash
# Run on the node as root: installs the homelab_fw nftables table and its systemd unit.
# Own table, policy accept, only drops the listed ports for non-local, non-cluster sources.
# Safety: arms a 5 minute rollback timer first; it is cancelled only if you confirm.
# Override CIDRs with CLUSTER_CIDR / SERVICE_CIDR (defaults are the k3s defaults).
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_CIDR=${CLUSTER_CIDR:-10.42.0.0/16}
SERVICE_CIDR=${SERVICE_CIDR:-10.43.0.0/16}

command -v nft >/dev/null || { apt-get update -qq && apt-get install -y nftables; }
# The distro nftables.service loads a config that starts with "flush ruleset", which would wipe
# kube-router's rules if restarted. We use our own unit, so keep that one off.
systemctl disable --now nftables.service 2>/dev/null || true

pod_cidr=$(k3s kubectl get node -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null || true)
echo "node podCIDR: ${pod_cidr:-unknown}; using cluster ${CLUSTER_CIDR}, service ${SERVICE_CIDR}"
if [ -n "$pod_cidr" ]; then
  python3 - "$pod_cidr" "$CLUSTER_CIDR" <<'PY' || { echo "podCIDR not inside CLUSTER_CIDR; set CLUSTER_CIDR" >&2; exit 1; }
import ipaddress, sys
sys.exit(0 if ipaddress.ip_network(sys.argv[1]).subnet_of(ipaddress.ip_network(sys.argv[2])) else 1)
PY
fi

sed -e "s#@CLUSTER_CIDR@#${CLUSTER_CIDR}#" -e "s#@SERVICE_CIDR@#${SERVICE_CIDR}#" \
  homelab-fw.nft.in > /etc/homelab-fw.nft.new
nft -c -f /etc/homelab-fw.nft.new
mv /etc/homelab-fw.nft.new /etc/homelab-fw.nft
install -m 0644 homelab-fw.service /etc/systemd/system/
systemctl daemon-reload

systemctl stop homelab-fw-rollback.timer 2>/dev/null || true
systemd-run --on-active=5min --unit=homelab-fw-rollback /usr/sbin/nft delete table inet homelab_fw
systemctl enable --now homelab-fw.service
systemctl restart homelab-fw.service
nft list table inet homelab_fw
echo
echo "Rules active. Verify from another host, then cancel the rollback:"
echo "  systemctl stop homelab-fw-rollback.timer"
