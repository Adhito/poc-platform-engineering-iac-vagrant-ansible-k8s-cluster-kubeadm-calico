#!/usr/bin/env bash
#
# Create, and PROVE, the two operator identities that day-to-day work needs once
# root is revoked:
#
#   snapshot-operator   take Raft snapshots (90-snapshot.sh)        -> A9.2/A9.3
#   platform-admin      onboard other teams (80-onboard-team.sh)
#
# ############################################################################
# WHY THIS SCRIPT EXISTS
#
# After 99-revoke-root.sh the only human identity was break-glass, which may
# only START generate-root and rekey. Every snapshot, and every new team, would
# have cost a generate-root ceremony with three shares. These two identities
# remove that, each scoped to one job (see 20-policies/<name>.hcl).
#
# Same design as 95-create-breakglass.sh: a userpass PASSWORD (it doesn't
# expire), not a stored token (it would). Each login mints a 15-minute token.
# Unlike break-glass these keep the `default` policy, so a token can look
# itself up and revoke itself, which the bootstrap helpers rely on.
#
# CUSTODY: passwords are written beside vault-init.json, mode 0600:
#   <keys dir>/snapshot-operator-userpass.txt
#   <keys dir>/platform-admin-userpass.txt
# Both belong in the password-manager note. See documents/key-custody.md.
# ############################################################################
#
# Needs a ROOT token. After 99 that means regenerating one (break-glass login +
# three shares, documents/runbooks/seal-unseal.md), then revoking it again.
#
# Usage:
#   ./96-create-operators.sh                      # create if absent, then verify
#   ./96-create-operators.sh --rotate <user>      # new password for one user, then verify
#
# Exits non-zero if any verification fails.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ROTATE_USER=""
if [[ "${1:-}" == "--rotate" ]]; then
  ROTATE_USER="${2:-}"
  [[ -n "$ROTATE_USER" ]] || die "usage: $0 --rotate <snapshot-operator|platform-admin>"
fi

MOUNT="userpass"
OPERATORS=(snapshot-operator platform-admin)   # user name == policy name
[[ -z "$ROTATE_USER" || " ${OPERATORS[*]} " == *" ${ROTATE_USER} "* ]] \
  || die "unknown user '${ROTATE_USER}'. Known: ${OPERATORS[*]}"

require_cmd vault jq openssl
require_vault_env
require_vault_authenticated

# Writing userpass users and policies is beyond every non-root identity here.
# Fail early with the reason, rather than halfway through with a 403.
[[ "$(vault token lookup -format=json | jq -r '.data.policies | index("root") != null')" == "true" ]] \
  || die "this needs a ROOT token. Regenerate one first (break-glass + 3 shares):
     documents/runbooks/seal-unseal.md -> 'Generate a new root token'"

auth_method_enabled "$MOUNT" \
  || die "auth/${MOUNT} is not enabled. Run 95-create-breakglass.sh first."

KEYS_DIR="$(vault_poc_keys_dir)"
assert_keys_path_safe "$KEYS_DIR"

PASS=0; FAIL=0
pass() { log_ok  "PASS  $*"; PASS=$((PASS + 1)); }
fail() { log_err "FAIL  $*"; FAIL=$((FAIL + 1)); }

pw_file() { printf '%s/%s-userpass.txt' "$KEYS_DIR" "$1"; }

# ---------------------------------------------------------------------------
log_step "Policies"
for u in "${OPERATORS[@]}"; do
  vault policy write "$u" "${SCRIPT_DIR}/20-policies/${u}.hcl" >/dev/null
  log_ok "policy ${u}  (<- 20-policies/${u}.hcl)"
done

# ---------------------------------------------------------------------------
log_step "Users"

for u in "${OPERATORS[@]}"; do
  f="$(pw_file "$u")"
  settings=(token_policies="$u" token_ttl=15m token_max_ttl=1h)

  if vault read "auth/${MOUNT}/users/${u}" >/dev/null 2>&1 && [[ "$ROTATE_USER" != "$u" ]]; then
    [[ -r "$f" ]] || die "user '${u}' exists but ${f} is missing, so it cannot be verified.
     Restore it from the password-manager note, or: $0 --rotate ${u}"
    # Re-assert the settings without touching the password: no drift on re-run.
    vault write "auth/${MOUNT}/users/${u}" "${settings[@]}" >/dev/null
    log_skip "user ${u} (password file present; settings re-asserted)"
    continue
  fi

  umask 077
  new="$(mktemp "${KEYS_DIR}/.${u}.XXXXXX")"
  openssl rand -base64 32 | tr -d '\n' > "$new"
  # password=@file: never an argument (argv is visible in the process list),
  # never echoed.
  vault write "auth/${MOUNT}/users/${u}" password=@"$new" "${settings[@]}" >/dev/null
  mv -f "$new" "$f"
  chmod 0600 "$f"
  log_ok "user ${u}; password -> ${f} (0600)"
  log_warn "Add it to the password-manager note beside vault-init.json."
done

# ---------------------------------------------------------------------------
# Rule 6: prove what each token can and CANNOT do. `token capabilities` asks
# Vault's own policy engine, so nothing is written or read to find out.
log_step "Verify"

TOKENS=()
trap 'for t in "${TOKENS[@]}"; do vault token revoke "$t" >/dev/null 2>&1 || true; done' EXIT

login() {  # user -> token on stdout
  vault write -format=json "auth/${MOUNT}/login/$1" password=@"$(pw_file "$1")" 2>/dev/null \
    | jq -r '.auth.client_token // empty'
}

caps() {  # token path
  VAULT_TOKEN="$1" vault token capabilities "$2" 2>/dev/null || printf 'error'
}

expect() {  # token path cap...
  local t="$1" p="$2" got c; shift 2
  got="$(caps "$t" "$p")"
  for c in "$@"; do
    grep -qw -- "$c" <<<"$got" || { fail "${p}: needs ${*}, got [${got}]"; return; }
  done
  pass "${p}: ${*}"
}

expect_deny() {  # token path
  local got; got="$(caps "$1" "$2")"
  if [[ "$got" == "deny" ]]; then pass "denied: $2"; else fail "${2}: should be DENIED, got [${got}]"; fi
}

expect_no() {  # token path cap  (allowed to hold other caps there, not this one)
  local got; got="$(caps "$1" "$2")"
  if grep -qw -- "$3" <<<"$got"; then fail "${2}: must NOT have ${3}, got [${got}]"; else pass "${2}: no ${3}"; fi
}

for u in "${OPERATORS[@]}"; do
  log ""
  log "  -- ${u}"
  t="$(login "$u" || true)"   # a failed login must be reported, not abort the run
  if [[ -z "$t" ]]; then fail "login FAILED for ${u}"; continue; fi
  TOKENS+=("$t")
  pass "login works (token $(redact "$t"))"

  pols="$(VAULT_TOKEN="$t" vault token lookup -format=json | jq -r '.data.policies | sort | join(",")')"
  [[ "$pols" == "default,${u}" || "$pols" == "${u},default" ]] \
    && pass "token policies are exactly [${pols}]" \
    || fail "expected [default,${u}], got [${pols}]"

  case "$u" in
    snapshot-operator)
      expect      "$t" sys/storage/raft/snapshot read
      expect_no   "$t" sys/storage/raft/snapshot update
      expect_deny "$t" sys/storage/raft/snapshot-force
      expect_deny "$t" secret/data/level1/app
      expect_deny "$t" sys/policies/acl/snapshot-operator
      expect_deny "$t" sys/seal
      ;;
    platform-admin)
      expect      "$t" sys/policies/acl/team-example create read update delete
      expect      "$t" auth/kubernetes/role/team-example create read update delete
      expect      "$t" secret/data/teams/example/app create update
      expect_no   "$t" secret/data/teams/example/app read
      expect      "$t" secret/metadata/teams/example/app read list
      expect_deny "$t" sys/policies/acl/level4-pgp
      expect_deny "$t" sys/policies/acl/platform-admin
      expect_deny "$t" auth/kubernetes/role/level4-app
      expect_deny "$t" auth/kubernetes/role/eso
      expect_deny "$t" auth/userpass/users/breakglass
      expect_deny "$t" secret/data/level4/pgp
      expect_deny "$t" sys/storage/raft/snapshot
      expect_deny "$t" sys/generate-root/attempt
      expect_deny "$t" sys/seal
      expect_deny "$t" sys/mounts/secret
      expect_deny "$t" sys/audit/stdout
      ;;
  esac
done

# ---------------------------------------------------------------------------
log_step "Result"
log "  passed: ${PASS}   failed: ${FAIL}"
(( FAIL == 0 )) || { log_err "The operator identities are NOT proven. Fix the failures before relying on them."; exit 1; }

cat >&2 <<EOF

  Both identities are proven. With them, root is no longer needed for:

    snapshots   ./90-snapshot.sh            (logs in as snapshot-operator itself)
    new teams   ./80-onboard-team.sh <team> <namespace> <serviceaccount>
    audit       ./80-onboard-team.sh --verify

  Owed now:
    1. Add both passwords to the password-manager note:
         $(pw_file snapshot-operator)
         $(pw_file platform-admin)
    2. REVOKE THE ROOT TOKEN you regenerated for this:  vault token revoke -self
    3. Log both events in documents/key-custody.md.
EOF
