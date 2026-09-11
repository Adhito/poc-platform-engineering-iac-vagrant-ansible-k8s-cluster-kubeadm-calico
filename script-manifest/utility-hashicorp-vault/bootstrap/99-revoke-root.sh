#!/usr/bin/env bash
#
# Phase A6 step 9 — revoke the initial root token (D10).
#
# ############################################################################
# ROOT TOKENS ARE FOR BOOTSTRAP ONLY.
#
# Leaving one alive teaches the wrong reflex, and it is the credential most
# likely to end up pasted somewhere it should not be. Bootstrap completes, root
# is revoked, and it is regenerated ON DEMAND — with a quorum of unseal shares —
# when genuinely needed.
#
# This is safe precisely BECAUSE it is reversible: `vault operator generate-root`
# mints a new one from the key shares. Revoking root does not lock you out; it
# just makes reaching for root a deliberate act with an audit trail.
#
# Run this LAST. Everything after it needs either a Kubernetes-auth token or a
# regenerated root.
# ############################################################################
#
# Usage:
#   ./99-revoke-root.sh          # preflight, then prompt
#   ./99-revoke-root.sh --yes    # non-interactive

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ASSUME_YES=0
[[ "${1:-}" == "--yes" ]] && ASSUME_YES=1

require_cmd vault jq
require_vault_env
require_vault_authenticated

# ---------------------------------------------------------------------------
# Refuse to revoke root while bootstrap is incomplete. Regenerating root is
# possible but tedious, and discovering a half-finished bootstrap afterwards is
# a worse experience than being stopped here.
log_step "Preflight — bootstrap must be complete"

BLOCKED=0
check() {  # description | test-command...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then log_ok "$desc"; else log_err "$desc"; BLOCKED=1; fi
}

check "auth/kubernetes enabled"            auth_method_enabled kubernetes
check "auth/kubernetes configured"         vault read auth/kubernetes/config
check "secret/ (KV v2) mounted"            secrets_engine_enabled secret
check "database/ mounted"                  secrets_engine_enabled database
check "policy level1-reader"               policy_exists level1-reader
check "policy level2-reader"               policy_exists level2-reader
check "policy level3-db"                   policy_exists level3-db
check "policy level4-pgp"                  policy_exists level4-pgp
check "policy eso-reader"                  policy_exists eso-reader
check "role level1-app"                    vault read auth/kubernetes/role/level1-app
check "role eso"                           vault read auth/kubernetes/role/eso
check "secret/level1/app seeded"           kv_path_exists secret level1/app
check "secret/level4/pgp seeded"           kv_path_exists secret level4/pgp
check "audit device enabled"               audit_device_enabled file

# Vault 2.0 made sys/generate-root authenticated. Once root is revoked, the
# break-glass identity from 95-create-breakglass.sh is the ONLY way back in — so
# prove it logs in and can reach generate-root NOW, rather than trusting that 95
# passed at some earlier point.
BG_PW_FILE="$(vault_poc_keys_dir)/breakglass-userpass.txt"
breakglass_works() {
  local login tok
  [[ -r "$BG_PW_FILE" ]] || return 1
  login="$(vault write -format=json auth/userpass/login/breakglass password=@"$BG_PW_FILE" 2>/dev/null)" || return 1
  tok="$(jq -r '.auth.client_token // empty' <<<"$login")"
  [[ -n "$tok" ]] || return 1
  if ! VAULT_TOKEN="$tok" vault operator generate-root -status >/dev/null 2>&1; then
    vault token revoke "$tok" >/dev/null 2>&1 || true
    return 1
  fi
  vault token revoke "$tok" >/dev/null 2>&1 || true
}
check "break-glass login + generate-root (95)" breakglass_works

if (( BLOCKED )); then
  die "bootstrap is incomplete — refusing to revoke root.
     Finish the failing steps above, then re-run. If only the break-glass check
     failed, run ./95-create-breakglass.sh first: on Vault 2.x, revoking root
     without a working break-glass identity is a lockout."
fi

# The token in use must actually be root; revoking a non-root token here would
# silently do nothing useful.
SELF="$(vault token lookup -format=json)"
if ! jq -e '.data.policies | index("root")' <<<"$SELF" >/dev/null; then
  log_warn "the current token is not a root token — nothing to revoke."
  log_warn "policies: $(jq -r '.data.policies | join(",")' <<<"$SELF")"
  exit 0
fi

# ---------------------------------------------------------------------------
log_step "Confirm"

cat >&2 <<'EOF'
  About to revoke the initial root token.

  After this:
    - VAULT_TOKEN in this shell stops working immediately
    - The root_token field in vault-init.json is dead (the five unseal SHARES
      remain valid and are still the thing that matters)
    - Regenerate root only when needed. On Vault 2.x generate-root is an
      authenticated endpoint, so log in as break-glass first (95-):

        export VAULT_TOKEN="$(vault write -field=token auth/userpass/login/breakglass \
            password=@$HOME/.credentials/vault-poc/breakglass-userpass.txt)"
        OTP="$(vault operator generate-root -generate-otp)"   # KEEP it for -decode
        vault operator generate-root -init -otp="$OTP"        # note the nonce
        vault operator generate-root -nonce=<nonce>           # x3, one per key share
        vault operator generate-root -decode=<encoded> -otp="$OTP"

  Verify that procedure works ONCE before you rely on it — a recovery path you
  have never walked is a hypothesis (A6 exit gate).
EOF

if (( ! ASSUME_YES )); then
  read -r -p "  Revoke the root token now? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { log "  aborted — nothing changed"; exit 0; }
fi

# ---------------------------------------------------------------------------
log_step "Revoke"

vault token revoke -self >/dev/null 2>&1 || true

if vault token lookup >/dev/null 2>&1; then
  die "the token still works — revocation did not take effect."
fi
log_ok "root token revoked"

cat >&2 <<'EOF'

  Stage A bootstrap is complete.

  Before handing off to Stage B, confirm the exit gates that no script can
  assert for you:
    - The 4x4 access matrix passed (./70-verify-access.sh, run while root
      still existed, or re-run with a Kubernetes-auth token)
    - operator generate-root exercised once
    - documents/key-custody.md written — method and holder, never the location
      and never the shares
    - The A9.3 restore drill run, and its RTO recorded

  Stage B applies root-applications.yaml from the vault repo. Not before.
EOF
