#!/usr/bin/env bash
#
# Phase A0 preflight — every readiness check in one pass.
#
# RUN THIS FIRST, before 00-init-unseal.sh and before applying root-platform.
# It checks the CLUSTER; the numbered scripts configure VAULT. Nothing here
# writes anything: it is read-only apart from one optional dry-run PVC test.
#
# What it answers:
#   - the five hard blockers that make a deploy fail or silently do nothing
#   - the six values marked unverified in documents/environment.md
#   - the three A0.5 Prometheus questions that decide whether A9.4 is possible
#
# ############################################################################
# WHERE TO RUN THIS
#
# Run it wherever you intend to run the numbered bootstrap scripts — normally
# the Dev VM, which has kubectl, jq, and the vault CLI.
#
# Running it on the Windows host works for the cluster checks but will report
# missing tooling (jq, vault) that is only actually needed on the machine doing
# the bootstrap. Read a tooling FAIL as "not here", not necessarily "nowhere".
#
# The git checks only mean something where the repo clone lives. They SKIP
# cleanly elsewhere.
# ############################################################################
#
# Exit codes:
#   0  no hard blockers — safe to proceed
#   1  at least one hard blocker
#
# Usage:
#   ./preflight.sh                 # check everything
#   ./preflight.sh --pvc-test      # also bind a throwaway PVC (P8 proof)

set -uo pipefail            # deliberately NOT -e: every check must run
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
set +e                      # common.sh sets -e; undo it

PVC_TEST=0
[[ "${1:-}" == "--pvc-test" ]] && PVC_TEST=1

PROPOSED_VIP="${VAULT_LB_IP:-192.168.56.241}"
NODEPORT="30004"
REPO_NAME="poc-platform-engineering-iac-vagrant-ansible-k8s-cluster-kubeadm-calico"

N_PASS=0; N_FAIL=0; N_WARN=0; N_SKIP=0
FINDINGS=""     # accumulates the environment.md paste block

_p() { printf '  %s%-6s%s %s\n' "$2" "$1" "$_c_reset" "$3" >&2; }
ok_()   { _p "PASS" "$_c_grn" "$1"; N_PASS=$((N_PASS+1)); }
bad_()  { _p "FAIL" "$_c_red" "$1"; N_FAIL=$((N_FAIL+1)); }
warn_() { _p "WARN" "$_c_ylw" "$1"; N_WARN=$((N_WARN+1)); }
skip_() { _p "SKIP" "$_c_dim" "$1"; N_SKIP=$((N_SKIP+1)); }
note_() { printf '         %s%s%s\n' "$_c_dim" "$1" "$_c_reset" >&2; }
record(){ FINDINGS+="$1"$'\n'; }

# ===========================================================================
log_step "0 — tooling on this machine"

for c in kubectl jq; do
  if command -v "$c" >/dev/null 2>&1; then ok_ "$c present"; else bad_ "$c MISSING — required"; fi
done
for c in vault gpg openssl git; do
  if command -v "$c" >/dev/null 2>&1; then ok_ "$c present"; else warn_ "$c missing — needed later by the numbered scripts"; fi
done
note_ "these must exist on the machine that runs the bootstrap scripts (normally"
note_ "the Dev VM). A miss here is only a blocker if this IS that machine."

# ===========================================================================
log_step "1 — git state (blocks ArgoCD: it pulls from the remote, not your disk)"

if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse >/dev/null 2>&1; then
  REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
  DIRTY="$(git -C "$REPO_ROOT" status --porcelain -- script-manifest/utility-hashicorp-vault | wc -l | tr -d ' ')"
  if [[ "$DIRTY" == "0" ]]; then
    ok_ "utility-hashicorp-vault is fully committed"
  else
    bad_ "${DIRTY} uncommitted file(s) under utility-hashicorp-vault"
    note_ "ArgoCD syncs what is on the REMOTE. Uncommitted work is invisible to it."
  fi

  BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
  AHEAD="$(git -C "$REPO_ROOT" rev-list --count "origin/${BRANCH}..${BRANCH}" 2>/dev/null || echo '?')"
  if [[ "$AHEAD" == "0" ]]; then
    ok_ "branch '${BRANCH}' is pushed"
  else
    bad_ "branch '${BRANCH}' is ${AHEAD} commit(s) ahead of origin — push before syncing"
  fi

  if [[ "$BRANCH" != "main" ]]; then
    warn_ "on branch '${BRANCH}', but the Applications pin targetRevision: main"
    note_ "merge to main, or change targetRevision while testing"
  fi
else
  skip_ "not a git repo — skipping git checks"
fi

# ===========================================================================
log_step "2 — cluster reachability"

if ! timeout 20 kubectl version -o json >/dev/null 2>&1; then
  bad_ "cannot reach the cluster"
  note_ "vagrant up, then re-run. If a node fails to boot see"
  note_ "documents/DOCUMENTS-runbook-node-recovery.md in the repo root."
  log ""
  log_err "stopping — every remaining check needs the API server"
  log "  passed=${N_PASS} failed=${N_FAIL} warned=${N_WARN} skipped=${N_SKIP}"
  exit 1
fi
ok_ "API server reachable"

NOT_READY="$(kubectl get nodes --no-headers 2>/dev/null | grep -vc ' Ready ')"
TOTAL_NODES="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$NOT_READY" == "0" ]]; then
  ok_ "all ${TOTAL_NODES} nodes Ready"
else
  bad_ "${NOT_READY}/${TOTAL_NODES} nodes NOT Ready"
fi

record "### Nodes"
record ""
record '| Node | IP | Role |'
record '|---|---|---|'
# ROLES comes from kubectl's default output, which derives it from the
# node-role.kubernetes.io/* labels. (Reading a single label via custom-columns
# printed <none>, because no label called kubernetes.io/role exists.)
while read -r name _status roles _rest; do
  ip="$(kubectl get node "$name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
  record "| \`${name}\` | \`${ip}\` | ${roles} |"
done < <(kubectl get nodes --no-headers 2>/dev/null)
record ""

# ---- P2 Kubernetes version -------------------------------------------------
K8S_VER="$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"')"
K8S_MINOR="$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.minor // "0"' | tr -d '+')"
if [[ "$K8S_MINOR" =~ ^[0-9]+$ ]] && (( K8S_MINOR >= 32 )); then
  ok_ "Kubernetes ${K8S_VER} (P2 satisfied)"
else
  warn_ "Kubernetes ${K8S_VER} — P2 wants >= 1.32"
  note_ "KNOWN failed gate, accepted deliberately. Pins target 1.29 compatibility."
fi
record "Kubernetes version: \`${K8S_VER}\`"
record ""

# ===========================================================================
log_step "3 — storage (P8) — blocks A2"

SC_LIST="$(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null)"
if [[ -z "$SC_LIST" ]]; then
  bad_ "no StorageClass at all — Vault and Postgres PVCs will never bind"
else
  note_ "StorageClasses: $(tr '\n' ' ' <<<"$SC_LIST")"
  if grep -q '^local-path|' <<<"$SC_LIST"; then
    ok_ "StorageClass 'local-path' exists"
    grep -q '^local-path|true' <<<"$SC_LIST" && note_ "and is the cluster default" \
      || note_ "not default — fine, the manifests name it explicitly"
    record "StorageClass: \`local-path\` ✅"
  else
    bad_ "StorageClass 'local-path' NOT found"
    note_ "Vault values-onprem.yaml and the postgres overlay both name it."
    note_ "Install local-path-provisioner, or change BOTH to the real name."
    record "StorageClass: ❌ \`local-path\` missing"
  fi
fi

if kubectl get pods -n local-path-storage --no-headers 2>/dev/null | grep -q Running; then
  ok_ "local-path-provisioner is running"
else
  warn_ "no Running pod in namespace local-path-storage"
fi

if (( PVC_TEST )); then
  log "  binding a throwaway PVC (WaitForFirstConsumer needs a pod, so this uses one)"
  kubectl delete pvc preflight-test --ignore-not-found >/dev/null 2>&1
  cat <<'EOF' | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: preflight-test }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: { requests: { storage: 1Gi } }
EOF
  kubectl run preflight-test --image=busybox:1.36 --restart=Never \
    --overrides='{"spec":{"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"preflight-test"}}],"containers":[{"name":"c","image":"busybox:1.36","command":["sh","-c","sleep 5"],"volumeMounts":[{"name":"v","mountPath":"/d"}]}]}}' \
    >/dev/null 2>&1
  sleep 20
  if kubectl get pvc preflight-test -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Bound; then
    NODE="$(kubectl get pod preflight-test -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
    ok_ "test PVC bound (PV landed on ${NODE:-unknown})"
  else
    bad_ "test PVC did not bind — $(kubectl get pvc preflight-test -o jsonpath='{.status.phase}' 2>/dev/null)"
  fi
  kubectl delete pod preflight-test --ignore-not-found >/dev/null 2>&1
  kubectl delete pvc preflight-test --ignore-not-found >/dev/null 2>&1
else
  skip_ "PVC bind test (pass --pvc-test to run it)"
fi

# ===========================================================================
log_step "4 — cert-manager — blocks wave 0, and therefore Vault"

if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
  ok_ "cert-manager CRDs present"
  CM_VER="$(kubectl get deploy -n cert-manager cert-manager -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')"
  [[ -n "$CM_VER" ]] && note_ "version: ${CM_VER}"
  kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -q Running \
    && ok_ "cert-manager pods Running" || bad_ "cert-manager CRDs exist but no Running pods"
else
  bad_ "cert-manager NOT installed"
  note_ "Wave 0's Certificate never issues -> the StatefulSet cannot mount vault-tls"
  note_ "-> Vault never starts. This is A0 step 6."
fi

for iss in selfsigned-bootstrap vault-poc-ca-issuer; do
  if kubectl get clusterissuer "$iss" >/dev/null 2>&1; then
    READY="$(kubectl get clusterissuer "$iss" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [[ "$READY" == "True" ]] && ok_ "ClusterIssuer ${iss} Ready" || bad_ "ClusterIssuer ${iss} exists but Ready=${READY:-unknown}"
  else
    warn_ "ClusterIssuer ${iss} not applied yet"
    note_ "kubectl apply -k ../base/cert-manager-issuers"
  fi
done

# ===========================================================================
log_step "5 — MetalLB (P4) and address availability"

if kubectl get crd ipaddresspools.metallb.io >/dev/null 2>&1; then
  ok_ "MetalLB CRDs present"
  POOLS="$(kubectl get ipaddresspool -A -o jsonpath='{range .items[*]}{.metadata.name}={.spec.addresses[*]}{"\n"}{end}' 2>/dev/null)"
  [[ -n "$POOLS" ]] && { ok_ "IPAddressPool(s) defined"; while read -r l; do [[ -n "$l" ]] && note_ "$l"; done <<<"$POOLS"; } \
                    || bad_ "MetalLB installed but NO IPAddressPool — LoadBalancer stays Pending"
  record "MetalLB pools:"
  while read -r l; do [[ -n "$l" ]] && record "  - \`${l}\`"; done <<<"$POOLS"
  record ""
else
  bad_ "MetalLB not installed — vault-lb (the primary path) cannot get an address"
fi

USED_IPS="$(kubectl get svc -A -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null | grep -v '^$')"
if grep -qx "$PROPOSED_VIP" <<<"$USED_IPS"; then
  OWNER="$(kubectl get svc -A -o jsonpath="{range .items[?(@.status.loadBalancer.ingress[0].ip=='${PROPOSED_VIP}')]}{.metadata.namespace}/{.metadata.name}{end}" 2>/dev/null)"
  bad_ "proposed VIP ${PROPOSED_VIP} is TAKEN by ${OWNER}"
  note_ "pick a free address and update overlays/onprem/vault-extras + the cert SANs"
else
  ok_ "proposed VIP ${PROPOSED_VIP} appears free"
  note_ "in use elsewhere: $(tr '\n' ' ' <<<"$USED_IPS")"
fi
record "Vault MetalLB VIP: \`${PROPOSED_VIP}\`"
record ""

if kubectl get svc -A -o jsonpath='{range .items[*]}{range .spec.ports[*]}{.nodePort}{"\n"}{end}{end}' 2>/dev/null | grep -qx "$NODEPORT"; then
  bad_ "NodePort ${NODEPORT} already in use — the break-glass Service will not create"
else
  ok_ "NodePort ${NODEPORT} is free"
fi

# ===========================================================================
log_step "6 — ArgoCD (P6) — blocks delivery"

if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  ok_ "ArgoCD CRDs present"
  ARGO_VER="$(kubectl get deploy -n argocd argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')"
  [[ -n "$ARGO_VER" ]] && note_ "argocd-server: ${ARGO_VER}  (multi-source needs >= 2.6)"

  REPO_SECRETS="$(kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository -o name 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$REPO_SECRETS" == "0" ]]; then
    bad_ "no repository credentials registered in ArgoCD"
  else
    ok_ "${REPO_SECRETS} repository credential(s) registered"
    FOUND=0
    for s in $(kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository -o name 2>/dev/null); do
      U="$(kubectl get -n argocd "$s" -o jsonpath='{.data.url}' 2>/dev/null | base64 -d 2>/dev/null)"
      note_ "$U"
      [[ "$U" == *"$REPO_NAME"* ]] && FOUND=1
    done
    (( FOUND )) && ok_ "a credential exists for this repo" \
                || bad_ "NO credential for ${REPO_NAME} — every child Application will fail to fetch"
  fi
else
  bad_ "ArgoCD not installed"
fi

# ===========================================================================
log_step "7 — Prometheus (A0.5) — decides whether A9.4 is possible"

if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1 \
   && kubectl get crd prometheusrules.monitoring.coreos.com >/dev/null 2>&1; then
  ok_ "5a: ServiceMonitor + PrometheusRule CRDs present"
  record "A0.5 5a — operator-managed: **yes**"

  SEL="$(kubectl get prometheus -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}  smSel={.spec.serviceMonitorSelector}  nsSel={.spec.serviceMonitorNamespaceSelector}  ruleSel={.spec.ruleSelector}{"\n"}{end}' 2>/dev/null)"
  if [[ -n "$SEL" ]]; then
    ok_ "5b: Prometheus CR found — READ THE SELECTORS BELOW"
    while read -r l; do [[ -n "$l" ]] && note_ "$l"; done <<<"$SEL"
    note_ "Put the required label into overlays/onprem/monitoring/kustomization.yaml."
    note_ "Wrong label = applies cleanly, never scraped, no error."
    record "A0.5 5b — selectors:"
    while read -r l; do [[ -n "$l" ]] && record "  - \`${l}\`"; done <<<"$SEL"
  else
    warn_ "5b: CRDs exist but no Prometheus CR found — cannot read the selectors"
  fi

  AM="$(kubectl get alertmanager -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$AM" == "0" ]]; then
    warn_ "5c: no Alertmanager — VaultNodeSealed will fire but page nobody"
    record "A0.5 5c — Alertmanager: **none**"
  else
    ok_ "5c: ${AM} Alertmanager(s) — verify a receiver reaches a human"
    note_ "kubectl get secret -n <ns> alertmanager-<name> -o jsonpath='{.data.alertmanager\\.yaml}' | base64 -d"
    record "A0.5 5c — Alertmanager present; receiver: _______"
  fi
else
  warn_ "5a: Prometheus Operator CRDs ABSENT"
  note_ "The stack is not operator-managed. Adding a scrape target would mean"
  note_ "EDITING a config that currently works — Rule 8 forbids it. STOP AND REPORT."
  note_ "Remove vault-monitoring.yaml from argocd/applications/; the rest is fine."
  record "A0.5 5a — operator-managed: **no** — A9.4 not possible additively"
fi
record ""

# ===========================================================================
log_step "8 — OIDC issuer — blocks A6"

ISSUER="$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null | jq -r '.issuer // empty' 2>/dev/null)"
if [[ -n "$ISSUER" ]]; then
  ok_ "issuer: ${ISSUER}"
  record "OIDC issuer: \`${ISSUER}\`"
else
  bad_ "could not read the OIDC issuer"
  note_ "PRD lists this under 'stop and ask' — do not substitute a plausible value"
  record "OIDC issuer: ❌ unreadable"
fi
record ""

# ===========================================================================
log_step "9 — namespaces and manual prerequisites"

for ns in vault external-secrets poc-hashicorp-vault-application; do
  kubectl get ns "$ns" >/dev/null 2>&1 && ok_ "namespace ${ns}" \
    || warn_ "namespace ${ns} missing — kubectl apply -k ../base/namespaces"
done

if kubectl get secret -n poc-hashicorp-vault-application postgres-admin >/dev/null 2>&1; then
  ok_ "Secret postgres-admin exists"
else
  warn_ "Secret postgres-admin missing — the postgres pod will not start"
  note_ "kubectl -n poc-hashicorp-vault-application create secret generic postgres-admin \\"
  note_ "  --from-literal=POSTGRES_PASSWORD=\"\$(openssl rand -base64 24)\""
fi

# ===========================================================================
log_step "10 — registry (P7) — blocks Stage B builds only"
skip_ "cannot be checked from here — run on the dev VM / a node:"
note_ "podman ps --filter name=registry          # on the dev VM"
note_ "crictl pull <registry>/hello              # on a node: proves TRUST, not reachability"
record "Registry: _______ (unverified)"
record ""

# ===========================================================================
log ""
log_step "Summary"
log "  passed=${N_PASS}  failed=${N_FAIL}  warned=${N_WARN}  skipped=${N_SKIP}"
log ""

if (( N_FAIL > 0 )); then
  log_err "${N_FAIL} hard blocker(s). Do not apply root-platform yet."
else
  log_ok "no hard blockers — safe to apply root-platform"
fi

cat >&2 <<'EOF'

  ---------- paste into documents/environment.md ----------
EOF
printf '%s\n' "$FINDINGS" >&2
cat >&2 <<'EOF'
  ---------------------------------------------------------

  WARN is not always a blocker: Kubernetes 1.29 and a missing Alertmanager are
  both known, accepted deviations. FAIL means a deploy will fail or, worse,
  report Synced while nothing actually runs.
EOF

(( N_FAIL == 0 ))
