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
| cert-manager | `v1.18.6` — **EOL** | `base/cert-manager/` (A0, applied directly, not via ArgoCD) |
| External Secrets Operator | `0.13.0` — **EOL** | `argocd/applications/external-secrets.yaml` |
| local-path-provisioner | `v0.0.37` | `base/local-path-provisioner/` (A0, applied directly) |
| PostgreSQL | `16.15-alpine` | `base/postgres/statefulset.yaml` |

Each is the newest release that still supports this cluster's Kubernetes 1.29,
verified 2026-09-11. The two marked **EOL** are forced by that version gate —
upgrading Kubernetes is what makes supported versions possible for them.

**These were chosen for Kubernetes 1.29 compatibility, not because they are
current.** Verify against upstream release notes at implementation time — the
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

**Check the API version before bumping.** `ClusterSecretStore` is currently
`external-secrets.io/v1beta1`, because ESO `0.13.0` (the newest line for
Kubernetes 1.29) serves `v1beta1` as its storage version. The ESO releases that
serve `v1` need a newer Kubernetes, so this bump rides with the Kubernetes
upgrade. Moving to `v1` is then a one-line change in
`base/external-secrets/clustersecretstore.yaml` — but confirm the CRD is served
(`kubectl get crd clustersecretstores.external-secrets.io -o jsonpath='{.spec.versions[*].name}'`)
before changing the manifest, or the sync fails on an unknown kind.

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

**Outstanding: the control plane is on v1.29.15 (kubelets v1.29.0) and P2 requires ≥ 1.32.** Recorded as a
failed A0 gate in [`../environment.md`](../environment.md).

It is a coordination item, not a unilateral one — the cluster is shared with the
observability and tracing-poc teams. When it happens:

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
