helm repo add argo https://argoproj.github.io/argo-helm
kubectl create namespace argocd
helm template --release-name argocd argo/argo-cd --version 7.7.6 --namespace argocd -f argocd/cluster-addons/argocd/values.yaml | kubectl apply -f -
kubectl apply -f argocd/appset.yaml
kubectl apply -f k8s-secrets.yaml