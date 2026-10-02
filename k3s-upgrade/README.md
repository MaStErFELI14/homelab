# k3s upgrades

The node runs k3s v1.30.x. Kubernetes does not allow skipping minor versions, so
upgrade one minor at a time to the stable channel (currently v1.36.x):
1.31 -> 1.32 -> 1.33 -> 1.34 -> 1.35 -> 1.36.

This directory is deliberately **not** managed by Argo CD: merging a Plan to `main`
must never start an upgrade by itself.

## One-time setup

```bash
# system-upgrade-controller (pinned release)
kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/download/v0.20.2/crd.yaml
kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/download/v0.20.2/system-upgrade-controller.yaml

# nightly backups (on the NUC, as root)
scp -r host/backup root@192.168.0.252:/root/ && ssh root@192.168.0.252 /root/backup/install.sh
```

Optional offsite copy: put `BACKUP_REMOTE=user@host:/path` in `/etc/default/k3s-backup`.

## Each hop

1. Pick the latest patch of the next minor: `curl -s https://update.k3s.io/v1-release/channels | jq` or the k3s releases page.
2. `./upgrade-step.sh v1.31.<patch>+k3s1` (backs up, applies the Plan, waits, lists unhealthy pods).
3. Check Home Assistant, Homebridge and Argo CD before the next hop. Traefik moves to v3 along the way; verify ingress after that hop.

Failed upgrades leave the node cordoned: `kubectl uncordon <node>` and delete the Plan
(`kubectl -n system-upgrade delete plan k3s-server`).

## Restore

Stop k3s, extract the archive over `/var/lib/rancher/k3s`, start k3s:

```bash
systemctl stop k3s
tar --zstd -xf /var/backups/k3s/k3s-<stamp>.tar.zst -C /var/lib/rancher/k3s
systemctl start k3s
```

After you are on the stable channel, replace the pinned `version:` with
`channel: https://update.k3s.io/v1-release/channels/stable` for hands-off upgrades.
