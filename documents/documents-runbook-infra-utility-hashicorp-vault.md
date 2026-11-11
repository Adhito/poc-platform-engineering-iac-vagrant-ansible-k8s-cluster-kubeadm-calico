# Runbook index — HashiCorp Vault (`utility-hashicorp-vault`)

The entry point for everything under
[`script-manifest/utility-hashicorp-vault/`](../script-manifest/utility-hashicorp-vault/).
Each section says in a few lines what a part does, then links to the document that
has the detail. **Read this first; read the linked document before you act.**

---

## What it is

HashiCorp Vault on this cluster: **Stage A** of the
`poc-sre-app-golang-pattern-vault-hashicorp` POC. Stage A builds the secrets
*authority*: Vault itself, Kubernetes auth, policies, the KV and database
engines, audit, and External Secrets Operator. Stage B (the vault repo's Level 1–4
apps) consumes it later.

It is the one `script-manifest/` directory that **Ansible does not apply.**
ArgoCD deploys the Vault process from git, and the bootstrap shell scripts
configure what lives inside Vault. `vagrant provision` touches none of it.

| | |
|---|---|
| Vault | **2.0.4** (Helm chart 0.34.1), Raft storage, Shamir seal 5 shares / threshold 3 |
| Replicas | **1** (`vault-0` on `devnodeworker02`). Raising it to 3 is Phase A4, not yet done |
| Address | `https://192.168.56.241:8200`: MetalLB VIP, service `vault-lb`, primary |
| Break-glass address | `https://<any node IP>:30004`: NodePort, for when the VIP is down or Vault is sealed |
| CA | `vault-poc-ca`, from Secret `vault/vault-tls`; installed at `/etc/vault-poc/ca.crt` in the Dev VM |
| ArgoCD root app | `utility-hashicorp-vault` (from `argocd/root-platform.yaml`), 5 child apps |
| Namespaces | `vault`, `external-secrets`, `poc-hashicorp-vault-application` (PostgreSQL + Stage B) |

---

## Current status (2026-11-11)

| Phase | What | State |
|---|---|---|
| A0–A1 | Prerequisites (storage, cert-manager, namespaces), ArgoCD root app | ✅ Done; all apps Synced / Healthy |
| A2 | Init + unseal (`00`) | ✅ Done 2026-10-05 |
| A2 gate | Unseal using shares read from the password-manager copy | ✅ Passed 2026-11-11: `vault-0` restarted, unsealed with shares typed from the password manager |
| A6 | Kubernetes auth, policies, isolation tests, break-glass, root revoked | ✅ Done 2026-11-01 (`70` passed 10/10, `95` 9/9) |
| A7 | KV, dynamic Postgres credentials, revocation proof | ✅ Done 2026-11-01 |
| A9.1–A9.2 | Audit to stdout, first snapshot | ✅ Done 2026-11-01 |
| — | Operator logins: `snapshot-operator`, `platform-admin` (`96`) | ✅ Done 2026-11-11. Snapshots and team onboarding no longer need root |
| A9.3 | Restore drill and recovery time (RTO) | ⏳ **Open**. Unblocked: a fresh snapshot exists (2026-11-11) |
| A4 | Scale to 3 replicas | ⏳ Not started |
| A9.4 | Automated seal alert | ⛔ Parked: no Prometheus Operator CRDs on this cluster |

**Day-to-day identities.** `breakglass` may only start `generate-root` and `rekey`.
For routine work, `96-create-operators.sh` adds `snapshot-operator` (save snapshots,
used by `90`) and `platform-admin` (onboard teams, used by `80`). Anything else still
needs a root token from `generate-root`, revoked again afterwards.

The custody event log (who did what, when; never key material) is the register at
the bottom of [`key-custody.md`](../script-manifest/utility-hashicorp-vault/documents/key-custody.md).

---

## Where to run things

| Machine | Used for |
|---|---|
| **Dev VM** (`learning-labs-developer-workspace-type-01`, `vagrant ssh` from that project) | **All** `vault` commands and bootstrap scripts. The repo is mounted at `~/workspace-app/poc-platform-engineering-iac-vagrant-ansible-k8s-cluster-kubeadm-calico`, a live view of the Windows working tree, so the branch checked out on Windows decides which script versions run |
| **Windows (Git Bash)** at the repo root | git, `vagrant` for the cluster nodes, `kubectl --kubeconfig configs/config`, and `clip.exe < file` to copy secrets into the password manager without displaying them. Never run the bootstrap scripts here: they need Linux `curl` and paths, and the default `~/.kube/config` on this host points at an unrelated EKS cluster |

Dev VM session setup. Re-run it after every login; nothing below survives a logout:

```bash
cd ~/workspace-app/poc-platform-engineering-iac-vagrant-ansible-k8s-cluster-kubeadm-calico
export VAULT_ADDR=https://192.168.56.241:8200
export VAULT_CACERT=/etc/vault-poc/ca.crt
export VAULT_POC_KEYS="$HOME/workspace-app/poc-platform-engineering-iac-vagrant-ansible-k8s-cluster-kubeadm-calico/.credentials/vault-poc"
```

Root is revoked, so admin work starts with the break-glass login. It prints nothing:

```bash
export VAULT_TOKEN="$(vault write -field=token auth/userpass/login/breakglass \
    password=@"$VAULT_POC_KEYS/breakglass-userpass.txt")"
```

Developers who only need the CLI: see *developer-setup.md* in the table below.

---

## Map of the folder

### Top level: [`README.md`](../script-manifest/utility-hashicorp-vault/README.md)

The manifests and how they are delivered:
- why Stage A lives in this repo rather than the vault repo, a deliberate deviation from the PRD;
- the Phase A0 prerequisite checklist;
- the ArgoCD sync waves.

**Open it for** deploying or redeploying the platform, or to understand how the folder is laid out.

### `argocd/`: GitOps wiring

- **`root-platform.yaml`:** the app-of-apps root, applied once by hand.
- **`applications/`:** the five children, synced in waves:
  - wave 0: `vault-extras` (TLS cert, reviewer token, Services);
  - wave 1: `vault` (the Helm chart);
  - wave 3: `external-secrets` and `postgres`;
  - wave 4: `external-secrets-store`.
- **`disabled/`:** parked apps. Today that is only `vault-monitoring`, parked for the reason in
  [`disabled/README.md`](../script-manifest/utility-hashicorp-vault/argocd/disabled/README.md).

**Never rename or delete a live app here:** its finalizer cascade-deletes Vault.

### `base/` + `overlays/onprem/` + `helm/vault/`: the manifests

- **`base/`:** environment-neutral structure: namespaces, cert-manager issuers, Vault extras,
  ESO store, PostgreSQL, monitoring.
- **`overlays/onprem/`:** this cluster's values, such as the pinned VIP `.241`, node IPs in the
  certificate SANs, and the StorageClass.
- **`helm/vault/values-onprem.yaml`:** the Vault server configuration (HCL, Raft,
  `OnDelete` updates, replica count).

Details are in the top-level README and *architecture.md*.

### `bootstrap/`: configuring what is *inside* Vault

A set of numbered shell scripts. Each one is idempotent and safe to re-run, and they run in
order from the **Dev VM**. The manifests deploy the process; these scripts enable engines,
write policies and roles, seed secrets, and turn on audit, because Vault has its own API
that Kubernetes objects can't express.

| Script | Does |
|---|---|
| `preflight.sh` | Read-only readiness check of the cluster (Phase A0) |
| `00-init-unseal.sh` | Initialises Vault and writes the unseal shares to `vault-init.json`. Re-run it to unseal (`--all-peers` for every pod) |
| `10`–`20` | Kubernetes auth and the policies and roles in `20-policies/*.hcl` |
| `30`–`50` | KV v2, the dynamic PostgreSQL credentials engine, seeded secrets and the Level 4 PGP key |
| `60` | Audit device (stdout) |
| `70-verify-access.sh` | The isolation tests: proves each app can read only its own level |
| `80-onboard-team.sh` | Onboards another team (policy, Kubernetes auth role and KV path, all `team-<name>`) without root. `--verify` checks nobody has widened a team's access |
| `85-rekey.sh` | Replaces the unseal shares **without printing them**. The old shares stay valid until the new ones are verified |
| `90-snapshot.sh` | Raft snapshot, saved beside the keys |
| `95-create-breakglass.sh` | Creates the `breakglass` recovery login that Vault 2.x needs, and proves it works |
| `96-create-operators.sh` | Creates the `snapshot-operator` and `platform-admin` logins and proves exactly what each can and can't do. Needs a regenerated root, once |
| `99-revoke-root.sh` | Checks the whole bootstrap, then revokes the root token. Already run |

**Full run order, prerequisites, guards and the KV path trap:**
[`bootstrap/README.md`](../script-manifest/utility-hashicorp-vault/bootstrap/README.md).

### `documents/`: design and reference

| Document | Covers | Open it when |
|---|---|---|
| [`architecture.md`](../script-manifest/utility-hashicorp-vault/documents/architecture.md) | Topology, the Kubernetes auth handshake, trust boundaries, the two exposure paths, storage limits, what was deliberately not built | You need to understand *why* it is built this way |
| [`environment.md`](../script-manifest/utility-hashicorp-vault/documents/environment.md) | Verified live values: IPs, VIP, versions, StorageClass, registry, OIDC issuer, host-network quirks. Also measurements still owed (RTO, failover) | You need a value. **Never hardcode one; read it from here** |
| [`developer-setup.md`](../script-manifest/utility-hashicorp-vault/documents/developer-setup.md) | Installing the `vault` 2.0.4 CLI and CA on the Dev VM, and checking the connection | A new developer, or a rebuilt Dev VM |
| [`key-custody.md`](../script-manifest/utility-hashicorp-vault/documents/key-custody.md) | How the unseal shares and break-glass password are held, the accepted risks of keeping them in the repo, what to do after a leak or loss, and the **event register** | Anything touching the keys, and after every custody event |
| [`licensing.md`](../script-manifest/utility-hashicorp-vault/documents/licensing.md) | Vault's BUSL 1.1 licence, the OpenBao alternative, and an organisation-policy check still outstanding | Before any non-lab use |

### `documents/runbooks/`: procedures

| Runbook | Covers | Open it when |
|---|---|---|
| [`seal-unseal.md`](../script-manifest/utility-hashicorp-vault/documents/runbooks/seal-unseal.md) | Sealing explained; detecting it; unsealing over the VIP or NodePort; rekeying; regenerating root via break-glass; the last-resort path if break-glass is lost | `vault status` says `Sealed true`, after any pod or node restart, or a key is exposed |
| [`snapshot-restore.md`](../script-manifest/utility-hashicorp-vault/documents/runbooks/snapshot-restore.md) | Taking and restoring Raft snapshots, and the A9.3 drill | Before an upgrade or destructive change, or Vault data is lost |
| [`upgrade.md`](../script-manifest/utility-hashicorp-vault/documents/runbooks/upgrade.md) | Version bumps: one pod at a time (`OnDelete`); each pod comes back sealed; no downgrades | Bumping Vault, the chart, ESO or cert-manager |

---

## Lessons learned the hard way

Each one cost time on this cluster. Details are in the linked documents.

**Keys and recovery**
- **Debugging in chat is how keys leak.** On 2026-11-01 all five shares appeared
  in a screenshot and one share was pasted into an assistant chat. The fix was a
  same-day `85-rekey.sh`. Share command *output*, never `vault-init.json` or the
  terminal around it. *(key-custody.md)*
- **Use the `unseal_keys_b64` entries, a different one each time.** Re-entering a share
  gives "given key has already been provided". Never mix in the `_hex` list.
  *(seal-unseal.md)*
- **`generate-root` needs the same shell from start to finish.** The OTP lives in a
  shell variable, so logging out loses it. Then cancel the orphaned attempt
  (`vault operator generate-root -cancel`, as break-glass) and start again.
  *(seal-unseal.md)*

**Networking**
- **A sealed Vault is unreachable on the VIP.** `vault-lb` only routes to the
  active pod. Unseal through the NodePort `:30004`. *(seal-unseal.md)*
- **`1/1 Running` does not mean unsealed.** The readiness probe counts a sealed pod
  as ready (`sealedcode=204`), so only `vault status` tells you. *(seal-unseal.md)*
- **The break-glass token can't look itself up or revoke itself.** It has no `default`
  policy, so a `403` on `token lookup` is expected. Test it with
  `vault operator generate-root -status`. *(seal-unseal.md)*
- **The host network drops UDP DNS.** CoreDNS was switched to TCP upstreams by a
  live hotfix that is not in code (backlog #5). If ESO or ArgoCD start failing on name
  resolution after a cluster rebuild, check this first. *(environment.md)*
- **A resume that ends in `aborted-saved` is not a dead node.** The Windows hypervisor
  came back on. Switch it off, then `VBoxManage startvm` each such VM. Vault stays
  unsealed because the saved memory is restored. Never discard the saved state.
  *([DOCUMENTS-runbook-node-recovery.md](DOCUMENTS-runbook-node-recovery.md))*
- **MetalLB must advertise on `eth1`.** ARP on the NAT interface `eth0` exhausted
  VirtualBox's NAT and cut the master off. Fixed in `addon_metallb` (PR #22).
  *(environment.md)*

**PostgreSQL and access tests**
- **Dynamic Postgres users need `REVOKE ALL` before `DROP ROLE`**, or revocation
  silently leaves the role behind. A lease that failed repeatedly is marked
  irrevocable; clear it with `vault lease revoke -force -prefix <lease>`.
  *(bootstrap/README.md)*
- **Postgres trusts connections from the pod itself (`127.0.0.1`).** A password test from
  inside the pod proves nothing; connect to the pod IP. *(bootstrap/README.md)*
- **A negative test must fail for the right reason.** `70` accepts only the role
  binding's "not authorized" denial. An "invalid role name" error used to pass by accident.
  *(bootstrap/README.md)*

---

## Hard rules

- **Never run `git clean -xfd` or `git clean -X` in this repo.** The unseal shares,
  break-glass password and snapshots live in the gitignored `.credentials/vault-poc/`.
  Losing the shares makes Vault *and every snapshot* unrecoverable.
- **Never `git add -f`** anything under `.credentials/`.
- **Never print, paste or screenshot** `vault-init.json`, a share, a token or the
  break-glass password. If one leaks: run `85-rekey.sh` (or `95-create-breakglass.sh --rotate`) the
  same day, and record the event in `key-custody.md`.
- **Snapshots and `vault-init.json` are a matched pair.** Back up and restore them
  together.
- **Teams get `team-*` access only through `80-onboard-team.sh`**, never a hand-written
  policy. Run `80-onboard-team.sh --verify` after any change. Team secrets are DEV values
  the team can recreate: no production credentials.
- **Never `VAULT_SKIP_VERIFY`.** A TLS error means a missing SAN or the wrong CA;
  fix that instead.

---

## Open items

| Item | Where |
|---|---|
| Settle the BUSL licence question before opening Vault to other teams | [`licensing.md`](../script-manifest/utility-hashicorp-vault/documents/licensing.md) |
| A9.3 restore drill, recording the RTO | [`snapshot-restore.md`](../script-manifest/utility-hashicorp-vault/documents/runbooks/snapshot-restore.md) |
| A4: 3 replicas, failover time, which worker hosts two peers | [`environment.md`](../script-manifest/utility-hashicorp-vault/documents/environment.md) → Measurements |
| A human (developer) login method | [`DOCUMENTS-backlog.md`](DOCUMENTS-backlog.md) #4 |
| Make the CoreDNS TCP fix permanent; fix node DNS | [`DOCUMENTS-backlog.md`](DOCUMENTS-backlog.md) #5 |
| ESO 2.11.0's support window is about 3 weeks; bump deliberately | [`upgrade.md`](../script-manifest/utility-hashicorp-vault/documents/runbooks/upgrade.md) |
| Cosmetic: `00-init-unseal.sh` prints `HA mode : n/a` | — |
