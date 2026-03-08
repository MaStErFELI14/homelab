# Homelab

GitOps-managed homelab running on an Intel NUC with k3s, deployed via ArgoCD.

## Services

| Service | Domain | Description |
|---------|--------|-------------|
| ArgoCD | argocd.beaners.club | GitOps controller (self-managed) |
| Homebridge | homebridge.beaners.club | Apple HomeKit bridge (cameras, ratgdo) |
| Home Assistant | hass.beaners.club | Smart home automations and integrations |
| Matter Server | matter.beaners.club | Matter protocol server for WiFi/Thread devices |

## Stack

- **k3s** - Lightweight Kubernetes (single node)
- **ArgoCD** - GitOps continuous delivery
- **Traefik** - Ingress controller (k3s built-in)
- **cert-manager** - Automated TLS via Let's Encrypt (Cloudflare DNS01)
- **Cloudflare** - DNS for `*.beaners.club`
- **Unifi Cloud Gateway** - Network stack with NextDNS (split DNS)

## Bootstrap

```bash
# 1. Copy and fill in your Cloudflare API token
cp k8s-secrets.yaml.example k8s-secrets.yaml
# Edit k8s-secrets.yaml with your base64-encoded token

# 2. Run bootstrap (installs ArgoCD and applies ApplicationSet)
./bootstrap.sh
```

After bootstrap, ArgoCD takes over and deploys everything from `argocd/cluster-addons/`.

## Structure

```
argocd/
  appset.yaml                  # Bootstrap ApplicationSet
  cluster-addons/
    argocd/                    # ArgoCD self-management
    argocd-apps/               # ApplicationSet managed by ArgoCD
    cert-manager/              # TLS certificate automation
    cert-manager-issuers/      # Let's Encrypt ClusterIssuer
    home-assistant/            # Home Assistant
    homebridge/                # Homebridge (TrueCharts)
    matter-server/             # Matter protocol server
```

Each addon has:
- `app.yaml` - Chart source (repo, version, namespace)
- `values.yaml` - Helm value overrides

## Adding a new addon

1. Create `argocd/cluster-addons/<name>/app.yaml` with chart source
2. Create `argocd/cluster-addons/<name>/values.yaml` with overrides
3. Push to `main` - ArgoCD auto-syncs
