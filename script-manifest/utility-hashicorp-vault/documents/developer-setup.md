# Developer setup — using Vault from the Dev VM

How to get a working `vault` CLI on the Dev VM and talk to this cluster's Vault over
verified TLS. Written for a developer joining the project. It takes about five
minutes.

**This guide never initialises, unseals, or re-keys anything.** That's a one-time
operator task, already done. If `vault status` says `Initialized false` or `Sealed true`,
stop and tell the operator ([Troubleshooting](#troubleshooting)). Don't run
`00-init-unseal.sh` yourself.

---

## What you get

| | |
|---|---|
| Vault server | **2.0.4**, 3-peer-ready Raft, TLS from the cluster's own CA |
| Address (normal) | `https://192.168.56.241:8200`: MetalLB VIP, service `vault-lb` |
| Address (break-glass) | `https://192.168.56.10:30004` (any node IP): NodePort `vault-nodeport`, for when MetalLB is broken |
| CA certificate | `vault-poc-ca`, published by cert-manager in Secret `vault/vault-tls` |
| Where you run it | The **Dev VM** (`learning-labs-developer-workspace-type-01`), which already has `kubectl` for this cluster |

These values come from [`environment.md`](environment.md). If they change, that file
is updated first.

---

## Before you start

- [ ] The Dev VM is up, and you can `vagrant ssh` into it from its project folder.
- [ ] `kubectl get nodes` works **inside the Dev VM**, with three nodes `Ready`.
      If it fails with `x509: certificate signed by unknown authority`, the cluster was
      rebuilt and your kubeconfig is stale. Run the observability repo's
      `scripts/utility-node-registry-recovery.sh` (it refreshes the kubeconfig), or ask
      the platform team.
- [ ] `curl`, `unzip`, `openssl` and `jq` are present (they are on the standard Dev VM).

Everything below runs **inside the Dev VM**:

```bash
# on Windows (Git Bash)
cd "/c/Programming-Repository/Github - Adhito909/learning-labs-developer-workspace-type-01"
vagrant ssh
```

---

## 1. Install the `vault` CLI (match the server: 2.0.4)

Use the official release binary and **verify its checksum** before installing:

```bash
cd /tmp \
  && curl -fsSLO https://releases.hashicorp.com/vault/2.0.4/vault_2.0.4_linux_amd64.zip \
  && curl -fsSL https://releases.hashicorp.com/vault/2.0.4/vault_2.0.4_SHA256SUMS \
       | grep linux_amd64 | sha256sum -c - \
  && unzip -o vault_2.0.4_linux_amd64.zip vault \
  && sudo install -m 0755 vault /usr/local/bin/vault \
  && vault version
```

Expected: `vault_2.0.4_linux_amd64.zip: OK`, then `Vault v2.0.4 ...`.

**If `sha256sum` doesn't print `OK`, stop.** Don't install the binary. Re-download it,
and if it still fails, report it.

> **Why pin the version?** The CLI talks to the server's API, and some commands
> changed between 1.x and 2.x. In particular, `generate-root` and `rekey` are
> authenticated on 2.x. Matching the server avoids confusing errors. When the server is
> upgraded (see [`runbooks/upgrade.md`](runbooks/upgrade.md)), change the version in
> both URLs above.

## 2. Install Vault's CA certificate

Vault serves TLS with a certificate from the cluster's private CA. Your CLI needs that
CA to verify the connection:

```bash
sudo mkdir -p /etc/vault-poc
kubectl -n vault get secret vault-tls -o jsonpath='{.data.ca\.crt}' \
  | base64 -d | sudo tee /etc/vault-poc/ca.crt >/dev/null
openssl x509 -in /etc/vault-poc/ca.crt -noout -subject -enddate
```

Expected: `subject=CN = vault-poc-ca` and an end date years away.

This file is the CA's **public** certificate, not a secret, so it's fine to copy it
around.

## 3. Set the environment, permanently

Write the settings to a small file and load it from your shell profile, so every new
shell has them:

```bash
cat > ~/.vault-poc.env <<'EOF'
# Vault (utility-hashicorp-vault) - see script-manifest/utility-hashicorp-vault/documents/developer-setup.md
export VAULT_ADDR=https://192.168.56.241:8200
export VAULT_CACERT=/etc/vault-poc/ca.crt
EOF
grep -q 'vault-poc.env' ~/.bashrc || echo '[ -f ~/.vault-poc.env ] && . ~/.vault-poc.env' >> ~/.bashrc
. ~/.vault-poc.env
```

**Never add any of these to that file:**
- `VAULT_SKIP_VERIFY=true`. It turns off TLS verification. The bootstrap scripts refuse
  to run with it set (Rule 3). A TLS error is a real problem to fix, not to bypass.
- `VAULT_TOKEN=...`. A token in a dotfile outlives its purpose and leaks into backups.
  Log in per session instead (step 5).

## 4. Verify

```bash
vault status
```

Healthy output looks like this:

```
Seal Type               shamir
Initialized             true
Sealed                  false
Version                 2.0.4
Storage Type            raft
HA Enabled              true
```

`vault status` needs no login. If you get this far with `Sealed false`, your CLI, CA and
network are all correct.

To check the break-glass path as well:

```bash
VAULT_ADDR=https://192.168.56.10:30004 vault status
```

## 5. Getting access (logging in)

> **Not available yet for humans.** As of 2026-10-05, Vault has no developer login
> method. It has:
> - **Kubernetes auth roles for workloads** (`level1-app` … `level4-app`, `eso`). Pods use
>   these, people don't.
> - **One `breakglass` userpass identity.** It's for the operator's root-recovery
>   procedure only, and its password is held with the unseal keys
>   ([`key-custody.md`](key-custody.md)). Never use it for day-to-day work.
>
> The root token is revoked once the bootstrap is done (`99-revoke-root.sh`). Until a
> developer login method exists (tracked in the cluster repo's
> `documents/DOCUMENTS-backlog.md`), you can use unauthenticated endpoints
> (`vault status`, `/v1/sys/health`) and inspect workloads through Kubernetes. For
> anything that reads secrets, ask the operator.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `x509: certificate signed by unknown authority` | CA missing, or stale after a cluster rebuild (new CA) | Redo step 2 |
| `x509: certificate is valid for ..., not 192.168.56.x` | You used an address that isn't in the certificate's SANs | Use the addresses above. If one of them fails, report it: it's a SAN gap to fix in `overlays/onprem/vault-extras` |
| `dial tcp 192.168.56.241:8200: connect: connection refused` / timeout | MetalLB or `vault-lb` is down | Use the break-glass address; tell the platform team |
| `Initialized false` | Vault was redeployed or its storage wiped | **Stop.** Operator task: don't initialise it yourself |
| `Sealed true` | A Vault pod restarted (every restart comes back sealed) | **Stop.** The operator unseals ([`runbooks/seal-unseal.md`](runbooks/seal-unseal.md)) |
| `vault: command not found` in a new shell | `/usr/local/bin` not on `PATH`, or the install step failed | `ls -l /usr/local/bin/vault`; redo step 1 |
| Variables missing in a new shell | `~/.bashrc` line not added | Redo step 3 |
| `kubectl` fails in step 2 | Stale or missing kubeconfig on the Dev VM | See *Before you start* |

---

## For the operator only — bootstrap and key custody

This isn't part of developer setup. It's recorded here so the whole picture is in one
place.

- The bootstrap scripts (`bootstrap/00-…` through `99-…`) need one more variable, which
  makes them write the unseal keys to the **Windows host** through the shared folder:
  ```bash
  export VAULT_POC_KEYS="$HOME/workspace-app/.credentials/vault-poc"
  ```
- Keys, the break-glass password and snapshots live there:
  `C:\Programming-Repository\Github - Adhito909\.credentials\vault-poc\`. That's outside
  every repo, and it survives a Dev VM `vagrant destroy`.
  [`key-custody.md`](key-custody.md) records the method and its trade-off (the shared
  folder can't enforce `0600`).
- Run order and guards: [`../bootstrap/README.md`](../bootstrap/README.md).
- **Never** paste `vault-init.json`, a share, a root token or the break-glass password
  into a chat, ticket, commit or screenshot. If one leaks: rekey, as the lifecycle table
  in `key-custody.md` describes.
