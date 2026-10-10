# Homelab

GitOps-managed homelab on an Intel NUC running single-node k3s, deployed with Argo CD. Everything under `argocd/cluster-addons/` is reconciled from `main`.

## Services

| Service | Host | Notes |
|---------|------|-------|
| Argo CD | argocd.beaners.club | Self-managed |
| Home Assistant | hass.beaners.club | `hostNetwork`, PVC on `local-path` |
| Matter server | none (no ingress) | matter.js server, `hostNetwork` |
| Homebridge | homebridge.beaners.club | bjw-s `app-template`, PVC retained |
| Gatus | gatus.beaners.club | Status page and alerts, in-memory state, needs `gatus-secrets` |

Also: Traefik (bundled with k3s), cert-manager (Let's Encrypt via Cloudflare DNS-01, `*.beaners.club`), Cloudflare DNS.
Exact versions live in each addon's `app.yaml`; the cluster itself is on the k3s stable channel (see below).

## Repository layout

```
argocd/
  appset.yaml                  # Bootstrap-only copy of the ApplicationSet
  cluster-addons/<name>/       # app.yaml (chart source) + values.yaml (overrides)
    argocd/  argocd-apps/  cert-manager/  cert-manager-issuers/
    gatus/  home-assistant/  homebridge/  matter-server/
host/backup/                   # Nightly k3s backup (systemd timer), installed on the node
host/heartbeat/                # Dead-man's-switch timer (healthchecks.io ping), installed on the node
host/smart/                    # Weekly SMART disk-health check (systemd timer, reports to Gatus), installed on the node
host/ssh/                      # Key-only SSH drop-in, installed on the node
host/firewall/                 # nftables table dropping LAN access to internal service ports, installed on the node
k3s-upgrade/                   # system-upgrade-controller plans + staged upgrade script
.github/workflows/validate.yaml  # helm template of every chart, Homebridge smoke test, Renovate config check
renovate.json                  # Dependency updates (see below)
bootstrap.sh  k8s-secrets.yaml.example
```

Each addon has `app.yaml` (`repoURL`, `targetRevision`, `chart`, `namespace`, optional `serverSideApply: true`) and `values.yaml`. The ApplicationSet picks up every `app.yaml` automatically.

## How changes reach the cluster

1. Merge to `main`. The ApplicationSet (defined in `argocd-apps/values.yaml`, managed by Argo CD itself) generates one Application per addon with auto-sync, prune and self-heal.
2. Argo CD and the ApplicationSet poll git every ~3 minutes. To pull immediately:
   `kubectl -n argocd annotate applicationset homelab argocd.argoproj.io/application-set-refresh=true --overwrite`
3. Change the ApplicationSet in **both** `argocd/appset.yaml` (bootstrap) and `argocd-apps/values.yaml` (live).

Never edit live resources by hand: self-heal reverts them. To pause an app, change the ApplicationSet in git.

## Bootstrap

```bash
cp k8s-secrets.yaml.example k8s-secrets.yaml   # add base64 Cloudflare token (gitignored)
./bootstrap.sh                                  # installs Argo CD at the version in argocd/app.yaml
```

## Updates

- **Charts and images:** Renovate (GitHub app) opens PRs. Stable releases only, 3-day release-age wait. Chart **patch** bumps automerge once `validate` passes; **minor/major** need a manual merge (label `manual-review`). Read the upstream upgrade notes first; Argo CD and cert-manager have had breaking changes.
- **k3s:** `k3s-upgrade/plans/server-plan-channel.yaml` follows patch releases of the current minor (`v1.36`). Minor bumps are manual, one at a time, via `k3s-upgrade/upgrade-step.sh` (see `k3s-upgrade/README.md`).
- **OS:** unattended-upgrades with automatic reboot at 04:30 (only when nobody is logged in).

## Backups

`host/backup/` installs a nightly timer (03:30 UTC) that stops k3s for a few seconds and archives the sqlite datastore, tokens/TLS and all `local-path` PVC data to `/var/backups/k3s` (14 kept). Set `BACKUP_REMOTE` in `/etc/default/k3s-backup` for an off-box copy. **Take a backup before any risky change** (`systemctl start k3s-backup`). Restore steps are in `k3s-upgrade/README.md`.

After each run the script reports to the Gatus external endpoint `host_nightly-backup` (`POST $GATUS_URL/api/v1/endpoints/<key>/external?success=true|false`, bearer token). It retries for up to ~5 minutes because Gatus runs inside k3s, a failure sends `success=false`, and a heartbeat problem never fails the backup. Optional variables in `/etc/default/k3s-backup` (0600): `BACKUP_HEARTBEAT_TOKEN` (unset = no heartbeat), `GATUS_URL` (default `https://gatus.beaners.club`), `GATUS_ENDPOINT_KEY`. Re-run `host/backup/install.sh` after changing the script.

### Off-box backups (restic to S3-compatible storage)

After the local archive is written and k3s is back up, the script uploads it with `restic backup --tag k3s` to an encrypted repository (client-side encryption; the bucket only holds restic's data layout) and then prunes with `--keep-daily 14 --keep-weekly 4`. Failed uploads are retried 3 times with backoff. The local backup still counts, but the heartbeat then reports `success=false&error=offsite-upload-failed`, so Gatus alerts. The upload is enabled only when `RESTIC_REPOSITORY` is set in `/etc/default/k3s-backup` (0600, root). Variables (names only): `RESTIC_REPOSITORY` (`s3:<endpoint host>/<bucket>/k3s`), `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` (`auto` for Cloudflare R2). After a successful upload and prune the script also runs `restic stats --mode raw-data` and logs the repository size to the journal. If it exceeds `R2_MAX_BYTES` (optional, default 6000000000, about 6 GB, set in `/etc/default/k3s-backup`) the heartbeat is `success=false&error=r2-size-high` instead of success; the backup and upload still count and the script exits 0. Precedence when several things fail: `backup-failed` > `offsite-upload-failed` > `r2-size-high`. If `restic stats` itself fails, a warning is logged and no alert is sent (size unknown). As a second safeguard, also set a usage-based billing notification in the Cloudflare dashboard (Notifications) so storage growth is flagged even if the script cannot run. Install `restic` on the node (`apt install restic`) and run `restic init` once. **Store the restic password and the bucket keys in your password manager as well: without the password the off-box data is unrecoverable.**

Restore on a fresh node (install k3s of the same minor version first, then stop it):

```bash
set -a; . /etc/default/k3s-backup; set +a   # or export the five variables by hand
restic snapshots --tag k3s
mkdir /var/tmp/restore && restic restore latest --tag k3s --target /var/tmp/restore
systemctl stop k3s
tar --zstd -xf "$(find /var/tmp/restore -name 'k3s-*.tar.zst')" -C /var/lib/rancher/k3s
systemctl start k3s
```

Then check `kubectl get nodes`, Argo CD applications, certificates, and remove `/var/tmp/restore`. Use `restic restore <snapshot-id>` for an older snapshot, and `restic check` to verify the repository.

## Dead-man's switch

`host/heartbeat/` installs a timer (every 5 minutes) that pings a healthchecks.io check **only if** the node is Ready and Gatus answers `/health` (queried via its Service ClusterIP, so cert/DNS/ingress problems cannot mask or fake Gatus health). If either fails it stays silent and the missed ping raises the alert, covering a dead node, k3s or Gatus. `HEALTHCHECK_PING_URL` lives in `/etc/default/homelab-heartbeat` (0600, not in git). Install with `host/heartbeat/install.sh` on the node.

## Disk health

`host/smart/` installs a weekly timer (Sundays 04:10 UTC, up to 30 min random delay, `Persistent=true`) that runs `smartctl -H -A` on the system disk and reports to the Gatus external endpoint `host_disk-health` (Discord alert on the first failure; the endpoint expects a push at least every 8 days). It reports `success=false` with a short error when the overall health is not PASSED (`smart-failed`), when Reallocated_Sector_Ct, Current_Pending_Sector, Offline_Uncorrectable or Uncorrectable_Error_Cnt are above 0 (`...-increased` if they grew since the previous run, otherwise `...-nonzero`), when the CRC error count grew (`crc-errors-increased`), when the normalized Wear_Leveling_Count drops below 20 (`wear-below-20`) or the temperature exceeds 60 C (`temp-<C>`). The previous values are kept in `/var/lib/homelab-smart/last.json`, a one-line summary goes to the journal (`journalctl -u homelab-smart-check`), and an unreachable Gatus is retried and logged but never fails the unit. Config in `/etc/default/homelab-smart-check` (0600): `DISK_HEALTH_TOKEN`, optional `GATUS_URL`, `GATUS_ENDPOINT_KEY`, `SMART_DEVICE` (default `/dev/sda`). Needs `smartmontools` and `python3`; the token is the `DISK_HEALTH_TOKEN` key of the `gatus-secrets` Secret. Install with `host/smart/install.sh`. Setting `SMART_TEST_FORCE_FAIL=1` for one manual run sends a test failure without touching the state.

## Host firewall

`host/firewall/` installs a separate nftables table (`inet homelab_fw`, input hook, policy accept) that drops TCP 5580 (Matter), 8581 (Homebridge UI), 6443 (k3s API) and 10250 (kubelet) unless the traffic is from loopback, established, from an address owned by the node, or from the cluster/service CIDRs (templated at install, k3s defaults). k3s rules and the distro `nftables.service` are not used. Ingress, SSH, Home Assistant (8123) and HomeKit ports stay open. `install.sh` checks the syntax, arms a 5 minute rollback timer (`homelab-fw-rollback`), loads the table via `homelab-fw.service` (persistent) and tells you to cancel the timer (`systemctl stop homelab-fw-rollback.timer`) after verifying. Remove with `systemctl disable --now homelab-fw`. For remote `kubectl`, tunnel over SSH.

## SSH hardening

`host/ssh/` installs `/etc/ssh/sshd_config.d/10-homelab-hardening.conf` (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin prohibit-password`). The `10-` prefix matters: sshd is first-match-wins and reads drop-ins before the main file. `install.sh` is idempotent, refuses to run without an authorized key, runs `sshd -t`, arms a 5 minute rollback timer (`homelab-ssh-rollback`) and reloads sshd. Keep your session open, test with a new connection (key works, password is refused), then `systemctl stop homelab-ssh-rollback.timer`. Remove by deleting the drop-in and running `systemctl reload ssh`.

## Gotchas

- **Matter is one-way:** the matter.js server migrated the old python-matter-server data; there is no supported path back. Its probes are disabled (`values.yaml`) because first start takes minutes and the chart's liveness probe kills it.
- **Argo CD uses Server-Side Apply** (`serverSideApply: true` in its `app.yaml`): required since v3.3 for the ApplicationSet CRD size.
- `hostNetwork` pods (Home Assistant, Matter, Homebridge) briefly fail probes on every node restart; that is expected.
- Secrets: never commit real values. `k8s-secrets.yaml` and `.env.local` are gitignored.

## Adding an addon

1. `argocd/cluster-addons/<name>/app.yaml` with `repoURL`, `targetRevision`, `chart`, `namespace` in exactly that order (Renovate parses it).
2. `values.yaml` with overrides.
3. Open a PR; `validate` renders the chart. Merge and Argo CD deploys it.
