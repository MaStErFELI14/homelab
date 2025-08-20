# Repository Guidelines

## Project Structure & Module Organization
- `argocd/appset.yaml`: ApplicationSet used for bootstrap (apps-of-apps).
- `argocd/cluster-addons/<component>/`: One folder per addon with:
  - `app.yaml`: Chart source (repoURL, chart, version, namespace).
  - `values.yaml`: Helm overrides applied by the ApplicationSet.
- Root files: `bootstrap.sh` (installs Argo CD and applies manifests), `k8s-secrets.yaml` (example secret), `.gitignore`, `README.md`.

## Build, Test, and Development Commands
- `./bootstrap.sh`: Add Argo Helm repo, install Argo CD, apply ApplicationSet and secrets.
- Render a chart locally (example: cert-manager):
  - `helm template cm jetstack/cert-manager --version 1.16.2 -n cert -f argocd/cluster-addons/cert-manager/values.yaml`
- Preview changes against the cluster:
  - `kubectl apply --dry-run=server -f argocd/appset.yaml`
  - `kubectl diff -f argocd/appset.yaml`
- Inspect Argo resources:
  - `kubectl get applications,applicationsets -n argocd`

## Coding Style & Naming Conventions
- YAML: 2-space indentation, lowercase keys, no tabs.
- Keep addon folders named after the deployed component; files must be `app.yaml` and `values.yaml`.
- Domains and hosts follow repo usage (e.g., `*.beaners.club`). Keep `namespace` explicit in `app.yaml` and values consistent.

## Testing Guidelines
- Validate Helm values by rendering: see `helm template` example above.
- Validate Kubernetes compatibility before merging: `kubectl apply --dry-run=server ...` and `kubectl diff ...`.
- Small, reviewable changes: one addon per PR when possible.

## Commit & Pull Request Guidelines
- Commits: short, imperative present tense (e.g., `add home-assistant ingress`, `bump argocd chart`).
- PRs include:
  - Summary of change and impact (namespaces, hosts, CRDs).
  - Commands used to validate (`helm template`, `kubectl diff`).
  - Screenshots or logs if Argo CD sync is relevant.
  - Linked issue (if any) and update to docs if structure changed.

## Security & Configuration Tips
- Do not commit real secrets. Prefer an external secret manager; if using `k8s-secrets.yaml`, store placeholders and apply real values out-of-band (base64-encoded).
- Ensure issuer/secret names match across `cert-manager-issuers` and any ingress TLS settings.
