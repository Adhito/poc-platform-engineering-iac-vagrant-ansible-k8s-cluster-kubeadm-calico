#!/usr/bin/env bash
#
# Onboard another team onto Vault, without root.
#
# A team gets three things, all named after it:
#   policy   team-<team>             read secret/teams/<team>/*, nothing else
#   role     team-<team>             Kubernetes auth, bound to the team's own
#                                    namespace + ServiceAccount(s)
#   KV path  secret/teams/<team>/    where its secrets live
#
# Runs as `platform-admin` (96-create-operators.sh), and logs in by itself if
# no working token is set. That identity can only touch team-* names, and can
# write team secrets but not read them (20-policies/platform-admin.hcl).
#
# ############################################################################
# THE TEMPLATE IS THE GUARD.
#
# Anyone with platform-admin can write a team-* policy or role saying anything,
# including a policy granting `path "*"`, or a role bound to level4-pgp. Vault
# Community can't stop that. So policies are only ever written from
# render_policy() below, and `--verify` diffs every team-* policy and role
# against it. Run --verify after any change and before trusting the setup.
# ############################################################################
#
# Usage:
#   ./80-onboard-team.sh <team> <namespace> <serviceaccount>[,<serviceaccount>...]
#   ./80-onboard-team.sh --verify
#
# Re-running for an existing team replaces its role (namespace / ServiceAccounts)
# and re-renders its policy. Secrets are never touched.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TOKEN_TTL="1h"
VAULT_IN_CLUSTER="https://vault.vault.svc:8200"

# Namespaces a team may not claim: Vault's own, the platform's, and Stage B's.
# Stage B's four levels share one namespace and are separated only by
# ServiceAccount names (20-apply-policies.sh), so a team role there would sit
# inside that boundary.
RESERVED_NS=(vault external-secrets poc-hashicorp-vault-application
             kube-system kube-public kube-node-lease default
             argocd cert-manager metallb-system ingress-nginx local-path-storage)

usage() {
  sed -n 's/^#   \(\.\/80-.*\)/  \1/p' "$0" >&2
  exit 2
}

render_policy() {  # team
  cat <<EOF
# team-$1: written by bootstrap/80-onboard-team.sh. DO NOT EDIT BY HAND.
# '80-onboard-team.sh --verify' reports any difference from this template.
path "secret/data/teams/$1/*" {
  capabilities = ["read"]
}
path "secret/metadata/teams/$1/*" {
  capabilities = ["read", "list"]
}
EOF
}

require_cmd vault jq
require_vault_env
use_operator_login_if_needed platform-admin
require_vault_authenticated

# ---------------------------------------------------------------------------
verify() {
  local problems=0 p team got roles r role_json r_pols r_sa r_ns
  log_step "Policies named team-*"

  mapfile -t pols < <(vault policy list -format=json | jq -r '.[] | select(startswith("team-"))')
  (( ${#pols[@]} )) || log "  (none)"
  for p in "${pols[@]}"; do
    team="${p#team-}"
    got="$(vault read -field=policy "sys/policies/acl/${p}")"
    if diff -bB <(render_policy "$team") <(printf '%s\n' "$got") >/dev/null; then
      log_ok "${p}: matches the template"
    else
      log_err "${p}: DIFFERS from the template. Inspect: vault policy read ${p}"
      problems=$((problems + 1))
    fi
  done

  log_step "Kubernetes auth roles named team-*"
  mapfile -t roles < <(vault list -format=json auth/kubernetes/role 2>/dev/null | jq -r '.[]? | select(startswith("team-"))')
  (( ${#roles[@]} )) || log "  (none)"
  for r in "${roles[@]}"; do
    role_json="$(vault read -format=json "auth/kubernetes/role/${r}")"
    r_pols="$(jq -r '(.data.token_policies // []) + (.data.policies // []) | unique | join(",")' <<<"$role_json")"
    r_sa="$(jq -r '.data.bound_service_account_names | join(",")' <<<"$role_json")"
    r_ns="$(jq -r '.data.bound_service_account_namespaces | join(",")' <<<"$role_json")"

    if [[ "$r_pols" != "$r" ]]; then
      log_err "${r}: carries policies [${r_pols}]. A team role must carry exactly [${r}]"
      problems=$((problems + 1))
    elif [[ ",${r_sa},${r_ns}," == *",*,"* || "$r_sa" == *"*"* || "$r_ns" == *"*"* ]]; then
      log_err "${r}: wildcard binding (sa=${r_sa} ns=${r_ns})"
      problems=$((problems + 1))
    elif [[ " ${pols[*]} " != *" ${r} "* ]]; then
      log_err "${r}: its policy ${r} does not exist. Re-run onboarding for ${r#team-}"
      problems=$((problems + 1))
    else
      log_ok "${r}: ns=${r_ns} sa=${r_sa} policies=${r_pols}"
    fi
  done

  log_step "Result"
  if (( problems )); then
    log_err "${problems} problem(s). Treat a template difference as a possible privilege grab:"
    log_err "check the audit log for who wrote it before 'fixing' it."
    exit 1
  fi
  log_ok "every team-* policy and role matches the template"
}

if [[ "${1:-}" == "--verify" ]]; then verify; exit 0; fi
[[ $# -eq 3 ]] || usage

TEAM="$1" NS="$2" SAS="$3"
ROLE="team-${TEAM}"

# ---------------------------------------------------------------------------
log_step "Check the request"

[[ "$TEAM" =~ ^[a-z][a-z0-9-]{0,28}[a-z0-9]$ ]] \
  || die "team name '${TEAM}': 2-30 chars, lowercase letters, digits and '-', starting with a letter"
[[ "$NS" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] \
  || die "namespace '${NS}' is not a valid Kubernetes namespace name"
[[ " ${RESERVED_NS[*]} " != *" ${NS} "* ]] \
  || die "namespace '${NS}' is reserved (Vault, platform or Stage B). Give the team its own namespace."

IFS=',' read -r -a SA_LIST <<<"$SAS"
for sa in "${SA_LIST[@]}"; do
  [[ "$sa" != "*" && "$sa" =~ ^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$ ]] \
    || die "ServiceAccount '${sa}' is not allowed. Name each one explicitly; never '*'."
done
log_ok "team=${TEAM}  namespace=${NS}  serviceaccounts=${SAS}"

if command -v kubectl >/dev/null 2>&1; then
  kubectl get namespace "$NS" >/dev/null 2>&1 \
    && log_ok "namespace ${NS} exists" \
    || log_warn "namespace ${NS} does not exist yet. The role still works once it does."
fi

if before="$(vault read -format=json "auth/kubernetes/role/${ROLE}" 2>/dev/null)"; then
  log_warn "${ROLE} already exists (ns=$(jq -r '.data.bound_service_account_namespaces | join(",")' <<<"$before")" \
           "sa=$(jq -r '.data.bound_service_account_names | join(",")' <<<"$before")). It will be REPLACED."
fi

# ---------------------------------------------------------------------------
log_step "Policy ${ROLE}"
render_policy "$TEAM" | vault policy write "$ROLE" - >/dev/null
log_ok "written from the template: read secret/teams/${TEAM}/*"

log_step "Role ${ROLE}"
vault write "auth/kubernetes/role/${ROLE}" \
  bound_service_account_names="$SAS" \
  bound_service_account_namespaces="$NS" \
  token_policies="$ROLE" \
  token_ttl="$TOKEN_TTL" >/dev/null
log_ok "bound to ns=${NS} sa=${SAS}, ttl=${TOKEN_TTL}"

# Rule 6: read back what Vault stored, through the same check --verify uses.
verify

# ---------------------------------------------------------------------------
CA_B64="$(base64 -w0 < "$VAULT_CACERT")"
cat >&2 <<EOF

  ${TEAM} is onboarded. Hand the team the following.

  1. SECRETS go under secret/teams/${TEAM}/. Platform seeds them, as platform-admin
     (write-only: it cannot read them back). Values from a file, so they stay
     out of shell history and the process list:

       vault kv put -mount=secret teams/${TEAM}/app DB_PASSWORD=@db_password.txt

  2. IN THEIR NAMESPACE, a namespaced SecretStore that logs in as THEIR
     ServiceAccount. Not the shared ClusterSecretStore 'vault-backend': that one
     runs as ESO's own identity, which can't read team paths, by design.

---
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault
  namespace: ${NS}
spec:
  provider:
    vault:
      server: "${VAULT_IN_CLUSTER}"
      path: "secret"
      version: "v2"
      # vault-poc-ca, the CA that signs Vault's certificate (public, not a secret)
      caBundle: "${CA_B64}"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "${ROLE}"
          serviceAccountRef:
            name: "${SA_LIST[0]}"
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: app
  namespace: ${NS}
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: vault
  target:
    name: app-secrets
  dataFrom:
    - extract:
        key: teams/${TEAM}/app
---

     Or, without ESO, the app logs in itself: POST auth/kubernetes/login with
     role=${ROLE} and its ServiceAccount JWT (as Stage B's Level 2 does).

  3. LIMITS to state up front: DEV only, recreatable values only, no SLA.
     A Vault restart is an outage until an operator unseals it.
EOF
