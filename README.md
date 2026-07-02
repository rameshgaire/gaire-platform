# gaire-platform

A reproducible, self-hosted Kubernetes (K3s) lab on Azure, provisioned with
Terraform, configured with Ansible, and running applications via GitOps (ArgoCD).
Built to be destroyed and recreated on demand — no resource is hand-clicked,
rebuilds pick up a fresh public IP automatically (DNS follows it), TLS certs
reissue and replicate themselves, ArgoCD's own repo credentials regenerate
automatically, and every application redeploys from Git.

> Status: the full stack — infrastructure, cluster, storage, ingress, TLS
> (issue-once/reflect-everywhere), DNS, GitOps (fully self-bootstrapping,
> including its own repo credentials), and seven applications — has been
> destroyed and rebuilt from this repo multiple times and verified end-to-end.
> A rebuild needs only the Terraform/Ansible runs plus a handful of
> control-node-local secret *files* (documented below) — no manual `kubectl`
> and no manual in-cluster secret creation.

---

## What's running

All apps are GitOps-managed (ArgoCD), served over trusted/staging HTTPS via a
single wildcard certificate replicated across namespaces (Reflector).

| App         | URL                        | Type        | Storage        | Replicas |
|-------------|----------------------------|-------------|----------------|----------|
| ArgoCD      | `argocd.gairelab.uk`       | GitOps UI   | —              | 1        |
| whoami      | `hello.gairelab.uk`        | test app    | —              | 1        |
| Memos       | `memos.gairelab.uk`        | notes       | 5 Gi Longhorn  | 1        |
| homepage    | `homepage.gairelab.uk`     | dashboard   | — (ConfigMap)  | 1        |
| n8n         | `n8n.gairelab.uk`          | automation  | 5 Gi Longhorn  | 1        |
| Ollama      | internal only (11434)      | model server| 15 Gi Longhorn | 1        |
| Open WebUI  | `openwebui.gairelab.uk`    | LLM chat UI | 5 Gi Longhorn  | 1        |
| AnythingLLM | `anythingllm.gairelab.uk`  | RAG / docs  | 10 Gi Longhorn | **0**    |
| Grafana     | `grafana.gairelab.uk`      | dashboards  | 2 Gi (single-replica) | 1 |

AnythingLLM is deployed but scaled to zero by design (see "The LLM stack") —
flip `replicas: 0 → 1` in Git when you want to use it, and consider scaling
Open WebUI down at the same time so they're not both competing with Ollama
for RAM.

Monitoring (Prometheus + Grafana + Loki) is infrastructure, not an app — see
"Monitoring" below for why, and note it was installed onto an already-running
cluster; it has not yet been proven via a full `01→10` rebuild from scratch.
Treat that as the real test the next time you rebuild.

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
- **Certificate distribution:** ONE wildcard cert is issued (currently via the
  `letsencrypt-staging` issuer — see "TLS" section for why), then replicated
  into every app namespace by Reflector (avoids Let's Encrypt's duplicate-cert
  limit entirely).
- **DNS:** Cloudflare; A-records (`*` + apex) are managed by Terraform and point
  at the master's current public IP — updated automatically on every apply.
- **GitOps:** ArgoCD watches this repo, including its own repo credentials
  (recreated from the Ansible Vault on every install — no manual secret step).
  A root "app-of-apps" Application creates one ArgoCD Application per app.
  Deploying/removing an app = committing a manifest.
- **Monitoring:** Prometheus + Grafana + Loki (`kube-prometheus-stack` +
  `loki-stack`), installed as infrastructure via Ansible (not an ArgoCD
  Application) — it watches every namespace cluster-wide and isn't scoped to
  a single app's lifecycle. Grafana is reachable at `grafana.gairelab.uk`.
- **Storage classes:** `longhorn` (default, 2 replicas) for anything that
  matters; `longhorn-single-replica` (1 replica) for lower-stakes volumes
  where you'd rather save disk than survive a single node failure — currently
  used by the monitoring stack's PVCs. See "Storage" below.

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
│   │   ├── 06-ingress.yml           # Traefik + cert-manager + Cloudflare secret + both ClusterIssuers (with readiness waits)
│   │   ├── 07-argocd.yml            # ArgoCD + repo deploy-key Secret (from vault) + its Ingress + root app-of-apps
│   │   ├── 08-reflector.yml         # install Reflector (Helm) — replicates the wildcard TLS secret
│   │   ├── 09-wildcard.yml          # issue the ONE source wildcard Certificate (with readiness waits)
│   │   └── 10-monitoring.yml        # single-replica StorageClass + kube-prometheus-stack + loki-stack + Grafana Ingress
│   └── scripts/
│       └── kube-tunnel.sh           # SSH tunnel to the K3s API (run, leave open) for local kubectl
├── docs/                            # (reserved for future design notes / diagrams)
├── kubernetes/
│   ├── apps/                        # one folder per application
│   │   ├── whoami/whoami.yaml               # test app, single-file (namespace+Deploy+Svc+Ingress)
│   │   ├── memos/                           # notes (namespace, PVC, Deployment, Service, Ingress)
│   │   ├── homepage/                        # dashboard (namespace, ConfigMap, Deployment, Service, Ingress)
│   │   ├── n8n/                             # automation (namespace, PVC, Deployment, Service, Ingress)
│   │   ├── ollama/                          # model server (namespace, PVC, Deployment, Service — NO Ingress, internal only)
│   │   ├── openwebui/                       # LLM chat UI (namespace, PVC, Deployment, Service, Ingress)
│   │   └── anythingllm/                     # RAG (namespace, PVC, Deployment [replicas:0], Service, Ingress)
│   ├── infrastructure/              # cluster services (not user apps) — no per-app Certificates live here anymore
│   │   ├── traefik/values.yaml              # Helm values (hostPort 80/443, pinned to master)
│   │   ├── argocd/
│   │   │   ├── values.yaml                   # Helm values (server.insecure: true)
│   │   │   └── ingress.yaml                  # Ingress for argocd.gairelab.uk (applied by 07-argocd.yml)
│   │   ├── cert-manager/
│   │   │   ├── cluster-issuer-staging.yaml          # Let's Encrypt staging (DNS-01 via Cloudflare)
│   │   │   ├── cluster-issuer-production.yaml       # Let's Encrypt production (trusted)
│   │   │   └── wildcard-source.yaml                 # THE single reflected source cert (see TLS section)
│   │   ├── longhorn/
│   │   │   ├── values.yaml                          # Helm values (2 replicas, /var/lib/longhorn)
│   │   │   └── single-replica-storageclass.yaml     # "longhorn-single-replica" — 1 replica, lower-stakes volumes
│   │   └── monitoring/
│   │       ├── kube-prometheus-stack-values.yaml    # trimmed resources + retention for a lab
│   │       ├── loki-stack-values.yaml               # Loki+Promtail only, Grafana disabled (use the one above)
│   │       └── ingress.yaml                         # Grafana Ingress (grafana.gairelab.uk)
│   └── argocd/
│       ├── root.yaml                # app-of-apps: watches applications/ and creates an App per file
│       └── applications/            # one ArgoCD Application manifest per app (the on/off toggles)
│           ├── whoami.yaml
│           ├── memos.yaml
│           ├── homepage.yaml
│           ├── n8n.yaml
│           ├── ollama.yaml
│           ├── openwebui.yaml
│           └── anythingllm.yaml
├── secrets/
│   ├── README.md
│   ├── ansible-secrets.yml          # Ansible Vault (committed ENCRYPTED): Cloudflare token + ArgoCD deploy key
│   └── terraform.tfvars             # gitignored: subscription id, SSH source IP, CF token + zone id
└── terraform/
    ├── networking/                  # apply 1st: RG, VNET, subnets, NSG, static public IP
    ├── compute/                     # apply 2nd: NICs + VMs; renders hosts.ini; Cloudflare DNS records
    │   └── cloudflare.tf            # Cloudflare provider + A-records (* and apex) -> master public IP
    └── storage/                     # apply 3rd: 50 GB managed data disk per worker + attachment
```

**Files you must CREATE locally (gitignored — never committed):**

```
secrets/terraform.tfvars              subscription id, SSH source IP, Cloudflare token + zone id
~/.vault_pass                         Ansible Vault password (decrypts ansible-secrets.yml)
~/.ssh/gaire-platform-admin[.pub]     interactive SSH keypair
~/.ssh/gaire-platform-ansible[.pub]   Ansible automation SSH keypair
~/.ssh/argocd-gaire-platform[.pub]    ArgoCD read-only deploy key (public half goes on GitHub)
```

> The ArgoCD deploy key's **private half is also stored in the encrypted vault**
> (`argocd_deploy_key` variable) so `07-argocd.yml` can recreate the in-cluster
> Secret automatically on every rebuild — see "ArgoCD repo access" below. You
> still need the keypair present locally the first time (to add the public key
> to GitHub and to seed the vault).

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

- **Domain** `gairelab.uk` → your domain. Appears in: `wildcard-source.yaml`
  `dnsNames`, app Ingress `host` rules, the issuer `email`, and the
  n8n/homepage env vars.
- **Email** in the two `cluster-issuer-*.yaml` files → your email.
- **Azure** `subscription_id`, and `region` / `resource group` if you want different ones.
- **Cloudflare** `cloudflare_zone_id` and the API token (your own zone + token).
- **GitHub repo** the `repoURL` in `kubernetes/argocd/root.yaml`, every
  `kubernetes/argocd/applications/*.yaml`, AND `repo_url` in `07-argocd.yml`
  → your repo (SSH form `git@github.com:you/repo.git`).

---

## Prerequisites (one-time per control node)

- Azure CLI, authenticated: `az login`
- Terraform >= 1.5
- Ansible, plus collections: `ansible-galaxy collection install -r ansible/requirements.yml`
- `kubectl` and Helm 3
- `git`, with access to your fork of this repo
- A Cloudflare account with your domain's zone, and an API token (see below)

---

## First-time setup — create the files that are NOT in the repo

### 1. SSH keypairs

```bash
ssh-keygen -t ed25519 -f ~/.ssh/gaire-platform-admin   -C "gaire-platform admin"   -N ""
ssh-keygen -t ed25519 -f ~/.ssh/gaire-platform-ansible -C "gaire-platform ansible" -N ""
ssh-keygen -t ed25519 -f ~/.ssh/argocd-gaire-platform  -C "argocd-deploy-key"      -N ""
```

Add the ArgoCD public key to GitHub now (read-only deploy key):
```bash
cat ~/.ssh/argocd-gaire-platform.pub
#   -> GitHub repo -> Settings -> Deploy keys -> Add deploy key
#      Title: argocd ; paste ; leave "Allow write access" UNCHECKED.
```

### 2. Cloudflare API token (needs TWO permissions)

Cloudflare dashboard → My Profile → API Tokens → Create Custom Token:
- Permissions: **Zone → DNS → Edit** AND **Zone → Zone → Read** (both required)
- Zone Resources: Include → your zone (e.g. `gairelab.uk`)

Find your **Zone ID** on the domain's Overview page (right-hand "API" section).

### 3. `secrets/terraform.tfvars` (gitignored)

```bash
cat > secrets/terraform.tfvars <<'TFV'
subscription_id      = "<your-azure-subscription-id>"
ssh_source_address   = "<your-control-node-public-ip>/32"
cloudflare_api_token = "<your-cloudflare-api-token>"
cloudflare_zone_id   = "<your-cloudflare-zone-id>"
TFV
```

### 4. `~/.vault_pass` + `secrets/ansible-secrets.yml` (Cloudflare token + ArgoCD deploy key, encrypted)

The vault now holds **two** secrets: the Cloudflare token (for cert-manager) and
the ArgoCD deploy **private key** (so `07-argocd.yml` can fully automate the
repo credential — no manual `kubectl create secret` on rebuild).

```bash
# a) Vault password (control-node-local, never committed)
nano ~/.vault_pass
chmod 600 ~/.vault_pass

# b) Build the plaintext vault file — the deploy key as a YAML block scalar,
#    indented consistently under the key:
{
  echo "---"
  echo "cloudflare_api_token: \"<your-cloudflare-api-token>\""
  echo "argocd_deploy_key: |"
  sed 's/^/  /' ~/.ssh/argocd-gaire-platform
} > secrets/ansible-secrets.yml

# c) Sanity-check the structure (BEGIN/END markers, consistent 2-space indent):
tail -20 secrets/ansible-secrets.yml

# d) Encrypt it
cd ansible
ansible-vault encrypt ../secrets/ansible-secrets.yml
head -c 30 ../secrets/ansible-secrets.yml; echo    # confirm: $ANSIBLE_VAULT...
cd ..
```

> Never `cat` or `ansible-vault view` these into a shared screen/log longer
> than needed. To check a secret exists, test for the KEY, not the value.

### 5. `.gitignore` (verify it protects secrets)

```gitignore
**/.terraform/*
*.tfstate
*.tfstate.*
!**/.terraform.lock.hcl

secrets/*
!secrets/README.md
!secrets/ansible-secrets.yml

ansible/inventory/hosts.ini
*.save
*.save.*
```

---

## Build (from nothing) — full sequence

### 1. Infrastructure (Terraform)

```bash
cd terraform/networking
terraform init
terraform apply -var-file=../../secrets/terraform.tfvars

cd ../compute
terraform init
terraform apply -var-file=../../secrets/terraform.tfvars  # note master_public_ip in output

cd ../storage
terraform init
terraform apply -var-file=../../secrets/terraform.tfvars
cd ../..
```

### 2. Cluster, storage, ingress, GitOps, TLS (Ansible) — fully automated, in order

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible all -m ping

ansible-playbook playbooks/01-base.yml          # OS prep
ansible-playbook playbooks/02-k3s.yml           # build the cluster
ansible-playbook playbooks/03-kubeconfig.yml    # write ~/.kube/config
ansible-playbook playbooks/04-longhorn-prep.yml # format + mount worker data disks
ansible-playbook playbooks/05-longhorn.yml      # Longhorn + sole default StorageClass
ansible-playbook playbooks/06-ingress.yml       # Traefik + cert-manager + Cloudflare secret + issuers (waits for Ready)
ansible-playbook playbooks/07-argocd.yml        # ArgoCD + repo deploy-key Secret (from vault) + its Ingress + root
ansible-playbook playbooks/08-reflector.yml     # Reflector
ansible-playbook playbooks/09-wildcard.yml      # issue the ONE source wildcard cert (waits for Ready + Secret)
ansible-playbook playbooks/10-monitoring.yml    # single-replica StorageClass + Prometheus/Grafana/Loki + Grafana ingress
cd ..
```

Playbook 10 is the least-proven of the set — see "Monitoring" below for why —
so watch its output closely on the next full rebuild rather than assuming
it'll be as uneventful as 01–09 have become.

Every step above is fully unattended — no manual `kubectl apply`, no manual
secret creation. This is a change from earlier in the project: the ArgoCD
repo deploy-key Secret and ArgoCD's own Ingress used to be manual post-install
steps; both are now inside `07-argocd.yml`.

### 3. Open the kubectl tunnel (per work session — the one truly manual, local-only step)

```bash
./ansible/scripts/kube-tunnel.sh
# in another terminal:  kubeup   (prints "tunnel up")
```

### 4. Pull models into Ollama (one-time data step, not GitOps)

```bash
kubectl -n ollama get pods                                     # wait for 1/1 Running
kubectl -n ollama exec deploy/ollama -- ollama pull llama3.2:3b
kubectl -n ollama exec deploy/ollama -- ollama pull nomic-embed-text   # embeddings — AnythingLLM needs this too
kubectl -n ollama exec deploy/ollama -- ollama list             # confirm both present
```

### 5. Verify (end-to-end proof)

```bash
kubectl get nodes -o wide                          # 3 nodes Ready
kubectl get storageclass                           # only "longhorn (default)"
kubectl get clusterissuer                          # staging + production READY=True
kubectl -n cert-manager get certificate             # wildcard-source READY=True
kubectl -n argocd get applications                 # root + all 7 apps Synced/Healthy
dig +short hello.gairelab.uk                       # current master public IP
curl -Ik https://hello.gairelab.uk                 # 200 (-k while on staging cert — see TLS section)
curl -Ik https://memos.gairelab.uk
curl -Ik https://homepage.gairelab.uk
curl -Ik https://n8n.gairelab.uk
curl -Ik https://openwebui.gairelab.uk
curl -Ik https://argocd.gairelab.uk
```

---

## ArgoCD repo access (deploy key) — now fully automated

This used to be a manual rebuild step (`kubectl create secret ...` by hand).
It is now handled entirely by `07-argocd.yml`:

1. The private key lives in the **Ansible Vault** (`argocd_deploy_key`).
2. The playbook writes it to a plain file on the master (`/tmp/argocd-deploy-key`,
   `no_log: true`), then builds the Secret with
   `k3s kubectl create secret generic ... --from-file=sshPrivateKey=<file>`.
3. It deletes any existing `repo-gaire-platform` Secret first, so every run
   starts from a clean slate rather than "updating" a possibly-stale one.
4. The temp key file is removed from the master afterward.

> **Why `--from-file` and not a templated YAML Secret:** an earlier version of
> this playbook rendered the key into a `content: |` YAML block scalar via a
> Jinja `indent()` filter. A multi-line SSH key nested inside another YAML
> block scalar is fragile — a single misplaced indent produced `ssh: no key
> found` in the ArgoCD repo-server logs, and **every** Application showed
> `SYNC STATUS: Unknown` (not just new ones — a good diagnostic tell that the
> repo connection itself is broken, not an individual app). `--from-file`
> reads the key's bytes exactly as-is with no YAML re-parsing, which is the
> same mechanism used to fix it by hand and is far more robust. See "Notes /
> gotchas learned" for the full diagnostic story.

If you ever need to recreate this manually (e.g. debugging), the equivalent is:

```bash
kubectl -n argocd delete secret repo-gaire-platform --ignore-not-found
kubectl -n argocd create secret generic repo-gaire-platform \
  --from-literal=type=git \
  --from-literal=url=git@github.com:<you>/gaire-platform.git \
  --from-file=sshPrivateKey=$HOME/.ssh/argocd-gaire-platform
kubectl -n argocd label secret repo-gaire-platform \
  argocd.argoproj.io/secret-type=repository
```

Verify in the ArgoCD UI: Settings → Repositories → status **Successful**. Or:
```bash
kubectl -n argocd get secret repo-gaire-platform -o jsonpath='{.data.sshPrivateKey}' | base64 -d | head -1
# must show: -----BEGIN OPENSSH PRIVATE KEY-----
```

> Diagnostic pattern worth remembering: if **every** Application (not just one)
> shows `SYNC STATUS: Unknown`, suspect the repo connection itself (deploy key,
> secret, or network) rather than any individual app's manifests. Check
> `kubectl -n argocd logs deploy/argocd-repo-server --tail=50 | grep -i error`.

---

## ArgoCD admin password — reset if forgotten

The auto-generated initial password's secret (`argocd-initial-admin-secret`) is
deleted after first login, per ArgoCD's own hardening guidance — so once you
change the password, there is no "retrieve," only "reset":

```bash
NEWPASS='choose-a-new-strong-password'
BCRYPT_HASH=$(htpasswd -nbBC 10 "" "$NEWPASS" | tr -d ':\n' | sed 's/^\$2y/\$2a/')
# needs apache2-utils if htpasswd is missing: sudo apt-get install -y apache2-utils

kubectl -n argocd patch secret argocd-secret \
  -p "{\"stringData\": {\"admin.password\": \"$BCRYPT_HASH\", \"admin.passwordMtime\": \"$(date +%FT%T%Z)\"}}"
kubectl -n argocd rollout restart deployment argocd-server
kubectl -n argocd rollout status deployment argocd-server
unset NEWPASS BCRYPT_HASH
```

Log in at `https://argocd.gairelab.uk` as `admin` / `$NEWPASS`.

---

## TLS — issue once, replicate everywhere (Reflector)

**Why:** Let's Encrypt limits identical certificates to **5 per week** for the
same set of names. Issuing a separate `*.gairelab.uk` cert per namespace hit
this limit during the build (twice — once from per-app Certificates, once
again from repeated manual annotate/delete cycles while migrating). The fix,
now fully implemented: issue the wildcard **once**, replicate the resulting
secret into every namespace with Reflector, and never issue a duplicate again.

**How it works, end to end:**

1. `09-wildcard.yml` applies **one** source `Certificate`
   (`kubernetes/infrastructure/cert-manager/wildcard-source.yaml`) in the
   `cert-manager` namespace, requesting `*.gairelab.uk` + `gairelab.uk`.
2. Its `secretTemplate` carries Reflector annotations marking the resulting
   secret as reflectable, with an explicit auto-namespace list.
3. **Reflector** (installed by `08-reflector.yml`, which runs *before* 09 so
   it's already watching) copies the secret into every listed namespace
   immediately, and into new namespaces the moment they're created.
4. Every app's Ingress references the local `wildcard-gairelab-uk-tls` secret.
   **No app manifest contains a `Certificate`** — the cert just appears.

The source Certificate:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-source
  namespace: cert-manager
spec:
  secretName: wildcard-gairelab-uk-tls
  secretTemplate:
    annotations:
      reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "*"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "memos,homepage,n8n,demo,argocd,openwebui,anythingllm,ollama"
  issuerRef:
    name: letsencrypt-staging     # <-- see "Current issuer" below
    kind: ClusterIssuer
  dnsNames:
    - "gairelab.uk"
    - "*.gairelab.uk"
```

`09-wildcard.yml` waits for both the `Certificate` to report `Ready` and the
`Secret` to actually exist before finishing, so downstream playbooks/apps never
race an unissued cert.

### Current issuer: staging (deliberate, temporary)

**`wildcard-source.yaml` currently points at `letsencrypt-staging`**, not
`letsencrypt-production`. This is a direct consequence of the duplicate-cert
limit above: repeated manual fixes while building the Reflector migration
(annotate/delete/reissue cycles) burned through the production quota, and Let's
Encrypt enforces a **1-week** cooldown per exact name-set. Rather than wait
idle, we build and validate the *entire* pipeline on staging — cryptographically
identical process, just an untrusted CA — so every app, Reflector, and Ingress
is proven working. This is why `curl` needs `-k` and browsers show a warning
right now.

**To flip to production once the cooldown clears (one-line change):**

```bash
sed -i 's/letsencrypt-staging/letsencrypt-production/' \
  kubernetes/infrastructure/cert-manager/wildcard-source.yaml
git add kubernetes/infrastructure/cert-manager/wildcard-source.yaml
git commit -m "cert: flip source cert to letsencrypt-production"
git push
kubectl apply -f kubernetes/infrastructure/cert-manager/wildcard-source.yaml   # or re-run 09-wildcard.yml
```

cert-manager reissues into the same secret name; Reflector re-fans-out
automatically to every namespace with zero other changes.

Adding a brand-new app namespace later needs **no cert work at all** — add its
name to `reflection-auto-namespaces` (or rely on the `*`-allowed default) and
Reflector populates it the moment the namespace exists.

> **Net effect:** 1 issuance per environment-state, every namespace covered,
> renewals replicate automatically. The rate limit is now structurally
> impossible to hit again.

---

## Ingress & TLS components

- **Traefik** (chart 40.2.0), `06-ingress.yml`, hostPort 80/443 pinned to
  `k3s-master`. No LoadBalancer, no MetalLB. (Helm task runs WITHOUT `--wait` —
  a single hostPort pod produces false readiness timeouts.)
- **cert-manager** (v1.18.x), Let's Encrypt **DNS-01** via Cloudflare — lets us
  issue wildcards and doesn't depend on inbound reachability.
- **Two ClusterIssuers**, applied by `06-ingress.yml`, each followed by an
  explicit `kubectl wait --for=condition=Ready` task so later playbooks never
  race an issuer that isn't actually ready yet: `letsencrypt-staging`
  (untrusted, no rate limit) and `letsencrypt-production` (trusted, rate-limited).
- **Cloudflare API token** lives in the Ansible Vault; `06-ingress.yml` creates
  the `cloudflare-api-token` Kubernetes Secret from it.

---

## GitOps (ArgoCD)

- **Install:** `07-argocd.yml` (Helm chart 9.7.1 / Argo CD v3.4.4).
  `server.insecure: true` so Traefik terminates TLS in front. Also in this one
  playbook, in order: the repo deploy-key Secret (from vault), ArgoCD's own
  Ingress, and the root app-of-apps bootstrap.
- **App-of-apps:** `kubernetes/argocd/root.yaml` watches
  `kubernetes/argocd/applications/` and creates an Application per file there.
- **Deploying an app:** create `kubernetes/apps/<app>/` +
  `kubernetes/argocd/applications/<app>.yaml`, commit, push. Root creates the
  Application; it syncs. **No `kubectl apply`.**
- **Turning an app OFF:**
  - *Temporarily:* `replicas: 0` in Git, commit. (Never `kubectl scale` —
    `selfHeal` reverts it.)
  - *Permanently:* delete the app's `applications/<app>.yaml` (root prunes it).
- **Infra vs. apps ownership (no split-brain):** ArgoCD Applications only ever
  point at `kubernetes/apps/<app>/` paths. Anything under
  `kubernetes/infrastructure/` (Traefik, cert-manager, the wildcard source,
  Reflector, ArgoCD's own Ingress) is applied by Ansible, never by an ArgoCD
  Application — so there is exactly one owner per resource and no reconciler
  fights another. This split is deliberate: infra is bootstrap-phase (needed
  before ArgoCD is even useful), apps are steady-state (the right fit for
  continuous reconciliation).

---

## Deploying apps — the pattern

Each app is a folder under `kubernetes/apps/<app>/` plus one Application under
`kubernetes/argocd/applications/<app>.yaml`. Apps get their TLS secret from
Reflector — no per-app Certificate, ever.

A typical stateful app contains:

1. `namespace.yaml`
2. `pvc.yaml` — Longhorn PVC (only for apps that store data)
3. `deployment.yaml` — `strategy: Recreate` for single-PVC apps (ReadWriteOnce
   can't attach to two pods mid-rollout)
4. `service.yaml` — ClusterIP
5. `ingress.yaml` — host `<app>.gairelab.uk`, `entrypoints: websecure`,
   `secretName: wildcard-gairelab-uk-tls` (Ollama has NO Ingress — it's
   internal-only, consumed by other pods via
   `ollama.ollama.svc.cluster.local:11434`.)

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

Commit + push → root creates the Application → ArgoCD syncs → cert appears via
Reflector → app live at `https://<app>.gairelab.uk`. **No kubectl, ever.**

---

## The LLM stack — Ollama, Open WebUI, AnythingLLM

### Resource planning (read this before flipping anything to `replicas: 1`)

Hardware: 2 workers × 8 GB = 16 GB, minus Kubernetes/Longhorn/Traefik overhead
→ realistically **~13 GB usable**. LLM inference is RAM-hungry and CPU-only
inference on 2 vCPU is slow (seconds, not instant). Observed headroom before
deploying the LLM stack: ~1 GB used cluster-wide out of 16 GB — comfortable.

| App          | Request / Limit (RAM) | Request / Limit (CPU) | Notes |
|--------------|------------------------|------------------------|-------|
| Ollama       | 2Gi / 4Gi              | 1 / 2                  | `OLLAMA_MAX_LOADED_MODELS=1` — keep one model resident |
| Open WebUI   | 512Mi / 1Gi            | 250m / 1               | thin frontend |
| AnythingLLM  | 1Gi / 2Gi              | 500m / 1               | ~2 GB baseline per its own docs |

**Practical rule:** run Ollama + ONE frontend at a time. Don't run Open WebUI
and AnythingLLM simultaneously unless headroom is confirmed via
`kubectl top nodes` — both compete for the same Ollama-backed inference.

### Ollama (model server)

- Image pinned to an exact version, **not `:latest`** — Docker Hub's `latest`
  tag for `ollama/ollama` has lagged behind real releases before (confirmed via
  a GitHub issue against the project), so pin explicitly and bump deliberately.
- `OLLAMA_HOST=0.0.0.0:11434` to listen cluster-wide; `OLLAMA_MAX_LOADED_MODELS=1`.
- No Ingress — internal only, `strategy: Recreate`, 15 Gi PVC at `/root/.ollama`.
- Models are pulled **after** deploy (data operation, not GitOps):
  ```bash
  kubectl -n ollama exec deploy/ollama -- ollama pull llama3.2:3b
  kubectl -n ollama exec deploy/ollama -- ollama pull nomic-embed-text
  ```
  `llama3.2:3b` (~2 GB) is the chat model; `nomic-embed-text` is required for
  **any** embedding-based feature (AnythingLLM's document RAG) — skip it and
  document uploads fail *silently*, which is a confusing failure mode to debug
  blind, so pull it up front even if you start with Open WebUI only.

### Open WebUI

- `ghcr.io/open-webui/open-webui:v0.10.1` (pinned; the project also publishes
  `:cuda`/`:ollama` combo images we don't need on CPU-only hardware).
- `OLLAMA_BASE_URL=http://ollama.ollama.svc.cluster.local:11434` — in-cluster
  DNS, no Ingress hop needed pod-to-pod.
- `WEBUI_AUTH=true` (it's internet-reachable via Ingress — keep login on).
- 5 Gi PVC at `/app/backend/data`.

### AnythingLLM — deployed, scaled to zero

- Image pinned to `mintplexlabs/anythingllm:1.15.0` (was `:latest` during the
  initial scale-to-zero deploy; pinned once a real stable tag was confirmed).
- Requires `securityContext.capabilities.add: ["SYS_ADMIN"]` (the Docker
  `cap_add: SYS_ADMIN` requirement from AnythingLLM's own docs, translated to
  Kubernetes) and `fsGroup: 1000` on the PVC.
- Env vars (from AnythingLLM's official docker-compose reference):
  `LLM_PROVIDER=ollama`, `OLLAMA_BASE_PATH=http://ollama.ollama.svc.cluster.local:11434`,
  `OLLAMA_MODEL_PREF=llama3.2:3b`, `EMBEDDING_ENGINE=ollama`,
  `EMBEDDING_BASE_PATH=<same as OLLAMA_BASE_PATH>`,
  `EMBEDDING_MODEL_PREF=nomic-embed-text:latest`, `VECTOR_DB=lancedb`,
  `STORAGE_DIR=/app/server/storage`.
- **`JWT_SECRET` is a Kubernetes Secret (`anythingllm-secrets`), referenced via
  `valueFrom.secretKeyRef`** — not inline plaintext. The Secret itself is
  intentionally **not committed to Git** (there's nothing to persist: the
  PVC is wiped on every destroy anyway, so a fresh random value each time is
  fine). This means it's a genuine **manual step, but only if/when you flip
  AnythingLLM on**:
  ```bash
  kubectl -n anythingllm create secret generic anythingllm-secrets \
    --from-literal=JWT_SECRET="$(openssl rand -hex 32)"
  ```
  Without this Secret present, the pod fails to start (missing `secretKeyRef`).
  (If the Secret already exists and you need to rotate it: `kubectl delete
  secret` first — `create` fails on an existing name rather than updating it.)
- To turn it on: recreate the Secret above, then edit `replicas: 0 → 1` in
  Git, commit, push. Consider scaling Open WebUI to 0 at the same time (see
  resource table above). The `1.15.0` pin has never actually been run yet —
  watch the pod carefully the first time, the way every other app here has
  had at least one first-run surprise.

---

## Storage classes

Two Longhorn StorageClasses exist:

- **`longhorn`** (default, 2 replicas) — everything that stores real data:
  Memos, n8n, Ollama's models, Open WebUI, AnythingLLM.
- **`longhorn-single-replica`** (1 replica) — for volumes where losing a
  single node's copy is an acceptable risk in exchange for using half the
  disk. Currently used by the monitoring stack (Prometheus, Loki, Grafana).

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-single-replica
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "1"
  staleReplicaTimeout: "2880"
```

**Why this exists — a real capacity lesson:** adding the monitoring stack
requested ~22 Gi of new 2-replica volumes on top of an already-committed ~40 Gi
across the existing apps, against only 50 Gi of raw disk *per worker* (100 Gi
total). Several Prometheus/Loki volumes came up `faulted`/`unknown` in
Longhorn — not because of a bad values.yaml, but because **disk space is a
separate constraint from CPU/RAM, and `kubectl top nodes` tells you nothing
about it.** The fix was to move the monitoring stack's lower-stakes volumes to
a single-replica class, roughly halving their real disk footprint.

**Before adding anything storage-heavy, check disk — not just `kubectl top`:**

```bash
kubectl -n longhorn-system get volumes                 # any "faulted"/"unknown" ROBUSTNESS is a red flag
kubectl -n longhorn-system get nodes.longhorn.io -o custom-columns=NAME:.metadata.name,DISK:.status.diskStatus
# or, directly on a worker:
ssh -F ~/.ssh/config k3s-worker01 df -h /var/lib/longhorn
```

**PVC `storageClassName` is immutable once bound.** Trying to change an
existing PVC's StorageClass via a Helm upgrade fails with `spec is immutable
after creation` — the fix is to delete the PVC (and whatever pod is using it)
so it gets recreated fresh against the new class, not patch it in place.

---

## Monitoring (Prometheus, Grafana, Loki)

Installed as **infrastructure** (Ansible, `10-monitoring.yml`), not an ArgoCD
Application — same reasoning as Traefik/cert-manager/Reflector: it watches
every namespace cluster-wide and isn't scoped to a single app's lifecycle.

- **`kube-prometheus-stack`** (prometheus-community, pinned `87.5.1`) —
  Prometheus, Grafana, Alertmanager, kube-state-metrics, node-exporter, all in
  one chart. Retention trimmed to 3 days (lab, not production); resource
  requests/limits trimmed to fit alongside the LLM stack.
- **`loki-stack`** (grafana, pinned `2.10.3`) — Loki + Promtail for logs.
  Its bundled Grafana is disabled (`grafana.enabled: false`) since
  kube-prometheus-stack already provides one; Loki is wired in as an
  additional Grafana datasource instead. Note: `loki-stack` is the simpler,
  if now-legacy, chart — Grafana's newer split `loki` + `alloy`/`promtail`
  charts are more capable but more complex; not worth it for a lab.
- Both use **`longhorn-single-replica`** for their PVCs (see "Storage classes"
  above) — Prometheus 10 Gi, Loki 10 Gi, Grafana 2 Gi.
- **Grafana** is reachable at `grafana.gairelab.uk` via an Ingress
  (`kubernetes/infrastructure/monitoring/ingress.yaml`, applied by the same
  playbook) referencing the Reflector-provided wildcard secret — no separate
  Certificate, same as every app.
- **Default login is `admin` / `prom-operator`** (kube-prometheus-stack's
  built-in default) — change it on first login, Settings → Profile.
- Confirm Loki is wired up: Grafana → Connections → Data sources → should
  list both **Prometheus** and **Loki**.

> **Not yet proven via a full rebuild.** This was installed onto an
> already-running cluster (`10-monitoring.yml` run standalone, not as part of
> a `01→10` sequence from a fresh destroy). The next full rebuild is the real
> test of whether it comes back cleanly in sequence — watch it closely the
> first time through, the same way every other playbook needed at least one
> fix the first time it ran end-to-end.

---

## Local kubectl access

- **Each rebuild:** `03-kubeconfig.yml` regenerates `~/.kube/config`.
- **Each work session:** `./ansible/scripts/kube-tunnel.sh`, leave it open; use
  kubectl in another terminal.
- **`kubeup`** reports tunnel status. "connection refused" = tunnel down,
  restart the script — this does **not** affect the cluster or ArgoCD (ArgoCD
  syncs from Git independently of your local tunnel).
- Don't start a second tunnel — "Address already in use".

```bash
echo "alias kubeup='(echo > /dev/tcp/127.0.0.1/6443) 2>/dev/null && echo \"tunnel up\" || echo \"tunnel DOWN — run kube-tunnel.sh\"'" >> ~/.bashrc
source ~/.bashrc
```

---

## DNS (Cloudflare, automated)

- `terraform/compute/cloudflare.tf` (Cloudflare provider `~> 5.0`).
- Two A-records at the master's current public IP: wildcard `*` and apex `@`.
- `proxied = false` — TLS is handled by Traefik + cert-manager, not Cloudflare.

---

## Destroy and rebuild

### Destroy (reverse dependency order)

```bash
cd terraform/storage    && terraform destroy -var-file=../../secrets/terraform.tfvars
cd ../compute           && terraform destroy -var-file=../../secrets/terraform.tfvars   # also removes Cloudflare A-records
cd ../networking        && terraform destroy -var-file=../../secrets/terraform.tfvars   # releases the public IP
cd ../..

az resource list -g gaire-platform-rg -o table     # empty, or "group not found"
```

Storage is **disposable** — Longhorn data (Memos notes, n8n workflows/credentials,
Ollama's downloaded models, any AnythingLLM documents) is destroyed with it.

### Rebuild — what actually has to happen, in order

1. **Confirm control-node-local files exist:**
   ```bash
   ls -la ~/.vault_pass \
          ~/.ssh/gaire-platform-admin ~/.ssh/gaire-platform-ansible \
          ~/.ssh/argocd-gaire-platform \
          secrets/terraform.tfvars
   ```
   On a brand-new control node, recreate per "First-time setup" — note the
   vault must contain **both** `cloudflare_api_token` and `argocd_deploy_key`.

2. **Check the control node's public IP** matches `ssh_source_address`:
   ```bash
   curl -s ifconfig.me; echo
   grep ssh_source_address secrets/terraform.tfvars
   ```

3. **Terraform** (networking → compute → storage).

4. **Ansible 01–09**, in order — this now does *everything*: cluster, storage,
   ingress, ClusterIssuers, ArgoCD, ArgoCD's own repo credentials, ArgoCD's own
   Ingress, root app-of-apps, Reflector, and the source wildcard cert.

5. **Open the tunnel:** `./ansible/scripts/kube-tunnel.sh`.

6. **Pull Ollama's models** (data step, not Git-managed):
   ```bash
   kubectl -n ollama exec deploy/ollama -- ollama pull llama3.2:3b
   kubectl -n ollama exec deploy/ollama -- ollama pull nomic-embed-text
   ```

7. **Verify** — see "Build" step 5.

**Manual rebuild touchpoints — the complete, current list:**
- Recreate control-node-local secret *files* if on a fresh machine (step 1) —
  this is unavoidable by design (the private material can't live in Git).
- Open the kubectl tunnel (step 5) — local access only, doesn't gate the cluster.
- Pull Ollama's models (step 6) — data, not configuration.

That's it. **The ArgoCD deploy-key secret and ArgoCD's own Ingress are no
longer manual** — both used to be on this list; both are now inside
`07-argocd.yml`. The wildcard cert is no longer manual either — it's
`09-wildcard.yml`. Everything else — infra, cluster, storage, ingress, DNS,
ArgoCD, Reflector, TLS, and all seven applications — is fully automatic.

> **Note on app data:** a full destroy wipes Longhorn, so Memos notes, n8n
> workflows/credentials, and any downloaded Ollama models do NOT survive a
> rebuild. Acceptable for a lab; for persistence across rebuilds you'd need
> off-cluster backups (Longhorn → object storage) — not currently configured.

---

## How rebuild-safety works

- `hosts.ini` is **generated** by Terraform's compute module every apply.
- `group_vars` derive paths/IPs from the environment and the generated
  inventory — nothing hardcoded.
- Private IPs are stable declared inputs.
- Cloudflare A-records follow the live public IP automatically.
- The Longhorn data disk is mounted by **UUID**; the format step is guarded.
- TLS uses DNS-01 (ownership via Cloudflare TXT, independent of the IP), so the
  source cert re-issues cleanly and Reflector re-replicates it.
- ArgoCD's repo credentials are rebuilt from the vault via `--from-file` (not
  fragile YAML templating) — see "ArgoCD repo access."
- ArgoCD's root app-of-apps means the whole application layer is declarative:
  `07-argocd.yml` bootstraps it, and every app returns from Git.

---

## Secrets summary

`secrets/` is gitignored except `README.md` and the encrypted vault:
- `terraform.tfvars` — plaintext, **NOT** committed.
- `ansible-secrets.yml` — Vault-encrypted, **committed as ciphertext**. Holds
  the Cloudflare API token AND the ArgoCD deploy private key.

Control-node-local, never in Git: `secrets/terraform.tfvars`, `~/.vault_pass`,
the three SSH keypairs (admin, ansible, argocd).

`.terraform.lock.hcl` files **are** committed; `*.tfstate` files are **not**.

**Known gap:** AnythingLLM's `JWT_SECRET` is currently plaintext in
`deployment.yaml` (see "The LLM stack" above) — acceptable while scaled to
zero, flagged for hardening before real use.

---

## Notes / gotchas learned

**Infrastructure / Azure**
- **VM size:** `Standard_B2s` hit capacity limits; Basv2 started at a 0-core
  quota — raised via `az quota create`. Nodes are `Standard_B2as_v2` (8 GB).
- **Ubuntu image (Gen2):** `Canonical` / `0001-com-ubuntu-server-jammy` /
  `22_04-lts-gen2` — the v2 VM series is Gen2-only.
- **Disk naming:** `/dev/sdb` is NOT stable — use
  `/dev/disk/azure/scsi1/lun0` and mount by UUID.

**Cloudflare / certs**
- **Token needs TWO permissions:** `Zone:DNS:Edit` AND `Zone:Zone:Read`.
- **`9109 Invalid access token`** = bad token in the vault; verify before
  encrypting via the Cloudflare token-verify endpoint.
- **`10502 Too many authentication failures`** = Cloudflare cooldown, clears
  in ~5–10 min.
- **`429 too many certificates (5) ... exact set of identifiers`** = Let's
  Encrypt's duplicate-cert limit, **1-week cooldown**. Hit this TWICE during
  the build — once from per-namespace Certificates, again from manual
  annotate/delete cycles while migrating to Reflector. Lesson: once you're
  rate-limited, **stop manually iterating against production** — switch the
  issuer to `letsencrypt-staging`, validate the entire pipeline there, and
  only flip back to production once the fix is proven and the cooldown clears.
- **Terraform Cloudflare provider v5:** `cloudflare_dns_record` (not
  `cloudflare_record`); IP field is `content`; record `name` is relative to
  the zone (`*` / `@`).

**Helm / Ansible**
- **Helm `--wait` false timeouts:** dropped `--wait` on the single hostPort
  Traefik pod. Stuck release: `helm -n <ns> rollback <rel> <rev>`.
- **`kubernetes.core.k8s` needs the Python `kubernetes` lib on the target** —
  not present on the master. Standardize on `k3s kubectl apply -f` for every
  manifest apply in every playbook (no Python dependency, one consistent
  pattern).
- **YAML: spaces only, never tabs.** Verify multi-play files with
  `ansible-playbook <file> --list-tasks` after every edit.
- **Disk space is invisible to `kubectl top` and Helm's own success reporting.**
  Adding the monitoring stack's ~22 Gi of 2-replica volumes caused several
  Longhorn volumes to go `faulted`/`unknown` — not a values.yaml problem, a
  genuine capacity limit that neither `kubectl top nodes` (CPU/memory only)
  nor Helm's "STATUS: deployed" caught. Check
  `kubectl -n longhorn-system get volumes` (watch for `faulted`/`unknown`
  ROBUSTNESS) and real disk usage on the workers *before* adding anything
  storage-heavy, not just node CPU/memory.
- **A PVC's `storageClassName` is immutable once bound.** Trying to move an
  existing PVC to a different StorageClass via `helm upgrade` fails with
  `spec is immutable after creation` — delete the PVC (and the pod using it)
  so it's recreated fresh, don't try to patch it in place.
- **Nested YAML block scalars are fragile — avoid them.** Templating a
  multi-line SSH private key into a YAML `content: |` block (itself inside an
  Ansible task) via a Jinja `indent()` filter produced `ssh: no key found` —
  a single misplaced indent silently corrupted the key, and the failure only
  surfaced later as **every** ArgoCD Application showing `SYNC STATUS: Unknown`.
  The robust fix: write the raw secret to a plain file with
  `ansible.builtin.copy: content: "{{ var }}"`, then build the Kubernetes
  Secret with `k3s kubectl create secret --from-file=<key>=<file>` — no YAML
  nesting, no filter, no indentation to get wrong. Applies to any multi-line
  credential going into a Secret, not just this one.
- **A silently-missing playbook step is invisible until you look for it.**
  ArgoCD's own Ingress was applied manually once, months into the build, and
  never added to any playbook — on the next full rebuild, every *app* came
  back (root app-of-apps handled that) but `argocd.gairelab.uk` itself 404'd,
  because nothing had ever re-applied its Ingress. Anything under
  `kubernetes/infrastructure/` that isn't referenced by any playbook is a
  silent rebuild gap; periodically audit with:
  ```bash
  find kubernetes/infrastructure -name "*.yaml" | while read f; do
    grep -rq "$(basename "$f")" ansible/playbooks/ && echo "OK: $f" || echo "⚠️  $f"
  done
  ```

**GitOps discipline**
- **The cluster reflects Git, not your local edits.** If a fix "won't apply":
  (a) `grep` the file to confirm the change is really there, (b) `git status`
  shows it modified/staged, (c) `git push` transfers a NEW commit. A
  silently-failed file write looks identical to ArgoCD doing nothing.
- **Don't `kubectl edit`/`scale` ArgoCD-managed resources** — `selfHeal`
  reverts them. Change Git instead.
- **Long heredocs over a flaky SSH session can truncate.** Write large files
  in pieces, or as a downloaded file, and verify with `wc -l`/`tail` after.
- **Diagnostic pattern — one app vs. all apps broken:** if a single
  Application misbehaves, suspect that app's manifests. If **every**
  Application shows the same abnormal status simultaneously (e.g. all
  `Unknown`), suspect the shared dependency underneath them all — the repo
  connection, the deploy key, or ArgoCD itself — not each app individually.
- **Infra vs. apps: keep exactly one owner per resource.** ArgoCD Applications
  should only ever point at `kubernetes/apps/<app>/`. Bootstrap-phase
  infrastructure (Traefik, cert-manager, Reflector, ArgoCD's own Ingress) is
  Ansible's job. Mixing the two — the same resource applied by both a
  playbook and an ArgoCD Application — is what causes split-brain; a clean
  path boundary avoids it by construction.

**App-specific config (each app had at least one trap)**
- **Memos:** needs `MEMOS_PORT=5230`, `MEMOS_ADDR=0.0.0.0`, `MEMOS_MODE=prod`
  or it starts on "port 0" (binds nothing) — pod shows `1/1 Running`, every
  request 502s. Data dir `/var/opt/memos`.
- **homepage:** needs `HOMEPAGE_ALLOWED_HOSTS=homepage.gairelab.uk`, and the
  ConfigMap must NOT mount directly at `/app/config` (read-only →
  `ENOENT mkdir /app/config/logs` → 500). Use an `emptyDir` + `subPath` files.
- **n8n:** `N8N_HOST`, `N8N_PROTOCOL=https`, `WEBHOOK_URL=https://n8n.gairelab.uk/`,
  `N8N_PROXY_HOPS=1`, `fsGroup: 1000` (runs as uid 1000). Also
  `N8N_RUNNERS_ENABLED=true`, `DB_SQLITE_POOL_SIZE=5` (deprecation warnings).
  `N8N_ENCRYPTION_KEY` auto-generates on the PVC — lost on storage wipe.
- **Ollama:** Docker Hub's `:latest` tag has historically lagged real
  releases — pin an explicit version. `OLLAMA_MAX_LOADED_MODELS=1` keeps RAM
  bounded on constrained hardware.
- **AnythingLLM:** needs `cap_add: SYS_ADMIN` (→ pod
  `securityContext.capabilities.add`) and the `nomic-embed-text` embedding
  model pulled in Ollama — without it, document uploads fail **silently**
  (no error shown, just nothing happens), which is a nasty one to debug blind.

**Diagnosis shorthand**
- **502** = Traefik reached the Service but the backend isn't answering
  (port/config — e.g. Memos port 0). **500** = backend reached but errored
  internally (e.g. homepage's ENOENT). **`ssh: no key found`** in
  repo-server logs = the deploy-key Secret is malformed, not a network/DNS
  issue. A clean "connection refused" from an in-cluster test pod means the
  target app isn't listening — not a firewall problem (firewalls typically
  cause timeouts, not clean refusals).

---

## Roadmap

- [x] Networking, Compute, Storage (Terraform)
- [x] Base OS prep + K3s cluster (Ansible)
- [x] Longhorn (2 replicas)
- [x] Ingress (Traefik) + cert-manager + ClusterIssuers with readiness waits
- [x] Cloudflare A-record automation
- [x] Destroy + rebuild reproducibility verified (multiple times)
- [x] GitOps (ArgoCD) + app-of-apps — apps deploy from Git, no manual kubectl
- [x] ArgoCD's own Ingress folded into the playbook (was a silent rebuild gap)
- [x] ArgoCD repo deploy-key Secret fully automated from the vault (`--from-file`, no fragile templating)
- [x] Reflector — one wildcard cert replicated to all namespaces
- [x] Single dedicated source Certificate (`wildcard-source.yaml`) replacing all per-namespace certs
- [x] Memos, homepage, n8n — running, GitOps-managed
- [x] Ollama + Open WebUI — running; models pulled (`llama3.2:3b`, `nomic-embed-text`)
- [x] AnythingLLM — deployed, scaled to zero, ready to flip on
- [x] AnythingLLM hardening: `JWT_SECRET` via Kubernetes Secret, image pinned to `1.15.0`
- [x] Monitoring (Prometheus + Grafana + Loki) installed — **not yet proven via a full rebuild**
- [x] `longhorn-single-replica` StorageClass for lower-stakes volumes (disk-capacity lesson)
- [ ] Flip `wildcard-source.yaml` to `letsencrypt-production` once the 1-week duplicate-cert cooldown clears
- [ ] Verify the full `01→10` sequence on the next destroy/rebuild, especially playbook 10
- [ ] Monitor real disk usage as more storage-heavy apps get added — 100 Gi raw (2×50 Gi) is not unlimited
- [ ] Off-cluster backups (Longhorn → object storage) for app data across rebuilds
- [ ] Optional: seal secrets (SealedSecrets/SOPS) as a further hardening layer
