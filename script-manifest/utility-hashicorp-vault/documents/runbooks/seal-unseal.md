# Runbook — seal and unseal

Phase A3 deliverable. Written to be usable **cold, by someone who did not build
this**, over either network path.

If Vault is sealed right now and you just need it working, go to
[Unseal](#unseal-the-procedure). Read the rest afterwards.

---

## What sealing actually is

Vault's data is encrypted at rest with a **master key**. That key is itself
encrypted, and Vault does not hold it on disk in usable form. When Vault starts,
it has the ciphertext and not the key — so it can read nothing, answer nothing,
and serve nothing. That state is **sealed**.

Unsealing is the act of reconstructing the master key in memory from key shares.
It is not a login. Nothing about it identifies you; it makes the *storage*
readable. Authentication happens afterwards and separately.

Three consequences worth internalising:

- **A sealed Vault is not a broken Vault.** The data is intact and safe. It is
  waiting, deliberately.
- **Restarting Vault always seals it.** The master key lives only in memory, so a
  restart discards it. This is by design, not a bug.
- **Every peer seals independently.** Unsealing `vault-0` does nothing for
  `vault-1`. This surprises people, and it is why one sealed follower can sit
  unnoticed for weeks.

## When Vault seals

| Cause | Notes |
|---|---|
| Pod restart, reschedule, node reboot | The common one. Expect it after any deploy or node event |
| `vault operator seal` | Deliberate |
| Loss of Raft quorum | The peers that remain seal themselves rather than serve stale data |
| Seal-wrapping / storage errors | Rare; treat as an incident, not a routine unseal |

---

## Detection

### Primary — the `VaultNodeSealed` alert

`vault_core_unsealed == 0`, per peer, firing after 5 minutes.
Defined in `base/monitoring/prometheusrule.yaml`.

> **Do not trust this alert until it has been fired on purpose.** Phase A9.4
> requires sealing a follower and watching it fire. Until that test passes,
> **manual checking is the only detection you actually have** — and if the
> Prometheus discovery labels are wrong (see `environment.md` 5b) the rule was
> never loaded at all, silently.

### Why this needs an alert at all

A sealed pod **passes its readiness probe**. The chart's health check treats
`sealedcode=204` as healthy deliberately, so Kubernetes will not kill a pod that
is merely waiting to be unsealed.

So with 3 peers, one sealed follower costs *nothing visible*: quorum holds, apps
keep working, no pod restarts, nothing goes red — while the cluster sits one
event away from needing the restore drill. That is silent degradation, and it is
worse than a loud failure because it removes the chance to act.

### Manual check

```bash
# All peers at once — the honest view
kubectl -n vault get pods -l app.kubernetes.io/name=vault -o name \
  | xargs -I{} sh -c 'echo "--- {}"; kubectl -n vault exec {} -- vault status 2>&1 | grep -E "Sealed|HA Mode"'

# Whatever is behind VAULT_ADDR
vault status
```

`Sealed  true` on any peer means that peer is doing nothing.

---

## Unseal — the procedure

You need **3 of the 5 key shares**. They are in `vault-init.json` — see
[Key custody](#key-custody) for where, and ask the holder if you do not have it.

### Step 1 — set up the client

```bash
export VAULT_ADDR=https://192.168.56.241:8200      # MetalLB VIP (primary)
export VAULT_CACERT=/etc/vault-poc/ca.crt
```

If the CA is not on this machine:

```bash
sudo mkdir -p /etc/vault-poc
kubectl -n vault get secret vault-tls -o jsonpath='{.data.ca\.crt}' \
  | base64 -d | sudo tee /etc/vault-poc/ca.crt >/dev/null
```

**If `VAULT_ADDR` does not respond, switch to the break-glass path** — MetalLB
may be exactly what broke:

```bash
export VAULT_ADDR=https://192.168.56.10:30004      # any node IP, NodePort
```

> **Never reach for `-tls-skip-verify`.** A TLS error here means a missing SAN or
> the wrong CA, and both are fixable in less time than the bypass will cost you
> later — because the bypass never gets removed. The node IPs are the SAN most
> often forgotten, and their absence breaks this exact path at this exact moment.

### Step 2 — unseal

The scripted path handles one peer or all of them:

```bash
cd script-manifest/utility-hashicorp-vault/bootstrap
./00-init-unseal.sh                # unseal whatever VAULT_ADDR points at
./00-init-unseal.sh --all-peers    # unseal every peer via kubectl exec
```

It is idempotent — an already-unsealed peer is skipped, not disturbed.

By hand, if you prefer or the script is unavailable:

```bash
vault operator unseal      # prompts; repeat 3x with three DIFFERENT shares
```

Or per peer, without going through the network:

```bash
kubectl -n vault exec -it vault-1 -- vault operator unseal
```

**Three different shares.** The same share entered three times does not count —
Vault tracks distinct shares and will sit at `Unseal Progress 1/3`.

### Step 3 — verify

```bash
vault status                                  # Sealed: false
vault operator raft list-peers                # all peers, exactly one leader
```

Then confirm **both** paths, because a working primary hides a broken break-glass:

```bash
VAULT_ADDR=https://192.168.56.241:8200 vault status
VAULT_ADDR=https://192.168.56.10:30004 vault status
```

---

## Quorum: what this cluster can and cannot survive

**This cluster runs 3-node Raft to exercise Raft, not to achieve availability.**

There are two workers and three replicas with *soft* anti-affinity (D4 — hard
anti-affinity would leave a pod permanently `Pending`). So **two peers share one
worker node.**

> Node hosting two peers: `________________` — fill in from Phase A4 step 5:
> `kubectl get pods -n vault -o wide`

Losing that node drops quorum, and Vault becomes unavailable until either the
node returns or the cluster is rebuilt from snapshot. A third worker is the fix;
it is a capacity item, not a configuration one.

And because storage is `local-path`, a lost node's peer **loses its data volume
outright** — it cannot reschedule. See
[`snapshot-restore.md`](snapshot-restore.md).

---

## Key custody

**POC arrangement:** all five shares live together in
`~/.credentials/vault-poc/vault-init.json` on the dev workspace host, mode `0600`
in a `0700` directory, **outside the repo tree**, with a copy in a password
manager.

Outside the repo because `.gitignore` is not sufficient: `git clean -xfd` deletes
gitignored files *by design* — that is what `-x` means — and it is exactly what
gets run when resetting a working tree. `git add -f` bypasses `.gitignore` too.
`bootstrap/lib/common.sh` asserts the path is outside the repo and aborts if not.

**What a real arrangement requires, and what we are deliberately not doing:**
five shares to five separate holders, threshold three, no single person able to
unseal alone, shares held offline. The 5/3 split we use otherwise *implies* a
ceremony that is not happening — one person holds all five, so the split provides
no separation of duty, only redundancy against corruption.

That trade is proportionate here: nothing in this POC is irreplaceable. KV is
re-seeded by script, database credentials are generated on demand, the PGP
keypair is regenerable. Key loss costs hours of rebuild, not data.

Record the method and the holder in `key-custody.md` — **never the location, and
never the shares.**

> **A backup you have never read from is a hypothesis.** A2's exit gate requires
> sealing a node and unsealing it from a share retrieved out of the
> password-manager copy, not the working file.

---

## Rekey — replace the shares

Use when a share is exposed, a holder leaves, or you want a different split.
Requires a threshold of *current* shares. The master key is unchanged; only the
shares that reconstruct it are replaced.

**On Vault 2.x, `sys/rekey` is authenticated.** In 1.x the shares alone were
enough; on 2.x you first need a token allowed to call it. After A6 revokes root,
that token comes from the break-glass login (`bootstrap/95-create-breakglass.sh`):

```bash
export VAULT_TOKEN="$(vault write -field=token auth/userpass/login/breakglass \
    password=@$HOME/.credentials/vault-poc/breakglass-userpass.txt)"

vault operator rekey -init -key-shares=5 -key-threshold=3   # note the nonce
vault operator rekey -nonce=<nonce>                          # x3, one per current share
```

The new shares are printed **once**. Distribute and store them before you close
the terminal, then destroy the old `vault-init.json` and update the
password-manager copy.

> Snapshots taken before a rekey are still restorable with the **new** shares —
> rekey does not change the master key, so it does not orphan backups.

## Generate a new root token

Root is revoked at the end of A6 (D10) and regenerated on demand. This is the
procedure that makes revocation safe rather than reckless.

**On Vault 2.x, `sys/generate-root` is authenticated** — so after root is revoked
you cannot even start this without the break-glass login. That identity can
*start* a root generation but not finish one: the three unseal shares are still
required. Two factors, and root never exists at rest.

```bash
# 1. Authenticate as break-glass (a 15-minute token)
export VAULT_TOKEN="$(vault write -field=token auth/userpass/login/breakglass \
    password=@$HOME/.credentials/vault-poc/breakglass-userpass.txt)"

# 2. Generate the one-time password and KEEP it — step 4 needs the same value.
#    Inlining it into -init with $(...) discards it, and the root token that
#    step 3 produces can then never be decoded.
OTP="$(vault operator generate-root -generate-otp)"

# 3. Start the attempt, then supply three shares
vault operator generate-root -init -otp="$OTP"   # note the nonce
vault operator generate-root -nonce=<nonce>      # x3, one per key share

# 4. Decode the encoded token returned after the third share
vault operator generate-root -decode=<encoded-token> -otp="$OTP"
```

**Exercise this once, while you still have a working root** (A6 exit gate). A
recovery path you have never walked is a hypothesis. Revoke the regenerated token
when the task that needed it is done.

### Last resort — break-glass lost as well

If the break-glass password is gone *and* root is revoked, there is no in-band
path. The shares still suffice, via an out-of-band config change:

1. Add `enable_unauthenticated_access = ["generate-root"]` to the Vault HCL in
   `helm/vault/values-onprem.yaml` — the Vault 2.0 key that restores 1.x
   behaviour. Confirm its exact placement against the 2.0 configuration docs.
2. Commit, let ArgoCD roll it out, and restart the pods (`OnDelete`). Each comes
   back **sealed** — unseal each one.
3. Generate root from the shares alone (steps 2–4 above, no login), then run
   `95-create-breakglass.sh --rotate` to restore a working break-glass.
4. **Remove the key again** and roll the pods once more. Leaving it set quietly
   reverses the owner's decision to keep generate-root authenticated.

Slow and disruptive by design. If you end up here, record in `key-custody.md`
how the password was lost.

---

## Auto-unseal — considered, not built

### Transit auto-unseal (Vault unsealing Vault)

Requires a second, separately-sealed Vault whose only job is the Transit engine.
The primary asks it to decrypt the master key at startup.

**It moves the problem rather than eliminating it** — the unsealer still needs
unsealing, by hand, with its own shares. The genuine win is at scale: N Vaults
and one unsealer. With one Vault it is strictly more machinery for the same
number of manual unseals.

Documented as a design note (A3 step 2). Not deployed.

### Cloud KMS auto-unseal

The usual production answer, and unavailable here: no cloud dependency on-prem,
and it introduces an external trust anchor that changes the DR story entirely —
your Vault becomes unrecoverable without a third party.

Backlog, tied to the Stage A v2 cloud expansion.

### Why manual, then

Manual unseal forces engagement with the seal lifecycle, which is the single most
operationally distinctive thing about Vault. Hiding it behind dev mode or a KMS
on day one means never learning the failure mode you will actually meet.

---

## Related

| Document | Covers |
|---|---|
| [`../environment.md`](../environment.md) | Addresses, node IPs, CA extraction |
| [`snapshot-restore.md`](snapshot-restore.md) | Backup, and what to do when unsealing is not enough |
| [`upgrade.md`](upgrade.md) | Version bumps — every upgrade seals every peer |
| `../../bootstrap/00-init-unseal.sh` | The scripted unseal |
