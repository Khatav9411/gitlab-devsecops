#!/usr/bin/env bash
#
# Bootstraps the AKS cluster after `terraform apply` has run.
# Idempotent — safe to re-run.
#
# Prerequisites in your shell BEFORE running:
#   az login + correct subscription set
#   helm, kubectl installed
#   (optional) export DH_USER=... NEW_DH_TOKEN=...   to auto-create DH pull secrets
#
# What it does:
#   1. helm repo add/update
#   2. NGINX ingress (with externalTrafficPolicy=Local — the AKS+NGINX gotcha fix)
#   3. cert-manager + ClusterIssuer (Let's Encrypt prod)
#   4. Argo CD + Argo CD Image Updater
#   5. External Secrets Operator (workload identity → KV)
#   6. Grafana (workload identity → Azure Monitor)
#   7. Docker Hub pull secrets (if creds in env)
#   8. Argo Application (Argo then manages myapp from k8s/ in git)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT/terraform"

TF_RG=$(terraform output -raw resource_group_name)
TF_CLUSTER=$(terraform output -raw cluster_name)
TF_ESO_CLIENT=$(terraform output -raw eso_uami_client_id)
TF_GRAFANA_CLIENT=$(terraform output -raw grafana_uami_client_id)
TF_TENANT=$(terraform output -raw tenant_id)
TF_SUB=$(az account show --query id -o tsv)
TF_KV_URI=$(terraform output -raw key_vault_uri)

cd "$REPO_ROOT"

echo "==> Kube credentials"
az aks get-credentials -g "$TF_RG" -n "$TF_CLUSTER" --overwrite-existing >/dev/null

echo "==> Helm repos"
helm repo add ingress-nginx    https://kubernetes.github.io/ingress-nginx >/dev/null
helm repo add jetstack         https://charts.jetstack.io                 >/dev/null
helm repo add argo             https://argoproj.github.io/argo-helm       >/dev/null
helm repo add external-secrets https://charts.external-secrets.io         >/dev/null
helm repo add grafana          https://grafana.github.io/helm-charts      >/dev/null
helm repo update >/dev/null

echo "==> NGINX ingress (externalTrafficPolicy=Local — required for AKS LB health probes)"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.externalTrafficPolicy=Local \
  --wait --timeout 5m

echo "==> cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --wait --timeout 5m

echo "==> ClusterIssuer (one-time)"
kubectl apply -f bootstrap/cluster-issuer.yaml

echo "==> Argo CD"
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 7.7.10 \
  --set configs.params."server\.insecure"=true \
  --wait --timeout 5m

echo "==> Argo CD Image Updater"
helm upgrade --install argocd-image-updater argo/argocd-image-updater \
  --namespace argocd \
  --version 0.12.0 \
  --wait --timeout 3m

echo "==> External Secrets Operator (workload identity client_id=${TF_ESO_CLIENT})"
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --version 0.10.7 \
  --set installCRDs=true \
  --set "serviceAccount.annotations.azure\.workload\.identity/client-id=${TF_ESO_CLIENT}" \
  --set-string "podLabels.azure\.workload\.identity/use=true" \
  --wait --timeout 4m

echo "==> Grafana"
echo "    NOTE: argo/grafana-values.yaml has hardcoded UAMI/subscription/tenant IDs."
echo "    If terraform recreated resources, the IDs may have changed:"
echo "      Expected client_id:      ${TF_GRAFANA_CLIENT}"
echo "      Expected subscription:   ${TF_SUB}"
echo "      Expected tenant:         ${TF_TENANT}"
echo "    Update argo/grafana-values.yaml then rerun this script."
helm upgrade --install grafana grafana/grafana \
  --namespace grafana --create-namespace \
  --version 8.5.7 \
  -f argo/grafana-values.yaml \
  --wait --timeout 5m

echo "==> Docker Hub pull secrets"
if [ -n "${NEW_DH_TOKEN:-}" ] && [ -n "${DH_USER:-}" ]; then
  python3 - <<'PYEOF'
import json, base64, subprocess, os
user, token = os.environ['DH_USER'], os.environ['NEW_DH_TOKEN']
auth = base64.b64encode(f'{user}:{token}'.encode()).decode()

def apply(ns, name, dcj):
    subprocess.run(['kubectl', 'create', 'ns', ns, '--dry-run=client', '-o', 'yaml'],
                   capture_output=True).stdout
    subprocess.run(['kubectl', 'apply', '-f', '-'], input=f'''apiVersion: v1
kind: Namespace
metadata:
  name: {ns}
''', text=True, capture_output=True)
    manifest = f'''apiVersion: v1
kind: Secret
metadata:
  name: {name}
  namespace: {ns}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: {base64.b64encode(dcj.encode()).decode()}
'''
    subprocess.run(['kubectl', 'apply', '-f', '-'], input=manifest, text=True, check=True)

multi  = json.dumps({'auths': {
    'https://index.docker.io/v1/': {'auth': auth},
    'registry-1.docker.io':        {'auth': auth},
    'docker.io':                   {'auth': auth},
}})
single = json.dumps({'auths': {'https://index.docker.io/v1/': {'auth': auth}}})

apply('argocd',  'dockerhub-creds',  multi)
apply('myapp',   'dockerhub-secret', single)
apply('todoapp', 'dockerhub-secret', single)
PYEOF
else
  echo "    Skipped (DH_USER + NEW_DH_TOKEN env vars not set)."
  echo "    Set them and re-run, or create the secrets manually."
fi

echo "==> Render todoapp manifests with Cosmos endpoint + UAMI client ID"
TODOAPI_CLIENT=$(cd terraform && terraform output -raw todoapi_uami_client_id)
COSMOS_ENDPOINT=$(cd terraform && terraform output -raw cosmos_endpoint)
sed -i.bak \
  -e "s|REPLACE_TODOAPI_UAMI_CLIENT_ID|${TODOAPI_CLIENT}|g" \
  k8s/todoapp/serviceaccount-api.yaml
sed -i.bak \
  -e "s|REPLACE_COSMOS_ENDPOINT|${COSMOS_ENDPOINT}|g" \
  k8s/todoapp/api-deployment.yaml
rm -f k8s/todoapp/*.bak
echo "    Rendered. Commit + push so Argo syncs them:"
echo "      git add k8s/todoapp/ && git commit -m 'render todoapp manifests' && git push"

echo "==> Argo Applications"
kubectl apply -f argo/myapp-application.yaml
kubectl apply -f argo/todoapp-application.yaml

cat <<EOF

================================================================================
 Bootstrap complete.

 Argo CD UI:
   kubectl -n argocd port-forward svc/argocd-server 8080:443
   open https://localhost:8080
   admin password:
     kubectl -n argocd get secret argocd-initial-admin-secret \\
       -o jsonpath='{.data.password}' | base64 -d; echo

 Grafana UI: https://grafana.shugeinfo.xyz/
   admin password:
     kubectl -n grafana get secret grafana \\
       -o jsonpath='{.data.admin-password}' | base64 -d; echo

 Apps (require DNS A records → ingress LB IP):
   myapp:  https://myapp.shugeinfo.xyz/
   todo:   https://todo.shugeinfo.xyz/

 Add the todo DNS A record + push the rendered k8s/todoapp/ manifests, and
 Argo will sync the 3-tier app (React + Express + Cosmos DB).
================================================================================
EOF
