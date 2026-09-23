# Backlog — known issues deferred on purpose

Things we know about and chose **not** to fix yet. Each entry records why it's deferred,
who owns it, and what would trigger picking it up. Remove an entry when it's done.

| # | Item | Owner | Status | Opened |
|---|---|---|---|---|
| 1 | [ingress-nginx is retired upstream](#1--ingress-nginx-is-retired-upstream) | Platform (this repo) | Kept in use, deliberately | 2026-09-22 |
| 2 | [Dashboard archived; its manifest overrides the pinned metrics-server](#2--dashboard-archived-its-manifest-overrides-the-pinned-metrics-server) | this repo | Waiting on its JIRA ticket | 2026-09-22 |
| 3 | [Guardrails for the Platform / SRE ingress boundary](#3--guardrails-for-the-platform--sre-ingress-boundary) | Platform (this repo) | Not started | 2026-09-23 |

---

## 1 — ingress-nginx is retired upstream

**What:** Kubernetes retired the community ingress-nginx controller. The repo was archived on
2026-03-24: no more releases, bug fixes, or security patches. The final release,
`controller-v1.15.1` (Helm chart `4.15.1`), is tested only up to **Kubernetes 1.35**, and this
cluster runs 1.36.

**Why it's still in use:** it still works. The images and charts remain downloadable, and the
Ingress API (`networking.k8s.io/v1`) is stable. The lab sits on a VirtualBox host-only network
that isn't reachable from the internet, which is the main risk the retirement warnings are
about. Decided 2026-09-22: keep using it for now.

**What depends on it:**
- The observability / tracing-poc teams' own Ingresses. Since 2026-09-23 the controller itself
  is owned by this repo (`addon_ingress_nginx`, v1.15.1, pinned to `.240`).
- This repo's ArgoCD Ingress (`https://infra-utility-argocd.192.168.56.240.nip.io`). The
  NodePort `https://localhost:30002` remains the fallback.
- **Not** Vault. It's exposed through a MetalLB VIP and a NodePort (D8), not an Ingress.

**Conditions while it stays:**
1. Run the final release, **v1.15.1** (`software.ingress_nginx` in `settings.yaml`). Older releases carry fixes that will never be
   backported, and the admission webhook has had critical RCEs before (IngressNightmare,
   2025). Check the running version:
   ```bash
   kubectl -n ingress-nginx get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
   ```
2. Keep new Ingresses portable. SREs still create Ingresses self-service, but should avoid
   `nginx.ingress.kubernetes.io/*` annotations unless needed. Each one is something to
   rewrite when the controller is replaced.

**Picking it up — triggers:** a CVE in ingress-nginx or its bundled NGINX; breakage on 1.36;
the next Kubernetes minor (1.37+); or anything in the lab becoming reachable from outside the
host.

**Replacement options:** Gateway API with a maintained implementation (Envoy Gateway, NGINX
Gateway Fabric, Traefik), or the separate F5 NGINX Ingress Controller. The F5 controller's
annotations differ, including the `backend-protocol` one
[`argocd-ingress-nip.yaml.j2`](../script-manifest/utility-argocd/argocd-ingress-nip.yaml.j2)
uses, so it's not a drop-in swap. The controller is Platform's to replace, but every SRE team's
Ingresses move with it, so the choice and the migration window are agreed with them.

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
  Dashboard is enabled. **Confirmed after the 2026-09-22 rebuild:** the running image is
  `metrics-server:v0.7.1`, and `kubectl top nodes` works.

**Why deferred:** Dashboard and Headlamp changes wait for their own JIRA ticket.

**When picked up:** either retire the Dashboard (`software.dashboard: ""`), or drop the
metrics-server objects from the Dashboard components manifest so the control plane's pinned
copy stands. Headlamp `0.26.0` is also well behind (current `0.45.0`); consider it in the
same ticket.

---

## 3 — Guardrails for the Platform / SRE ingress boundary

**What:** Since 2026-09-23 the split is: **Platform (this repo)** owns MetalLB, its pool
(`192.168.56.240-.250`), the ingress-nginx controller and its `.240` address. **SREs** own
their `Ingress` objects and `Service`s in their own repos, self-service. Today that split is a
convention only. Every ArgoCD app runs in the `default` project, which can deploy anything,
anywhere, so an app repo could still install a second MetalLB (the original clash) or claim
another team's hostname.

**To do:**
1. **ArgoCD AppProjects.** One for Platform, one per SRE app team. SRE projects are denied
   `metallb.io/*`, `IngressClass`, and cluster-scoped resources generally, and limited to their
   own namespaces.
2. **Hostname convention.** Platform tools use `infra-utility-<tool>.192.168.56.240.nip.io`
   (already the case); each app team gets its own prefix, so two Ingresses never claim the
   same host. ingress-nginx merges rules for a shared host, so a collision is silent.
3. **"How to expose your app" guide** in `documents/`: the IngressClass (`nginx`, also the
   default), the shared IP, the hostname pattern, which annotations are fine, and how to
   request a dedicated LoadBalancer IP from Platform (reserved so far: `.240` ingress-nginx,
   `.241` Vault).

**Why deferred:** separate work from the ownership move itself, and the AppProjects change
touches the other teams' Applications, so it needs their agreement.

**Picking it up — triggers:** a third team joining the cluster, any accidental install of a
second MetalLB, or a hostname collision.
