#!/usr/bin/env bash
# Nightly k3s backup: datastore (sqlite), TLS/token, and local-path PVC data.
# k3s is stopped for a few seconds so state.db is copied consistently;
# running containers keep running (KillMode=process).
# Optionally uploads the archive to an encrypted restic repository (S3-compatible,
# e.g. Cloudflare R2) and reports the result to a Gatus external endpoint (see README).
set -euo pipefail

BACKUP_DIR=${BACKUP_DIR:-/var/backups/k3s}
KEEP=${KEEP:-14}
BACKUP_REMOTE=${BACKUP_REMOTE:-}   # optional scp target, e.g. user@nas:/volume1/backups/k3s
GATUS_URL=${GATUS_URL:-https://gatus.beaners.club}       # optional: Gatus base URL
GATUS_ENDPOINT_KEY=${GATUS_ENDPOINT_KEY:-host_nightly-backup}  # <group>_<name>, lowercased, spaces -> '-'
RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-}                 # optional: unset = no off-box upload
BACKUP_HEARTBEAT_TOKEN=${BACKUP_HEARTBEAT_TOKEN:-}       # optional: unset = no heartbeat
[ -f /etc/default/k3s-backup ] && . /etc/default/k3s-backup

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$BACKUP_DIR/k3s-$stamp.tar.zst"
mkdir -p "$BACKUP_DIR"

# Report to Gatus; never fails the backup. Retries because Gatus runs inside k3s,
# which may still be starting. The token goes to curl via stdin, not argv.
heartbeat() {
  [ -n "$BACKUP_HEARTBEAT_TOKEN" ] || return 0
  local ok=$1 err=${2:-}
  for _ in $(seq 1 30); do
    if printf 'header = "Authorization: Bearer %s"\n' "$BACKUP_HEARTBEAT_TOKEN" |
       curl -fsS -m 10 -K - -X POST -G --data-urlencode "success=$ok" --data-urlencode "error=$err" \
         -o /dev/null "$GATUS_URL/api/v1/endpoints/$GATUS_ENDPOINT_KEY/external" 2>/dev/null; then
      echo "heartbeat sent (success=$ok)"
      return 0
    fi
    sleep 10
  done
  echo "heartbeat not delivered (success=$ok)" >&2
  return 0
}

stopped=0
on_exit() {
  local rc=$?
  [ "$stopped" -eq 1 ] && systemctl start k3s
  [ "$rc" -ne 0 ] && heartbeat false "backup-failed-exit-$rc"
  return 0
}
trap on_exit EXIT
stopped=1
systemctl stop k3s

tar --zstd -cf "$out.partial" \
  -C /var/lib/rancher/k3s \
  server/db/state.db server/db/state.db-wal server/db/state.db-shm \
  server/token server/agent-token server/tls server/cred \
  storage 2>/dev/null || [ $? -eq 1 ]   # exit 1 = files changed while reading (PVC data); acceptable

mv "$out.partial" "$out"
systemctl start k3s
stopped=0

[ -n "$BACKUP_REMOTE" ] && scp -q -o BatchMode=yes "$out" "$BACKUP_REMOTE/"

# retention
ls -1t "$BACKUP_DIR"/k3s-*.tar.zst | tail -n +$((KEEP + 1)) | xargs -r rm -f
echo "backup written: $out ($(du -h "$out" | cut -f1))"

# Off-box copy via restic. Enabled only when RESTIC_REPOSITORY is set; the
# credentials (RESTIC_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
# AWS_DEFAULT_REGION) come from /etc/default/k3s-backup and are never logged.
# Failure does not fail the local backup but reports a failed heartbeat.
upload_offsite() {
  [ -n "$RESTIC_REPOSITORY" ] || return 0
  export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
  local attempt
  for attempt in 1 2 3; do
    if restic backup "$out" --tag k3s --quiet &&
       restic forget --tag k3s --keep-daily 14 --keep-weekly 4 --prune --quiet; then
      echo "offsite upload ok"
      return 0
    fi
    echo "offsite upload attempt $attempt failed" >&2
    [ "$attempt" -lt 3 ] && sleep $((attempt * 60))
  done
  return 1
}

if upload_offsite; then
  heartbeat true
else
  echo "offsite upload FAILED; local backup is intact" >&2
  heartbeat false offsite-upload-failed
fi
