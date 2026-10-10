#!/usr/bin/env bash
# Dead-man's switch: ping healthchecks.io only while the node is Ready and Gatus is healthy.
# When a check fails the script stays silent, so the missed ping raises the alert.
# Gatus is probed through its Service ClusterIP (not the ingress) so an expired cert,
# DNS trouble or Traefik outage does not mask a healthy Gatus; Gatus itself checks the ingress.
set -euo pipefail

HEALTHCHECK_PING_URL=${HEALTHCHECK_PING_URL:-}
GATUS_NAMESPACE=${GATUS_NAMESPACE:-gatus}
GATUS_SERVICE=${GATUS_SERVICE:-gatus}
GATUS_PORT=${GATUS_PORT:-8080}
[ -f /etc/default/homelab-heartbeat ] && . /etc/default/homelab-heartbeat

if [ -z "$HEALTHCHECK_PING_URL" ]; then
  echo "HEALTHCHECK_PING_URL not set" >&2
  exit 1
fi

kubectl() { k3s kubectl "$@"; }

ready=$(kubectl get nodes --no-headers | awk '$2 == "Ready" {n++} END {print n + 0}')
total=$(kubectl get nodes --no-headers | wc -l)
if [ "$ready" -lt 1 ] || [ "$ready" -ne "$total" ]; then
  echo "node not Ready ($ready/$total); not pinging" >&2
  exit 1
fi

ip=$(kubectl -n "$GATUS_NAMESPACE" get svc "$GATUS_SERVICE" -o jsonpath='{.spec.clusterIP}')
if ! curl -fsS -m 10 -o /dev/null "http://$ip:$GATUS_PORT/health"; then
  echo "gatus unhealthy; not pinging" >&2
  exit 1
fi

# URL contains the check secret: pass it via stdin, not argv.
printf 'url = "%s"\n' "$HEALTHCHECK_PING_URL" | curl -fsS -m 10 --retry 2 -o /dev/null -K -
echo "ping sent"
