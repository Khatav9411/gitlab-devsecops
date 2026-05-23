# Deployment Guide

End-to-end runbook to bring this POC up from a clean Azure subscription, and to
tear it back down. Roughly **30–45 minutes** end-to-end the first time.

---

## 0. Prerequisites

### Accounts

| Account | Used for |
|---|---|
| Azure subscription (Owner or User Access Admin on the target RG) | AKS, Cosmos, Key Vault, UAMIs, role assignments |
| GitLab.com (free tier) | Git hosting, CI/CD, security templates |
| Docker Hub | Container registry (POC uses public repos) |
| GoDaddy (or any DNS provider for `shugeinfo.xyz`) | A records for the three app hostnames |

### Local tools

```bash
# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# kubectl  (after az is installed)
az aks install-cli

# Helm 3
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Terraform >= 1.6
sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform

# Other niceties (used by bootstrap.sh and verification commands)
sudo apt-get install -y python3 jq
```

Verify:
```bash
az version && kubectl version --client && helm version && terraform version
```

### Clone the repo

```bash
git clone https://gitlab.com/Siddhuge/gitlab-devsecops-poc.git
cd gitlab-devsecops-poc
```

---

## 1. Azure login

```bash
az login                                        # opens browser
az account set --subscription "<your-subscription-id>"
az account show -o table                        # confirm

# Register Azure providers (one-time per subscription)
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.OperationsManagement
az provider register --namespace Microsoft.OperationalInsights
az provider register --namespace Microsoft.DocumentDB
```

---

## 2. Provision infrastructure with Terraform

The Terraform module creates:

- Resource group `rg-aks-poc`
- AKS cluster `aks-poc` (2× `Standard_B2s`, OIDC issuer + Workload Identity + Container Insights + Microsoft Defender)
- Log Analytics workspace
- Azure Key Vault with RBAC + sample secret
- Azure Cosmos DB account (**free tier**: 1000 RU/s + 25 GB free per subscription) + database `todoapp` + container `todos`
- Three User-Assigned Managed Identities (UAMIs) + federated identity credentials, one each for:
  - External Secrets Operator (reads KV)
  - Grafana (reads Azure Monitor + Log Analytics)
  - todoapi backend (reads/writes Cosmos)
- All required RBAC role assignments

```bash
cd terraform
terraform init
terraform plan -out tfplan
terraform apply tfplan
# ~8–10 minutes
```

Save the outputs:
```bash
terraform output
```

You'll see Cosmos endpoint, UAMI client IDs, tenant ID, KV URI, etc.

---

## 3. Run the bootstrap script

The script installs everything in the cluster that isn't part of the app
manifests themselves — ingress controller, cert-manager, Argo CD, Image
Updater, External Secrets Operator, and Grafana — then renders the
placeholders in `k8s/todoapp/` with real values from the Terraform outputs.

### 3.1 Set Docker Hub credentials

Create a personal access token at https://hub.docker.com (Account Settings →
Security → New Access Token, Read & Write). Then in your shell:

```bash
export DH_USER='<your-dockerhub-username>'
export NEW_DH_TOKEN='<your-dh-pat>'
```

### 3.2 Run bootstrap

```bash
cd ..    # back to repo root
./bootstrap/bootstrap.sh
# ~5 minutes
```

The script is idempotent — safe to re-run if anything fails partway through.

What it does:

1. Adds all required Helm repos.
2. Installs **NGINX ingress** with `externalTrafficPolicy: Local` (critical for AKS — the default `Cluster` causes Azure LB health probes to fail with 404 because NGINX returns 404 on probe requests without the right Host header).
3. Installs **cert-manager** + applies the `letsencrypt-prod` ClusterIssuer.
4. Installs **Argo CD** + **Argo CD Image Updater**.
5. Installs **External Secrets Operator** with the ESO UAMI client ID baked into the service account annotation.
6. Installs **Grafana** with the Grafana UAMI client ID baked in, Azure Monitor data source provisioned, `workload_identity_enabled = true` in `grafana.ini`.
7. Creates the Docker Hub pull secrets in `argocd`, `myapp`, and `todoapp` namespaces.
8. Renders `REPLACE_*` placeholders in `k8s/todoapp/` with values from Terraform outputs.
9. Applies the two Argo Applications (`myapp` and `todoapp`).

### 3.3 Commit the rendered manifests

The render step modified `k8s/todoapp/serviceaccount-api.yaml` and
`k8s/todoapp/api-deployment.yaml` with real values. Commit so Argo can sync
from git:

```bash
git add k8s/todoapp/
git commit -m "render todoapp manifests"
git push origin main
```

---

## 4. Configure GitLab CI/CD

GitLab project → **Settings → CI/CD → Variables → Add variable**. All
Protected; `DOCKERHUB_TOKEN` also Masked.

| Key | Value |
|---|---|
| `DOCKERHUB_USERNAME` | your Docker Hub username |
| `DOCKERHUB_TOKEN` | the same PAT you exported above |

No Azure credentials in CI — deployments are GitOps via Argo CD running
inside the cluster, which uses workload identity for everything.

---

## 5. DNS

Look up the NGINX LoadBalancer public IP:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; echo
```

In your DNS provider, create **three A records** pointing to that IP:

| Host | Type | Value |
|---|---|---|
| `myapp.shugeinfo.xyz` | A | `<NGINX LB IP>` |
| `grafana.shugeinfo.xyz` | A | `<NGINX LB IP>` |
| `todo.shugeinfo.xyz` | A | `<NGINX LB IP>` |

TTL `600` is fine for a POC. Wait for propagation (`dig +short
<host> @8.8.8.8` returns the IP from multiple resolvers). Don't proceed
until DNS is consistent — Let's Encrypt rate-limits failed challenges, and
old DNS will burn rate-limit budget.

---

## 6. Wait for the pipeline to build images

The push from step 3.3 triggered a pipeline. Watch it in GitLab UI →
**Build → Pipelines**. Stages:

1. `validate` — hadolint on Dockerfiles, kustomize lint on k8s/
2. `test` — SAST (Semgrep) + Secret Detection + Dependency Scanning in parallel
3. `build` — matrix builds 3 images (myapp, todoapi, todofrontend) in parallel via Kaniko
4. `scan` — matrix container_scanning on each pushed image

Once it's green, Argo CD Image Updater (polls Docker Hub every 2 minutes)
detects the new commit-SHA tags and bumps the Argo Application's kustomize
image override. Argo redeploys.

---

## 7. Verify

### Check certificates

```bash
kubectl get cert --all-namespaces
# All three should be Ready=True within 1–3 minutes after DNS is set
```

### Check Argo applications

```bash
kubectl -n argocd get application
# myapp + todoapp should both be Synced + Healthy
```

### Check pods

```bash
kubectl -n myapp   get pod
kubectl -n todoapp get pod
kubectl -n grafana get pod
# All Running, 1/1 Ready
```

### Smoke test the apps

```bash
# myapp — exposes a KV-backed secret on /
curl -sS https://myapp.shugeinfo.xyz/

# todoapp — full CRUD on Cosmos DB through the React frontend
curl -sS https://todo.shugeinfo.xyz/api/todos
curl -sS -X POST -H "Content-Type: application/json" \
  -d '{"text":"hello from cli"}' \
  https://todo.shugeinfo.xyz/api/todos
curl -sS https://todo.shugeinfo.xyz/api/todos | jq .

# Open the React UI in a browser
open https://todo.shugeinfo.xyz/
```

### Verify data lands in Cosmos

Browser: https://portal.azure.com → Cosmos DB → `cosmos-aks-poc-<random>` →
**Data Explorer** → `todoapp` → `todos` → `Items`. You should see your todos
as JSON documents.

### Get UI passwords

```bash
# Argo CD initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
# Port-forward then open https://localhost:8080
kubectl -n argocd port-forward svc/argocd-server 8080:443

# Grafana admin password
kubectl -n grafana get secret grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
# Browse https://grafana.shugeinfo.xyz/
```

In Grafana → Connections → Data sources → Azure Monitor → **Save & test**
(workload identity should pass), then Dashboards → Import → use Grafana.com
ID `10956` (Azure Insights/Containers) and pick your subscription / cluster.

---

## 8. Day-2 operations

Every push to `main` from this point on:

1. GitLab CI builds new image tags (`:<git-sha-short>`) and pushes to Docker Hub.
2. Container scanning runs against each image.
3. Argo CD Image Updater (in-cluster, polls every 2 min) detects the new tag, bumps the Argo Application's kustomize override.
4. Argo CD applies the change; rolling update completes; `kubectl rollout status` returns success.

**Zero Azure credentials touch CI.** Zero static Cosmos / Key Vault secrets
ever exist in the cluster. Every Azure data-plane call (ESO → KV, Grafana →
Log Analytics, todoapi → Cosmos) is brokered by federated identity
credentials and the Azure Workload Identity webhook.

---

## 9. Teardown

```bash
# Helm releases first, so the LoadBalancer releases its public IP cleanly
helm -n argocd            uninstall argocd argocd-image-updater
helm -n external-secrets  uninstall external-secrets
helm -n grafana           uninstall grafana
helm -n cert-manager      uninstall cert-manager
helm -n ingress-nginx     uninstall ingress-nginx

# Tear down everything Terraform manages (RG + AKS + LAW + KV + Cosmos + UAMIs + federated creds)
cd terraform
terraform destroy -auto-approve

# Optional: delete the DNS A records in your DNS provider
# Optional: delete the Docker Hub repos and PAT
# Optional: delete the GitLab CI variables (DOCKERHUB_USERNAME, DOCKERHUB_TOKEN)
```

After `terraform destroy` the billing meter stops. AKS, LB, public IPs, LAW,
Cosmos — all gone. Soft-deleted KVs reserve the name for 7 days but don't
bill.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pipeline job stuck on "no runners that match all the job's tags" | Free GitLab.com shared runners need your account to validate a credit card (anti-abuse, no charge) | Validate at GitLab → avatar → Edit profile → Validate account |
| `kubectl get nodes` returns empty silently | snap-installed kubectl 1.35+ talking to a 1.34 server — known quirk | Use `kubectl get nodes --request-timeout=15s -v=2` or install kubectl via `az aks install-cli` |
| Cert stuck `Ready=False` with `Timeout during connect (likely firewall problem)` | DNS A record points at the wrong IP, OR the LB rejects connections | Verify `dig +short <host> @8.8.8.8` matches NGINX LB IP. If LB rejects, see next row. |
| External `curl` to a host hangs (TCP timeout) but the same host responds from inside the cluster | NGINX svc has `externalTrafficPolicy: Cluster` — Azure LB probe gets 404 from NGINX → backend marked unhealthy | `kubectl -n ingress-nginx patch svc ingress-nginx-controller --type=merge -p '{"spec":{"externalTrafficPolicy":"Local"}}'`. bootstrap.sh sets this automatically. |
| Argo `OutOfSync` on `ExternalSecret` even though it works | ESO admission webhook adds defaulted fields not in your git manifest | Write the defaults explicitly: `deletionPolicy: Retain`, `conversionStrategy: Default`, `decodingStrategy: None`, `metadataPolicy: None` |
| Image Updater error: "repository name not known to registry" | DH repo doesn't exist yet (image hasn't been pushed by pipeline) | Wait for the first successful pipeline run — Docker Hub auto-creates repos on first push |
| Grafana data source asks for tenant/client ID despite `azureAuthType: workloadidentity` in values | `grafana.ini > [azure] > workload_identity_enabled = true` is missing | Already set in `argo/grafana-values.yaml`. If you customised values, ensure that block is present, then `helm upgrade` |
| Local `curl <host>` times out but `--resolve` works | Your local DNS resolver cached the previous (stale) IP | `sudo systemd-resolve --flush-caches` or restart NetworkManager |
| Bootstrap fails on ESO with `cannot unmarshal bool into Go struct field … labels of type string` | Helm `--set` coerced a string to bool | Use `--set-string` for label values; bootstrap.sh already does this |
