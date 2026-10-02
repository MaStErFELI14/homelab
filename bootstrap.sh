#!/usr/bin/env bash
# One-time bootstrap: installs Argo CD, then hands everything else to GitOps.
# The Argo CD chart version is read from argocd/cluster-addons/argocd/app.yaml
# so it cannot drift from what Argo CD later manages (Renovate bumps app.yaml).
set -euo pipefail
cd "$(dirname "$0")"

version=$(awk '/^targetRevision:/ {gsub(/"/, "", $2); print $2}' argocd/cluster-addons/argocd/app.yaml)

helm repo add argo https://argoproj.github.io/argo-helm
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm template --release-name argocd argo/argo-cd --version "$version" --namespace argocd \
  -f argocd/cluster-addons/argocd/values.yaml | kubectl apply --server-side --force-conflicts -f -
kubectl apply -f argocd/appset.yaml
kubectl apply -f k8s-secrets.yaml
