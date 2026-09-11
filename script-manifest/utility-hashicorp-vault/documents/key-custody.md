# Key custody

Phase A2 exit-gate deliverable (D20).

This records **the method, and who holds it.** It does not record where anything
is, and it will never contain a key share.

---

## A note on what "not the location" means here

The *path convention* — `${VAULT_POC_KEYS:-$HOME/.credentials/vault-poc}` — is
public. It has to be: it is a default in `00-init-unseal.sh`, and it appears in
the bootstrap README and the seal/unseal runbook. A convention that operators
cannot look up is not a convention.

What is **not** written down, here or anywhere:

- which physical machine holds the primary copy
- which password manager, which vault within it, which account
- any share, any fragment of a share, or the root token
- anything from which the above could be reconstructed

So: *"a file on the operator's workstation, outside the repo tree"* is method.
*"the laptop on the third desk, in the Ops vault of <product>"* is location, and
belongs in nobody's git history.

---

## What is in custody

`vault operator init` emitted the first two once, and they cannot be regenerated.
The third exists because Vault 2.0 made root recovery an authenticated operation:

| Item | Count | Status |
|---|---|---|
| Unseal key shares | 5, threshold 3 | **Live — the thing that matters** |
| Initial root token | 1 | Revoked at the end of Phase A6 (D10) |
| Break-glass password (`userpass/breakglass`) | 1 | **Live** — created by `bootstrap/95-create-breakglass.sh` |

After A6, `vault-init.json`'s remaining value is **purely the five shares**. The
root token entry is dead weight; leave it rather than editing the file.

**Why the break-glass password is in custody at all.** On Vault 2.x,
`sys/generate-root` requires authentication. Once root is revoked, logging in as
`breakglass` is the only in-band way to *start* regenerating it — the shares are
still needed to *finish*. Recovery therefore needs both, and losing the password
is as serious as losing the working copy of the shares. It lives beside
`vault-init.json` (`breakglass-userpass.txt`, mode `0600`) and belongs in the same
password-manager note.

**What it does not add:** separation of duty. The same person holds the password
and all five shares, so this is two factors held by one holder — a real gain
against a single leaked file, none against a compromised holder.

> **Snapshots and shares are a matched pair.** A Raft snapshot is encrypted under
> the seal of the cluster it came from. Without these shares it is an unopenable
> blob. Losing either loses both — which means backup verification covers *both
> halves*, not just the file. See [`runbooks/snapshot-restore.md`](runbooks/snapshot-restore.md).

---

## The method

### Primary copy

A single JSON file on the operator's workstation, **outside the repository
tree**, mode `0600` inside a `0700` directory. `00-init-unseal.sh` resolves the
directory, creates it with those modes, and **asserts the resolved path is
outside the repo, aborting if it is not** — so the guard is mechanical, not a
matter of remembering.

### Second copy

The full contents pasted into a password-manager secure note, by hand, once, at
init time.

This exists to cover what a single workstation cannot: disk failure, OS
reinstall, lost or stolen laptop. Those are the realistic loss events here — not
an attacker, but an accident.

### Why not the alternatives

Each of these was considered and rejected for a specific reason, which is worth
keeping because "it seemed safer" is how they come back.

| Rejected | Why |
|---|---|
| **In-repo + `.gitignore`** | Survives `vagrant destroy`, but **`git clean -xfd` deletes gitignored files by design** — that is what `-x` means, and it is exactly the command reached for when resetting a working tree. `git add -f` bypasses `.gitignore` entirely. Two silent failure modes, removed at zero cost by moving one directory up |
| **Dev VM only** | Destroyed by a routine `vagrant destroy` — an operation this project performs deliberately and often |
| **In the cluster** | Circular. The keys are what you need in order to reach the thing that would be holding them |
| **Split across five holders** | The correct production answer. Disproportionate for a solo lab — see below |

---

## Holders

| Role | Holds | Notes |
|---|---|---|
| Adhito — SRE, repository owner | Primary copy + password-manager copy | Sole holder |
| _(none)_ | — | No second person currently holds any share |

> **Update this table when it stops being true**, and treat a change of holder as
> a rekey trigger rather than a handover of files.

---

## What this scheme does not provide

**Separation of duty. One person holds all five shares.**

The 5-of-3 split therefore buys *redundancy* — three shares are enough, so
corruption of one or two is survivable — and **not** split custody. Nobody is
prevented from unsealing alone, because there is nobody else.

This is worth stating plainly because a 5/3 split *looks* like a ceremony. If
this document said only "5 shares, threshold 3", a reader would reasonably
assume five holders and a quorum, and that assumption would be wrong.

---

## The production alternative, deliberately not done

Five shares distributed to **five separate holders**, threshold three:

- No single person can unseal alone; any three must convene
- Shares held offline — paper, HSM, or hardware token, not a file
- Distribution recorded and witnessed at a key ceremony
- Rekey on any holder change, with the ceremony repeated
- Root token regenerated per use and revoked immediately after

That is what the 5/3 split is *for*. It is not being done here.

## Why that trade is proportionate

**Nothing in this POC is irreplaceable:**

- KV secrets are re-seeded by `50-seed-secrets.sh`
- Database credentials are generated on demand and expire anyway
- The PGP keypair is regenerable — the only cost is re-encrypting the Level 4
  fixture and re-shipping it
- The cluster itself is reproducible from Vagrant, Ansible, git, and the
  bootstrap scripts

So **key loss costs hours of rebuild, not data.** A second copy is right-sized
against that. A key ceremony is not — it would be security theatre performed by
one person, which teaches the wrong lesson about proportionality.

**This reasoning does not transfer.** The moment anything in Vault becomes
genuinely unrecoverable, this scheme is inadequate and the production
alternative above becomes the requirement.

---

## Obligations

### Before Phase A2 can close

- [ ] Password-manager copy created
- [ ] **Restore verified**: seal a node and unseal it using a share retrieved
      from the password-manager copy — *not* the working file
- [ ] This document completed (holders table filled)

> **A backup you have never read from is a hypothesis.** The verification step
> is the one that turns "I have a copy" into "I have a copy that works", and it
> is the step most often skipped because it feels redundant at the moment you
> would do it.

### Ongoing

| When | Do |
|---|---|
| After any rekey | Replace both copies; destroy the superseded ones |
| On holder change | Rekey — do not hand over files |
| Every 6 months | Re-verify the second copy is readable and current |
| Before any upgrade | Confirm shares are to hand — every upgraded pod comes back sealed |

---

## Lifecycle events

| Event | Action |
|---|---|
| **Share exposed** (pasted in chat, committed, screenshotted) | `vault operator rekey` immediately. The master key is unchanged, so snapshots remain restorable with the new shares |
| **Holder leaves / laptop lost** | Rekey. Assume the old shares are compromised |
| **Password-manager copy is stale after a rekey** | Replace it the same day. A stale second copy is worse than none — it will be trusted at the exact moment it fails |
| **Primary copy lost, second copy intact** | Restore from the second copy, then create a fresh primary. Consider rekeying if the loss was not clean |
| **Both copies lost** | The cluster is unrecoverable — snapshots included. Rebuild from scratch: redeploy, `operator init`, re-run the bootstrap scripts. This is the accepted worst case, and it costs hours |
| **Root token needed again** | Log in as `breakglass`, then `vault operator generate-root` with three shares — Vault 2.x requires both. Revoke the new root when the task is done — see [`runbooks/seal-unseal.md`](runbooks/seal-unseal.md) |
| **Break-glass password lost, root still live** | `95-create-breakglass.sh --rotate` using the root token. Nothing is locked out yet — fix it before root is revoked |
| **Break-glass password lost AND root revoked** | No in-band way back. Use the last-resort procedure in [`runbooks/seal-unseal.md`](runbooks/seal-unseal.md): temporarily set `enable_unauthenticated_access`, generate root from the shares, rotate break-glass, remove the key again |
| **Break-glass password exposed** | `95-create-breakglass.sh --rotate` immediately. Alone it cannot produce a root token — the shares are still required — but it is half of the recovery pair |

---

## Register

Record custody events here. **Events only — never contents.**

| Date | Event | Performed by | Verified |
|---|---|---|---|
| ______ | `operator init` — 5 shares / threshold 3 | ______ | — |
| ______ | Password-manager copy created | ______ | ______ |
| ______ | Restore verified from second copy (A2 gate) | ______ | ______ |
| ______ | Break-glass identity created and verified (`95-`) | ______ | ______ |
| ______ | Break-glass password added to the password-manager note | ______ | ______ |
| ______ | Root token revoked (A6, D10) | ______ | ______ |
| ______ | `generate-root` exercised once, via break-glass (A6 gate) | ______ | ______ |

---

## Not recorded here

- Key shares, root tokens, or any fragment of either
- Which machine, which password manager, which vault, which account
- Snapshot contents or their location beyond "beside the keys"

If you are about to add any of the above to this file: that is the failure mode
this document exists to prevent. `.gitignore` will not save you — it does not
cover `key-custody.md`, because this file is *meant* to be committed.

---

## Related

| Document | Covers |
|---|---|
| [`runbooks/seal-unseal.md`](runbooks/seal-unseal.md) | Using the shares; rekey and generate-root procedures |
| [`runbooks/snapshot-restore.md`](runbooks/snapshot-restore.md) | Why shares and snapshots are a matched pair |
| [`environment.md`](environment.md) | Cluster facts and outstanding A0 values |
| [`../bootstrap/00-init-unseal.sh`](../bootstrap/00-init-unseal.sh) | The script that enforces the outside-the-repo guard |
