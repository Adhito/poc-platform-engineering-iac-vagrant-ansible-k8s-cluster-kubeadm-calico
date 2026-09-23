# HashiCorp Vault — Stage A platform manifests

Kubernetes manifests + ArgoCD wiring for **Stage A** of
`poc-sre-app-golang-pattern-vault-hashicorp` — standing up HashiCorp Vault so that
repo's Stage B applications (Levels 1–4) have something to consume.

The authoritative specification is **`documents/PRD_HashiCorp_Vault_Kubernetes_Cluster_Onprem.md`
in the vault repo**, not this README. Where the two disagree, the PRD wins.

---

## Deliberate deviation: manifests live here, not in the vault repo

The Stage A PRD (**D18**, **D19**, Phase A0 step 9) places Stage A manifests inside the
vault repo under `platform/kubernetes/base/…` with ArgoCD children in
`argocd/applications/platform/`. **This build puts them here instead**, under this
repo's existing `script-manifest/utility-*` convention, because Stage A is platform work
owned by this repo (the vault repo's own `documents/troubleshooting.md` notes: *"The
Platform team executes Stage A from the Stage A PRD"*).

**Consequences, stated plainly:**

- The ArgoCD `Application`s in `argocd/` here point at **this** repo's URL, not the vault
  repo's. D18's "cross-stage references stay live in one clone" no longer holds — Stage A
  and Stage B are two clones.
- Stage B's already-written children (`argocd/applications/applications/*.yaml` in the
  vault repo) are unaffected; they still source from the vault repo. Only the *platform*
  half moved.
- `root-platform.yaml` lives here. `root-applications.yaml` stays in the vault repo and is
  still **not applied during Stage A** (D19).

This deviation is logged in the vault repo's `documents/troubleshooting.md`, matching how
the apps team logged their `docs/` → `documents/` change.

---

## Layout

```
script-manifest/utility-hashicorp-vault/
├── argocd/
│   ├── root-platform.yaml            # app-of-apps root — applied Phase A1
│   ├── applications/                 # synced by root-platform
│   │   ├── vault-extras.yaml         # wave 0 · cert, reviewer Secret, CRB, Services
│   │   ├── vault.yaml                # wave 1 · multi-source Helm chart + git values
│   │   ├── external-secrets.yaml     # wave 3 · ESO chart
│   │   ├── postgres.yaml             # wave 3 · POC PostgreSQL for Level 3
│   │   └── external-secrets-store.yaml  # wave 4 · ClusterSecretStore
│   └── disabled/                     # parked — NOT synced; see its README
│       └── vault-monitoring.yaml     # wave 2 · no Prometheus Operator CRDs on this cluster
├── base/                             # structure — environment-agnostic
│   ├── namespaces/
│   ├── cert-manager-issuers/
│   ├── vault-extras/
│   ├── monitoring/
│   ├── external-secrets/
│   └── postgres/
├── overlays/onprem/                  # the A0-discovered environment values
├── helm/vault/values-onprem.yaml     # git side of the multi-source Vault Application (D1)
├── bootstrap/                        # configures Vault's CONTENTS (D9) — see below
└── documents/
    ├── architecture.md               # what is built, and what is deliberately absent
    ├── environment.md                # verified live values — read these, never hardcode
    ├── licensing.md                  # BUSL 1.1 position + the outstanding policy check
    ├── key-custody.md                # unseal-key custody: method and holder, never location
    └── runbooks/
        ├── seal-unseal.md
        ├── snapshot-restore.md
        └── upgrade.md
```

**Start at [`documents/environment.md`](documents/environment.md).** It carries every
cluster-specific value, marked verified / inferred / unknown, with the command that
answers each unknown. `bootstrap/preflight.sh` resolved most of them on 2026-09-11;
what is still open is marked in the A0 status table below.

> **`troubleshooting.md` is not here on purpose.** Both stages log to the single file in
> the vault repo (`documents/troubleshooting.md`), Stage A section included — a second
> copy would fragment the one record that is meant to be complete. Anything that
> surprised you, *including things that contradicted a PRD*, goes there.

`base/` holds structure; `overlays/onprem/` carries the values discovered from the live
cluster in Phase A0. That split exists so the PRD's *"never hardcode environment values"*
rule has somewhere to land — node IPs, the MetalLB VIP, and the StorageClass name are
patched in at the overlay, not baked into the base.

---

## Before this can be applied — Phase A0 status

These are **not** optional polish. Several will silently half-work if skipped.
Status as of the 2026-09-23 preflight run, on the rebuilt 1.36 cluster (from the Dev VM):
**passed 19, failed 3** — MetalLB (below), and git state until this branch is pushed and merged.

| # | Item | Where it lands | Status |
|---|---|---|---|
| 1 | **Kubernetes ≥ 1.32** (P2) — **v1.36.4** on all nodes (was v1.29.15) | cluster | ✅ **Rebuilt 2026-09-22** — see below |
| 2 | `local-path-provisioner` (P8) | cluster | ✅ **v0.0.37 installed 2026-09-23** — StorageClass `local-path`, *not* default |
| 3 | MetalLB VIP for Vault | `overlays/onprem` | ⏳ `192.168.56.241` free, but **MetalLB itself is not installed** on the rebuilt cluster — it returns when this repo's `addon_metallb` runs (`vagrant provision devnodeworker02`); this repo owns MetalLB since 2026-09-23. **Blocks `root-platform`:** wave 0's `vault-lb` never gets an address, so ArgoCD never starts wave 1 |
| 4 | Prometheus discovery labels (A0.5 check 5b) | — | n/a — moot while 5 is "no" |
| 5 | Prometheus operator-managed (A0.5 check 5a) | — | ✅ **No** — `vault-monitoring` parked in `argocd/disabled/` |
| 6 | Cluster OIDC issuer | bootstrap | ✅ `https://kubernetes.default.svc.cluster.local` |
| 7 | ArgoCD access to this repo | ArgoCD config | ✅ **Not needed** — the repo is public, and every Application uses its HTTPS URL; see below |
| 8 | Postgres admin password Secret | cluster | ✅ Created 2026-09-23 (32 chars, via a 0600 temp file) — never in git (Rule 1) |
| 9 | cert-manager | cluster | ✅ **v1.21.2 installed 2026-09-23** — `selfsigned-bootstrap` and `vault-poc-ca-issuer` Ready, `vault-poc-ca` issued |
| 10 | Namespaces | cluster | ✅ Applied 2026-09-23 |

### 1 — Kubernetes 1.36 (P2 gate — resolved by the rebuild)

PRD P2 requires ≥ 1.32 and says *"bump if still on 1.29 (EOL)"*. The cluster was on
v1.29.15 (kubelets v1.29.0). On 2026-09-11 the owner first chose to stay and accept the
risk, which forced cert-manager and ESO onto end-of-life lines. On 2026-09-22 that was
reversed, and the same day **the cluster was rebuilt on Kubernetes 1.36.4** (all three
nodes `Ready`, CRI-O 1.36.6, Calico 3.32.2) — the newest minor every
component below supports (1.37 was four weeks old and not yet in cert-manager's or
Calico's matrices). Procedure: [`documents/DOCUMENTS-runbook-cluster-upgrade-1-36.md`](../../documents/DOCUMENTS-runbook-cluster-upgrade-1-36.md).

Pins, verified against each project's support matrix on 2026-09-22:

| Component | Pinned | On K8s 1.36 |
|---|---|---|
| cert-manager | `v1.21.2` | ✅ 1.21 supports 1.33–1.36 |
| Vault Helm chart | `0.34.1` (Vault `2.0.4`) | ✅ chart declares K8s ≥ 1.20 |
| External Secrets Operator | `2.11.0` | ✅ 2.11 supports 1.36 — **short support window**, see below |
| local-path-provisioner | `v0.0.37` | ✅ still the latest release |
| PostgreSQL | `16.15-alpine` | ✅ current 16.x patch |

ESO ships a minor roughly every three weeks, and each is supported only until the next. So
`2.11.0` will be "EOL" within weeks. Plan for that: bump it deliberately when you next touch
the platform, not the moment it lapses.

> Vault's storage format is version-sensitive and **downgrades are not supported** — the
> version is settled before `operator init`, not after. Vault 2.0 also changed how root
> recovery works: see `bootstrap/95-create-breakglass.sh`.

### 5 — Prometheus is not operator-managed (monitoring parked)

This cluster's observability stack is **Grafana LGTM** (`observability` namespace, managed
by the `observability-local` ArgoCD app, owned by another team). A0.5 check 5a found the
Prometheus Operator CRDs **absent**:

```bash
kubectl get crd servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com
```

The PRD is explicit for this case — **stop and report, do not edit their scrape config**. The
`vault-monitoring` child is parked in `argocd/disabled/` (not synced), with the reason
recorded; the other children are unaffected. **The cost: there is no automated seal alert**,
so the manual check in `documents/runbooks/seal-unseal.md` is the detection until the
observability team installs the operator CRDs.

### 7 — ArgoCD cannot use this repo's git remote as-is

The remote is an SSH host alias:

```
git@github.com-adhito909:Adhito/poc-platform-engineering-iac-vagrant-ansible-k8s-cluster-kubeadm-calico.git
```

ArgoCD cannot resolve `github.com-adhito909`, so the `Application`s here use the HTTPS URL.
**The repo is public** (verified 2026-09-22: anonymous `git ls-remote` works, GitHub reports
`"private": false`), so ArgoCD reads it anonymously and **no credential is needed**.
`bootstrap/preflight.sh` probes anonymous access first, and falls back to checking for a
credential only if the probe fails. If the repo is ever made private, register a
credential or a deploy key; the vault repo's `root-applications.yaml` has the same concern.

### 8 — Postgres admin password ✅ done

Rule 1 (*never commit secret material*) means the `vaultadmin` password cannot live in git.
`base/postgres/statefulset.yaml` reads it from a Secret named `postgres-admin`, created
out-of-band on 2026-09-11 — through a `0600` temp file rather than a command-line argument,
and only if absent. **Never regenerate it**: once Postgres initialises against a value, a
new one breaks the database.

```bash
# how it was created — needed again only on a rebuilt cluster
umask 077; f=$(mktemp); openssl rand -base64 24 | tr -d '\n' > "$f"
kubectl -n poc-hashicorp-vault-application create secret generic postgres-admin \
  --from-file=POSTGRES_PASSWORD="$f"; shred -u "$f"
```

Phase A7 then rotates it away with `vault write -f database/rotate-root/poc-postgres`,
after which no human knows it — which is the point of the exercise.

---

## Deploying

Phase A1 applies **only** the platform root (D19):

```bash
kubectl apply -f script-manifest/utility-hashicorp-vault/argocd/root-platform.yaml
```

Sync waves order the children:

| Wave | Child | Why this order |
|---|---|---|
| 0 | `vault-extras` | The StatefulSet **mounts** the cert and reviewer Secret — they must exist first |
| 1 | `vault` | The chart itself |
| 3 | `external-secrets`, `postgres` | The ESO chart, and the database Level 3 needs |
| 4 | `external-secrets-store` | Its CRD comes from the ESO chart in wave 3 |

Wave 2 (`vault-monitoring`) is parked in `argocd/disabled/` — see section 5.

The Phase A0 prerequisites are applied **directly**, not through the root app — they must
exist before ArgoCD creates anything that depends on them. In order:

```bash
# storage — done 2026-09-23 on the 1.36 cluster
kubectl apply -k script-manifest/utility-hashicorp-vault/base/local-path-provisioner
# namespaces — done 2026-09-23 on the 1.36 cluster
kubectl apply -k script-manifest/utility-hashicorp-vault/base/namespaces
# cert-manager v1.21.2 — done 2026-09-23; --server-side for its large CRDs
kubectl apply --server-side -k script-manifest/utility-hashicorp-vault/base/cert-manager
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
# the issuer chain — only once the webhook is serving, or the apply is rejected
kubectl apply -k script-manifest/utility-hashicorp-vault/base/cert-manager-issuers
```

> `root-applications.yaml` (Stage B) stays in the vault repo and is **not applied during
> Stage A**. Applying it early deploys app pods before Kubernetes auth exists — a
> crash-loop that reads as an app bug and is actually a sequencing error (D19).

---

## Configuring Vault — `bootstrap/`

The manifests deploy the Vault *process*. Nothing here can enable a secrets engine or
write a policy, because Vault has its own API and authorization language. That is
`bootstrap/` — imperative and idempotent by design (D9), with its own
[README](bootstrap/README.md).

Run order, after `root-platform` has synced and Vault is running:

| # | Script | Phase |
|---|---|---|
| — | `preflight.sh` | A0 — **run first**; read-only readiness check of the whole cluster |
| 00 | `00-init-unseal.sh` | A2 — **produces the unseal keys** |
| 10 | `10-enable-kubernetes-auth.sh` | A6 |
| 20 | `20-apply-policies.sh` + `20-policies/*.hcl` | A6 |
| 30 | `30-enable-kv.sh` | A7 |
| 40 | `40-enable-database.sh` | A7 — **rotates the Postgres admin password, one-way** |
| 50 | `50-seed-secrets.sh` | A7 — KV values + Level 4 PGP keypair |
| 60 | `60-enable-audit.sh` | A9.1 — **before Stage B**; audit is not retroactive |
| 70 | `70-verify-access.sh` | A6 — the negative tests; non-zero exit on failure |
| 90 | `90-snapshot.sh` | A9.2 |
| 95 | `95-create-breakglass.sh` | A6 — **the recovery identity Vault 2.0 requires**; proves it before root can go |
| 99 | `99-revoke-root.sh` | A6 — last; preflights the whole bootstrap, including 95 |

## What is deliberately *not* here

- **The A7 revocation proof** — `psql` in with a generated credential,
  `vault lease revoke`, confirm the connection now fails and `\du` shows the role
  dropped. `40-` proves issuance; a revocation you have not watched fail is not proven.
- **The A9.3 restore drill** — destroy Vault including PVCs, redeploy, restore, unseal
  with the *original* shares. Its real output is a wall-clock number: the actual RTO.
- **`documents/environment.md`, `key-custody.md`, the three runbooks** — written, not
  generated.

**Coordination item inherited from the vault repo:** its `documents/troubleshooting.md`
records that Stage B reads `documents/environment.md` while the Stage A PRD writes
`docs/environment.md`. Whoever runs Phase A0 should write **`documents/`**, matching what
Stage B already expects.
