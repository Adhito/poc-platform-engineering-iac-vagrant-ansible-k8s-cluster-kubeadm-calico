# Node Recovery Runbook

For when a node VM becomes unresponsive/unbootable — typically from the external SSD
(`F:\Programming-Environment-01\...`) disconnecting or being interrupted mid-write, which has
corrupted a VM's `.vmdk` header (`VERR_VD_VMDK_INVALID_HEADER`) more than once.

> **This recovery is not complete after `kubectl get nodes` shows `Ready`.** Step 4 (cross-project
> fixup) is mandatory, not optional cleanup — skip it and the rebuilt node silently breaks image
> pulls for the observability/tracing-poc apps. If you don't have Dev VM access yourself, flag the
> apps team to run it once Step 3 finishes.

### Node → IP reference

| Node | IP |
|---|---|
| `devnodemaster01` | `192.168.56.10` |
| `devnodeworker01` | `192.168.56.11` |
| `devnodeworker02` | `192.168.56.12` |

(Pattern: `network.control_ip` in `settings.yaml`, then `+1` per worker index — see `Vagrantfile`.)

## Step 0 — Diagnose first. Don't skip this.

```bash
vagrant ssh <node>
```

Also try starting the VM directly from the VirtualBox GUI.

- **If either works**: the node is not actually unbootable. Use the lighter path instead —
  drain, investigate, reprovision. Do **not** destroy/rebuild for a node that's still reachable.
  ```bash
  kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
  # investigate: sudo systemctl status kubelet crio
  vagrant provision <node>
  kubectl uncordon <node>
  ```
- **If both fail**: the node is genuinely down. Continue below.

## Step 1 — Graceful halt, then a full host reboot

**Do not** run `taskkill /IM VBoxSVC.exe /F` to clear VirtualBox host-level errors (e.g.
`VERR_UNRESOLVED_ERROR` on `startvm`). It does not just restart the coordinating service — it can
kill every currently-running VM on the host, including the control plane, with an abrupt process
kill rather than a graceful shutdown. A full host reboot is the safer route to the same clean
VirtualBox state:

1. `vagrant halt` — gracefully stops **all** VMs, letting etcd/kubelet/containerd on the control
   plane shut down cleanly (this is the step that makes a reboot safe rather than risky).
2. Restart the host machine.
3. `vagrant up` — brings the surviving VMs back (not a rebuild, just a restart).
4. Verify before continuing:
   ```bash
   kubectl get nodes
   kubectl get pods -n kube-system
   ```
   Confirm `etcd-devnodemaster01`, `kube-apiserver-*`, `kube-controller-manager-*`,
   `kube-scheduler-*` are all `Running` with no crash loops.

## Step 2 — Clear the broken node from Kubernetes and Vagrant/VirtualBox state

```bash
kubectl delete node <node-name>
```
Clears the stale Node object immediately, instead of waiting ~5 minutes for the automatic
unreachable-node taint eviction. Also force-deletes any pods still bound to it.

```bash
vagrant destroy <node-name> -f
```

- **If this succeeds cleanly**, skip to Step 3.
- **If it fails with `Could not find a registered machine with UUID ...`** (VirtualBox already
  dropped the corrupted VM from its own registry — this happens if VBoxSVC gets restarted before
  the destroy runs), clean up manually:
  ```bash
  rm -rf .vagrant/machines/<node-name>
  ```
  Then check for and remove the orphaned VM folder on the external drive (already confirmed
  corrupted and unregistered — nothing recoverable in it):
  ```bash
  ls "/f/Programming-Environment-01/VM-Default-Virtualbox/Development Kubernetes Cluster Kubeadm Calico Vagrant Ansible/<NODE-NAME-ANSIBLE>"
  rm -rf "/f/Programming-Environment-01/VM-Default-Virtualbox/Development Kubernetes Cluster Kubeadm Calico Vagrant Ansible/<NODE-NAME-ANSIBLE>"
  ```

## Step 3 — Rebuild

```bash
vagrant provision devnodemaster01
```
Proactively refreshes the kubeadm join token before it's needed — it expires in 24h
(`share_join_command.yaml` regenerates it unconditionally on every control-plane provision), and
every rebuild so far has hit `could not find a JWS signature` without this step.

```bash
vagrant up <node-name>
```
Full fresh VM creation + provision. If this is the last worker (per `settings.yaml`
`nodes.workers.count`), `pb_addons.yaml` also re-runs automatically — safe, all addon tasks are
idempotent `kubectl apply`/guarded patches.

```bash
kubectl get nodes
```
Confirm all nodes `Ready`.

## Step 4 — MANDATORY: cross-project fixup (SSH + registry trust)

A rebuilt node gets a brand-new identity — fresh SSH host key, no CRI-O registry trust config.
Kubernetes-native things (Calico CNI, ArgoCD-managed workloads) self-heal automatically on rejoin;
**these two do not**, because they're imperative one-off configs owned by the observability
project (`poc-swe-app-java-quarkus-pattern-observability-grafana-lgtm-opentelemetry`), not part of
this repo's Ansible provisioning. This step is a hard requirement of the recovery, not cleanup —
treat `kubectl get nodes` showing `Ready` as "rebuild done," not "recovery done."

**Script: run it inside the Dev VM, not on the Windows host.** It copies the *Dev VM's* SSH key
and uses the Dev VM's Ansible and kubeconfig. Run from Git Bash on Windows, it fails at once with
`ssh-copy-id: ERROR: No identities found` (seen 2026-09-22).

Usage: `<node-ip>` is required (see the reference table above), `[namespace]` defaults to
`tracing-poc`. Example for a rebuilt `devnodeworker02`:

```bash
# on the host:
cd "/c/Programming-Repository/Github - Adhito909/learning-labs-developer-workspace-type-01"
vagrant ssh
```
```bash
# inside the Dev VM:
cd ~/workspace-app/poc-swe-app-java-quarkus-pattern-observability-grafana-lgtm-opentelemetry
./scripts/utility-node-registry-recovery.sh 192.168.56.12 tracing-poc   # password prompt: vagrant
```

The script checks SSH trust on **every** node in the Dev VM's inventory, because its registry
step connects to all of them. It replaces a rebuilt node's stale host key and refreshes a
kubeconfig that no longer reaches the cluster. It prompts for the password only where the key is
missing. The same command therefore covers a single-node rebuild and a full cluster rebuild. See
[DOCUMENTS-runbook-cluster-upgrade-1-36.md](DOCUMENTS-runbook-cluster-upgrade-1-36.md) step 5.

If you (whoever is running this cluster-side recovery) don't have direct access to run this — **it
still needs to happen. Hand off to the apps team with the node IP** rather than considering the
recovery finished.

What it does (4 steps, idempotent, safe to re-run):
1. `ssh-copy-id`s the Dev VM's SSH key to the rebuilt node
2. Re-applies the CRI-O registry-trust Ansible playbook (safe against all nodes, not just this one)
3. Force-deletes any pods stuck in `ImagePullBackOff`/`ErrImagePull` in the target namespace
4. Waits 15s and shows final pod status

**Symptom if this step is skipped**: new pods scheduled on the rebuilt node sit in
`ImagePullBackOff` with `http: server gave HTTP response to HTTPS client`.

## Condensed checklist

- [ ] `vagrant ssh <node>` and VirtualBox GUI start both fail? → confirmed down, continue.
- [ ] `vagrant halt` (graceful) → restart host → `vagrant up` → verify `kube-system` healthy.
- [ ] `kubectl delete node <node-name>`
- [ ] `vagrant destroy <node-name> -f` (manual `.vagrant/machines` + orphaned-folder cleanup if it 404s)
- [ ] `vagrant provision devnodemaster01` (fresh join token)
- [ ] `vagrant up <node-name>`
- [ ] `kubectl get nodes` — all `Ready` (this is "rebuild done," not "recovery done")
- [ ] **MANDATORY**: run `utility-node-registry-recovery.sh <node-ip> <namespace>` from the Dev VM
      (self, or hand off to the apps team — do not skip)
- [ ] `kubectl get pods -A | grep -v Running` — confirm nothing stuck
