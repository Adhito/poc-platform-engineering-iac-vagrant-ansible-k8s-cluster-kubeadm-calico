# Backlog — known issues deferred on purpose

Things we know about and chose **not** to fix yet. Each entry records why it's deferred,
who owns it, and what would trigger picking it up. Remove an entry when it's done.

| # | Item | Owner | Status | Opened |
|---|---|---|---|---|
| 1 | [ingress-nginx is retired upstream](#1--ingress-nginx-is-retired-upstream) | observability team (controller) / this repo (ArgoCD Ingress) | Kept in use, deliberately | 2026-09-22 |
| 2 | [Dashboard archived; its manifest overrides the pinned metrics-server](#2--dashboard-archived-its-manifest-overrides-the-pinned-metrics-server) | this repo | Waiting on its JIRA ticket | 2026-09-22 |

---

## 1 — ingress-nginx is retired upstream

**What:** Kubernetes retired the community ingress-nginx controller. The repo was archived on
2026-03-24: no more releases, bug fixes, or security patches. The final release,
`controller-v1.15.1` (Helm chart `4.15.1`), is tested only up to **Kubernetes 1.35**, and this
cluster is moving to 1.36.

**Why it's still in use:** it still works. The images and charts remain downloadable, and the
Ingress API (`networking.k8s.io/v1`) is stable. The lab sits on a VirtualBox host-only network
that isn't reachable from the internet, which is the main risk the retirement warnings are
about. Decided 2026-09-22: keep using it for now.

**What depends on it:**
- The observability / tracing-poc teams' own Ingresses. They own the controller, via their
  `ingress-nginx` ArgoCD app.
- This repo's ArgoCD Ingress (`https://infra-utility-argocd.192.168.56.240.nip.io`). The
  NodePort `https://localhost:30002` remains the fallback.
- **Not** Vault. It's exposed through a MetalLB VIP and a NodePort (D8), not an Ingress.

**Conditions while it stays:**
1. Run the final release, **v1.15.1**. Older releases carry fixes that will never be
   backported, and the admission webhook has had critical RCEs before (IngressNightmare,
   2025). Check the running version:
   ```bash
   kubectl -n ingress-nginx get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
   ```
2. Build nothing new on it. New HTTP routing goes through whatever replaces it.

**Picking it up — triggers:** a CVE in ingress-nginx or its bundled NGINX; breakage on 1.36;
the next Kubernetes minor (1.37+); or anything in the lab becoming reachable from outside the
host.

**Replacement options:** Gateway API with a maintained implementation (Envoy Gateway, NGINX
Gateway Fabric, Traefik), or the separate F5 NGINX Ingress Controller. The F5 controller's
annotations differ, including the `backend-protocol` one
[`argocd-ingress-nip.yaml.j2`](../script-manifest/utility-argocd/argocd-ingress-nip.yaml.j2)
uses, so it's not a drop-in swap. Since the controller is shared, the choice is made with the
observability team.

**References:** [Retirement announcement](https://www.kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
· [Steering & SRC statement](https://www.kubernetes.io/blog/2026/01/29/ingress-nginx-statement/)
· [Archived repo (supported-versions table)](https://github.com/kubernetes/ingress-nginx)

---

## 2 — Dashboard archived; its manifest overrides the pinned metrics-server

**What:**
- Kubernetes Dashboard was archived upstream on 2026-01-21. Headlamp is the official successor
  and is already deployed here. `settings.yaml` still installs Dashboard `2.7.0`.
- `script-manifest/utility-dashboard/kubernetes-ui-dashboard-components.yaml` bundles its own
  **metrics-server v0.7.1**. `addon_dashboard` applies it *after* the control plane installs the
  pinned **v0.9.0**, so the running metrics-server ends up at v0.7.1. That still works on 1.36
  (0.7.x supports 1.27+), but the `software.metrics_server` pin is overridden while the
  Dashboard is enabled.

**Why deferred:** Dashboard and Headlamp changes wait for their own JIRA ticket.

**When picked up:** either retire the Dashboard (`software.dashboard: ""`), or drop the
metrics-server objects from the Dashboard components manifest so the control plane's pinned
copy stands. Headlamp `0.26.0` is also well behind (current `0.45.0`); consider it in the
same ticket.
