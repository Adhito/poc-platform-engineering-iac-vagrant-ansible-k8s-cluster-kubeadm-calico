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

> Setting up the CLI for the first time? The step-by-step version, with checks and
> troubleshooting, is [`../documents/developer-setup.md`](../documents/developer-setup.md).

On the Dev VM (`192.168.56.20`), with `vault`, `kubectl`, `jq`, `gpg`, `openssl`.
**Not from Windows Git Bash.** Its `curl` can't read the `<(...)` process substitution
that `85-` uses to keep the token out of the process list, and its default kubeconfig
is not this cluster. Run the scripts from the repo root with their full path, for example
`./script-manifest/utility-hashicorp-vault/bootstrap/70-verify-access.sh`:

```bash
cd ~/workspace-app/poc-platform-engineering-iac-vagrant-ansible-k8s-cluster-kubeadm-calico
export VAULT_ADDR=https://192.168.56.241:8200      # MetalLB VIP (D8 primary)
export VAULT_CACERT=/etc/vault-poc/ca.crt          # CA that signed Vault's cert
# Keys in this repo's gitignored .credentials/ folder (on the Windows host, via the
# Dev VM's shared folder). See documents/key-custody.md for the accepted risks.
export VAULT_POC_KEYS="$HOME/workspace-app/poc-platform-engineering-iac-vagrant-ansible-k8s-cluster-kubeadm-calico/.credentials/vault-poc"
```

The `vault` CLI must match the server (2.0.4). Install the release binary, checksum-verified:

```bash
cd /tmp && curl -fsSLO https://releases.hashicorp.com/vault/2.0.4/vault_2.0.4_linux_amd64.zip \
  && curl -fsSL https://releases.hashicorp.com/vault/2.0.4/vault_2.0.4_SHA256SUMS | grep linux_amd64 | sha256sum -c - \
  && unzip -o vault_2.0.4_linux_amd64.zip vault && sudo install -m 0755 vault /usr/local/bin/vault && vault version
```

Extract the CA from the cluster if you don't have it locally:

```bash
kubectl -n vault get secret vault-tls -o jsonpath='{.data.ca\.crt}' \
  | base64 -d | sudo tee /etc/vault-poc/ca.crt >/dev/null
```

`VAULT_SKIP_VERIFY` is rejected outright by `lib/common.sh`. A TLS failure means
a missing SAN or an unmounted CA — fix that (Rule 3). The node IPs are the usual
omission, which breaks the NodePort break-glass path precisely when it's needed.

**Run `00-init-unseal.sh` through the break-glass path.** The VIP above only routes
to the *active* (unsealed, leading) pod, and an uninitialised or fully sealed Vault
has none. Until `00` has run, `192.168.56.241` answers `no route to host`. The NodePort
reaches every Vault pod, sealed or not:

```bash
export VAULT_ADDR=https://192.168.56.10:30004      # any node IP — all are in the cert SANs
./00-init-unseal.sh
export VAULT_ADDR=https://192.168.56.241:8200      # back to the VIP once Vault is active
```

Use the same NodePort address whenever MetalLB itself is broken.

## Run order

| # | Script | Phase | Notes |
|---|---|---|---|
| — | `preflight.sh` | A0 | **Run first.** Read-only; checks the cluster, not Vault. Exits non-zero on a hard blocker |
| 00 | `00-init-unseal.sh` | A2 | **Produces the unseal keys.** `--all-peers` for A4 |
| 10 | `10-enable-kubernetes-auth.sh` | A6 | Needs sync wave 0 to have applied |
| 20 | `20-apply-policies.sh` | A6 | Applies `20-policies/*.hcl`, binds roles. The ESO `ClusterSecretStore` stays Degraded until this runs, and then took ~7 min to turn Healthy (2026-11-01). Wait for it before assuming a fault |
| 30 | `30-enable-kv.sh` | A7 | KV v2 at `secret/` |
| 40 | `40-enable-database.sh` | A7 | **Rotates the Postgres admin password — one-way** |
| 50 | `50-seed-secrets.sh` | A7 | KV values + PGP keypair for Level 4 |
| 60 | `60-enable-audit.sh` | A9.1 | **Before Stage B** — audit is not retroactive |
| 70 | `70-verify-access.sh` | A6 | The negative tests. Exits non-zero on failure |
| 80 | `80-onboard-team.sh` | as needed | Onboard another team: `team-<name>` policy (read `secret/teams/<name>/*`) and Kubernetes auth role bound to its namespace + ServiceAccounts. Runs as `platform-admin`. `--verify` diffs every `team-*` policy and role against the template. Run it after any change |
| 85 | `85-rekey.sh` | as needed | Replace the unseal shares (exposed share, holder change). New shares are written to `vault-init.json`, never printed; old shares stay valid until the new ones are verified from the saved file. `--prompt` to type the current shares |
| 90 | `90-snapshot.sh` | A9.2 | Raft snapshot |
| 95 | `95-create-breakglass.sh` | A6 | **Vault 2.0 requires it.** `generate-root` is authenticated on 2.x, so once root is revoked this identity is the only way back. Creates it, then proves it |
| 96 | `96-create-operators.sh` | after 99 | **Needs a regenerated root, once.** Creates and proves `snapshot-operator` (save-only snapshots, used by `90`) and `platform-admin` (`team-*` onboarding, used by `80`). Passwords go beside the keys |
| 99 | `99-revoke-root.sh` | A6 | **Last.** Preflights the whole bootstrap first — including a live break-glass login |

After `00`, and until `99`:

```bash
export VAULT_TOKEN="$(jq -r .root_token $VAULT_POC_KEYS/vault-init.json)"
```

All of these environment variables, the token included, are lost when you log out of the Dev VM.
Re-run the block after every login.

## After 99 — which token now

**`99` ran on 2026-11-01: the root token is revoked**, and the `root_token` field in
`vault-init.json` is dead. Leave it there. The only human identity is `breakglass`:

```bash
export VAULT_TOKEN="$(vault write -field=token auth/userpass/login/breakglass \
    password=@"$VAULT_POC_KEYS/breakglass-userpass.txt")"
```

Its policy (`20-policies/breakglass-admin.hcl`) covers **only** `sys/generate-root/*`
and `sys/rekey/*`. That's enough for `85-rekey.sh`.

Two narrower identities cover routine work. `96-create-operators.sh` creates them,
once, with a regenerated root:

| Identity | Can | Used by |
|---|---|---|
| `snapshot-operator` | Save a Raft snapshot (not restore) | `90-snapshot.sh`, which logs in as it by itself when no working token is set |
| `platform-admin` | Write `team-*` policies and roles; write (not read) `secret/teams/*` | `80-onboard-team.sh`, same automatic login |

Everything else still needs a root token regenerated from three shares, then revoked
again: [`../documents/runbooks/seal-unseal.md`](../documents/runbooks/seal-unseal.md) →
*Generate a new root token*. That covers re-running `10`–`70` and `96`, restoring a
snapshot, and the A9.3 drill.

> **`platform-admin` is close to admin-equivalent.** Anyone who can write a policy and a
> role can grant themselves more, and Vault Community can't restrict what a policy
> says. `80-onboard-team.sh --verify` is the control: it flags any `team-*` policy that
> differs from the template, and any `team-*` role carrying another policy or a
> wildcard. See the header of `20-policies/platform-admin.hcl`.

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

Unseal keys go to `$VAULT_POC_KEYS/vault-init.json` (default
`$VAULT_POC_KEYS`). **On this project, `VAULT_POC_KEYS` is the repo's own
gitignored `.credentials/vault-poc/`** (the owner's decision, 2026-10-05; see
[`../documents/key-custody.md`](../documents/key-custody.md)).

Before anything is written, `assert_keys_path_safe` checks that the path is either
outside the repo, or inside it but **gitignored and untracked**. Otherwise it refuses.
That guarantees the keys can't be committed by an ordinary `git add`. It can't protect
against these, so treat them as rules:

- **Never run `git clean -xfd` (or `-X`) in this repo.** It deletes ignored files, the
  unseal keys included.
- **Never `git add -f`** anything under `.credentials/`.

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
  **Done 2026-11-01. It found a real bug.** What it taught:
  - **The role survived revocation.** `DROP ROLE` fails while the role still holds
    grants, and Vault reports nothing to the client: it retries in the background and
    eventually marks the lease *irrevocable*. `40-`'s `revocation_statements` now run
    `REVOKE ALL ... ; DROP ROLE ...`, and `40-` checks `pg_roles` after revoking its
    own test lease. Clear an already-stuck lease with
    `vault lease revoke -force -prefix <lease-id>`.
  - **Test the password over the pod IP, not `127.0.0.1`.** `pg_hba` trusts local
    connections, so any password "works" there. Connect with
    `psql -h "$(hostname -i)"` inside the pod, and include a wrong-password control
    so you can tell that the server actually checks passwords.
- **Why `70-` checks the denial's wording.** A negative test that passes on *any*
  error proves nothing. Vault 2.0.4 answers a wrong ServiceAccount with
  403 `service account name not authorized`. A wrong role name gets
  400 `invalid role name`, which also "denies", but for a reason that says nothing about
  isolation. `70-` accepts only the first, and reports anything else as inconclusive.
- **The A9.3 restore drill** — destroy Vault including PVCs, redeploy, restore,
  unseal with the *original* shares. Its real output is a wall-clock number:
  your actual RTO.
- **`documents/environment.md`, `key-custody.md`, the runbooks** — written, not
  generated.
