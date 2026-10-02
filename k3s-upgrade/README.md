# k3s upgrades

State: the node runs the k3s stable channel (v1.36.x). `plans/server-plan-channel.yaml` is applied on the
cluster and installs **patch** releases of the current minor automatically (`channels/v1.36`).
This directory is deliberately **not** managed by Argo CD: merging a Plan to `main` must never start an upgrade by itself.

Kubernetes does not allow skipping minor versions, so minor bumps are manual, one at a time.

## Setup (already done; for rebuilding the node)

```bash
# system-upgrade-controller (pinned release)
kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/download/v0.20.2/crd.yaml
kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/download/v0.20.2/system-upgrade-controller.yaml
kubectl apply -f plans/server-plan-channel.yaml

# nightly backups (on the node, as root): copy host/backup there and run install.sh
```

Offsite copy: put `BACKUP_REMOTE=user@host:/path` in `/etc/default/k3s-backup`.
Unattended OS upgrades reboot at 04:30 (`/etc/apt/apt.conf.d/52auto-reboot`, only when nobody is logged in); the backup runs at 03:30.

## Moving to the next minor (e.g. v1.36 -> v1.37)

1. Check addon compatibility and upstream notes (Traefik, CoreDNS and other bundled components change with k3s).
2. Find the latest patch of the next minor: `curl -s https://api.github.com/repos/k3s-io/k3s/releases` (the update channel for the new minor also works).
3. `./upgrade-step.sh v1.37.<patch>+k3s1`: takes a backup, applies a pinned Plan (replacing the channel Plan), waits for the node to report the version, lists unhealthy pods and Argo apps.
4. Verify Home Assistant, Matter devices, Homebridge, Argo CD and all four `*.beaners.club` hosts.
5. Edit `plans/server-plan-channel.yaml` to the new minor channel (`.../channels/v1.37`), re-apply it, and commit the change.

Failed upgrades leave the node cordoned: `kubectl uncordon <node>` and delete the Plan (`kubectl -n system-upgrade delete plan k3s-server`).
A Plan pod showing `Unknown` after the node restarts is normal (the k3s restart kills it); delete it.

## Restore

Whole node (datastore, tokens, PVC data):

```bash
systemctl stop k3s
tar --zstd -xf /var/backups/k3s/k3s-<stamp>.tar.zst -C /var/lib/rancher/k3s
systemctl start k3s
```

Single app's data: Argo CD self-heal will scale the workload back up, so first pause sync by disabling `automated` in the ApplicationSet (git), scale the StatefulSet to 0, move the PVC directory under `/var/lib/rancher/k3s/storage/` aside, extract only that directory from the archive, then scale up and re-enable sync.
Test restores on a copy: the archive contains `server/db/state.db`, which can be integrity-checked with Python's `sqlite3`.
