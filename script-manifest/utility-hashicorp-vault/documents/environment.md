# Environment — verified live values

Phase A0 deliverable. Everything Stage A and Stage B need to know about *this*
cluster, read from the cluster rather than from a PRD example.

> **The rule this file exists to enforce:** never hardcode environment values in
> a manifest or a script. MetalLB VIP, StorageClass name, node IPs, registry
> address, OIDC issuer, and the Prometheus discovery labels all live here. If a
> value you need is missing, **go and get it and add it — do not guess, and do
> not copy one out of a PRD.**

**Location note.** Stage A lives in the cluster repo
(`poc-platform-engineering-iac-vagrant-ansible-k8s-cluster-kubeadm-calico`), so
this file does too — beside the manifests it describes. Stage B should reference
it by that repo and path, not as a local `documents/environment.md`.

---

## Status: IN PROGRESS — verified by `preflight.sh` on 2026-09-11

| | Meaning |
|---|---|
| ✅ | Read from the live cluster |
| ⚠️ | Inferred from repo config or a sibling project; confirm before relying on it |
| ❌ | **Missing or not known.** Blocks the phase named |

Nothing below marked ❌ may be guessed. Re-run `bootstrap/preflight.sh` to refresh.

| Value | Status | Blocks |
|---|---|---|
| Node names and IPs | ✅ | — |
| Kubernetes version | ✅ `v1.29.15` | **A0 gate — fails P2** |
| MetalLB pool and existing allocations | ✅ | — |
| MetalLB VIP for Vault | ✅ `192.168.56.241` — free | — |
| NodePort `30004` | ✅ free | — |
| ArgoCD version | ✅ `v2.14.8` — multi-source supported (≥ 2.6) | — |
| **ArgoCD credential for this repo** | ❌ **absent** — only the OTel Helm repo is registered | **A1** — every child fails to fetch |
| Cluster OIDC issuer | ✅ `https://kubernetes.default.svc.cluster.local` | — |
| **StorageClass** | ❌ **none exists at all** — `local-path-provisioner` never installed | **A2** — Vault and Postgres PVCs |
| **cert-manager** | ❌ **not installed** | **A2** — wave 0 cannot issue Vault's cert |
| Prometheus operator-managed? (5a) | ✅ **no** — ServiceMonitor/PrometheusRule CRDs absent | **A9.4 cannot be done additively** — reported, not worked around |
| Prometheus discovery labels (5b) | n/a | moot while 5a is "no" |
| Alertmanager receiver (5c) | n/a | moot while 5a is "no" |
| Dev workspace VM address | ⚠️ | A2 (client access) |
| Private registry address | ✅ `192.168.56.20:5000`, insecure — read from worker01's CRI-O drop-in `dev-vm-registry.conf` | — |
| **Registry trust on worker02** | ❌ **drop-in absent** — fixup script never run after the 2026-08-29 rebuild | Stage B / tracing-poc images scheduled on worker02 |

---

## Cluster identity

| | |
|---|---|
| Lab environment | `learning-labs-developer-workspace-type-01` |
| Kubernetes cluster repo | `poc-platform-engineering-iac-vagrant-ansible-k8s-cluster-kubeadm-calico` |
| Provisioning | Vagrant + Ansible (`ansible_local`), kubeadm |
| CNI | Calico v3.28.0 |
| Container runtime | CRI-O |
| Pod CIDR / Service CIDR | `172.16.1.0/16` / `172.17.1.0/18` |

> The PRD's header says "Target cluster: `learning-labs-developer-workspace-type-01`".
> That name is the **lab environment / dev workspace VM repo**, not the Kubernetes
> cluster — P1 and P3 describe them as separate things. The cluster is the one above.

### Nodes ✅

Verified with `kubectl get nodes -o wide`.

| Node | IP | Role |
|---|---|---|
| `devnodemaster01` | `192.168.56.10` | control-plane |
| `devnodeworker01` | `192.168.56.11` | worker |
| `devnodeworker02` | `192.168.56.12` | worker |

**Two workers, and that is fixed for v1 (P5).** It drives D4 — 3 Vault replicas
with *soft* anti-affinity, so two peers share a worker. See
[`runbooks/seal-unseal.md`](runbooks/seal-unseal.md) for the consequence.

### Kubernetes version ✅ — and this is a failed gate

```
control plane (API server)   v1.29.15
kubelets                     v1.29.0     (settings.yaml apt pin 1.29.0-*)
```

P2 requires **≥ 1.32** and says to bump if still on 1.29 (EOL). It has not been
bumped. The owner chose to **stay and accept the risk**, recorded as a failed
gate rather than a passed one (Rule 4): the cluster is shared with the
observability and tracing-poc teams, so the upgrade is a coordination item rather
than a unilateral one. The kubelet/control-plane skew is within Kubernetes'
support policy — but it does mean the control plane was patch-upgraded and the
kubelets were not.

Every Stage A component is pinned to the **newest version that supports 1.29**,
verified against upstream on 2026-09-11:

| Component | Pin | On K8s 1.29 |
|---|---|---|
| cert-manager | `v1.18.6` | ⚠️ newest line for 1.29 — **EOL since 2026-03-10** |
| Vault Helm chart | `0.34.1` (Vault `2.0.4`) | ✅ chart declares K8s ≥ 1.20 |
| External Secrets Operator | `0.13.0` | ⚠️ newest line for 1.29 — **EOL since 2025-02-04** |
| local-path-provisioner | `v0.0.37` | ✅ |
| PostgreSQL | `16.15-alpine` | ✅ current 16.x patch |

**Two of these are end-of-life because of the version gate, not by choice.** That
is the concrete cost of staying on 1.29, and the strongest argument for the
upgrade: it is what unlocks a supported cert-manager — the component that issues
Vault's TLS — and a supported ESO.

---

## This is a shared cluster

Three teams' workloads coexist here. It matters for Rule 8 (additive-only).

| Namespace | Owner | Notes |
|---|---|---|
| `observability` | observability team | Grafana LGTM stack |
| `tracing-poc` | tracing-poc team | Quarkus demo apps |
| `metallb-system` | observability team | via ArgoCD app `metallb` |
| `ingress-nginx` | observability team | via ArgoCD app `ingress-nginx` |
| `argocd`, `kubernetes-dashboard`, `headlamp` | platform (this repo) | |
| `vault`, `external-secrets`, `poc-hashicorp-vault-application` | **Stage A** | created by A0 |

**You may add objects. You may not edit theirs.** MetalLB and ingress-nginx are
ArgoCD-managed by another team — a manual `kubectl edit` on either is reverted on
their next sync, and an edit to their `IPAddressPool` or scrape config is out of
bounds regardless.

---

## Networking

### MetalLB ✅

Verified with `kubectl get ipaddresspool -A`.

| Pool | Range | Owner |
|---|---|---|
| `local-pool` | `192.168.56.240` – `192.168.56.250` | ArgoCD app `metallb` (observability team) |

Known allocations:

| IP | Service |
|---|---|
| `192.168.56.240` | `ingress-nginx-controller` |

**Vault's VIP: `192.168.56.241`** ⚠️ — *proposed, unconfirmed.*

```bash
kubectl get svc -A -o wide | grep 192.168.56.24     # confirm .241 is free
```

Requesting an address *from* their pool is additive; it allocates, it does not
edit the pool. It must be **pinned**, not auto-assigned, because it appears in
the certificate SANs and an address that moves on resync silently invalidates the
cert. Pinned via `metallb.io/loadBalancerIPs` in
`overlays/onprem/vault-extras/kustomization.yaml`.

> This repo's own MetalLB and ingress-nginx addons are **disabled**
> (`software.metallb: ""`, `software.ingress_nginx: ""` in `settings.yaml`)
> precisely so they do not fight the observability team's install.

### Vault exposure (D8)

| Path | Address | Use |
|---|---|---|
| Primary — MetalLB | `https://192.168.56.241:8200` | documented, everyday |
| Break-glass — NodePort | `https://<any-node-ip>:30004` | when MetalLB is the problem |

Both target `vault-active`, so both follow leader failover with no intervention.
Vault terminates its own TLS on both — nothing proxies or re-encrypts.

`vault.learning-labs.local` is in the cert SANs for a hosts-file entry on the dev
workspace (A5 step 3). If that name ever changes, **reissue the cert** — add the
name first, not after the browser complains.

### Dev workspace VM ⚠️

| | |
|---|---|
| Hostname | `ubuntu-jammy` (Vagrant machine `dev-developer-workspace-type-01`) |
| Address on the node subnet | `192.168.56.20` (per PRD P3) |
| Repo | `learning-labs-developer-workspace-type-01` |

Confirm reachability before A2: `ping 192.168.56.10` from the dev VM.

---

## Storage ❌ — blocks A2

P8 expects Rancher **`local-path-provisioner`** with
`volumeBindingMode: WaitForFirstConsumer`. **Not verified, and probably absent** —
no `local-path-storage` namespace appeared in a full `kubectl get pods -A` during
this session.

```bash
kubectl get sc
kubectl get pods -n local-path-storage
```

If it is missing, install it before A2 — Vault's `dataStorage.storageClass` and
Postgres's `volumeClaimTemplates` both name `local-path`. Record the real name
here and correct `helm/vault/values-onprem.yaml` and
`overlays/onprem/postgres/kustomization.yaml` if it differs.

### Understand what you are accepting

`local-path` creates a hostPath-backed PV on whichever node first schedules the
pod and **pins it there**:

- A Raft peer whose node is lost **loses its data volume outright**. It cannot
  reschedule — it must be removed from Raft and rejoined empty, or restored.
- PVCs are not portable. `kubectl delete pod` is safe; node loss is not.
- There is no storage-layer safety net: `local-path` does not implement CSI
  snapshots, so `VolumeSnapshot` does not work against it.
  **`vault operator raft snapshot` is the only backup mechanism in this design.**

Combined with two workers and soft anti-affinity, this is why
[`runbooks/snapshot-restore.md`](runbooks/snapshot-restore.md) matters.

This node-loss risk is **accepted, not mitigated** — the mitigation is that the
whole cluster is reproducible from Vagrant, Ansible, git, and the bootstrap
scripts. Correct for a lab; not correct for production.

---

## ArgoCD ✅

Present and managing this cluster. Verified with `kubectl get applications -n argocd`.

| Application | Owner |
|---|---|
| `local-root` | app-of-apps root (observability team) |
| `ingress-nginx` | observability team |
| `metallb` | observability team |
| `observability-local` | observability team |
| `root-platform` | **Stage A** (this repo) — applied at A1 |

### Repo credential ❌ — blocks A1

This repo's git remote is an SSH host alias ArgoCD cannot resolve:

```
git@github.com-adhito909:Adhito/poc-platform-engineering-iac-...git
```

The Applications use the HTTPS URL. ArgoCD needs a credential for it (the repo is
not public), or a plain SSH URL plus a deploy key. **The vault repo has the same
problem** — one fix, applied twice.

### Multi-source support ❌ — confirm before A1

`argocd/applications/vault.yaml` is a multi-source Application (chart from
HashiCorp's Helm repo, values from git). Confirm this ArgoCD version supports it,
and that `https://helm.releases.hashicorp.com` is permitted. Fallback is Kustomize
`helmCharts:` inflation — but confirm first rather than assuming.

---

## Observability ❌ — may cancel A9.4

The stack is **Grafana LGTM** in `observability`, ArgoCD-managed as
`observability-local`, owned by another team. Its metrics store is Mimir, which
**does not necessarily run the Prometheus Operator.**

### 5a — Is Prometheus operator-managed?

```bash
kubectl get crd servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com
```

**If these CRDs are absent: stop and report.** The stack is plain Prometheus with
a static scrape config, and adding a target means editing a file that currently
works — which Rule 8 forbids. Remove `vault-monitoring.yaml` from
`argocd/applications/` in that case; the other children are unaffected and Stage A
still completes without it.

Answer: _______________

### 5b — What selector does Prometheus use?

```bash
kubectl get prometheus -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.spec.serviceMonitorSelector}{"\t"}{.spec.serviceMonitorNamespaceSelector}{"\t"}{.spec.ruleSelector}{"\n"}{end}'
```

**This is the step people skip, and it fails silently.** Many
`kube-prometheus-stack` installs set `serviceMonitorSelectorNilUsesHelmValues:
true`, so only ServiceMonitors carrying the Helm release label are discovered. Get
it wrong and the object applies cleanly, reports no error, and is **never
scraped**.

Both `base/monitoring/*.yaml` currently carry a placeholder
`release: kube-prometheus-stack`. Correct it in
`overlays/onprem/monitoring/kustomization.yaml`.

Required labels: _______________

Also check `serviceMonitorNamespaceSelector` includes `vault`. If it does not,
adding it **would be an edit to their config** — report it, do not do it.

### 5c — Does Alertmanager reach a human?

```bash
kubectl get alertmanager -A
kubectl get secret -n <ns> alertmanager-<name> -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d
```

If there is no receiver, `VaultNodeSealed` still fires and is visible in the
Prometheus UI, which beats nothing — but **do not describe the alert as "working"
if nobody is paged.** Configuring a receiver is an edit to their stack: report the
finding and let the owner decide.

Answer: _______________

---

## OIDC issuer ❌ — blocks A6

```bash
kubectl get --raw /.well-known/openid-configuration | jq -r .issuer
```

`10-enable-kubernetes-auth.sh` looks this up itself and refuses to run without it.
Record the result here anyway — it is a documented environment fact, and if the
lookup ever returns something unexpected the PRD says stop and ask rather than
substitute a plausible value.

Issuer: _______________

---

## Private registry ❌ — blocks Stage B builds

P7 expects `registry:2` under Podman on the dev workspace, trusted by CRI-O on all
nodes. Stage B's `Makefile`s read `REGISTRY` from this file.

```bash
podman ps --filter name=registry          # on the dev VM
crictl pull <registry>/hello              # on a node — proves trust, not just reachability
```

Address: _______________

> Related: a rebuilt node loses CRI-O's registry-trust drop-in. See
> [`../../../documents/DOCUMENTS-runbook-node-recovery.md`](../../../documents/DOCUMENTS-runbook-node-recovery.md)
> — the cross-project fixup step is mandatory after any node rebuild.

---

## Client access

On the dev workspace VM:

```bash
# Primary
export VAULT_ADDR=https://192.168.56.241:8200
export VAULT_CACERT=/etc/vault-poc/ca.crt

# Break-glass — when MetalLB is the thing that is broken
export VAULT_ADDR=https://192.168.56.10:30004
```

Extract the CA:

```bash
sudo mkdir -p /etc/vault-poc
kubectl -n vault get secret vault-tls -o jsonpath='{.data.ca\.crt}' \
  | base64 -d | sudo tee /etc/vault-poc/ca.crt >/dev/null
```

**Never `-tls-skip-verify` / `VAULT_SKIP_VERIFY`.** A TLS failure means a missing
SAN or an unmounted CA — fix that. `bootstrap/lib/common.sh` refuses to run with
the bypass set. The node IPs are the usual omission, and their absence breaks the
break-glass path precisely when it is needed.

### Security posture of NodePort 30004

Reachable on **every node IP** from anywhere that can route to
`192.168.56.0/24`. On this lab network that is accepted deliberately. In a real
environment this port is firewalled to an admin subnet.

---

## Measurements owed to this file

Deliverables, not observations — they belong here, not in a terminal you will close.

| Measurement | Phase | Value |
|---|---|---|
| Leader failover window | A4 | _______ |
| **Which worker hosts two Raft peers** | A4 | _______ |
| Snapshot restore RTO | A9.3 | _______ |
| Prometheus discovery labels | A0.5 | _______ |
| Alertmanager routing status | A0.5 | _______ |
| System `default_lease_ttl` / `max_lease_ttl` | A7 | _______ |

---

## Related documents

| Document | Covers |
|---|---|
| [`architecture.md`](architecture.md) | Topology, trust boundaries, failure modes |
| [`licensing.md`](licensing.md) | BUSL 1.1 position — **org policy check outstanding** |
| [`runbooks/seal-unseal.md`](runbooks/seal-unseal.md) | Sealing, unsealing, rekey, generate-root |
| [`runbooks/snapshot-restore.md`](runbooks/snapshot-restore.md) | Backup and the A9.3 restore drill |
| [`runbooks/upgrade.md`](runbooks/upgrade.md) | Version bumps; downgrades are not supported |
| [`key-custody.md`](key-custody.md) | Unseal-key custody — method and holder. Its A2 checklist is unticked |
| [`../bootstrap/README.md`](../bootstrap/README.md) | Configuring Vault's contents |
| [`../README.md`](../README.md) | The manifests and ArgoCD wiring |
