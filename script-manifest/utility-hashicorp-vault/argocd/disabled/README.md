# Disabled ArgoCD children

Applications here are **not** synced — `root-platform` only reads
`argocd/applications/` (`directory.recurse: false`). Each one is parked for a
recorded reason, with its manifests kept intact so re-enabling is a single `mv`.

| Application | Parked on | Why | Re-enable when |
|---|---|---|---|
| `vault-monitoring.yaml` | 2026-09-11 | `preflight.sh` check 5a: the Prometheus Operator CRDs (`ServiceMonitor`, `PrometheusRule`) are **absent**. The observability stack is not operator-managed, so scraping Vault would mean editing another team's working scrape config — Rule 8 forbids it | The observability team installs the operator CRDs — then set the real discovery label in `overlays/onprem/monitoring/` (check 5b) and move this file back |

**The gap this leaves is real:** without `VaultNodeSealed` there is no automated
seal detection, and a sealed follower passes its readiness probe. Until this is
re-enabled, the manual check in `documents/runbooks/seal-unseal.md` *is* the
detection.
