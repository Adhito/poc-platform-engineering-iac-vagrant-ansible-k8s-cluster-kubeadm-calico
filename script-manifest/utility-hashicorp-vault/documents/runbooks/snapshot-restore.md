# Runbook — snapshot and restore

Phase A9.2 / A9.3 deliverable.

---

## Three things about Vault snapshots that surprise people

Read these before you need them. All three are discovered painfully otherwise.

**1. A snapshot is encrypted under the seal of the cluster it came from.**
It is not a portable export, not a dump, not something you can inspect. Without
the original unseal shares it is an unopenable blob.
**`vault-init.json` and the snapshots are a matched pair — losing either loses both.**

**2. `snapshot restore -force` overwrites the target's entire dataset.**
It is not a merge. There is no partial restore, no per-path restore, no "restore
just the KV mount". Everything in the target is replaced by everything in the
snapshot.

**3. After restoring, you unseal with the ORIGINAL shares.**
If you restored into a freshly-initialised Vault, the shares that `operator init`
just printed are **discarded** — the restore brings the old seal back with it.
This is the single most counter-intuitive part of Vault DR, and the reason the
drill exists.

---

## Where snapshots live

```
~/.credentials/vault-poc/snapshots/vault-<YYYY-MM-DD-HHMMSS>.snap
```

Beside the keys, mode `0600`, **outside the repo tree** — same reasoning as the
keys themselves (`git clean -xfd` deletes gitignored files by design). Override
with `VAULT_POC_SNAPSHOTS`; the outside-the-repo assertion still applies.

Retention: the 10 most recent, pruned automatically by `90-snapshot.sh`.

> **This is single-copy backup on one host.** A snapshot stored only on the
> machine that also holds the unseal keys survives neither a disk failure nor a
> stolen laptop. A real environment ships these off-host. Named here as an
> accepted POC shortcut, not an oversight.

---

## Taking a snapshot

```bash
cd script-manifest/utility-hashicorp-vault/bootstrap
export VAULT_ADDR=https://192.168.56.241:8200
export VAULT_CACERT=/etc/vault-poc/ca.crt
export VAULT_TOKEN=<a token with sys/storage/raft/snapshot read>

./90-snapshot.sh
```

By hand:

```bash
vault operator raft snapshot save vault-$(date +%F-%H%M%S).snap
```

Requires Raft storage — the snapshot API does not exist for other backends.

**Take one before every upgrade, before the restore drill, and before any
deliberate destruction.** They are cheap; the situations where you wish you had
one are not.

---

## Restoring

### When you need this

- Raft quorum lost and not recoverable (on this cluster: the node hosting two
  peers is gone — see [`seal-unseal.md`](seal-unseal.md))
- Data corruption or a destructive mistake
- Rebuilding the cluster from scratch

### Procedure

```bash
# 1. Confirm you have BOTH halves before touching anything.
ls -l ~/.credentials/vault-poc/vault-init.json
ls -lt ~/.credentials/vault-poc/snapshots/ | head

# 2. Vault must be running, initialised, and unsealed to accept a restore.
#    On a fresh instance that means initialising it first — those keys are
#    throwaway, see below.
vault status

# 3. Restore. This OVERWRITES EVERYTHING in the target.
vault operator raft snapshot restore -force ~/.credentials/vault-poc/snapshots/vault-<ts>.snap

# 4. Vault seals itself immediately — the restored data is under the OLD seal.
#    Unseal with the ORIGINAL shares from vault-init.json.
#    The keys from step 2's init are now worthless. Discard them.
vault operator unseal      # x3, original shares

# 5. Verify.
vault status                     # Sealed: false
vault operator raft list-peers
vault kv get -mount=secret level1/app
```

On a multi-peer cluster, restore against the **leader**; followers resynchronise
from Raft. Each peer still seals independently and must be unsealed —
`./00-init-unseal.sh --all-peers` handles that.

---

## The A9.3 drill

**Framing matters.** Node loss and rebuild are an *accepted* outcome for this
environment — you have already decided you can afford it. So this drill is **not
a DR requirement**. It is a learning deliverable, because the three facts at the
top of this page cannot be learned any other way, and all three surprise people.

It is also where the RTO number comes from.

Run it once, deliberately, so none of it is a discovery during an incident.

```bash
# 1. Snapshot.
./90-snapshot.sh

# 2. Write a canary AFTER the snapshot. It must NOT survive the restore —
#    that is what proves you restored the snapshot and not something else.
vault kv put -mount=secret canary v=post-snapshot

# 3. START THE CLOCK.

# 4. Destroy Vault completely — StatefulSet AND PVCs.
kubectl -n vault delete statefulset vault
kubectl -n vault delete pvc -l app.kubernetes.io/name=vault

#    Confirm the local-path directories are actually gone from the nodes.
#    They are hostPath-backed; a leftover directory will be silently reused.
for n in devnodemaster01 devnodeworker01 devnodeworker02; do
  vagrant ssh $n -c 'sudo ls /opt/local-path-provisioner 2>/dev/null || echo "(clean)"'
done

# 5. Redeploy. ArgoCD will recreate it — or force a sync.
argocd app sync vault      # or: kubectl -n argocd patch app vault ... 

# 6. Initialise the fresh instance. These keys are THROWAWAY.
vault operator init -key-shares=5 -key-threshold=3 -format=json > /tmp/throwaway-init.json
vault operator unseal   # x3, using the THROWAWAY shares, just to accept the restore

# 7. Restore.
vault operator raft snapshot restore -force ~/.credentials/vault-poc/snapshots/vault-<ts>.snap

# 8. Unseal with the ORIGINAL shares. This is the step that teaches the lesson.
vault operator unseal   # x3, from ~/.credentials/vault-poc/vault-init.json

# 9. STOP THE CLOCK.

# 10. Verify.
vault kv get -mount=secret level1/app   # pre-snapshot data: PRESENT
vault kv get -mount=secret canary       # canary: ABSENT  <- proves the restore

rm -f /tmp/throwaway-init.json
```

### Record the result

| | |
|---|---|
| Wall-clock, steps 3 → 9 | `____________` |
| Date run | `____________` |
| Anything that did not go to plan | `____________` |

**That number is your actual RTO.** Put it here and in
[`../environment.md`](../environment.md) — not in a terminal you will close.

---

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `failed to restore snapshot` | Target sealed or uninitialised | Init and unseal the target first — even with throwaway keys |
| Restore succeeds, then nothing works and unsealing fails | Using the *new* keys | Use the **original** shares. The restore brought the old seal with it |
| Restore succeeds, canary still present | Restored the wrong file, or the restore silently no-op'd | Check the timestamp; re-run with the correct snapshot |
| Old data reappears after a "clean" rebuild | `local-path` directory left on a node | Delete the hostPath dirs; PVC deletion does not always clear them |
| `snapshot save` fails | Not Raft storage, or the token lacks capability | Check `vault status`; policy needs `sys/storage/raft/snapshot` read |

---

## What this design does not have

- **No storage-layer safety net.** `local-path-provisioner` is a *provisioner*,
  not a storage system — it makes a directory on a node and hands it over. It
  does not implement CSI snapshots, so `VolumeSnapshot` does not work.
  `vault operator raft snapshot` is the **only** backup mechanism here.
- **No off-host copy.** Accepted; see above.
- **No automated schedule.** `90-snapshot.sh` is run by a human. A CronJob is the
  obvious next step and needs a token with a narrow policy, not root.

Rancher **Longhorn** would provide replicated block storage with real volume
snapshots and would remove the node-pinning problem entirely. Logged as backlog,
out of scope here.

---

## Related

| Document | Covers |
|---|---|
| [`seal-unseal.md`](seal-unseal.md) | Unsealing, key custody, quorum |
| [`../environment.md`](../environment.md) | Storage constraints, node topology |
| [`upgrade.md`](upgrade.md) | Snapshot before every upgrade |
