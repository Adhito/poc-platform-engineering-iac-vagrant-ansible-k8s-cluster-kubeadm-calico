# Runbook — rebuild the cluster on Kubernetes 1.36

Moves the cluster from Kubernetes **1.29** (end of life since Feb 2025) to **1.36.4** by
**rebuilding** it (`vagrant destroy` + `vagrant up`), not by upgrading in place.

> **This is a shared cluster.** The observability and tracing-poc teams run workloads on it
> through their own ArgoCD apps. A rebuild takes all of it down and wipes it. Do not start
> until step 1 is agreed with them.

## Why rebuild instead of `kubeadm upgrade`

- kubeadm moves **one minor at a time**, so 1.29 → 1.36 in place is **seven** upgrades. Each
  one means a repo switch, `kubeadm upgrade`, drain, a kubelet + CRI-O upgrade, and uncordon
  on every node, plus Calico upgrades along the way.
- The cluster holds **no persistent data** (no PVCs as of 2026-09-22), and everything on it is
  reproducible from git: this repo's Ansible, and the other teams' ArgoCD apps.
- Vault isn't deployed yet. **After Vault holds state, a rebuild is no longer an option**. It
  destroys the Raft data and the seal. Later upgrades must be in place, one minor at a time
  (see `script-manifest/utility-hashicorp-vault/documents/runbooks/upgrade.md`).

## What changes

| Component | Before | After | Why this version |
|---|---|---|---|
| Kubernetes | 1.29.15 (control plane) / 1.29.0 (kubelets) | **1.36.4** everywhere | Newest minor all add-ons support; EOL 2027-06-28 |
| CRI-O | 1.33.0 from unpinned `pkgs.k8s.io` `prerelease:/main` | **1.36.x** from `download.opensuse.org/.../isv:/cri-o:/stable:/v1.36` | Must match the kubelet minor; now derived from `software.kubernetes` |
| Calico | 3.28.0 | **3.32.2** | Tested on 1.34–1.36 |
| metrics-server | unpinned third-party copy of 0.7.2 | **0.9.0** upstream (+ `--kubelet-insecure-tls`) | Supports 1.34+ — but see [backlog #2](DOCUMENTS-backlog.md) |
| Argo CD | 2.14.8 (EOL Nov 2025) | **3.5.3** | Tested on 1.33–1.36 |
| cert-manager (Vault stack) | v1.18.6 (EOL) — never installed | **v1.21.2** | Supports 1.33–1.36 |
| ESO (Vault stack) | 0.13.0 (EOL) — never installed | **2.11.0** | Supports 1.36; `ClusterSecretStore` moves to `v1` |
| Dashboard / Headlamp | 2.7.0 / 0.26.0 | **unchanged** | Waiting on their own ticket — [backlog #2](DOCUMENTS-backlog.md) |
| ingress-nginx (observability team's) | — | **unchanged** | Retired upstream, kept deliberately — [backlog #1](DOCUMENTS-backlog.md) |

Unchanged: node names and IPs, the MetalLB pools, the Ubuntu 22.04 box (kernel 5.15, cgroup v2,
which is fine for 1.36).

---

## 1. Agree the rebuild with the other teams

Confirm with the observability and tracing-poc teams:

- [ ] **A date/time window.** Everything on the cluster is down until the rebuild and their
      re-bootstrap finish.
- [ ] **Who re-creates their ArgoCD root app** (`local-root`) afterwards, and from which repo.
      It isn't in this repo.
- [ ] **Their charts work on Kubernetes 1.36 and Argo CD 3.x**: MetalLB, ingress-nginx,
      observability-local. Argo CD 3.0 changed several defaults (for example, the default
      resource-tracking method and some RBAC behaviour). They should read the
      [2.14 → 3.0 upgrade notes](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/2.14-3.0/)
      before the window.
- [ ] **ingress-nginx is at v1.15.1**, or they accept that it isn't. Its final release is
      tested only up to 1.35 ([backlog #1](DOCUMENTS-backlog.md)).
- [ ] **Any kubeconfig they copied from this cluster will stop working.** The rebuild creates
      a new cluster CA. That includes the Dev workspace VM and other project repos.

## 2. Back up what isn't in git

The VMs must be running for this. Everything goes to `configs/`, which is gitignored and
survives `vagrant destroy` because it lives on the host.

```bash
export KUBECONFIG=./configs/config
mkdir -p configs/backup-pre-1-36
kubectl -n argocd get applications,appprojects -o yaml > configs/backup-pre-1-36/argocd-apps.yaml
kubectl get ipaddresspool,l2advertisement -A -o yaml > configs/backup-pre-1-36/metallb.yaml
kubectl get nodes -o wide > configs/backup-pre-1-36/nodes.txt
kubectl get pods -A -o wide > configs/backup-pre-1-36/pods.txt
```

This is a **reference, not a restore**. The other teams re-bootstrap from their own repos. The
backup is only for comparing afterwards if something comes back different.

## 3. Rebuild

From the repo root on the host, on the branch or merge that carries the 1.36 changes:

```bash
git switch feature/update-cluster-to-1-36
```
```bash
vagrant destroy -f
```
```bash
vagrant up
```

`vagrant destroy -f` is irreversible for the VMs. Run it yourself, and only after step 1 is
agreed. Expect `vagrant up` to take a while: VMs boot slowly while Hyper-V/VBS is on.

## 4. Verify the new cluster

```bash
export KUBECONFIG=./configs/config
kubectl get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion
```
Expect every node at `v1.36.4`, with runtime `cri-o://1.36.x`.

```bash
kubectl version
```
```bash
kubectl -n kube-system get pods -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image | grep -E 'calico-node|metrics-server|kube-apiserver'
```
```bash
kubectl top nodes
```
```bash
kubectl -n argocd get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

The metrics-server image will show **v0.7.1**, not v0.9.0, while the Dashboard is enabled.
That's expected: see [backlog #2](DOCUMENTS-backlog.md).

## 5. Restore the cross-project fixups

A fresh `kubeadm join` doesn't restore the Dev workspace VM's SSH trust or the CRI-O trust for
the private registry (`192.168.56.20:5000`). Run the observability project's fixup for **each
worker**. See [DOCUMENTS-runbook-node-recovery.md](DOCUMENTS-runbook-node-recovery.md):

```bash
"/c/Programming-Repository/Github - Adhito909/poc-swe-app-java-quarkus-pattern-observability-grafana-lgtm-opentelemetry/scripts/utility-node-registry-recovery.sh" 192.168.56.11 tracing-poc
```
```bash
"/c/Programming-Repository/Github - Adhito909/poc-swe-app-java-quarkus-pattern-observability-grafana-lgtm-opentelemetry/scripts/utility-node-registry-recovery.sh" 192.168.56.12 tracing-poc
```

## 6. Hand back to the other teams

- They re-create their ArgoCD root app. `local-root` then brings back MetalLB, ingress-nginx,
  and the observability stack.
- Once ingress-nginx has its LB IP again (expected `192.168.56.240`, the same pool), confirm
  the ArgoCD Ingress: `https://infra-utility-argocd.192.168.56.240.nip.io`. If the IP changed,
  update `network.existing_ingress_nginx_lb_ip` in `settings.yaml` and run
  `vagrant provision devnodeworker02`.
- Share the new ArgoCD admin password (`configs/credentials_argocd_admin_password`) through
  whatever channel you normally use. Never put it in git or chat.

## 7. Redo the Vault Stage A prerequisites

Everything installed for Vault on the old cluster is gone. From
`script-manifest/utility-hashicorp-vault/README.md`:

1. `local-path-provisioner`, namespaces, and the `postgres-admin` Secret.
2. The ArgoCD repository credential for this repo. Create it yourself; it holds a credential.
3. `bootstrap/preflight.sh`. It now **fails** (instead of warning) below Kubernetes 1.32.
4. cert-manager v1.21.2 and its issuers, then the root platform app.

## Rollback

There's no data on the cluster, so rollback is another rebuild on the old versions:

```bash
git switch main
```
```bash
vagrant destroy -f
```
```bash
vagrant up
```

Then repeat steps 5 and 6. This only works until `main` itself carries the 1.36 changes; after
the merge, check out the last 1.29 commit instead.
