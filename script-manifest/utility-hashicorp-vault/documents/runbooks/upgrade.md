# Runbook — upgrades

Phase A0 deliverable (D16).

---

## The rule that governs everything here

> ## Vault downgrades are not supported.
>
> Vault's storage format is version-sensitive. Once a version has written to
> Raft, an older binary may refuse to start against that data — or, worse, read
> it wrongly. **There is no rollback.** The only way back is
> [restore from a snapshot taken before the upgrade](snapshot-restore.md).

So: snapshot first, every time, without exception. And never `latest` — a
floating tag turns an unplanned pod reschedule into an unplanned upgrade.

---

## Current pins

All in git. Nothing floats.

| Component | Version | Where |
|---|---|---|
| Vault Helm chart | `0.34.1` | `argocd/applications/vault.yaml` → `targetRevision` |
| Vault image | `2.0.4` | `helm/vault/values-onprem.yaml` → `server.image.tag` |
| cert-manager | `v1.21.2` | `base/cert-manager/` (A0, applied directly, not via ArgoCD) |
| External Secrets Operator | `2.11.0` | `argocd/applications/external-secrets.yaml` |
| local-path-provisioner | `v0.0.37` | `base/local-path-provisioner/` (A0, applied directly) |
| PostgreSQL | `16.15-alpine` | `base/postgres/statefulset.yaml` |

Each is on a supported line for this cluster's Kubernetes 1.36, verified
2026-09-22. (On 1.29, cert-manager and ESO were forced onto end-of-life lines;
the rebuild removed that.) ESO's support window is one release (~3 weeks), so
it is the pin most likely to be stale when you read this.

**These were chosen for Kubernetes 1.36 compatibility.** Verify against upstream
release notes at implementation time — the
PRDs deliberately omit version numbers because anything written there is stale by
the time it runs.

> **Chart version and app version are different things.** Chart `0.34.1` ships a
> default Vault image; `values-onprem.yaml` pins the image explicitly and
> overrides it. Bumping one does not bump the other, and they can drift apart
> without anything complaining.

---

## Before any upgrade

```bash
# 1. Snapshot. This is your only rollback.
cd script-manifest/utility-hashicorp-vault/bootstrap
./90-snapshot.sh

# 2. Confirm you can still unseal — you will need to, three times, shortly.
ls -l ~/.credentials/vault-poc/vault-init.json

# 3. Record the starting state.
vault status
vault operator raft list-peers
kubectl -n vault get pods -o wide
```

Read the upstream changelog between your current version and the target. Vault's
release notes call out storage-format and seal changes explicitly; those are the
ones that make an upgrade a one-way door.

---

## Upgrading Vault

### The thing that makes this different from a normal Deployment

The chart sets `updateStrategy: OnDelete` for HA Raft. **Changing the image tag
does not restart anything.** Pods are replaced only when you delete them, one at
a time, by hand.

That is deliberate, and it is the right default: every pod that restarts comes
back **sealed**, and an automatic rolling update would seal all three peers in
sequence with nobody unsealing them — taking the cluster down while looking, from
Kubernetes' point of view, entirely healthy.

### Procedure

**1. Bump the version in git.** Not with `kubectl`.

```yaml
# helm/vault/values-onprem.yaml
server:
  image:
    tag: "2.0.4"    # -> new version (never lower — see the rule above)
```

ArgoCD has `selfHeal: true` on the `vault` Application, so any `kubectl edit` or
`kubectl set image` is reverted on the next sync. Commit, push, let it sync.

**2. Confirm the StatefulSet spec updated but pods did not.**

```bash
kubectl -n vault get sts vault -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
kubectl -n vault get pods -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
```

Spec shows the new tag; pods still show the old one. That is correct.

**3. Upgrade the standbys first, one at a time.**

Identify the leader — upgrade it **last**, so you take one failover instead of
several:

```bash
kubectl -n vault get pods -l vault-active=true
```

Then for each standby:

```bash
kubectl -n vault delete pod vault-2
kubectl -n vault wait --for=condition=Ready pod/vault-2 --timeout=180s

# It comes back SEALED. Readiness does not mean usable — that is the whole
# point of the VaultNodeSealed alert.
kubectl -n vault exec -it vault-2 -- vault operator unseal   # x3

# Confirm it rejoined Raft before touching the next one.
vault operator raft list-peers
```

**Do not proceed to the next peer until the previous one is unsealed and listed
as a peer.** Two peers down at once on a 3-node cluster is quorum loss.

**4. Upgrade the leader last.**

```bash
# Hand over deliberately rather than by killing the leader.
kubectl -n vault exec -it vault-0 -- vault operator step-down

kubectl -n vault delete pod vault-0
kubectl -n vault wait --for=condition=Ready pod/vault-0 --timeout=180s
kubectl -n vault exec -it vault-0 -- vault operator unseal   # x3
```

**5. Verify.**

```bash
vault status                      # version bumped, Sealed false
vault operator raft list-peers    # 3 peers, exactly one leader
vault kv get -mount=secret level1/app

# Both exposure paths — a working primary hides a broken break-glass.
VAULT_ADDR=https://192.168.56.241:8200 vault status
VAULT_ADDR=https://192.168.56.10:30004 vault status
```

`./00-init-unseal.sh --all-peers` can replace the per-pod unseals above, but run
it **between** deletions, not after all three — the point of the sequence is that
only one peer is down at a time.

---

## Upgrading the other components

### cert-manager

Installed in A0, outside ArgoCD. CRDs upgrade separately from the chart and must
go first. A cert-manager outage does not take Vault down — existing certificates
keep working; only issuance and renewal stop. So this is low-risk *unless* a
certificate is near expiry.

```bash
kubectl get certificate -A     # check nothing is about to renew
```

### External Secrets Operator

Bump `targetRevision` in `argocd/applications/external-secrets.yaml`.

**Check the API version before bumping.** `ClusterSecretStore` is
`external-secrets.io/v1`; ESO 2.11 still ships the `v1beta1` schema but with
`served: false`. Before any bump, confirm the target release still serves the
version the manifest uses, or the sync fails on an unknown kind:

```bash
kubectl get crd clustersecretstores.external-secrets.io \
  -o jsonpath='{range .spec.versions[*]}{.name}{" served="}{.served}{"\n"}{end}'
```

Also check the target's Kubernetes range in ESO's support table — it is tight
(2.11 lists only 1.36), so a Kubernetes minor bump usually needs an ESO bump too.

ESO going down does not break already-materialised Kubernetes Secrets; it stops
them refreshing. Level 1 keeps working on stale data, which is exactly the
staleness gap Stage B Level 1 exists to demonstrate.

### PostgreSQL

**Not an in-place upgrade.** A PostgreSQL major version bump needs a dump and
restore; the data directory format changes and the new binary will refuse to
start against the old one.

For this POC the database is throwaway — the simplest path is to destroy the PVC,
let it re-initialise from `base/postgres/seed-configmap.yaml`, and re-run
`40-enable-database.sh`.

> **After doing that, `40-enable-database.sh` must re-run.** A fresh PVC
> re-initialises Postgres with the password from the `postgres-admin` Secret,
> while Vault still holds the *rotated* one from the previous life. Every dynamic
> credential request fails to authenticate until the connection is reconfigured.

### Kubernetes itself

**1.29 → 1.36 was done by rebuild, not in place** (2026-09-22), before Vault was
deployed — see [`../environment.md`](../environment.md) and the cluster repo's
[`documents/DOCUMENTS-runbook-cluster-upgrade-1-36.md`](../../../../documents/DOCUMENTS-runbook-cluster-upgrade-1-36.md).
A rebuild is **not an option once Vault holds state**: it destroys the Raft data
and the seal. From here on, Kubernetes upgrades are in place, one minor at a
time (`kubeadm upgrade`), with Vault running.

It is a coordination item, not a unilateral one — the cluster is shared with the
observability and tracing-poc teams. For each in-place minor upgrade:

- Every node drain restarts Vault pods, and **each comes back sealed**. Plan
  unsealing into the upgrade window; do not discover it mid-drain.
- `local-path` volumes are node-pinned. A drained node's Vault peer cannot
  reschedule — it comes back only when that node does.
- Snapshot first.
- Re-check every version pin above for compatibility with the new K8s minor.

---

## Rollback

There isn't one for Vault.

| Component | Rollback |
|---|---|
| **Vault** | **None.** [Restore from snapshot](snapshot-restore.md) |
| cert-manager | Reinstall the previous chart version |
| ESO | Revert `targetRevision`, providing no CRD schema changed |
| PostgreSQL | Restore the PVC, or re-seed |

If a Vault upgrade goes wrong: stop, do not try a newer version to "fix forward"
past a storage-format problem, and restore the pre-upgrade snapshot.

---

## Related

| Document | Covers |
|---|---|
| [`snapshot-restore.md`](snapshot-restore.md) | The only rollback path that exists |
| [`seal-unseal.md`](seal-unseal.md) | Every upgraded pod comes back sealed |
| [`../environment.md`](../environment.md) | Current pins, the outstanding K8s gate |
