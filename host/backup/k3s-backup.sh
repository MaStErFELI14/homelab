#!/usr/bin/env bash
# Nightly k3s backup: datastore (sqlite), TLS/token, and local-path PVC data.
# k3s is stopped for a few seconds so state.db is copied consistently;
# running containers keep running (KillMode=process).
set -euo pipefail

BACKUP_DIR=${BACKUP_DIR:-/var/backups/k3s}
KEEP=${KEEP:-14}
BACKUP_REMOTE=${BACKUP_REMOTE:-}   # optional scp target, e.g. user@nas:/volume1/backups/k3s
[ -f /etc/default/k3s-backup ] && . /etc/default/k3s-backup

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$BACKUP_DIR/k3s-$stamp.tar.zst"
mkdir -p "$BACKUP_DIR"

restart() { systemctl start k3s; }
trap restart EXIT
systemctl stop k3s

tar --zstd -cf "$out.partial" \
  -C /var/lib/rancher/k3s \
  server/db/state.db server/db/state.db-wal server/db/state.db-shm \
  server/token server/agent-token server/tls server/cred \
  storage 2>/dev/null || [ $? -eq 1 ]   # exit 1 = files changed while reading (PVC data); acceptable

mv "$out.partial" "$out"
trap - EXIT
restart

[ -n "$BACKUP_REMOTE" ] && scp -q -o BatchMode=yes "$out" "$BACKUP_REMOTE/"

# retention
ls -1t "$BACKUP_DIR"/k3s-*.tar.zst | tail -n +$((KEEP + 1)) | xargs -r rm -f
echo "backup written: $out ($(du -h "$out" | cut -f1))"
