# Stage A bootstrap

Configures what lives *inside* Vault. The manifests one directory up deploy the
Vault process; nothing there can enable a secrets engine or write a policy,
because Vault has its own API and its own authorization language.

**Imperative and idempotent, by design (D9).** Not Terraform. The point of the
exercise includes understanding what `vault write auth/kubernetes/config`
actually does — the Terraform Vault provider is the right production answer and
is on the backlog, but wrapping the API on day one hides the surface being
learned. Every script is re-runnable: enables are guarded, writes replace by
name, and a second run should produce no errors and no drift (Rule 9).

## Start here

```bash
./preflight.sh              # add --pvc-test to also prove storage binds
```

Runs every Phase A0 check in one pass — the five hard blockers, the six
unverified values in `documents/environment.md`, and the three A0.5 Prometheus
questions that decide whether A9.4 is possible at all. Read-only. Exits non-zero
if anything would make a deploy fail, or silently do nothing.

It prints a paste-ready block for `environment.md` at the end.

## Prerequisites

On the Dev VM (`192.168.56.20`), with `vault`, `kubectl`, `jq`, `gpg`, `openssl`:

```bash
export VAULT_ADDR=https://192.168.56.241:8200      # MetalLB VIP (D8 primary)
export VAULT_CACERT=/etc/vault-poc/ca.crt          # CA that signed Vault's cert
```

Extract the CA from the cluster if you don't have it locally:

```bash
kubectl -n vault get secret vault-tls -o jsonpath='{.data.ca\.crt}' \
  | base64 -d | sudo tee /etc/vault-poc/ca.crt >/dev/null
```

`VAULT_SKIP_VERIFY` is rejected outright by `lib/common.sh`. A TLS failure means
a missing SAN or an unmounted CA — fix that (Rule 3). The node IPs are the usual
omission, which breaks the NodePort break-glass path precisely when it's needed.

If MetalLB is the thing that's broken, use the break-glass path instead:

```bash
export VAULT_ADDR=https://192.168.56.10:30004
```

## Run order

| # | Script | Phase | Notes |
|---|---|---|---|
| — | `preflight.sh` | A0 | **Run first.** Read-only; checks the cluster, not Vault. Exits non-zero on a hard blocker |
| 00 | `00-init-unseal.sh` | A2 | **Produces the unseal keys.** `--all-peers` for A4 |
| 10 | `10-enable-kubernetes-auth.sh` | A6 | Needs sync wave 0 to have applied |
| 20 | `20-apply-policies.sh` | A6 | Applies `20-policies/*.hcl`, binds roles |
| 30 | `30-enable-kv.sh` | A7 | KV v2 at `secret/` |
| 40 | `40-enable-database.sh` | A7 | **Rotates the Postgres admin password — one-way** |
| 50 | `50-seed-secrets.sh` | A7 | KV values + PGP keypair for Level 4 |
| 60 | `60-enable-audit.sh` | A9.1 | **Before Stage B** — audit is not retroactive |
| 70 | `70-verify-access.sh` | A6 | The negative tests. Exits non-zero on failure |
| 90 | `90-snapshot.sh` | A9.2 | Raft snapshot |
| 95 | `95-create-breakglass.sh` | A6 | **Vault 2.0 requires it.** `generate-root` is authenticated on 2.x, so once root is revoked this identity is the only way back. Creates it, then proves it |
| 99 | `99-revoke-root.sh` | A6 | **Last.** Preflights the whole bootstrap first — including a live break-glass login |

After `00`:

```bash
export VAULT_TOKEN="$(jq -r .root_token ~/.credentials/vault-poc/vault-init.json)"
```

## The two things most likely to bite

**The KV v2 path trap.** The CLI shows `secret/level1/app`; the API paths are
`secret/data/level1/app` (read) and `secret/metadata/level1/app` (list). A policy
written against the CLI-visible path applies without error and then denies
everything. Every file in `20-policies/` targets the API path — and
`70-verify-access.sh` includes a positive check specifically so a
deny-everything policy can't pass by denying the negative tests too.

**The reviewer JWT.** Vault reads `token_reviewer_jwt` once and never re-reads
it. A projected ServiceAccount token works perfectly until it rotates an hour
later, then fails with an error that says nothing about rotation. `10-` reads
from the `vault-reviewer-token` Secret, which isn't rotated, and warns if the
JWT carries an `exp`.

## Key custody (D20)

Unseal keys go to `~/.credentials/vault-poc/vault-init.json`, mode `0600`, in a
`0700` directory — **outside the repo tree**, asserted before anything is
written. In-repo plus `.gitignore` is not sufficient: `git clean -xfd` deletes
gitignored files by design, and `git add -f` bypasses `.gitignore` entirely.

Override the location with `VAULT_POC_KEYS`; the assertion still applies.

A **password-manager copy is owed** and is part of A2's exit gate, along with
actually restoring from it once. A backup you have never read from is a
hypothesis.

Snapshots land beside the keys (`VAULT_POC_SNAPSHOTS` to override) because a
snapshot is encrypted under the same seal — **snapshots and `vault-init.json`
are a matched pair, and losing either loses both.**

## Not in these scripts

- **The A7 revocation proof** — `psql` in, `vault lease revoke`, `psql` fails,
  `\du` shows the role gone. `40-` proves issuance and revokes its own test
  lease, but a revocation you haven't watched fail isn't proven.
- **The A9.3 restore drill** — destroy Vault including PVCs, redeploy, restore,
  unseal with the *original* shares. Its real output is a wall-clock number:
  your actual RTO.
- **`documents/environment.md`, `key-custody.md`, the runbooks** — written, not
  generated.
