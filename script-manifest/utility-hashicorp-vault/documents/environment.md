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

## Status: Stage A deployed and bootstrapped. Re-verified live on 2026-11-01

| | Meaning |
|---|---|
| ✅ | Read from the live cluster |
| ⚠️ | Inferred from repo config or a sibling project; confirm before relying on it |
| ❌ | **Missing or not known.** Blocks the phase named |

Nothing marked ❌ may be guessed. Re-run `bootstrap/preflight.sh` to refresh. The
rows below were last read from the cluster with `kubectl` on 2026-11-01. The
sections further down keep the original A0 reasoning, with their answers filled in.

| Value | Status | Blocks |
|---|---|---|
| Node names and IPs | ✅ unchanged: `.10` / `.11` / `.12` | — |
| Kubernetes version | ✅ `v1.36.4` on all nodes (rebuilt 2026-09-22; was `v1.29.15`) | — |
| MetalLB pool and allocations | ✅ `local-pool` `.240`–`.250`; `.240` ingress-nginx, `.241` `vault-lb`. L2 advertised on **`eth1` only** (see *MetalLB* below) | — |
| MetalLB VIP for Vault | ✅ `192.168.56.241`, held by `vault/vault-lb` | — |
| NodePort `30004` | ✅ `vault/vault-nodeport` | — |
| ArgoCD version | ✅ `v3.5.3`, multi-source works (`utility-hashicorp-vault-server` Synced/Healthy) | — |
| ArgoCD credential for this repo | ✅ **Not needed**: the repo is public and every Application uses its HTTPS URL | — |
| Cluster OIDC issuer | ✅ `https://kubernetes.default.svc.cluster.local` | — |
| StorageClass | ✅ `local-path` (`rancher.io/local-path`, `WaitForFirstConsumer`, **not** default), provisioner `v0.0.37` | — |
| cert-manager | ✅ `v1.21.2` | — |
| External Secrets Operator | ✅ `v2.11.0` | — |
| Prometheus operator-managed? (5a) | ✅ **no**: no `monitoring.coreos.com` CRDs | **A9.4 cannot be done additively**, so it was reported, not worked around |
| Prometheus discovery labels (5b) | n/a | moot while 5a is "no" |
| Alertmanager receiver (5c) | n/a | moot while 5a is "no" |
| Dev workspace VM address | ✅ `192.168.56.20`, where every bootstrap script has run | — |
| Private registry address | ✅ `192.168.56.20:5000`, insecure. Read from worker01's CRI-O drop-in `dev-vm-registry.conf` | — |
| Registry trust on worker02 | ⚠️ **Not re-checked since 2026-09-11**, when the drop-in was absent. Check before Stage B schedules images there | Stage B / tracing-poc images on worker02 |
| Cluster DNS upstream | ⚠️ **Live hotfix, not in code**: CoreDNS forwards over **TCP** to `8.8.8.8 1.1.1.1` (see *Host network* below) | Lost on a cluster rebuild |

---

## Cluster identity

| | |
|---|---|
| Lab environment | `learning-labs-developer-workspace-type-01` |
| Kubernetes cluster repo | `poc-platform-engineering-iac-vagrant-ansible-k8s-cluster-kubeadm-calico` |
| Provisioning | Vagrant + Ansible (`ansible_local`), kubeadm |
| CNI | Calico v3.32.2 (was v3.28.0 on 1.29) |
| Container runtime | CRI-O 1.36.6 — same minor as the kubelet (was a stale, unpinned 1.33.0 on 1.29) |
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

### Kubernetes version ✅ — rebuilt on 1.36

```
before (2026-09-11)   control plane v1.29.15, kubelets v1.29.0   — fails P2
now    (2026-09-22)   control plane + kubelets v1.36.4           (settings.yaml apt pin 1.36.4-*)
```

P2 requires **≥ 1.32** and says to bump if still on 1.29 (EOL). On 2026-09-11 the
owner chose to stay and accept the risk; on 2026-09-22 that was reversed. The
cluster is **rebuilt** (`vagrant destroy` + `vagrant up`), not upgraded in place:
kubeadm moves one minor at a time, so 1.29 → 1.36 in place is seven upgrades,
and the cluster holds no persistent data worth that. It is shared with the
observability and tracing-poc teams, so the rebuild is scheduled with them —
procedure in the cluster repo's
[`documents/DOCUMENTS-runbook-cluster-upgrade-1-36.md`](../../../documents/DOCUMENTS-runbook-cluster-upgrade-1-36.md).

**Why 1.36 and not 1.37:** 1.37 was four weeks old and not yet in cert-manager's
or Calico's support matrices. 1.35 would have reached end of life in Feb 2027;
1.36 is supported until June 2027.

Every Stage A component is pinned to a supported line for 1.36, verified against
upstream on 2026-09-22:

| Component | Pin | On K8s 1.36 |
|---|---|---|
| cert-manager | `v1.21.2` | ✅ 1.21 supports 1.33–1.36 |
| Vault Helm chart | `0.34.1` (Vault `2.0.4`) | ✅ chart declares K8s ≥ 1.20 |
| External Secrets Operator | `2.11.0` | ✅ 2.11 supports 1.36 — each minor is supported only until the next (~3 weeks) |
| local-path-provisioner | `v0.0.37` | ✅ still the latest release |
| PostgreSQL | `16.15-alpine` | ✅ current 16.x patch |

The upgrade removed both end-of-life pins that 1.29 forced, and let the
`ClusterSecretStore` move to `external-secrets.io/v1` as the PRD specifies.

**Known exception on the shared cluster:** the cluster's ingress-nginx
is upstream-retired (March 2026), and its final release (v1.15.1) is tested only
up to 1.35. It is kept deliberately for now and tracked in the cluster repo's
[`documents/DOCUMENTS-backlog.md`](../../../documents/DOCUMENTS-backlog.md). Vault
does not depend on it (D8 uses a MetalLB VIP and a NodePort).

---

## This is a shared cluster

Three teams' workloads coexist here. It matters for Rule 8 (additive-only).

| Namespace | Owner | Notes |
|---|---|---|
| `observability` | observability team | Grafana LGTM stack |
| `tracing-poc` | tracing-poc team | Quarkus demo apps |
| `metallb-system`, `ingress-nginx` | platform (this repo) | Ansible `addon_metallb` / `addon_ingress_nginx` — moved from the observability repo 2026-09-23 |
| `argocd`, `kubernetes-dashboard`, `headlamp` | platform (this repo) | |
| `vault`, `external-secrets`, `poc-hashicorp-vault-application` | **Stage A** | created by A0 |

**You may add objects. You may not edit theirs.** The observability stack is
ArgoCD-managed by another team — a manual `kubectl edit` is reverted on their next
sync, and an edit to their scrape config is out of bounds regardless. MetalLB and
ingress-nginx are platform infrastructure owned by **this repo**: change them via
`settings.yaml` and the Ansible roles, never by hand.

---

## Networking

### MetalLB ✅

Verified with `kubectl get ipaddresspool -A`.

| Pool | Range | Owner |
|---|---|---|
| `local-pool` | `192.168.56.240` – `192.168.56.250` | this repo — `network.metallb_ip_range`, applied by `addon_metallb` |

Known allocations:

| IP | Service |
|---|---|
| `192.168.56.240` | `ingress-nginx-controller` |
| `192.168.56.241` | `vault/vault-lb` |

**Vault's VIP: `192.168.56.241`** ✅, in use since 2026-10-05.

```bash
kubectl get svc -A -o wide | grep 192.168.56.24     # current allocations
```

**L2 advertisement is pinned to `eth1`** (the host-only network), by
`L2Advertisement local-l2` `interfaces: [eth1]`, set by `addon_metallb` since PR #22. On
2026-10-31 MetalLB also answered ARP on `eth0`, the VirtualBox NAT interface. That
exhausted the NAT engine (`Can't allocate mbuf` in `VBox.log`) and cut the master's
outbound traffic and `vagrant ssh`. Toggling the NIC (`setlinkstate1`) did not recover
it. A clean guest shutdown over host-only SSH followed by `vagrant up` did.

Requesting an address *from* the pool is additive; it allocates, it does not
edit the pool. It must be **pinned**, not auto-assigned, because it appears in
the certificate SANs and an address that moves on resync silently invalidates the
cert. Pinned via `metallb.io/loadBalancerIPs` in
`overlays/onprem/vault-extras/kustomization.yaml`.

> Since 2026-09-23 this repo is the **only** owner of MetalLB (0.16.1) and
> ingress-nginx (1.15.1, pinned to `.240`). The observability repo no longer installs
> either — two MetalLB installs fight over host ports. See the cluster repo's README.

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

The repo is mounted in the Dev VM at
`~/workspace-app/poc-platform-engineering-iac-vagrant-ansible-k8s-cluster-kubeadm-calico`.
It's a VirtualBox shared folder, a live view of the Windows working tree, so **the
branch checked out on Windows is what the Dev VM runs.**

### Host network: UDP DNS is dropped

On the host's current network, DNS over **UDP** is dropped for every resolver
except the ISP's own; DNS over TCP works. Inside the cluster, that showed up as
CoreDNS upstream timeouts. ESO, ArgoCD (Helm repo fetches) and anything else
resolving external names failed or crawled.

**Hotfix, applied live on 2026-11-01 and not in code:** the `coredns` ConfigMap
forwards to `8.8.8.8 1.1.1.1` with `force_tcp`. kubeadm owns that ConfigMap, so
a cluster rebuild (or `kubeadm upgrade`) reverts it. Node-level DNS (the nodes' own
`apt`, image pulls) is still UDP. Both follow-ups are in the cluster repo's
[`documents/DOCUMENTS-backlog.md`](../../../documents/DOCUMENTS-backlog.md) #5.

### Host side (Windows)

The default `~/.kube/config` on the Windows host points at an **unrelated AWS EKS
cluster**. From Windows, always pass `--kubeconfig configs/config` (repo root), or
run `kubectl` in the Dev VM.

---

## Storage ✅

`local-path-provisioner` **v0.0.37**, installed 2026-09-23 from
`base/local-path-provisioner`. StorageClass `local-path`, `WaitForFirstConsumer`,
deliberately **not** the cluster default. Vault's `dataStorage.storageClass` and
Postgres's `volumeClaimTemplates` both name it.

```bash
kubectl get sc
kubectl get pods -n local-path-storage
```

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
| `observability-local` | observability team |
| `utility-hashicorp-vault` | **Stage A** (this repo) root app, from `argocd/root-platform.yaml`, applied at A1. Five children `utility-hashicorp-vault-*`, all Synced/Healthy on 2026-11-01 |

### Repo credential ✅: not needed

This repo's git remote is an SSH host alias ArgoCD cannot resolve
(`git@github.com-adhito909:...`), so the Applications use the HTTPS URL. **The repo
is public** (verified 2026-09-22), so ArgoCD reads it anonymously. If it is ever made
private, register a credential or deploy key. The vault repo's
`root-applications.yaml` has the same concern.

### Multi-source support ✅

`argocd/applications/vault.yaml` is a multi-source Application (chart from
HashiCorp's Helm repo, values from git). ArgoCD v3.5.3 supports it, and the
app has synced from `https://helm.releases.hashicorp.com` since 2026-10-05.

---

## Observability ✅ answered: A9.4 parked

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

Answer: **No** (2026-09-11; re-checked 2026-11-01, zero `monitoring.coreos.com` CRDs).
`vault-monitoring` is parked in `argocd/disabled/`, so there is **no automated seal
alert**.

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

## OIDC issuer ✅

```bash
kubectl get --raw /.well-known/openid-configuration | jq -r .issuer
```

`10-enable-kubernetes-auth.sh` looks this up itself and refuses to run without it.
Record the result here anyway — it is a documented environment fact, and if the
lookup ever returns something unexpected the PRD says stop and ask rather than
substitute a plausible value.

Issuer: **`https://kubernetes.default.svc.cluster.local`** (re-read 2026-11-01).
From Windows Git Bash, prefix the command with `MSYS_NO_PATHCONV=1`, or Git Bash
rewrites `/.well-known/...` into a Windows path and the API server answers `NotFound`.

---

## Private registry ⚠️ — address known, worker02 trust unchecked

P7 expects `registry:2` under Podman on the dev workspace, trusted by CRI-O on all
nodes. Stage B's `Makefile`s read `REGISTRY` from this file.

```bash
podman ps --filter name=registry          # on the dev VM
crictl pull <registry>/hello              # on a node — proves trust, not just reachability
```

Address: **`192.168.56.20:5000`**, insecure (from worker01's CRI-O drop-in
`dev-vm-registry.conf`). Run the `crictl pull` check on **worker02** before Stage B:
that node's drop-in was missing on 2026-09-11.

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
| Vault pod placement (replicas = 1) | A2 | `vault-0` on `devnodeworker02` (2026-11-01) |
| Leader failover window | A4 | _______ |
| **Which worker hosts two Raft peers** | A4 | _______ |
| Snapshot restore RTO | A9.3 | _______ |
| Prometheus discovery labels | A0.5 | _______ |
| Alertmanager routing status | A0.5 | _______ |
| System `default_lease_ttl` / `max_lease_ttl` | A7 | `0` / `0` (2026-11-01, `30-enable-kv.sh`): unset in the server HCL, so Vault's built-in `768h` / `768h` apply. Mounts and roles set their own (e.g. `level3-app` 1h / 24h) |

---

## Related documents

| Document | Covers |
|---|---|
| [`architecture.md`](architecture.md) | Topology, trust boundaries, failure modes |
| [`licensing.md`](licensing.md) | BUSL 1.1 position — **org policy check outstanding** |
| [`runbooks/seal-unseal.md`](runbooks/seal-unseal.md) | Sealing, unsealing, rekey, generate-root |
| [`runbooks/snapshot-restore.md`](runbooks/snapshot-restore.md) | Backup and the A9.3 restore drill |
| [`runbooks/upgrade.md`](runbooks/upgrade.md) | Version bumps; downgrades are not supported |
| [`key-custody.md`](key-custody.md) | Unseal-key custody: method, holder, event register. One A2 item still open |
| [`../../../documents/documents-runbook-infra-utility-hashicorp-vault.md`](../../../documents/documents-runbook-infra-utility-hashicorp-vault.md) | **Index** of everything in this folder |
| [`../bootstrap/README.md`](../bootstrap/README.md) | Configuring Vault's contents |
| [`../README.md`](../README.md) | The manifests and ArgoCD wiring |
