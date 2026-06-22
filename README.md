# GitLab DevSecOps POC on AKS

An end-to-end **enterprise-grade DevSecOps pipeline** for Azure Kubernetes
Service. Push code to GitLab → CI builds and scans container images → Argo
CD reconciles the cluster → app is live on TLS, with secrets pulled from
Azure Key Vault at runtime and metrics flowing into Grafana.

Built to demonstrate every layer of a real production setup while staying
on the **free / cheap tier** of every service (~$50/month total).

See [`deployment.md`](deployment.md) for the step-by-step bring-up runbook.

---

## What this POC demonstrates

Two applications running on the same cluster:

1. **`myapp`** — a small Express service whose only purpose is to prove the
   **secrets pipeline**: a value lives in Azure Key Vault → External Secrets
   Operator pulls it via workload identity → mounts it into the pod as an
   env var → the app surfaces it on `GET /`.

2. **`todoapp`** — a true **3-tier app**:
   - **React + Vite frontend** served by `nginx-unprivileged` (uid 101).
   - **Node + Express API** using `@azure/cosmos` with
     `DefaultAzureCredential`.
   - **Azure Cosmos DB** (serverless, free tier) with `local_authentication_disabled = true` — Entra ID is the only way in.

   The backend writes to Cosmos using a **federated Kubernetes service
   account token** that Azure AD exchanges for an access token. **No
   connection string, no master key, no secret of any kind exists in the
   cluster.**

Plus the supporting platform:

- **GitLab CI/CD** pipeline (build → SAST → secret detection → dep scan → container scan)
- **Argo CD** for GitOps with **Argo CD Image Updater** for image-tag bumps
- **Grafana** with Azure Monitor data source, also via workload identity
- **cert-manager** + **Let's Encrypt** for TLS on every external host
- **NGINX ingress** as the single entry point
- **Terraform** for all Azure resources

---

## Architecture

```
                                    ┌──────────────────────────────────────────────────────┐
                                    │                     GitLab.com                       │
                                    │                                                      │
                              push  │   Repo  ──►  CI Pipeline (SAST, scans, Kaniko build) │
                                    │                          │                           │
                                    └──────────────────────────┼───────────────────────────┘
                                                               ▼
                                                        Docker Hub
                                                               │
                                                               │  (poll every 2 min)
                                                               ▼
   ┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
   │                                            AKS cluster                                          │
   │                                                                                                 │
   │   ┌────────────────┐         ┌───────────────────┐                                              │
   │   │  Argo CD       │◄────────│  Image Updater    │   detects new SHA tag                        │
   │   │  watches git   │  bumps  │  watches Docker   │   rewrites Argo Application                  │
   │   │  k8s/* paths   │  kust.  │  Hub for new tags │                                              │
   │   └───────┬────────┘         └───────────────────┘                                              │
   │           │ syncs                                                                               │
   │           ▼                                                                                     │
   │   ┌─────────────────────────────────────────────────────────────────────────────────────────┐   │
   │   │  Namespace: myapp                                                                       │   │
   │   │    Deployment (Express)  ◄── env DEMO_SECRET ◄── Secret myapp-demo                      │   │
   │   │                                                  ▲                                      │   │
   │   └──────────────────────────────────────────────────┼──────────────────────────────────────┘   │
   │                                                      │                                          │
   │                       ┌───────────────────────┐      │  ExternalSecret (synced every 1m)        │
   │                       │  External Secrets     │──────┘                                          │
   │                       │  Operator (WI → KV)   │                                                 │
   │                       └─────────┬─────────────┘                                                 │
   │                                 │ AAD token                                                     │
   │   ┌─────────────────────────────┼────────────────────────────────────────────────────────────┐  │
   │   │  Namespace: todoapp         │                                                            │  │
   │   │                             │                                                            │  │
   │   │   Ingress  ──► /api ──►  todoapi  (Express, distroless, WI ──► Cosmos)                   │  │
   │   │   (TLS)    ──►  /  ──►   todofrontend (React + nginx-unprivileged)                       │  │
   │   └──────────────────────────────────────────────────────────────────────────────────────────┘  │
   │                                                                                                 │
   │   ┌──────────────┐    ┌─────────────────────────────────────────────────────────────────────┐   │
   │   │ NGINX        │    │  Grafana  ──── Azure Monitor data source (WI ──► Log Analytics)     │   │
   │   │ ingress      │    └─────────────────────────────────────────────────────────────────────┘   │
   │   │ (LB IP)      │                                                                              │
   │   └──────┬───────┘                                                                              │
   └──────────┼──────────────────────────────────────────────────────────────────────────────────────┘
              │
              ▼
   3 DNS A records → NGINX LB → host-routed to myapp / todo / grafana
              │
              │   AAD token-exchange  (Workload Identity webhook injects projected SA token)
              ▼
   ┌─────────────────────────────────────────────────┐
   │  Azure                                          │
   │    Key Vault   ────►  ExternalSecret data       │
   │    Cosmos DB   ────►  Todo data                 │
   │    Log Analytics ──►  Container Insights data   │
   └─────────────────────────────────────────────────┘
```

---

## Tech stack and why

| Layer | Choice | Rationale (interview talking points) |
|---|---|---|
| **IaC** | Terraform | Industry standard for multi-cloud; explicit state; predictable diffs. Modules under `terraform/` create every Azure resource. |
| **Container runtime** | AKS (k8s 1.34) | Managed control plane; native Azure AD integration; Workload Identity + OIDC issuer are first-class. |
| **Node size** | 2 × `Standard_B2s` | Burstable, cheapest viable for hosting NGINX + cert-manager + Argo + ESO + Grafana + 2 apps. Scale-out beats scale-up here. |
| **Registry** | Docker Hub | Free public repos for a POC. Production would use Azure Container Registry with managed identity. |
| **CI/CD** | GitLab CI (free tier) | Built-in SAST, secret detection, dep scan, container scan templates — no extra tools. Shared SaaS runners. |
| **Build tool** | Kaniko | Rootless, runs as a normal container. No `docker:dind` privileged sidecar. |
| **GitOps** | Argo CD | Industry leader; declarative; reconciles git → cluster; built-in drift detection (`OutOfSync`). |
| **Image bumps** | Argo CD Image Updater | Removes the chicken-and-egg of "CI built a new image, now what?". Polls registry every 2 min, mutates Argo Application's kustomize image override. No git write-back required. |
| **Ingress** | NGINX | Mature, well-understood, plays nicely with cert-manager. `externalTrafficPolicy: Local` makes the Azure LB health probe work without faking a Host header. |
| **TLS** | cert-manager + Let's Encrypt HTTP-01 | Automatic issuance & 60-day renewal. ClusterIssuer lives outside the Argo Application (in `bootstrap/`) so it's not pruned. |
| **Secrets** | External Secrets Operator + Azure Key Vault | Keeps secret material out of git, out of CI, out of the manifests. ESO runs as a SA federated to a UAMI with `Key Vault Secrets User` on the vault. |
| **Database** | Azure Cosmos DB (SQL/Core, serverless, free tier) | 1000 RU/s + 25 GB free per subscription, forever. Local auth disabled → only Entra ID accepted. The backend's UAMI has `Cosmos DB Built-in Data Contributor` at the account scope. |
| **Observability** | Grafana + Azure Monitor data source | Container Insights already collects everything via the AKS add-on. Grafana queries Log Analytics through workload identity — no SP secret in the chart values. |
| **Pod Security** | `restricted` baseline enforced on every app namespace | Non-root, read-only root FS, `drop ALL` capabilities, seccomp `RuntimeDefault`. |

---

## Apps

### `myapp` — secrets pipeline demo

Endpoint: https://myapp.shugeinfo.xyz/

```json
{"app":"myapp","version":"dev","node":"v20.20.0","secret_from_kv":"hello-from-keyvault"}
```

The `secret_from_kv` field's value lives in Azure Key Vault. ESO pulls it,
creates a Kubernetes Secret, the Deployment mounts it as an env var.

Source: [`app/`](app/), manifest: [`k8s/`](k8s/).

### `todoapp` — 3-tier app with Cosmos DB

Endpoint: https://todo.shugeinfo.xyz/

A React SPA with a todo list backed by Cosmos DB. CRUD endpoints:

```
GET    /api/todos
POST   /api/todos       {"text": "..."}
PATCH  /api/todos/:id   {"done": true|false}
DELETE /api/todos/:id
```

Source: [`todoapp/`](todoapp/), manifest: [`k8s/todoapp/`](k8s/todoapp/).

The backend connects to Cosmos with **zero static credentials**:

```js
const cred   = new DefaultAzureCredential();
const cosmos = new CosmosClient({ endpoint, aadCredentials: cred });
```

`DefaultAzureCredential` finds the projected federated token, sends it to
Azure AD, gets back an access token for `https://cosmos.azure.com/.default`,
presents that to the Cosmos data plane. Cosmos validates the token's
audience and the principal's role assignment.

---

## Key design decisions

### Why Workload Identity instead of static service-principal secrets?

Every alternative requires storing a long-lived secret somewhere — in a K8s
Secret, an env var, a config file. Workload Identity issues short-lived
(1 hour) tokens that are exchanged on demand, scoped to a specific service
account, automatically rotated. **There is no secret to leak.**

This POC has *four* federated identities, one per workload (ESO, Grafana,
todoapi, plus the cluster's own system-assigned identity for OIDC). They
all share the same pattern:

```
Kubernetes Service Account
   │  (signed by AKS OIDC issuer)
   ▼
Azure Federated Identity Credential
   │  ("trust SA todoapp/todoapi to assume me")
   ▼
User-Assigned Managed Identity
   │  (granted RBAC roles on KV / Cosmos / LAW)
   ▼
Azure data plane
```

### Why Cosmos DB serverless / free tier?

Default-mode Cosmos with provisioned throughput costs ~$24/mo for 400 RU/s.
Serverless bills only for consumed RUs. The free tier exempts the first
1000 RU/s + 25 GB per subscription, forever — perfect for a POC that's
probably going to do a few dozen requests per minute peak.

### Why Argo CD Image Updater with `write-back-method: argocd`?

Two options for updating image tags in a GitOps loop:

1. **Git write-back** — Image Updater commits the new tag back to the
   manifests in git. Truly declarative; the git history shows every deploy.
   Needs an SSH/PAT credential for git push.
2. **Argo write-back** — Image Updater mutates the Argo Application's
   `spec.source.kustomize.images` override. Simpler (no git creds); the
   override is visible in the Argo UI but not in git.

POC uses #2 to keep the moving parts down. Production would use #1 for full
audit trail.

### Why two nodes instead of one?

A single `Standard_B2s` (2 vCPU / 4 GiB) couldn't fit everything (Argo CD,
Image Updater, ESO, Grafana, NGINX, cert-manager, both apps) — we hit
97% CPU requests during the first build. Two nodes gives breathing room
and demonstrates HA scheduling at almost the same cost.

### Why the `cluster-issuer.yaml` lives in `bootstrap/` instead of `k8s/`?

ClusterIssuer is cluster-scoped, not namespaced. When it sat under
`k8s/cluster-issuer.yaml` and we transitioned the Argo Application from
directory-mode to kustomize-mode, Argo's `prune: true` flag deleted the
ClusterIssuer (it was tracked from the directory-mode era but no longer in
the kustomization). Putting it in `bootstrap/` makes its "applied once at
cluster setup, not managed by Argo" status explicit.

---

## Security posture

| Control | How |
|---|---|
| No static credentials in cluster | Workload Identity for KV, Cosmos, Log Analytics |
| Least privilege | Each UAMI scoped to one role on one resource (`Key Vault Secrets User`, `Cosmos Data Contributor`, `Log Analytics Reader`, `Monitoring Reader`) |
| TLS everywhere | NGINX `force-ssl-redirect: true`; Let's Encrypt certs auto-renewed by cert-manager |
| Image provenance | Pinned Helm chart versions; Kaniko builds tagged with commit SHA (8 hex chars only — regex enforced in Image Updater) |
| Image vulnerability scanning | GitLab `Container-Scanning` template (Trivy) runs on every pushed image |
| Static analysis | GitLab `SAST` (Semgrep), `Secret-Detection`, `Dependency-Scanning` on every push |
| Pod Security | `restricted` baseline enforced on every app namespace |
| Container hardening | Non-root user, `readOnlyRootFilesystem`, `drop ALL` capabilities, `seccompProfile: RuntimeDefault`, distroless or nginx-unprivileged base images |
| Network policy ready | `automountServiceAccountToken: false` everywhere except the API pod that needs the federated token |
| Branch protection | `main` is protected in GitLab; force-pushes blocked; only `main` triggers production deploys |

---



## What I'd add for true production

- **Private endpoints** for Cosmos and Key Vault (currently
  `public_network_access_enabled = true`); pair with `azure_cni` overlay
  network policy
- **Azure Container Registry** with Workload Identity pull, replacing Docker Hub
- **OPA Gatekeeper** or **Kyverno** policies (image registry allow-list,
  required labels, no `latest` tags in prod)
- **Cosmos backup policy** beyond the default 8-hour continuous backup
- **PodDisruptionBudgets** so node drains don't take all replicas down
- **HorizontalPodAutoscaler** (currently hard-coded `replicas: 2`)
- **Argo CD ApplicationSet** if we add a second cluster or staging environment
- **Image Updater `write-back-method: git`** for fully auditable image bumps
- **External DNS** controller so Ingress hostnames automatically create A records
- **Falco** or Microsoft Defender for runtime threat detection
- **NetworkPolicies** restricting east-west traffic between namespaces
- **AKS automatic upgrade channels** (`patch` or `stable`)
- **Multi-region** Cosmos with automatic failover for true HA

---

## Repository layout

```
.
├── app/                   # myapp source (Node + Express, surfaces KV secret)
├── todoapp/
│   ├── api/               # Node + Express + @azure/cosmos backend
│   └── frontend/          # React + Vite SPA served by nginx-unprivileged
├── k8s/                   # myapp manifests (kustomize base)
│   └── todoapp/           # todoapp manifests (kustomize base)
├── bootstrap/
│   ├── cluster-issuer.yaml  # one-time apply, outside Argo's purview
│   └── bootstrap.sh         # idempotent cluster bring-up script
├── argo/                  # Argo Applications + Grafana Helm values
├── terraform/             # AKS, LAW, KV, Cosmos, 3 UAMIs, federated creds
├── .gitlab-ci.yml         # Validate → test → build (3 images) → scan
├── Dockerfile             # myapp container (distroless)
├── deployment.md          # Step-by-step bring-up runbook
└── README.md              # This file
```

---
