#!/usr/bin/env bash
#
# Phase A6 steps 5–6 — write the policies and bind them to Kubernetes identities.
#
# NOTE: the PRD's scaffold lists `20-policies/` as a directory but no script to
# apply it. This is that script. The HCL files are data; this turns them into
# Vault policies and attaches them to roles.
#
# ############################################################################
# THE ISOLATION BOUNDARY
#
# All four Stage B apps share ONE namespace. `bound_service_account_namespaces`
# is therefore identical across all four roles, which means
# `bound_service_account_names` is the ENTIRE thing separating Level 1 from
# Level 4's PGP key.
#
# Never `bound_service_account_names="*"`. And because the boundary is this
# thin, the negative tests in 70-verify-access.sh are load-bearing rather than
# ceremonial — an auth model that has never said "no" has not been tested.
# ############################################################################

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

POLICY_DIR="${SCRIPT_DIR}/20-policies"
APP_NS="poc-hashicorp-vault-application"
ESO_NS="external-secrets"
TOKEN_TTL="1h"

require_cmd vault jq
require_vault_env
require_vault_authenticated

auth_method_enabled kubernetes \
  || die "auth/kubernetes is not enabled. Run 10-enable-kubernetes-auth.sh first."

# ---------------------------------------------------------------------------
log_step "Write policies"

# `vault policy write` is inherently idempotent — it replaces by name — so no
# existence guard is needed. It is still reported per policy so a re-run shows
# what it touched.
for f in "${POLICY_DIR}"/*.hcl; do
  name="$(basename "$f" .hcl)"
  vault policy write "$name" "$f" >/dev/null
  log_ok "policy ${name}  (<- $(basename "$f"))"
done

# ---------------------------------------------------------------------------
log_step "Bind roles to ServiceAccount + namespace pairs"

# role_name | service_account | namespace | policy
ROLES=(
  "level1-app|level1-app|${APP_NS}|level1-reader"
  "level2-app|level2-app|${APP_NS}|level2-reader"
  "level3-app|level3-app|${APP_NS}|level3-db"
  "level4-app|level4-app|${APP_NS}|level4-pgp"
  "eso|external-secrets|${ESO_NS}|eso-reader"
)

for spec in "${ROLES[@]}"; do
  IFS='|' read -r role sa ns policy <<<"$spec"

  [[ "$sa" != "*" ]] || die "refusing to create role ${role} with a wildcard ServiceAccount"

  vault write "auth/kubernetes/role/${role}" \
    bound_service_account_names="$sa" \
    bound_service_account_namespaces="$ns" \
    policies="$policy" \
    ttl="$TOKEN_TTL" >/dev/null

  log_ok "role ${role}  <-  sa=${sa} ns=${ns} policy=${policy} ttl=${TOKEN_TTL}"
done

# ---------------------------------------------------------------------------
# Rule 6 — "applied cleanly" is not "working". Read back what Vault actually
# stored, rather than trusting that the writes above meant what they said.
log_step "Verify"

for spec in "${ROLES[@]}"; do
  IFS='|' read -r role sa ns policy <<<"$spec"
  got="$(vault read -format=json "auth/kubernetes/role/${role}" 2>/dev/null)" \
    || { log_err "role ${role} did not read back"; continue; }

  got_sa="$(jq -r '.data.bound_service_account_names | join(",")' <<<"$got")"
  got_ns="$(jq -r '.data.bound_service_account_namespaces | join(",")' <<<"$got")"
  got_pol="$(jq -r '(.data.token_policies // .data.policies) | join(",")' <<<"$got")"

  if [[ "$got_sa" == "$sa" && "$got_ns" == "$ns" && "$got_pol" == *"$policy"* ]]; then
    log_ok "${role}: sa=${got_sa} ns=${got_ns} policies=${got_pol}"
  else
    log_err "${role}: MISMATCH — sa=${got_sa} ns=${got_ns} policies=${got_pol}"
  fi
done

log ""
log "  Policies and roles exist, but NOTHING HAS BEEN PROVEN yet."
log "  The secrets engines are next, then 70-verify-access.sh runs the denials."
log ""
log "  Next: ./30-enable-kv.sh"
