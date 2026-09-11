# Architecture

Phase A0 deliverable. What Stage A builds, how the pieces fit, and which
decisions are load-bearing.

The authoritative specification is
`documents/PRD_HashiCorp_Vault_Kubernetes_Cluster_Onprem.md` in the vault repo.
This describes **what was actually built**, including where it diverges.

---

## The one distinction to get right first

**Vault is a secrets *authority*, not a secrets *distribution mechanism*.**

Vault's job is to decide who may hold which secret, for how long, and to record
that decision. Getting the secret onto a pod is a *separate* problem with several
valid answers — ESO, the Agent Injector, the direct API, the CSI driver.

**Stage A builds the authority. Stage B exercises the distribution mechanisms.**

Conflating the two is the most common Vault design error: teams treat it as "a
nicer etcd", never enable dynamic secrets, leases, or revocation, and never reach
the part where the security value actually lives.

---

## Topology

```
┌─ Dev workspace VM (192.168.56.20) ────────────────────────────┐
│  vault CLI · kubectl · argocd · podman · browser              │
│  VAULT_ADDR=https://192.168.56.241:8200                       │
│  VAULT_CACERT=/etc/vault-poc/ca.crt                           │
└──────────┬──────────────────────────┬─────────────────────────┘
           │ primary                  │ break-glass
           │ HTTPS :8200              │ HTTPS :30004
           ▼                          ▼
  ┌─ svc/vault-lb ─────────┐  ┌─ svc/vault-nodeport ───────┐
  │ type: LoadBalancer     │  │ type: NodePort  30004      │
  │ MetalLB VIP .241       │  │ any node IP                │
  └───────────┬────────────┘  └────────────┬───────────────┘
              └───────────┬────────────────┘
                          │  selector: vault-active="true"
                          │  TLS terminated by Vault itself
                          ▼
┌─ namespace: vault ─────────────────────────────────────────────┐
│  StatefulSet vault — Integrated Storage (Raft)                 │
│    vault-0 · vault-1 · vault-2   each: PVC (local-path, PINNED)│
│                                  each: cert-manager TLS        │
│                                  each: audit → stdout          │
│                                  each: SEALS INDEPENDENTLY     │
│                                                                │
│  Chart Services:  vault (all) · vault-active (leader)          │
│                   vault-standby · vault-internal (headless)    │
│                                                                │
│  ServiceAccount: vault  + ClusterRoleBinding system:auth-delegator
│  Secret: vault-reviewer-token   (non-expiring — D6)            │
└──────────┬─────────────────────────────────────────────────────┘
           │ TokenReview API
           ▼
     Kubernetes API server ── OIDC issuer ── validates SA JWTs
           ▲
           │ POST auth/kubernetes/login  (SA JWT → Vault token)
           │
┌──────────┴──────────────────┬─────────────────────────────────┐
│ ns: external-secrets        │ ns: poc-hashicorp-vault-        │
│   ESO controller            │     application                 │
│   SA: external-secrets      │   Stage B Levels 1–4            │
│   ClusterSecretStore ───────┘   PostgreSQL (Level 3)          │
└────────────────────────────────────────────────────────────────┘

┌─ Existing LGTM stack — NOT MODIFIED (Rule 8) ─────────────────┐
│  Prometheus ◄── ServiceMonitor   (new object, additive)        │
│             ◄── PrometheusRule   (new object, additive)        │
│  Loki / Tempo / Grafana / Mimir — untouched                    │
└────────────────────────────────────────────────────────────────┘
```

Audit goes to `stdout`, read with `kubectl logs`. Not shipped to Loki — that
would mean editing the observability team's log pipeline.

---

## Components

| Component | Namespace | Delivered by | Purpose |
|---|---|---|---|
| Vault StatefulSet | `vault` | ArgoCD (Helm, wave 1) | The authority |
| cert-manager `Certificate` | `vault` | ArgoCD (wave 0) | TLS for the listener |
| Reviewer token Secret + CRB | `vault` | ArgoCD (wave 0) | Kubernetes auth trust anchor |
| `vault-lb`, `vault-nodeport` | `vault` | ArgoCD (wave 0) | The two exposure paths |
| ServiceMonitor + PrometheusRule | `vault` | ArgoCD (wave 2) | Seal detection |
| External Secrets Operator | `external-secrets` | ArgoCD (Helm, wave 3) | Level 1 delivery |
| `ClusterSecretStore` | cluster-scoped | ArgoCD (wave 4) | ESO → Vault binding |
| PostgreSQL | `poc-hashicorp-vault-application` | ArgoCD (wave 3) | Level 3 dynamic creds |
| Policies, roles, engines, seeds | — | `bootstrap/*.sh` | Vault's *contents* |

**Manifests deploy the process; bootstrap configures the contents.** There is no
CRD for "enable the KV engine" — Vault has its own API and authorization
language, which is why `bootstrap/` is imperative by design (D9).

---

## The Kubernetes auth handshake

This is the conceptual core of Stage A. Stage B Level 2 reimplements it by hand,
which is why Level 2 and Level 3 deliberately duplicate code rather than share it.

```
 pod                     Vault                   K8s API server
  │                       │                           │
  │ 1. read own SA JWT    │                           │
  │    from the projected │                           │
  │    volume             │                           │
  │                       │                           │
  │ 2. POST auth/kubernetes/login {role, jwt}         │
  │ ─────────────────────►│                           │
  │                       │ 3. TokenReview(jwt),      │
  │                       │    authenticating with    │
  │                       │    the REVIEWER JWT ─────►│
  │                       │                           │
  │                       │◄── 4. {authenticated,     │
  │                       │        namespace, sa, uid}│
  │                       │                           │
  │                       │ 5. match ns + sa against  │
  │                       │    the role's             │
  │                       │    bound_service_account_*│
  │                       │                           │
  │                       │ 6. mint a Vault token     │
  │                       │    carrying the role's    │
  │                       │    policies               │
  │◄── {client_token, lease_duration, renewable}      │
  │                       │                           │
  │ 7. GET secret  (X-Vault-Token: …)                 │
  │ ─────────────────────►│                           │
```

**The pod never holds a Vault credential at rest.** Its identity *is* its
Kubernetes ServiceAccount. Vault trusts the cluster's word about who the caller
is, then applies its own authorization on top.

That "trusts the cluster's word" is doing a lot of work, and it rests entirely on
step 3 — which is why the reviewer JWT and the issuer configuration are the trust
anchor for the whole scheme.

---

## Trust boundaries

| Relationship | Basis | Fails how |
|---|---|---|
| Vault → K8s API server | Reviewer JWT + cluster CA + OIDC issuer | Wrong/rotated reviewer JWT → **every login fails, hours after it appeared to work** |
| Pod → Vault | Projected SA JWT, validated by TokenReview | Wrong SA name → login denied (the isolation boundary working) |
| Client → Vault | TLS, cert-manager CA | Missing SAN → verification failure, worst on the break-glass path |
| Vault → PostgreSQL | `vaultadmin` credential, rotated so no human holds it | PVC loss → Postgres re-inits with the stale Secret while Vault holds the rotated password |
| ESO → Vault | Its own SA, `eso` role, `eso-reader` policy | Store unready → **fails quietly**; check `status.conditions`, not the apply |

### The isolation boundary worth naming

All four Stage B apps share **one namespace**, so
`bound_service_account_namespaces` is identical across all four roles. That makes
**`bound_service_account_names` the entire thing** separating Level 1 from Level
4's PGP key.

Never `bound_service_account_names="*"`. And because the boundary is this thin,
`bootstrap/70-verify-access.sh` — which proves the denials — is load-bearing
rather than ceremonial.

---

## Exposure: two paths, on purpose

They fail *differently*, which is the point.

| | `vault-lb` (primary) | `vault-nodeport` (break-glass) |
|---|---|---|
| Depends on | MetalLB speakers, ARP, the IP pool | kube-proxy only |
| Address | `192.168.56.241:8200` | `<any node IP>:30004` |
| Use | Everyday, documented | When MetalLB is what broke |

Both select `vault-active="true"`, a pod label set by
`service_registration "kubernetes"`, so **both follow leader failover with no
intervention**. Vault terminates its own TLS on both — nothing proxies or
re-encrypts, which keeps the trust model trivial.

**No ingress.** SSL passthrough is off on this cluster and would need enabling on
a shared, ArgoCD-managed ingress-nginx owned by another team — for a proxy that
does nothing but forward bytes, since Vault terminates its own TLS regardless.
Direct Services remove the hop and the coordination.

> A seal event you cannot reach Vault to *fix* is the worst failure in this
> design. That is what the second path is for, and why the node IPs must be in
> the certificate SANs.

---

## Storage, and what it costs

Integrated Storage (Raft) on `local-path-provisioner`.

Raft rather than Consul: Consul means operating a second distributed system for
no POC benefit. Raft is the vendor default and the on-prem norm.

**`local-path` pins each PV to the node that first scheduled the pod:**

- A peer whose node is lost **loses its data volume outright**. It cannot
  reschedule — it must be removed from Raft and rejoined empty, or restored.
- `kubectl delete pod` is safe. Node loss is not.
- No CSI snapshot support, so `VolumeSnapshot` does not work.
  **`vault operator raft snapshot` is the only backup mechanism here.**

### The honest availability statement

Three replicas, two workers, *soft* anti-affinity (hard would leave one pod
permanently `Pending`). So **two peers share one node**.

> This cluster runs 3-node Raft **to exercise Raft, not to achieve
> availability.** Losing the node that hosts two peers drops quorum, and Vault is
> unavailable until that node returns or the cluster is rebuilt from snapshot. A
> third worker is the fix; it is a capacity item, not a configuration one.

Node loss is an **accepted** risk, not a mitigated one. The mitigation is that
the whole cluster is reproducible from Vagrant, Ansible, git, and the bootstrap
scripts.

---

## Delivery: GitOps, and why two roots

```
root-platform.yaml          (this repo)      applied Phase A1
  ├── wave 0  vault-extras          cert · reviewer Secret · CRB · Services
  ├── wave 1  vault                 Helm chart + git values (multi-source)
  ├── wave 3  external-secrets      ESO chart
  ├── wave 3  postgres              StatefulSet + seed
  └── wave 4  external-secrets-store  ClusterSecretStore

  wave 2  vault-monitoring  — PARKED in argocd/disabled/. This cluster has no
                              Prometheus Operator CRDs, so it cannot be added
                              without editing another team's scrape config.
                              Consequence: no automated seal alert.

root-applications.yaml      (vault repo)     applied Stage B Phase B0 — NOT BEFORE
  └── level1 … level4
```

**Wave 0 must complete before Vault starts** — the StatefulSet *mounts* the TLS
Secret and the reviewer token.

**Two roots, applied at different times, are what preserve the phase gate.** A
single root would deploy Stage B the moment it synced — before Kubernetes auth
exists — producing a crash-loop that reads as an application bug and is actually
a sequencing error.

Between them sit the bootstrap scripts, which are imperative and cannot be part
of either root.

---

## What Stage B consumes

The interface Stage A must deliver. Anything else is implementation detail.

| Level | Pattern | Needs from Stage A |
|---|---|---|
| 1 | ESO → K8s Secret → env var | `ClusterSecretStore vault-backend`, `secret/level1/*`, role `eso` |
| 2 | App does the auth handshake itself | Role `level2-app`, `secret/level2/*`, token self-renewal |
| 3 | Dynamic database credentials | Role `level3-app`, `database/creds/level3-app`, PostgreSQL with table `demo` |
| 4 | PGP key pulled and used in memory | Role `level4-app`, `secret/level4/pgp`, the encrypted fixture |

Each level's ServiceAccount name is its identity — see the isolation boundary
above.

---

## Where this build diverges from the PRD

All logged in the vault repo's `documents/troubleshooting.md`.

| Divergence | Why |
|---|---|
| **Stage A lives in the cluster repo**, not the vault repo (against D18) | Stage A is platform work owned by this repo. Cost: cross-stage references are now cross-repo |
| **Kubernetes 1.29**, not ≥ 1.32 (P2) | Recorded as a **failed gate**, designed around. Shared cluster — the upgrade is a coordination item |
| `ClusterSecretStore` uses **`v1beta1`**, not `v1` | The `v1` API needs a newer ESO than 1.29 compatibility allows |
| ESO reads the CA from the **`vault-tls` Secret**, not a copied ConfigMap | A ClusterSecretStore is cluster-scoped, so the copy is avoidable — and a copied CA goes stale on rotation |
| ServiceMonitor targets **`vault-internal`** (headless), not `vault` | The chart's Services share labels; selecting `vault` matches several and double-scrapes. Headless gives one target per peer, which is what per-peer seal status needs |
| Demo table named **`demo`** | Neither PRD names it; Stage B's Level 3 defaults `DEMO_TABLE=demo`. Matching removes a mismatch that would surface as a credential-looking error |

---

## Failure modes worth knowing before they happen

| Symptom | Actual cause |
|---|---|
| Everything works, then all logins fail an hour later | Reviewer JWT was a projected token (D6) |
| Policy applies cleanly, denies everything | KV v2 path trap — `secret/data/…`, not `secret/…` |
| ServiceMonitor applies, target never appears | Wrong Prometheus discovery label — fails silently |
| Cluster healthy, quorum fine, nothing alerting | A sealed follower. Sealed pods pass readiness |
| Vault stops serving entirely | Audit device cannot write. Vault refuses to serve what it cannot audit — the reason audit goes to stdout, not a PVC |
| Dynamic credentials all fail to authenticate | Postgres PVC was lost and re-initialised with the pre-rotation password |
| Upgrade rolls, cluster goes down | Every restarted pod comes back **sealed**; the chart uses `OnDelete` precisely to stop this happening automatically |

---

## Deliberately absent

| Not built | Why |
|---|---|
| Auto-unseal (Transit or cloud KMS) | Transit moves the problem — the unsealer needs unsealing. KMS adds an external trust anchor and no cloud exists here. Manual unseal forces engagement with the seal lifecycle, which is the most operationally distinctive thing about Vault |
| Vault Agent Injector | A fourth consumption pattern; Stage B already covers three |
| PKI engine / Vault as a CA | Large surface area; deserves its own POC |
| Audit → Loki | Would mean editing the observability team's log pipeline (Rule 8) |
| Multi-cluster replication | Community edition cannot; DR here is snapshot-based |
| Vault Enterprise features | Licensed; this targets Community — see [`licensing.md`](licensing.md) |
| A third worker | Not available. Drives the quorum risk above |

---

## Related

| Document | Covers |
|---|---|
| [`environment.md`](environment.md) | Live cluster values; six still unverified |
| [`licensing.md`](licensing.md) | BUSL 1.1, OpenBao, and the outstanding policy check |
| [`key-custody.md`](key-custody.md) | Unseal-key custody |
| [`runbooks/seal-unseal.md`](runbooks/seal-unseal.md) | The seal lifecycle |
| [`runbooks/snapshot-restore.md`](runbooks/snapshot-restore.md) | The only backup mechanism |
| [`runbooks/upgrade.md`](runbooks/upgrade.md) | Version bumps; no downgrades |
| [`../README.md`](../README.md) | The manifests |
| [`../bootstrap/README.md`](../bootstrap/README.md) | Configuring Vault's contents |
