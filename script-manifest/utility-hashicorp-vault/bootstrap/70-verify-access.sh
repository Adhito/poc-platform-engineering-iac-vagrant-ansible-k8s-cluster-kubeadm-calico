#!/usr/bin/env bash
#
# Phase A6 steps 7–8 — prove the authorization model, including that it DENIES.
#
# ############################################################################
# THIS SCRIPT IS A DELIVERABLE, NOT A CONVENIENCE (Rule 5).
#
# An unrun denial test is a FAILED GATE. And it matters more here than usual:
# all four Stage B apps share one namespace, so `bound_service_account_names`
# is the ENTIRE isolation boundary between Level 1 and Level 4's PGP key.
#
# An authorization model that has never said "no" has not been tested.
#
# Exits non-zero if any check fails, so it can gate a phase or a pipeline.
# ############################################################################
#
# NOTE ON SERVICEACCOUNTS: the four app SAs belong to Stage B, which has not
# deployed yet at Phase A6. This script creates them if missing — they are
# bare identity objects with no permissions, they are what the Vault roles
# already bind to, and ArgoCD adopts them when Stage B syncs. Without them
# there is no way to run the gate that A6 requires.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

APP_NS="poc-hashicorp-vault-application"
ESO_NS="external-secrets"

require_cmd vault jq kubectl
require_vault_env
require_vault_authenticated

PASS=0; FAIL=0
ISSUED_TOKENS=()

pass() { log_ok   "PASS  $*"; PASS=$((PASS + 1)); }
fail() { log_err  "FAIL  $*"; FAIL=$((FAIL + 1)); }

cleanup() {
  local t
  for t in "${ISSUED_TOKENS[@]:-}"; do
    [[ -n "$t" ]] && VAULT_TOKEN="$VAULT_TOKEN" vault token revoke "$t" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

ensure_sa() {
  local ns="$1" sa="$2"
  kubectl -n "$ns" get sa "$sa" >/dev/null 2>&1 && return 0
  kubectl -n "$ns" create sa "$sa" >/dev/null
  log_warn "created ServiceAccount ${ns}/${sa} (Stage B will adopt it)"
}

# Mints a short-lived SA JWT and exchanges it for a Vault token.
# Prints the Vault token on success; returns non-zero on denial.
login_as() {
  local ns="$1" sa="$2" role="$3" jwt resp token
  jwt="$(kubectl -n "$ns" create token "$sa" --duration=10m 2>/dev/null)" || return 1
  resp="$(vault write -format=json "auth/kubernetes/login" \
            role="$role" jwt="$jwt" 2>/dev/null)" || return 1
  token="$(jq -r '.auth.client_token // empty' <<<"$resp")"
  [[ -n "$token" ]] || return 1
  ISSUED_TOKENS+=("$token")
  printf '%s' "$token"
}

policies_of() {
  VAULT_TOKEN="$1" vault token lookup -format=json 2>/dev/null \
    | jq -r '.data.policies | sort | join(",")'
}

can_read() {  # $1 token, $2 path
  VAULT_TOKEN="$1" vault read "$2" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
log_step "Prepare ServiceAccounts"
for sa in level1-app level2-app level3-app level4-app; do ensure_sa "$APP_NS" "$sa"; done
ensure_sa "$ESO_NS" external-secrets

# ---------------------------------------------------------------------------
log_step "Positive — each bound SA logs in with exactly its own policy"

check_login() {  # sa | ns | role | expected-policy
  local sa="$1" ns="$2" role="$3" want="$4" tok got
  if tok="$(login_as "$ns" "$sa" "$role")"; then
    got="$(policies_of "$tok")"
    if [[ ",${got}," == *",${want},"* ]]; then
      pass "${sa} -> role ${role}  policies=[${got}]"
    else
      fail "${sa} -> role ${role}  expected '${want}', got [${got}]"
    fi
  else
    fail "${sa} -> role ${role}  login was DENIED but should have succeeded"
  fi
}

check_login level1-app       "$APP_NS" level1-app level1-reader
check_login level2-app       "$APP_NS" level2-app level2-reader
check_login level3-app       "$APP_NS" level3-app level3-db
check_login level4-app       "$APP_NS" level4-app level4-pgp
check_login external-secrets "$ESO_NS" eso        eso-reader

# ---------------------------------------------------------------------------
log_step "Negative — the deliverable"

# 1. Right role, wrong ServiceAccount. This is THE test: it proves the SA name
#    is genuinely load-bearing and not decoration.
if login_as "$APP_NS" default level2-app >/dev/null 2>&1; then
  fail "SA 'default' obtained role level2-app — THE ISOLATION BOUNDARY IS OPEN"
else
  pass "SA 'default' denied role level2-app"
fi

# 2. A real app SA reaching for someone else's role.
if login_as "$APP_NS" level1-app level4-pgp >/dev/null 2>&1; then
  fail "level1-app obtained role level4-pgp — cross-level login is possible"
else
  pass "level1-app denied role level4-pgp"
fi

# 3. Authorized login, unauthorized path. Login succeeding does not mean the
#    token may read anything — that is the policy's job, tested separately.
if L1="$(login_as "$APP_NS" level1-app level1-app)"; then
  if can_read "$L1" secret/data/level4/pgp; then
    fail "level1-reader token READ secret/data/level4/pgp — policy is too broad"
  else
    pass "level1-reader token denied secret/data/level4/pgp"
  fi

  if can_read "$L1" secret/data/level2/app; then
    fail "level1-reader token READ secret/data/level2/app — policy is too broad"
  else
    pass "level1-reader token denied secret/data/level2/app"
  fi

  # Sanity: the same token MUST still read its own path. A policy that denies
  # everything would pass every test above while being completely broken —
  # which is exactly what the KV v2 path trap produces.
  if can_read "$L1" secret/data/level1/app; then
    pass "level1-reader token reads its own secret/data/level1/app"
  else
    fail "level1-reader token cannot read its OWN path.
        This is the KV v2 path trap: policies must target secret/data/<path>,
        not the secret/<path> the CLI displays."
  fi
else
  fail "could not obtain a level1-app token; skipped the path checks"
fi

# ---------------------------------------------------------------------------
log_step "Result"
log "  passed: ${PASS}   failed: ${FAIL}"

if (( FAIL > 0 )); then
  log_err "Phase A6's exit gate is NOT met. Do not proceed to Stage B."
  exit 1
fi

log_ok "all checks passed — A6's authorization gate is met"
log ""
log "  Next: ./90-snapshot.sh, then ./99-revoke-root.sh"
