#!/usr/bin/env bash
#
# Phase A6 (addition) — create, and PROVE, the break-glass recovery identity.
# Runs before 99-revoke-root.sh, which refuses to revoke root without it.
#
# ############################################################################
# WHY THIS SCRIPT EXISTS
#
# Vault 2.0 made sys/generate-root and sys/rekey authenticated by default. D10
# revokes the root token at the end of A6 and relies on `operator generate-root`
# to get one back. On 2.x that command needs a token itself — so after root is
# revoked, this identity is the ONLY way back in. If it does not work, revoking
# root is a lockout. That is why this script verifies rather than just creates.
#
# DESIGN: a userpass identity, NOT a stored token.
# A stored token would be the durable credential — and tokens expire. A
# break-glass token that silently reached its max TTL would fail at the one
# moment it is needed: the same footgun as a projected reviewer JWT (D6).
# A userpass password does not expire; it mints a 15-minute token only when
# someone actually logs in.
#
# CUSTODY: the password is written beside vault-init.json, outside the repo,
# mode 0600. It belongs in the same password-manager note as the shares.
# See documents/key-custody.md.
# ############################################################################
#
# Usage:
#   ./95-create-breakglass.sh            # create if absent, then verify
#   ./95-create-breakglass.sh --rotate   # replace the password, then verify
#
# Exits non-zero if any verification fails.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ROTATE=0
[[ "${1:-}" == "--rotate" ]] && ROTATE=1

MOUNT="userpass"
BG_USER="breakglass"
POLICY="breakglass-admin"
POLICY_FILE="${SCRIPT_DIR}/20-policies/${POLICY}.hcl"

require_cmd vault jq openssl
require_vault_env
require_vault_authenticated     # this is the root (bootstrap) token

KEYS_DIR="$(vault_poc_keys_dir)"
assert_path_outside_repo "$KEYS_DIR"
PW_FILE="${KEYS_DIR}/breakglass-userpass.txt"

PASS=0; FAIL=0
pass() { log_ok  "PASS  $*"; PASS=$((PASS + 1)); }
fail() { log_err "FAIL  $*"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
log_step "Policy"
vault policy write "$POLICY" "$POLICY_FILE" >/dev/null
log_ok "policy ${POLICY}  (<- 20-policies/$(basename "$POLICY_FILE"))"

# ---------------------------------------------------------------------------
log_step "Auth method"
if auth_method_enabled "$MOUNT"; then
  log_skip "auth/${MOUNT}"
else
  vault auth enable -path="$MOUNT" userpass >/dev/null
  log_ok "auth/${MOUNT} enabled"
fi

# ---------------------------------------------------------------------------
log_step "Break-glass user"

# token_no_default_policy: the issued token carries breakglass-admin and nothing
# else — not even `default`. token_ttl/max: an operator gets 15 minutes per login.
USER_SETTINGS=(token_policies="$POLICY" token_no_default_policy=true token_ttl=15m token_max_ttl=1h)

USER_EXISTS=0
vault read "auth/${MOUNT}/users/${BG_USER}" >/dev/null 2>&1 && USER_EXISTS=1

if (( USER_EXISTS && ! ROTATE )); then
  [[ -r "$PW_FILE" ]] || die "user '${BG_USER}' exists but ${PW_FILE} is missing, so it cannot be verified.
     Restore the password from the password-manager note, or re-run with --rotate."
  # Re-assert the settings without touching the password — no drift on re-run (Rule 9).
  vault write "auth/${MOUNT}/users/${BG_USER}" "${USER_SETTINGS[@]}" >/dev/null
  log_skip "user ${BG_USER} (password file present; settings re-asserted)"
else
  umask 077
  NEW="$(mktemp "${KEYS_DIR}/.breakglass.XXXXXX")"
  openssl rand -base64 32 | tr -d '\n' > "$NEW"
  # password=@file: read from disk, never passed as an argument (argv is visible
  # in the process list) and never echoed (Rule 2).
  vault write "auth/${MOUNT}/users/${BG_USER}" password=@"$NEW" "${USER_SETTINGS[@]}" >/dev/null
  mv -f "$NEW" "$PW_FILE"
  chmod 0600 "$PW_FILE"
  if (( ROTATE )); then log_ok "password ROTATED -> ${PW_FILE} (0600)"; else log_ok "user ${BG_USER} created; password -> ${PW_FILE} (0600)"; fi
  log_warn "Add this password to the password-manager note beside vault-init.json NOW."
  log_warn "If it is lost AND root is revoked, recovery needs a Vault rebuild."
fi

# ---------------------------------------------------------------------------
log_step "Verify — prove the recovery path works (Rule 6)"

LOGIN="$(vault write -format=json "auth/${MOUNT}/login/${BG_USER}" password=@"$PW_FILE" 2>/dev/null)" \
  || die "break-glass LOGIN FAILED. Do not revoke root until this passes."
BG_TOKEN="$(jq -r '.auth.client_token' <<<"$LOGIN")"
BG_POLICIES="$(jq -r '.auth.policies | sort | join(",")' <<<"$LOGIN")"
BG_TTL="$(jq -r '.auth.lease_duration' <<<"$LOGIN")"

# The token has no `default` policy, so it cannot revoke itself. Revoke it with
# the root token this script is running as.
trap 'vault token revoke "$BG_TOKEN" >/dev/null 2>&1 || true' EXIT

pass "login works (token $(redact "$BG_TOKEN"), ttl ${BG_TTL}s)"
if [[ "$BG_POLICIES" == "$POLICY" ]]; then
  pass "token policies are exactly [${BG_POLICIES}] — not even default"
else
  fail "expected exactly [${POLICY}], got [${BG_POLICIES}]"
fi

# The capability that actually matters: start a root generation, then cancel it.
# Nothing changes without 3 unseal shares, and the attempt is cancelled at once.
GR_STATUS="$(VAULT_TOKEN="$BG_TOKEN" vault operator generate-root -status -format=json 2>&1)" \
  && pass "can read generate-root status" \
  || fail "cannot read generate-root status: ${GR_STATUS}"

if jq -e '.started == true' <<<"$GR_STATUS" >/dev/null 2>&1; then
  log_warn "a root-generation attempt is ALREADY in progress — not touching it."
  log_warn "Status read works; re-run once that attempt is finished or cancelled."
else
  OTP="$(VAULT_TOKEN="$BG_TOKEN" vault operator generate-root -generate-otp 2>/dev/null || true)"
  if [[ -n "$OTP" ]] && VAULT_TOKEN="$BG_TOKEN" vault operator generate-root -init -otp="$OTP" >/dev/null 2>&1; then
    pass "can START a root-generation attempt"
    if VAULT_TOKEN="$BG_TOKEN" vault operator generate-root -cancel >/dev/null 2>&1; then
      pass "can CANCEL it (attempt cleaned up)"
    else
      fail "started an attempt but could not cancel it — cancel with the root token NOW:  vault operator generate-root -cancel"
    fi
  else
    fail "cannot start a root-generation attempt — if this is 'permission denied', the policy is missing a capability"
  fi
  unset OTP
fi

VAULT_TOKEN="$BG_TOKEN" vault operator rekey -status >/dev/null 2>&1 \
  && pass "can read rekey status" \
  || fail "cannot read rekey status"

# Negative — it must be good for recovery and NOTHING else.
VAULT_TOKEN="$BG_TOKEN" vault kv get -mount=secret level1/app >/dev/null 2>&1 \
  && fail "break-glass token READ a secret — policy is too broad" \
  || pass "denied: secret/data/level1/app"
VAULT_TOKEN="$BG_TOKEN" vault secrets list >/dev/null 2>&1 \
  && fail "break-glass token can list mounts" \
  || pass "denied: sys/mounts"
VAULT_TOKEN="$BG_TOKEN" vault policy read "$POLICY" >/dev/null 2>&1 \
  && fail "break-glass token can read policies" \
  || pass "denied: sys/policy"

# ---------------------------------------------------------------------------
log_step "Result"
log "  passed: ${PASS}   failed: ${FAIL}"
if (( FAIL > 0 )); then
  log_err "The recovery path is NOT proven. Do not run 99-revoke-root.sh."
  exit 1
fi

cat >&2 <<EOF

  Break-glass is proven. Recovery after root revocation is now:

    export VAULT_TOKEN="\$(vault write -field=token auth/${MOUNT}/login/${BG_USER} password=@${PW_FILE})"
    OTP="\$(vault operator generate-root -generate-otp)"   # KEEP it: -decode needs the same OTP
    vault operator generate-root -init -otp="\$OTP"         # note the nonce
    vault operator generate-root -nonce=<nonce>             # x3, one per unseal share
    vault operator generate-root -decode=<encoded> -otp="\$OTP"
    # full procedure: documents/runbooks/seal-unseal.md

  Owed before you continue:
    - the password is in the password-manager note beside vault-init.json

  Next: ./99-revoke-root.sh  (it re-checks this login as a hard gate)
EOF
