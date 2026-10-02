# Repository Guidelines

GitOps repo for a single-node k3s homelab cluster. Argo CD reconciles everything under `argocd/cluster-addons/` from `main` with auto-sync, prune and self-heal. See `README.md` for layout, update flow, backups and gotchas.

## Structure
- `argocd/cluster-addons/<name>/app.yaml` + `values.yaml`: one folder per addon. `app.yaml` keys must stay in the order `repoURL`, `targetRevision`, `chart`, `namespace` (Renovate regex parses it); extra keys (e.g. `serverSideApply: true`) go after.
- The ApplicationSet exists twice: `argocd/appset.yaml` (bootstrap) and `argocd/cluster-addons/argocd-apps/values.yaml` (live). Change both together.
- `host/backup/` (nightly backup timer on the node) and `k3s-upgrade/` (system-upgrade-controller plans, staged upgrade script) are **not** Argo-managed on purpose.
- `docs/` and `CLAUDE.md` are gitignored; do not rely on them being present.

## Style
- YAML: 2-space indent, lowercase keys, no tabs. Folders named after the component; files are `app.yaml` and `values.yaml`.
- Hosts follow `*.beaners.club`. Keep `namespace` explicit and consistent between `app.yaml` and values.
- Commits: short, imperative (`bump argocd chart`). One addon per PR. PRs state impact (namespaces, hosts, CRDs) and the validation commands used. Co-author/attribution lines as instructed by the harness.

## Validate before opening a PR
Render charts with Helm (CI's `validate` workflow does this on every PR), or locally:
- `helm template <name> <repo>/<chart> --version <ver> -n <ns> -f argocd/cluster-addons/<name>/values.yaml`
- Diff old vs new chart version renders before bumping (`diff <(grep -E "^kind:|^  name:" old) <(... new)`).
- Renovate config: `pnpm dlx --package renovate@44 renovate-config-validator --strict` (needs Node 24; npm fails to install Renovate, use pnpm).
- Cluster checks: `kubectl get applications -n argocd`, `kubectl get pods -A | grep -v -E 'Running|Completed'`, `kubectl get certificate -A`.

## Operating rules
- Never hand-edit live resources: self-heal reverts them. Pausing sync means changing the ApplicationSet in git (and syncing `argocd-apps`).
- Argo CD and the ApplicationSet poll git every ~3 min; force with `kubectl -n argocd annotate applicationset homelab argocd.argoproj.io/application-set-refresh=true --overwrite`.
- Take a backup (`systemctl start k3s-backup` on the node) before upgrading k3s, Argo CD, cert-manager, Home Assistant or Matter. Upgrade one component at a time and verify apps, pods, certificates and `https://{argocd,hass,homebridge,matter}.beaners.club` between steps.
- Read upstream upgrade notes before minor/major bumps (Argo CD needs Server-Side Apply since v3.3; cert-manager 1.18+ changed defaults).
- k3s minor upgrades: one minor at a time via `k3s-upgrade/upgrade-step.sh`. The cluster-side Plan follows `channels/v1.36` for patches only.
- Do not commit real secrets (`k8s-secrets.yaml`, `.env.local` are gitignored). Do not print token values.

## Component notes
- **Home Assistant** (`home` ns): `hostNetwork: true`, Ingress via Traefik, PVC `local-path`. Set `configuration.trusted_proxies` in its values to the ingress/LAN CIDRs. HA reaches Matter at `ws://127.0.0.1:5580/ws`.
- **Matter server** (`home` ns, chart `home-assistant-matter-server` from `charts.derwitt.dev`): now the matter.js server. `livenessProbe`/`readinessProbe` are `null` in values because first start migrates data for minutes and the chart's probes kill it. Migration from python-matter-server is one-way.
- **Homebridge** (`homebridge` ns, bjw-s `app-template`): PVC is chart-owned, bound to an existing volume, `Prune=false`/Retain. Never update Homebridge/Node from inside the UI.
- **Argo CD**: self-managed, `serverSideApply: true`, `server.insecure: true` behind Traefik.
- **Traefik/CoreDNS/metrics-server/local-path**: bundled with k3s; versions change with k3s upgrades.

## Verify after a sync
- `kubectl -n home get pods,svc,sts | egrep 'home-assistant|matter'`
- `kubectl -n home logs -l app.kubernetes.io/name=home-assistant --tail=100`
- `kubectl -n home logs -l app.kubernetes.io/name=home-assistant-matter-server --tail=100`
