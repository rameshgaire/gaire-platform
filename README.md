# gaire-platform

A reproducible, self-hosted Kubernetes (K3s) lab on Azure, provisioned with
Terraform, configured with Ansible, and running applications via GitOps (ArgoCD).
Built to be destroyed and recreated on demand — no resource is hand-clicked,
rebuilds pick up a fresh public IP automatically (DNS follows it), TLS certs
reissue themselves, and every application redeploys from Git.

> Status: the full stack — infrastructure, cluster, storage, ingress, TLS, DNS,
> GitOps, and applications — has been destroyed and rebuilt from this repo and
> verified end-to-end. A rebuild needs only the Terraform/Ansible runs plus a
> handful of control-node-local secrets (documented below).

---

## What's running

All apps are GitOps-managed (ArgoCD), served over trusted HTTPS via a single
wildcard certificate replicated across namespaces (Reflector).

| App        | URL                       | Type      | Storage         |
|------------|---------------------------|-----------|-----------------|
| ArgoCD     | `argocd.gairelab.uk`      | GitOps UI | —               |
| whoami     | `hello.gairelab.uk`       | test app  | —               |
| Memos      | `memos.gairelab.uk`       | notes     | 5 Gi Longhorn   |
| homepage   | `homepage.gairelab.uk`    | dashboard | — (ConfigMap)   |
| n8n        | `n8n.gairelab.uk`         | automation| 5 Gi Longhorn   |

Planned (see "Future apps"): Ollama, Open WebUI, AnythingLLM.

---

## Architecture

- **Cloud:** Azure, region `australiaeast`, resource group `gaire-platform-rg`
- **Network:** VNET `10.10.0.0/16`
  - public subnet `10.10.1.0/24` (reserved for a future load balancer)
  - private subnet `10.10.2.0/24` (all nodes live here)
- **Nodes:** 3 x Ubuntu 22.04 LTS (`Standard_B2as_v2`, 2 vCPU / 8 GB)
  - `k3s-master`  — `10.10.2.10`, holds the one public IP, runs the K3s control plane + Traefik
  - `k3s-worker01` — `10.10.2.11` (private only, + 50 GB Longhorn data disk)
  - `k3s-worker02` — `10.10.2.12` (private only, + 50 GB Longhorn data disk)
- **Access:** SSH and all ingress enter through the master's public IP. Workers
  have no public IP and are reached by jumping through the master (SSH bastion).
- **Cluster:** K3s (installs latest stable; bundled Traefik and servicelb disabled
  so we install our own for version control).
- **Storage:** Longhorn (distributed block storage), 2 replicas, on dedicated
  50 GB disks mounted at `/var/lib/longhorn` on each worker.
- **Ingress/TLS:** Traefik (hostPort 80/443 on the master) + cert-manager issuing
  Let's Encrypt certs via Cloudflare DNS-01. Domain: `gairelab.uk`.
- **Certificate distribution:** ONE wildcard cert is issued, then replicated into
  every app namespace by Reflector (avoids Let's Encrypt's duplicate-cert limit).
- **DNS:** Cloudflare; A-records (`*` + apex) are managed by Terraform and point
  at the master's current public IP — updated automatically on every apply.
- **GitOps:** ArgoCD watches this repo. A root "app-of-apps" Application creates
  one ArgoCD Application per app. Deploying/removing an app = committing a manifest.

---

## Repository layout

`# gitignored` = not committed (local-only or generated). Everything else is committed.

```
.
├── README.md
├── ansible/
│   ├── ansible.cfg                  # inventory path, host-key checking off, vault password ref
│   ├── requirements.yml             # collections: kubernetes.core, community.general, ansible.posix
│   ├── inventory/
│   │   ├── hosts.ini.tftpl          # template; Terraform renders the real hosts.ini from this
│   │   └── group_vars/
│   │       ├── all.yml              # auth: admin user, ansible key, master internal IP
│   │       └── workers.yml          # SSH ProxyCommand (bastion-through-master) for private workers
│   ├── playbooks/
│   │   ├── 01-base.yml              # OS prep: apt upgrade, swap off, kernel modules, sysctls, open-iscsi
│   │   ├── 02-k3s.yml               # K3s server on master, agents joined on workers
│   │   ├── 03-kubeconfig.yml        # fetch kubeconfig to the control node (~/.kube/config)
│   │   ├── 04-longhorn-prep.yml     # format + mount the data disk at /var/lib/longhorn (by UUID)
│   │   ├── 05-longhorn.yml          # install Longhorn (Helm) + make it the sole default StorageClass
│   │   ├── 06-ingress.yml           # Traefik + cert-manager + Cloudflare secret + both ClusterIssuers
│   │   ├── 07-argocd.yml            # install ArgoCD (Helm) + bootstrap the root app-of-apps
│   │   └── 08-reflector.yml         # install Reflector (Helm) — replicates the wildcard TLS secret
│   └── scripts/
│       └── kube-tunnel.sh           # SSH tunnel to the K3s API (run, leave open) for local kubectl
├── kubernetes/
│   ├── apps/                        # one folder per application
│   │   ├── whoami/                  # test app (namespace + Deployment + Service + Ingress)
│   │   ├── memos/                   # notes (namespace, PVC, Deployment, Service, Ingress)
│   │   ├── homepage/                # dashboard (namespace, ConfigMap, Deployment, Service, Ingress)
│   │   └── n8n/                     # automation (namespace, PVC, Deployment, Service, Ingress)
│   ├── infrastructure/              # cluster services (not user apps)
│   │   ├── traefik/values.yaml              # Helm values (hostPort 80/443, pinned to master)
│   │   ├── longhorn/values.yaml             # Helm values (2 replicas, /var/lib/longhorn)
│   │   ├── argocd/
│   │   │   ├── values.yaml                   # Helm values (server.insecure: true)
│   │   │   └── ingress.yaml                  # cert + Ingress for argocd.gairelab.uk
│   │   ├── cert-manager/
│   │   │   ├── cluster-issuer-staging.yaml          # Let's Encrypt staging (DNS-01 via Cloudflare)
│   │   │   ├── cluster-issuer-production.yaml       # Let's Encrypt production (trusted)
│   │   │   ├── wildcard-certificate-staging.yaml    # *.gairelab.uk staging cert
│   │   │   ├── wildcard-certificate-production.yaml # *.gairelab.uk production cert
│   │   │   └── wildcard-source.yaml                 # CLEAN: single reflected source cert (see TLS section)
│   │   └── monitoring/              # placeholder (Prometheus/Grafana/Loki — future)
│   └── argocd/
│       ├── root.yaml                # app-of-apps: watches applications/ and creates an App per file
│       └── applications/            # one ArgoCD Application manifest per app (the on/off toggles)
│           ├── whoami.yaml
│           ├── memos.yaml
│           ├── homepage.yaml
│           └── n8n.yaml
├── secrets/
│   ├── README.md
│   ├── ansible-secrets.yml          # Ansible Vault (committed ENCRYPTED): Cloudflare API token
│   └── terraform.tfvars             # gitignored: subscription id, SSH source IP, CF token + zone id
└── terraform/
    ├── networking/                  # apply 1st: RG, VNET, subnets, NSG, static public IP
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── compute/                     # apply 2nd: NICs + VMs; renders hosts.ini; Cloudflare DNS records
    │   ├── main.tf
    │   ├── cloudflare.tf            # Cloudflare provider + A-records (* and apex) -> master public IP
    │   ├── variables.tf
    │   └── outputs.tf
    └── storage/                     # apply 3rd: 50 GB managed data disk per worker + attachment
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

**Files you must CREATE locally (gitignored — never committed):**

```
secrets/terraform.tfvars              subscription id, SSH source IP, Cloudflare token + zone id
~/.vault_pass                         Ansible Vault password (decrypts ansible-secrets.yml)
~/.ssh/gaire-platform-admin[.pub]     interactive SSH keypair
~/.ssh/gaire-platform-ansible[.pub]   Ansible automation SSH keypair
~/.ssh/argocd-gaire-platform[.pub]    ArgoCD read-only deploy key (for the private repo)
```

**Auto-generated / managed (do NOT create by hand):**

```
ansible/inventory/hosts.ini           rendered by Terraform (compute) on each apply  [gitignored]
terraform/*/terraform.tfstate*        Terraform state                                [gitignored]
terraform/*/.terraform/               provider binaries                              [gitignored]
terraform/*/.terraform.lock.hcl       provider version pins                          [COMMITTED]
```

---

## Customize for your own lab

If you fork this for your own infrastructure, change:

- **Domain** `gairelab.uk` → your domain. Appears in: cert `dnsNames`, app Ingress
  `host` rules, the issuer `email`, and the n8n/homepage env vars. (Terraform's DNS
  records use `*` / `@` against your zone id, so they are domain-agnostic.)
- **Email** in the two `cluster-issuer-*.yaml` files → your email.
- **Azure** `subscription_id`, and `region` / `resource group` if you want different ones.
- **Cloudflare** `cloudflare_zone_id` and the API token (your own zone + token).
- **GitHub repo** the `repoURL` in `kubernetes/argocd/root.yaml` and every
  `kubernetes/argocd/applications/*.yaml` → your repo (SSH form `git@github.com:you/repo.git`).

---

## Prerequisites (one-time per control node)

Install on the machine you run Terraform/Ansible from (the "control node"):

- Azure CLI, authenticated: `az login`
- Terraform >= 1.5
- Ansible, plus collections: `ansible-galaxy collection install -r ansible/requirements.yml`
- `kubectl` and Helm 3
- `git`, with access to your fork of this repo
- A Cloudflare account with your domain's zone, and an API token (see below)

---

## First-time setup — create the files that are NOT in the repo

After cloning the repo, create these on the control node before building.

### 1. SSH keypairs

```bash
# Interactive admin key (you SSH with this)
ssh-keygen -t ed25519 -f ~/.ssh/gaire-platform-admin   -C "gaire-platform admin"   -N ""
# Automation key (Ansible uses this)
ssh-keygen -t ed25519 -f ~/.ssh/gaire-platform-ansible -C "gaire-platform ansible" -N ""
# ArgoCD read-only deploy key (for the private repo)
ssh-keygen -t ed25519 -f ~/.ssh/argocd-gaire-platform  -C "argocd-deploy-key"      -N ""
```

### 2. Cloudflare API token (needs TWO permissions)

Cloudflare dashboard → My Profile → API Tokens → Create Custom Token:
- Permissions: **Zone → DNS → Edit** AND **Zone → Zone → Read** (both required)
- Zone Resources: Include → your zone (e.g. `gairelab.uk`)

Find your **Zone ID** on the domain's Overview page (right-hand "API" section).

> The token is used in TWO places: by Terraform (in `terraform.tfvars`) to manage
> DNS records, and by cert-manager (in the Vault file) to solve DNS-01 challenges.

### 3. `secrets/terraform.tfvars` (gitignored)

```bash
cat > secrets/terraform.tfvars <<'TFV'
subscription_id      = "<your-azure-subscription-id>"
ssh_source_address   = "<your-control-node-public-ip>/32"   # NSG allows SSH only from here
cloudflare_api_token = "<your-cloudflare-api-token>"
cloudflare_zone_id   = "<your-cloudflare-zone-id>"
TFV
```

Tip: your control node's public IP is `curl -s ifconfig.me`. If it changes, update
`ssh_source_address` and re-apply networking, or the NSG will block your SSH.

### 4. `~/.vault_pass` + `secrets/ansible-secrets.yml` (Cloudflare token, encrypted)

The encrypted `ansible-secrets.yml` is committed, but it is encrypted with a
password NOT in the repo — and you want your OWN token in it. Recreate both:

```bash
# a) Vault password (control-node-local, never committed)
nano ~/.vault_pass            # type one strong line, save
chmod 600 ~/.vault_pass

# b) Put your Cloudflare token in the secrets file (plaintext briefly)
cat > secrets/ansible-secrets.yml <<'SEC'
---
cloudflare_api_token: "<your-cloudflare-api-token>"
SEC

# c) Verify the token is valid BEFORE encrypting — prints status, not the token
TOKEN=$(grep cloudflare_api_token secrets/ansible-secrets.yml | sed 's/.*"\(.*\)".*/\1/')
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  | grep -o '"status":"[a-z]*"'        # want: "status":"active"
unset TOKEN

# d) Encrypt it (uses ~/.vault_pass via ansible.cfg — no prompt)
cd ansible
ansible-vault encrypt ../secrets/ansible-secrets.yml
head -c 30 ../secrets/ansible-secrets.yml; echo    # confirm: $ANSIBLE_VAULT...
cd ..
```

> Never `cat` or `ansible-vault view` a token into a shared screen/log. To check a
> secret exists, test for the KEY, not the value.

### 5. `.gitignore` (verify it protects secrets)

If forking fresh, ensure `.gitignore` keeps state and plaintext secrets out of Git:

```gitignore
# Terraform
**/.terraform/*
*.tfstate
*.tfstate.*
!**/.terraform.lock.hcl          # keep the lock files (pin provider versions)

# Secrets — keep the README and the ENCRYPTED vault, ignore everything else
secrets/*
!secrets/README.md
!secrets/ansible-secrets.yml

# Generated Ansible inventory
ansible/inventory/hosts.ini

# Editor scratch
*.save
*.save.*
```

---

## Build (from nothing) — full sequence

Run from the repo root (`~/gaire-platform`). Forward order matters: compute reads
networking's state; storage references the VMs.

### 1. Infrastructure (Terraform)

```bash
# Networking — RG, VNET, subnets, NSG, static public IP
cd terraform/networking
terraform init                                            # fresh clone only
terraform apply -var-file=../../secrets/terraform.tfvars

# Compute — VMs + NICs; renders ansible/inventory/hosts.ini with the live IP;
#           creates Cloudflare A-records (* and apex) pointing at it
cd ../compute
terraform init                                            # fresh clone only
terraform apply -var-file=../../secrets/terraform.tfvars  # note master_public_ip in output

# Storage — one 50 GB data disk per worker, attached
cd ../storage
terraform init                                            # fresh clone only
terraform apply -var-file=../../secrets/terraform.tfvars
cd ../..
```

### 2. Cluster, storage, ingress, GitOps (Ansible)

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml     # fresh clone only
ansible all -m ping                                       # all 3 nodes answer "pong"

ansible-playbook playbooks/01-base.yml          # OS prep
ansible-playbook playbooks/02-k3s.yml           # build the cluster
ansible-playbook playbooks/03-kubeconfig.yml    # write ~/.kube/config (server stays 127.0.0.1:6443)
ansible-playbook playbooks/04-longhorn-prep.yml # format + mount worker data disks
ansible-playbook playbooks/05-longhorn.yml      # Longhorn + sole default StorageClass
ansible-playbook playbooks/06-ingress.yml       # Traefik + cert-manager + Cloudflare secret + issuers
ansible-playbook playbooks/07-argocd.yml        # ArgoCD + bootstrap root app-of-apps
ansible-playbook playbooks/08-reflector.yml     # Reflector (replicates the wildcard TLS secret)
cd ..
```

### 3. Open the kubectl tunnel (per work session — MANUAL)

Run in a dedicated terminal and leave it open; use kubectl/helm in another.

```bash
./ansible/scripts/kube-tunnel.sh
# In the other terminal:  kubeup   (prints "tunnel up")
```

### 4. Wire up ArgoCD's access to the private repo (MANUAL — see "ArgoCD repo access")

ArgoCD needs the deploy key to read the private repo. This step is control-node-local
(the private key is not in Git). Without it, the root app and all apps stay OutOfSync.
See the dedicated section below for the exact commands.

### 5. Issue the wildcard certificate (MANUAL — once per cluster)

```bash
# The single source wildcard cert (reflected to all namespaces — see TLS section)
kubectl apply -f kubernetes/infrastructure/cert-manager/wildcard-source.yaml
kubectl -n cert-manager get certificate -w     # wait READY=True (DNS-01, ~1-5 min)
```

### 6. Verify (end-to-end proof)

```bash
kubectl get nodes -o wide                          # 3 nodes Ready
kubectl get storageclass                           # only "longhorn (default)"
kubectl get clusterissuer                          # staging + production READY=True
kubectl -n argocd get applications                 # root + all apps Synced/Healthy
dig +short hello.gairelab.uk                       # current master public IP
curl -i https://hello.gairelab.uk                  # HTTP/2 200, no -k = trusted cert
curl -I https://memos.gairelab.uk                  # 200
curl -I https://homepage.gairelab.uk               # 200
curl -I https://n8n.gairelab.uk                    # 200
```

---

## ArgoCD repo access (deploy key) — MANUAL rebuild step

ArgoCD authenticates to the private GitHub repo with a read-only SSH deploy key.
The private key lives on the control node only (never in Git), so this must be
recreated on every rebuild. Three parts:

```bash
# 1. (If not already created in first-time setup) generate the keypair:
ssh-keygen -t ed25519 -f ~/.ssh/argocd-gaire-platform -C "argocd-deploy-key" -N ""

# 2. Add the PUBLIC half to GitHub as a DEPLOY KEY (read-only):
cat ~/.ssh/argocd-gaire-platform.pub
#   -> GitHub repo → Settings → Deploy keys → Add deploy key
#      Title: argocd ; paste the key ; leave "Allow write access" UNCHECKED.
#   (On a rebuild the existing deploy key is still valid — skip if unchanged.)

# 3. Create the repo credential secret IN the cluster (reads the private key from disk):
kubectl -n argocd create secret generic repo-gaire-platform \
  --from-literal=type=git \
  --from-literal=url=git@github.com:<you>/gaire-platform.git \
  --from-file=sshPrivateKey=$HOME/.ssh/argocd-gaire-platform
kubectl -n argocd label secret repo-gaire-platform \
  argocd.argoproj.io/secret-type=repository
```

Verify in the ArgoCD UI: Settings → Repositories → status **Successful**. Once the
secret exists, the root app-of-apps syncs and all apps deploy automatically.

> Optional hardening (future): seal this secret (SealedSecrets/SOPS) so it CAN be
> committed, removing this manual step. For now it is documented as manual.

---

## TLS — issue once, replicate everywhere (Reflector)

**Why:** Let's Encrypt limits identical certificates to **5 per week** for the same
set of names. Issuing a separate `*.gairelab.uk` cert per namespace hits this limit
fast (it was hit at the 6th namespace during the build). The fix is to issue the
wildcard ONCE and replicate the resulting TLS secret into every namespace.

**How it works:**

1. A single source `Certificate` (`kubernetes/infrastructure/cert-manager/wildcard-source.yaml`)
   in the `cert-manager` namespace requests `*.gairelab.uk` from `letsencrypt-production`.
2. Its `secretTemplate` carries Reflector annotations marking the secret as
   reflectable into the app namespaces.
3. **Reflector** (installed by `08-reflector.yml`) copies the secret into each
   listed namespace automatically — and into NEW namespaces as they appear.
4. Each app's Ingress references the local `wildcard-gairelab-uk-tls` secret.
   App manifests contain NO `Certificate` — the cert just appears.

The source Certificate (`wildcard-source.yaml`) looks like:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-gairelab-uk
  namespace: cert-manager
spec:
  secretName: wildcard-gairelab-uk-tls
  secretTemplate:
    annotations:
      reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "demo,memos,homepage,n8n,openwebui,anythingllm,ollama"
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - "gairelab.uk"
    - "*.gairelab.uk"
```

Adding a new app namespace later needs NO cert work — add the namespace name to
`reflection-auto-namespaces` (or rely on the auto behaviour) and Reflector populates it.

> **Net effect:** 1 issuance total, every namespace covered, renewals replicate
> automatically. You never touch the cert rate limit again.

---

## Ingress & TLS components

- **Traefik** (chart 40.2.0), installed by `06-ingress.yml`, binds directly to the
  master's host ports 80/443 (`hostPort`), pinned to `k3s-master` via nodeSelector
  — servicelb is disabled and only the master has the public IP. No LoadBalancer,
  no MetalLB. (The Traefik Helm task runs WITHOUT `--wait`: a single hostPort pod
  produces false readiness timeouts.)
- **cert-manager** (v1.18.x) issues TLS via Let's Encrypt **DNS-01** using the
  Cloudflare API. DNS-01 (not HTTP-01) lets us issue **wildcard** certs and does
  not depend on inbound reachability.
- **Two ClusterIssuers** (`06-ingress.yml`): `letsencrypt-staging` (untrusted, no
  rate limit — for testing) and `letsencrypt-production` (trusted, rate-limited).
- **Cloudflare API token** lives in the Ansible Vault; `06-ingress.yml` creates the
  `cloudflare-api-token` Kubernetes Secret from it — never in Git or the shell.

---

## GitOps (ArgoCD)

- **Install:** `07-argocd.yml` (Helm chart 9.7.1 / Argo CD v3.4.4). `server.insecure: true`
  so Traefik terminates TLS in front (no double-TLS). UI at `argocd.gairelab.uk`.
- **App-of-apps:** `kubernetes/argocd/root.yaml` is one Application that watches
  `kubernetes/argocd/applications/` and creates an Application per file there.
  `07-argocd.yml` applies `root.yaml` at the end of the install, so on a rebuild
  all apps come back automatically (once the deploy-key secret exists).
- **Deploying an app:** create `kubernetes/apps/<app>/` (manifests) and
  `kubernetes/argocd/applications/<app>.yaml` (the Application), commit, push.
  The root app creates the new Application; it syncs. **No `kubectl apply`.**
- **Turning an app OFF:**
  - *Temporarily (keep data/config):* set `replicas: 0` in the app's Deployment in
    Git, commit. ArgoCD scales it down. (Do NOT `kubectl scale` — `selfHeal` reverts
    it; on/off must happen in Git.)
  - *Permanently:* delete `kubernetes/argocd/applications/<app>.yaml` (root prunes
    the Application; with `prune: true` the workloads are removed).

---

## Deploying apps — the pattern

Each app is a folder under `kubernetes/apps/<app>/` with separate resource files,
plus one Application under `kubernetes/argocd/applications/<app>.yaml`. Apps get
their TLS secret from Reflector (no per-app Certificate).

A typical stateful app (like Memos / n8n) contains:

1. `namespace.yaml` — the namespace (also created by the Application's `CreateNamespace=true`).
2. `pvc.yaml` — a Longhorn `PersistentVolumeClaim` (for apps that store data).
3. `deployment.yaml` — `strategy: Recreate` for single-PVC apps (a ReadWriteOnce
   Longhorn volume can't attach to two pods during a rolling update).
4. `service.yaml` — ClusterIP, port 80 → the app's container port.
5. `ingress.yaml` — host `<app>.gairelab.uk`, `entrypoints: websecure`, referencing
   the namespace-local `wildcard-gairelab-uk-tls` (provided by Reflector).

Then the Application:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app>
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:<you>/gaire-platform.git
    targetRevision: main
    path: kubernetes/apps/<app>
  destination:
    server: https://kubernetes.default.svc
    namespace: <app>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Commit + push → root app creates it → ArgoCD syncs → app live at `https://<app>.gairelab.uk`.

---

## Future apps (planned)

These are RAM-heavy; the cluster has ~16 GB across the two workers. Use the
scale-to-zero-via-Git pattern to run only what you need that week.

### Resource reality check
- Memos / homepage / n8n: light (hundreds of MB each).
- **Ollama**: heavy — a loaded model wants several GB of RAM (a 7B model ~5–6 GB).
  Likely only one large model resident at a time on this hardware.
- **Open WebUI**: moderate frontend, but pairs with Ollama (the heavy part).
- **AnythingLLM**: moderate-heavy; also wants a model backend.

Practical guidance: run Ollama + ONE frontend at a time. Keep the others scaled to
zero (in Git) when unused. Watch `kubectl top nodes` / `kubectl top pods`.

### Ollama (model server) — `ollama.gairelab.uk` (optional UI; usually internal)
- Stateful: large PVC for models (e.g. 30–50 Gi Longhorn) — models are big.
- `strategy: Recreate`. No env gotchas beyond `OLLAMA_HOST=0.0.0.0` to listen
  cluster-wide. Often exposed only in-cluster (no Ingress) and consumed by a frontend.
- Pull a model after deploy: `kubectl -n ollama exec deploy/ollama -- ollama pull llama3`.

### Open WebUI — `openwebui.gairelab.uk`
- Frontend for Ollama (and OpenAI-compatible backends). Stateful: small PVC for
  users/chats (e.g. 5 Gi).
- Point it at Ollama in-cluster: `OLLAMA_BASE_URL=http://ollama.ollama.svc.cluster.local:11434`.
- Reflector gives it the cert automatically (add `openwebui` to the source cert's
  auto-namespaces if not already listed).

### AnythingLLM — `anythingllm.gairelab.uk`
- RAG app. Stateful: PVC for its document store / vector data (e.g. 10 Gi).
- Configure its LLM provider to the in-cluster Ollama, or an external API.
- Heaviest of the three when indexing; scale to zero when not in use.

For each: create `kubernetes/apps/<app>/`, an Application in `argocd/applications/`,
ensure the namespace is in Reflector's auto-namespaces, commit, push. No kubectl.

---

## Local kubectl access

`kubectl`/`helm` reach the cluster through an SSH tunnel (API port 6443 is NOT
exposed in the NSG).

- **Each rebuild:** `ansible-playbook playbooks/03-kubeconfig.yml` regenerates `~/.kube/config`.
- **Each work session:** run `./ansible/scripts/kube-tunnel.sh` and leave it open;
  use kubectl in another terminal.
- **`kubeup`** reports whether the tunnel is up. "connection refused" = tunnel down,
  just restart `kube-tunnel.sh` (it does NOT affect the cluster or ArgoCD — ArgoCD
  syncs from Git regardless of your local tunnel).
- Don't start a second tunnel — it fails with "Address already in use".

```bash
# Optional kubeup alias:
echo "alias kubeup='(echo > /dev/tcp/127.0.0.1/6443) 2>/dev/null && echo \"tunnel up\" || echo \"tunnel DOWN — run kube-tunnel.sh\"'" >> ~/.bashrc
source ~/.bashrc
```

---

## DNS (Cloudflare, automated)

- Managed in `terraform/compute/cloudflare.tf` (Cloudflare provider `~> 5.0`).
- Two A-records at the master's CURRENT public IP: wildcard `*` and apex `@`.
- They use `local.public_ip_address` — the same value fed to the Ansible inventory —
  so DNS and Ansible always agree, and a rebuild's new IP propagates on `terraform apply`.
- `proxied = false` (DNS-only) — TLS is handled by Traefik + cert-manager; proxying
  would terminate TLS at Cloudflare and hide the real cert.

---

## Destroy and rebuild

### Destroy (reverse dependency order)

Storage references the VMs, and compute reads networking's state, so destroy
storage → compute → networking:

```bash
cd terraform/storage    && terraform destroy -var-file=../../secrets/terraform.tfvars
cd ../compute           && terraform destroy -var-file=../../secrets/terraform.tfvars   # also removes Cloudflare A-records
cd ../networking        && terraform destroy -var-file=../../secrets/terraform.tfvars   # releases the public IP
cd ../..

# Confirm Azure is empty (billing stopped):
az resource list -g gaire-platform-rg -o table     # empty, or "group not found"
```

The public IP is released; the next build draws a new one and the inventory +
Cloudflare records regenerate around it. Storage is **disposable** — Longhorn data
(and therefore app data: Memos notes, n8n workflows/credentials) is destroyed too.

### Rebuild (full sequence — what actually has to happen)

Everything in Git rebuilds automatically; the only manual parts are the
control-node-local secrets and two one-time apply steps. In order:

1. **Confirm control-node-local secrets exist** (survive on the control node; NOT in Git):
   ```bash
   ls -la ~/.vault_pass \
          ~/.ssh/gaire-platform-admin ~/.ssh/gaire-platform-ansible \
          ~/.ssh/argocd-gaire-platform \
          secrets/terraform.tfvars
   ```
   On a brand-new control node, recreate them per "First-time setup".

2. **Check the control node's public IP** matches `ssh_source_address` in
   `terraform.tfvars` (the NSG only allows SSH from there):
   ```bash
   curl -s ifconfig.me; echo
   grep ssh_source_address secrets/terraform.tfvars
   ```
   If different, update tfvars before applying networking.

3. **Terraform** (networking → compute → storage) — see "Build" step 1.
   Compute regenerates `hosts.ini` with the new IP and updates Cloudflare DNS.

4. **Ansible 01–08** — see "Build" step 2. This rebuilds the cluster, storage,
   ingress, cert-manager + issuers, ArgoCD (+ root app-of-apps), and Reflector.

5. **Open the tunnel:** `./ansible/scripts/kube-tunnel.sh` (separate terminal).

6. **Recreate the ArgoCD repo deploy-key secret** — see "ArgoCD repo access".
   (The deploy key on GitHub persists; only the in-cluster secret needs recreating.)
   Until this exists, the root app and all apps stay OutOfSync.

7. **Issue the source wildcard cert:**
   ```bash
   kubectl apply -f kubernetes/infrastructure/cert-manager/wildcard-source.yaml
   ```
   Reflector replicates it to all app namespaces as they appear.

8. **Verify** — see "Build" step 6. Within a few minutes ArgoCD shows root + all
   apps Synced/Healthy and every URL serves HTTPS.

**Manual rebuild touchpoints (the complete list):**
- Recreate control-node-local secrets if on a fresh machine (step 1).
- Open the kubectl tunnel (step 5) — for your own access only.
- Recreate the ArgoCD deploy-key secret (step 6).
- Apply `wildcard-source.yaml` once (step 7).

Everything else — infra, cluster, storage, ingress, DNS, ArgoCD, Reflector, and
all applications — is automatic.

> **Note on app data:** a full destroy wipes Longhorn, so Memos notes and n8n
> workflows/credentials do NOT survive a rebuild (n8n's encryption key is
> auto-generated on the PVC). For a lab this is acceptable — reconfigure after a
> rebuild. To persist app data across rebuilds you would need off-cluster backups
> (e.g. Longhorn backup to object storage) — not currently configured.

---

## How rebuild-safety works

- The Ansible inventory (`hosts.ini`) is **generated** by Terraform's compute module
  — gitignored, never hand-edited. Each apply rewrites it with the current public IP.
- `group_vars` use `lookup('env','HOME')` and read the master's address from the
  generated inventory — no hardcoded paths or IPs.
- Private IPs (`10.10.2.10/.11/.12`) are declared inputs, stable across rebuilds.
- Cloudflare A-records are set from the same live IP on every apply, so DNS follows
  the master automatically.
- The Longhorn data disk is mounted by **UUID**; the format step is guarded so
  re-running `04-longhorn-prep.yml` never reformats an existing disk.
- TLS uses DNS-01 (ownership via a Cloudflare TXT record, independent of the IP),
  so the source cert re-issues cleanly; Reflector re-replicates it.
- ArgoCD's root app-of-apps means the entire application layer is declarative: apply
  root once (automated in `07-argocd.yml`) and every app returns from Git.

---

## Secrets summary

`secrets/` is gitignored except `README.md` and the encrypted vault:
- `terraform.tfvars` — subscription id, SSH source IP, Cloudflare token + zone id
  (plaintext, **NOT** committed).
- `ansible-secrets.yml` — Cloudflare API token, Ansible Vault-encrypted (committed
  as ciphertext).

Control-node-local, never in Git, recreate on a fresh control node:
`secrets/terraform.tfvars`, `~/.vault_pass`, the two SSH keypairs, and the ArgoCD
deploy keypair (`~/.ssh/argocd-gaire-platform`).

`.terraform.lock.hcl` files **are** committed (pin provider versions);
`*.tfstate` files are **not** (can contain plaintext secrets).

---

## Notes / gotchas learned

**Infrastructure / Azure**
- **VM size:** `Standard_B2s` hit capacity limits; the Basv2 family started at a
  **0-core quota** in `australiaeast` — raised via `az quota create` after registering
  the `Microsoft.Quota` provider. Nodes are `Standard_B2as_v2` (8 GB).
- **Ubuntu image (Gen2):** publisher `Canonical`, offer `0001-com-ubuntu-server-jammy`,
  sku `22_04-lts-gen2` — the v2 VM series is Gen2-only.
- **Outbound:** workers use Azure default outbound access (no NAT gateway, to save cost).
- **Disk naming:** the data disk is `/dev/sdb` today but that is NOT stable — the
  playbook uses `/dev/disk/azure/scsi1/lun0` (stable LUN path) and mounts by UUID.

**Cloudflare / certs**
- **Token needs TWO permissions:** `Zone:DNS:Edit` AND `Zone:Zone:Read`. With only
  DNS:Edit, cert-manager fails with "could not find zone".
- **cert-manager `9109 Invalid access token`** = wrong/revoked token in the vault.
  Verify before encrypting: `curl -H "Authorization: Bearer $TOKEN" https://api.cloudflare.com/client/v4/user/tokens/verify` (expect `"status":"active"`).
- **`10502 Too many authentication failures`** = Cloudflare cooldown after repeated
  bad-token attempts; clears in ~5–10 min. Not a token problem.
- **`429 too many certificates (5) ... exact set of identifiers`** = Let's Encrypt
  **duplicate-cert limit** (5/week for the same name set). This is why we issue the
  wildcard ONCE and replicate with Reflector instead of per-namespace certs.
- **Terraform Cloudflare provider v5:** resource is `cloudflare_dns_record` (not
  `cloudflare_record`); IP field is `content` (not `value`); record `name` is
  relative to the zone (`*` and `@`, not the full domain).
- **Provider blocks:** a module has only ONE `required_providers` — add `cloudflare`
  to the existing block in `main.tf`; keep only `provider "cloudflare"` + resources
  in `cloudflare.tf`.

**Helm / Ansible**
- **Helm `--wait` false timeouts:** a single hostPort Traefik pod reports
  `context deadline exceeded` even when healthy — we dropped `--wait` on Traefik.
  Stuck release: `helm -n <ns> rollback <rel> <rev>`.
- **`kubernetes.core.k8s` needs the Python `kubernetes` lib on the target** — the
  master doesn't have it, so playbooks apply manifests with `k3s kubectl apply -f`
  instead (no Python dependency). Standardize on `k3s kubectl` for applies.
- **YAML: spaces only, never tabs.** `set tabstospaces` in `~/.nanorc`. In multi-play
  files each play's `- name:` is at column 0; verify with `--list-tasks`.

**GitOps discipline (important)**
- **Under GitOps the cluster reflects Git, not your local edits.** If a fix "won't
  apply": (a) `grep` the file to confirm the change is really there, (b) `git status`
  shows it modified/staged, (c) `git push` transfers a NEW commit (not "Everything
  up-to-date"). A silently-failed file edit looks identical to ArgoCD doing nothing.
  (During the build, a Memos fix took three tries because a heredoc silently didn't
  write — always verify the file changed before committing.)
- **Don't `kubectl edit`/`scale` ArgoCD-managed resources** — `selfHeal` reverts them.
  Change Git instead. Scale-to-zero = `replicas: 0` in Git, commit.
- **Long heredocs over a flaky SSH session can truncate** — write big files in
  pieces (or as a downloaded file) and verify with `wc -l` / `tail` after.

**App-specific config (each app had one trap)**
- **Memos:** needs `MEMOS_PORT=5230`, `MEMOS_ADDR=0.0.0.0`, `MEMOS_MODE=prod`.
  Without them it starts on "port 0" (binds nothing): pod is `1/1 Running` but every
  request gets 502 / connection refused. (Data dir: `/var/opt/memos`.)
- **homepage:** (1) requires `HOMEPAGE_ALLOWED_HOSTS=homepage.gairelab.uk` or it
  rejects the proxied request. (2) The ConfigMap must NOT mount directly at
  `/app/config` (read-only → `ENOENT mkdir /app/config/logs` → 500). Mount an
  `emptyDir` at `/app/config` and layer each config file in via `subPath`.
- **n8n:** set `N8N_HOST`, `N8N_PROTOCOL=https`, `WEBHOOK_URL=https://n8n.gairelab.uk/`,
  `N8N_PROXY_HOPS=1`; runs as uid 1000 so the PVC needs `fsGroup: 1000`. Also set
  `N8N_RUNNERS_ENABLED=true` and `DB_SQLITE_POOL_SIZE=5` (clears deprecations).
  Data dir: `/home/node/.n8n`. The `N8N_ENCRYPTION_KEY` is auto-generated on the PVC;
  a storage wipe loses stored credentials.

**Diagnosis shorthand**
- **502** = Traefik reached but the backend isn't answering (port/networking — e.g.
  Memos port 0). **500** = backend reached but errored internally (config — e.g.
  homepage ENOENT). Check `kubectl logs`; a clean "connection refused" from an
  in-cluster test means the app isn't listening, not a firewall issue.

---

## Roadmap

- [x] Networking (Terraform)
- [x] Compute (Terraform) + generated inventory
- [x] Base OS prep + K3s cluster (Ansible)
- [x] kubeconfig to control node
- [x] Storage module + Longhorn (2 replicas)
- [x] Ingress (Traefik) + cert-manager + wildcard cert (staging + production)
- [x] Cloudflare A-record automation in Terraform (DNS follows public IP)
- [x] Test app (whoami) over HTTPS — full stack proven
- [x] Destroy + rebuild reproducibility verified
- [x] GitOps (ArgoCD) + app-of-apps — apps deploy from Git, no manual kubectl
- [x] Reflector — one wildcard cert replicated to all namespaces
- [x] Memos (stateful, Longhorn-backed, persistence verified)
- [x] homepage (dashboard)
- [x] n8n (stateful automation)
- [ ] Clean cert source migration (dedicated `wildcard-source.yaml` replacing per-ns certs)
- [ ] Ollama + Open WebUI + AnythingLLM (with scale-to-zero-via-Git)
- [ ] Monitoring (Prometheus / Grafana / Loki)
- [ ] Off-cluster backups (Longhorn → object storage) for app data across rebuilds
- [ ] Optional: seal the ArgoCD deploy-key secret (remove the last manual rebuild step)
