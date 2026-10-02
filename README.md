# Homelab

GitOps-managed homelab on an Intel NUC running single-node k3s, deployed with Argo CD. Everything under `argocd/cluster-addons/` is reconciled from `main`.

## Services

| Service | Host | Notes |
|---------|------|-------|
| Argo CD | argocd.beaners.club | Self-managed |
| Home Assistant | hass.beaners.club | `hostNetwork`, PVC on `local-path` |
| Matter server | matter.beaners.club | matter.js server, `hostNetwork` |
| Homebridge | homebridge.beaners.club | bjw-s `app-template`, PVC retained |

Also: Traefik (bundled with k3s), cert-manager (Let's Encrypt via Cloudflare DNS-01, `*.beaners.club`), Cloudflare DNS.
Exact versions live in each addon's `app.yaml`; the cluster itself is on the k3s stable channel (see below).

## Repository layout

```
argocd/
  appset.yaml                  # Bootstrap-only copy of the ApplicationSet
  cluster-addons/<name>/       # app.yaml (chart source) + values.yaml (overrides)
    argocd/  argocd-apps/  cert-manager/  cert-manager-issuers/
    home-assistant/  homebridge/  matter-server/
host/backup/                   # Nightly k3s backup (systemd timer), installed on the node
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

## Gotchas

- **Matter is one-way:** the matter.js server migrated the old python-matter-server data; there is no supported path back. Its probes are disabled (`values.yaml`) because first start takes minutes and the chart's liveness probe kills it.
- **Argo CD uses Server-Side Apply** (`serverSideApply: true` in its `app.yaml`): required since v3.3 for the ApplicationSet CRD size.
- `hostNetwork` pods (Home Assistant, Matter, Homebridge) briefly fail probes on every node restart; that is expected.
- Secrets: never commit real values. `k8s-secrets.yaml` and `.env.local` are gitignored.

## Adding an addon

1. `argocd/cluster-addons/<name>/app.yaml` with `repoURL`, `targetRevision`, `chart`, `namespace` in exactly that order (Renovate parses it).
2. `values.yaml` with overrides.
3. Open a PR; `validate` renders the chart. Merge and Argo CD deploys it.
