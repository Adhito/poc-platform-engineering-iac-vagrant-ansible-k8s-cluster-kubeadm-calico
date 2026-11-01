#!/usr/bin/env bash
#
# Replace the five unseal key shares (rekey). Use when a share has been exposed,
# a holder leaves, or the split changes. See documents/runbooks/seal-unseal.md.
#
# The master key does NOT change, only the shares that reconstruct it. Every
# existing snapshot stays restorable, with the NEW shares.
#
# ############################################################################
# THE NEW SHARES ARE NEVER PRINTED.
#
# `vault operator rekey` prints the new shares to the terminal, exactly once.
# That is how shares end up in screenshots, scrollback and chat transcripts,
# which is usually why a rekey is happening in the first place. This script
# talks to the API directly and writes the new shares straight to disk.
#
# AND THE OLD SHARES STAY VALID UNTIL THE NEW ONES ARE PROVEN.
#
# The rekey is started with require_verification=true. Vault then keeps the
# OLD shares active until a threshold of the NEW ones has been supplied back to
# sys/rekey/verify. This script reads them back FROM THE SAVED FILE for that
# step, so the switch only happens once the file is known to hold working
# shares. Any failure before that point cancels the rekey and nothing changes.
# ############################################################################
#
# Usage:
#   ./85-rekey.sh            # current shares read from vault-init.json
#   ./85-rekey.sh --prompt   # type the current shares (hidden), e.g. from the
#                            # password-manager copy when the file is gone
#
# Needs a token allowed on sys/rekey/* (authenticated on Vault 2.x): the root
# token during bootstrap, or a break-glass login after 99-revoke-root.sh.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROMPT=0
[[ "${1:-}" == "--prompt" ]] && PROMPT=1

KEY_SHARES=5
KEY_THRESHOLD=3

require_cmd vault jq curl
require_vault_env
require_vault_authenticated

TOKEN="${VAULT_TOKEN:-$(cat "${HOME}/.vault-token" 2>/dev/null || true)}"
[[ -n "$TOKEN" ]] || die "no token in VAULT_TOKEN or ~/.vault-token"

KEYS_DIR="$(vault_poc_keys_dir)"
assert_keys_path_safe "$KEYS_DIR"
KEYS_FILE="${KEYS_DIR}/vault-init.json"
[[ -r "$KEYS_FILE" ]] || die "${KEYS_FILE} not found. The new shares are written in its format,
     so it has to exist (its root_token field is carried over as-is)."

STAMP="$(date +%F-%H%M%S)"
NEW_FILE="${KEYS_DIR}/vault-init.rekey-${STAMP}.json"
OLD_FILE="${KEYS_DIR}/vault-init.pre-rekey-${STAMP}.json"

# Calls the API with the token in a header read from a file descriptor, so it
# never appears in the process list. JSON body (if any) on stdin.
vault_api() {  # METHOD PATH
  curl -sS --cacert "$VAULT_CACERT" -X "$1" \
    -H @<(printf 'X-Vault-Token: %s\n' "$TOKEN") \
    -H 'Content-Type: application/json' \
    --data-binary @- "${VAULT_ADDR%/}/v1/$2"
}

api_ok() {  # $1 = response; dies on a Vault error
  jq -e '(.errors // []) | length == 0' <<<"$1" >/dev/null 2>&1 \
    || die "Vault said: $(jq -r '(.errors // ["unparseable response"]) | join("; ")' <<<"$1" 2>/dev/null || printf 'unparseable response')"
}

# ---------------------------------------------------------------------------
log_step "Preflight"

STATUS="$(vault_api GET sys/rekey/init </dev/null)"
api_ok "$STATUS"
if jq -e '.started == true' <<<"$STATUS" >/dev/null; then
  die "a rekey is already in progress (someone else's, or an interrupted run).
     Cancel it first, which leaves the current shares in place:
       vault operator rekey -cancel"
fi
log_ok "no rekey in progress"
log_ok "current shares from: $( (( PROMPT )) && echo 'hidden prompt' || echo "$KEYS_FILE" )"

# ---------------------------------------------------------------------------
STATE="none"
cleanup() {
  [[ "$STATE" == "done" || "$STATE" == "none" ]] && return 0
  # Cancels the whole rekey, including a pending verification: the OLD shares
  # remain the valid ones.
  vault_api DELETE sys/rekey/init </dev/null >/dev/null 2>&1 || true
  log_warn "rekey CANCELLED — the old shares are still the valid ones"
  [[ -e "$NEW_FILE" ]] && log_warn "the unverified ${NEW_FILE} is not usable; remove it by hand"
}
trap cleanup EXIT

log_step "Start the rekey (${KEY_SHARES} shares, threshold ${KEY_THRESHOLD}, verification required)"

INIT="$(printf '{"secret_shares":%d,"secret_threshold":%d,"require_verification":true}' \
          "$KEY_SHARES" "$KEY_THRESHOLD" | vault_api PUT sys/rekey/init)"
api_ok "$INIT"
STATE="started"
NONCE="$(jq -r '.nonce' <<<"$INIT")"
log_ok "started  (nonce ${NONCE})"

current_share() {  # $1 = index
  local k
  if (( PROMPT )); then
    read -rs -p "  Current unseal share $(( $1 + 1 ))/${KEY_THRESHOLD} (hidden): " k </dev/tty; echo >&2
  else
    k="$(jq -r ".unseal_keys_b64[$1] // empty" "$KEYS_FILE")"
  fi
  [[ -n "$k" ]] || die "no current share $(( $1 + 1 ))"
  printf '%s' "$k"
}

log_step "Authorize with ${KEY_THRESHOLD} of the CURRENT shares"

RESP=""
for (( i = 0; i < KEY_THRESHOLD; i++ )); do
  KEY="$(current_share "$i")"
  RESP="$(printf '{"key":"%s","nonce":"%s"}' "$KEY" "$NONCE" | vault_api PUT sys/rekey/update)"
  unset KEY
  api_ok "$RESP"
  if jq -e '.complete == true' <<<"$RESP" >/dev/null; then
    log_ok "share $(( i + 1 ))/${KEY_THRESHOLD} accepted — new shares generated"
    break
  fi
  log_ok "share $(( i + 1 ))/${KEY_THRESHOLD} accepted"
done

jq -e '.complete == true' <<<"$RESP" >/dev/null \
  || die "the rekey did not complete after ${KEY_THRESHOLD} shares"
jq -e '.verification_required == true' <<<"$RESP" >/dev/null \
  || die "Vault did not hold the switch for verification; refusing to continue blind"
STATE="generated"
VERIFY_NONCE="$(jq -r '.verification_nonce' <<<"$RESP")"

# ---------------------------------------------------------------------------
log_step "Save the new shares (never printed)"

umask 077
# The response goes in on stdin, not as an argument: arguments are visible in
# the process list.
jq --slurpfile r /dev/stdin \
   --argjson n "$KEY_SHARES" --argjson t "$KEY_THRESHOLD" \
   '.unseal_keys_b64 = $r[0].keys_base64
    | .unseal_keys_hex = $r[0].keys
    | .unseal_shares = $n
    | .unseal_threshold = $t' \
   "$KEYS_FILE" <<<"$RESP" > "${NEW_FILE}.tmp"
unset RESP
mv -f "${NEW_FILE}.tmp" "$NEW_FILE"
chmod 0600 "$NEW_FILE"
[[ "$(jq '.unseal_keys_b64 | length' "$NEW_FILE")" == "$KEY_SHARES" ]] \
  || die "the saved file does not hold ${KEY_SHARES} new shares"
log_ok "written: ${NEW_FILE}"

# ---------------------------------------------------------------------------
log_step "Verify the new shares — read back FROM THE SAVED FILE"

for (( i = 0; i < KEY_THRESHOLD; i++ )); do
  KEY="$(jq -r ".unseal_keys_b64[$i]" "$NEW_FILE")"
  VRESP="$(printf '{"key":"%s","nonce":"%s"}' "$KEY" "$VERIFY_NONCE" | vault_api PUT sys/rekey/verify)"
  unset KEY
  api_ok "$VRESP"
  log_ok "new share $(( i + 1 ))/${KEY_THRESHOLD} verified"
done
jq -e '.complete == true' <<<"$VRESP" >/dev/null \
  || die "verification did not complete"
STATE="done"
log_ok "Vault switched to the new shares — the old ones are now worthless"

# ---------------------------------------------------------------------------
log_step "Swap the files"

mv -f "$KEYS_FILE" "$OLD_FILE"
mv -f "$NEW_FILE" "$KEYS_FILE"
log_ok "${KEYS_FILE}  <- new shares"
log_ok "${OLD_FILE}  <- old shares (worthless now)"

vault_is_sealed && die "Vault reports sealed after the rekey — investigate before anything else"
log_ok "Vault still unsealed"

cat >&2 <<EOF

  Owed now:
    1. Replace the password-manager copy with the new ${KEYS_FILE}.
       Until you do, the backup holds shares that no longer open anything.
    2. Delete ${OLD_FILE} once (1) is done.
       Its shares are dead; its root_token is the same as the new file's.
    3. Log the rekey (date, reason) in documents/key-custody.md: the event,
       never the shares.

  Snapshots taken before today are still restorable, with the NEW shares.
EOF
