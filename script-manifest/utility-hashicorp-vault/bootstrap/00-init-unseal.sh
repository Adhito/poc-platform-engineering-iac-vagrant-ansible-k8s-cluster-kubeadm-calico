#!/usr/bin/env bash
#
# Phase A2 step 4 — initialise Vault and unseal it (D5, D20).
#
# ############################################################################
# THIS SCRIPT PRODUCES THE MOST SENSITIVE ARTIFACT IN THE POC.
#
# `vault operator init` emits 5 unseal key shares and a root token, ONCE, and
# they cannot be recovered afterwards. Everything downstream depends on them,
# and a Raft snapshot is encrypted under this same seal — snapshots and
# vault-init.json are a MATCHED PAIR. Losing either loses both.
#
# Guards enforced before anything is written:
#   1. .gitignore must already cover vault-init.json
#   2. The resolved key directory must be OUTSIDE the repo tree (D20)
# ############################################################################
#
# Usage:
#   ./00-init-unseal.sh              # init if needed, then unseal VAULT_ADDR
#   ./00-init-unseal.sh --all-peers  # also unseal vault-1..N via kubectl exec (A4)
#
# Env:
#   VAULT_ADDR       required, https://
#   VAULT_CACERT     required
#   VAULT_POC_KEYS   optional, default ~/.credentials/vault-poc
#   VAULT_NAMESPACE_K8S  optional, default "vault" (Kubernetes namespace)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ALL_PEERS=0
[[ "${1:-}" == "--all-peers" ]] && ALL_PEERS=1

K8S_NS="${VAULT_NAMESPACE_K8S:-vault}"
KEY_SHARES=5
KEY_THRESHOLD=3

require_cmd vault jq
require_vault_env
require_vault_reachable

# ---------------------------------------------------------------------------
log_step "Guard 1/2 — .gitignore must cover vault-init.json"

REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$REPO_ROOT" ]]; then
  if git -C "$REPO_ROOT" check-ignore -q vault-init.json 2>/dev/null; then
    log_ok ".gitignore covers vault-init.json"
  else
    die "vault-init.json is NOT gitignored in ${REPO_ROOT}.
     Commit a .gitignore containing it BEFORE any secret material can exist:
       vault-init.json
       *.key
       *.asc
       *.snap
       .env"
  fi
else
  log_warn "not inside a git repo — skipping the .gitignore check"
fi

# ---------------------------------------------------------------------------
log_step "Guard 2/2 — key directory must be outside the repo (D20)"

KEYS_DIR="$(vault_poc_keys_dir)"
assert_path_outside_repo "$KEYS_DIR"
KEYS_FILE="${KEYS_DIR}/vault-init.json"
log_ok "keys directory: ${KEYS_DIR} (0700, outside the repo)"

# ---------------------------------------------------------------------------
log_step "Initialise"

if vault_is_initialized; then
  log_skip "Vault is already initialised"
  [[ -r "$KEYS_FILE" ]] || die "Vault is initialised but ${KEYS_FILE} is missing or unreadable.
     Without the shares this instance cannot be unsealed and cannot be recovered.
     Retrieve them from the password-manager copy before going further."
else
  [[ ! -e "$KEYS_FILE" ]] || die "Vault reports uninitialised, but ${KEYS_FILE} already exists.
     Refusing to overwrite: those shares may belong to a Raft snapshot you still need.
     Move the file aside deliberately if this really is a fresh cluster."

  log "  running: vault operator init -key-shares=${KEY_SHARES} -key-threshold=${KEY_THRESHOLD}"
  umask 077
  vault operator init \
    -key-shares="${KEY_SHARES}" \
    -key-threshold="${KEY_THRESHOLD}" \
    -format=json > "$KEYS_FILE"
  chmod 0600 "$KEYS_FILE"
  log_ok "initialised; ${KEY_SHARES} shares written to ${KEYS_FILE} (0600)"

  log_warn "DO THIS NOW, not later: paste the full contents of that file into a"
  log_warn "password-manager secure note. ~/.credentials survives 'vagrant destroy'"
  log_warn "but not disk failure, OS reinstall, or a lost laptop (D20)."
fi

# ---------------------------------------------------------------------------
log_step "Unseal"

# Keys are passed on STDIN, never as argv — argv is visible in the process list
# to every user on the box.
unseal_via_addr() {
  local i key
  for (( i = 0; i < KEY_THRESHOLD; i++ )); do
    key="$(jq -r ".unseal_keys_b64[$i]" "$KEYS_FILE")"
    [[ -n "$key" && "$key" != "null" ]] || die "share $i missing from ${KEYS_FILE}"
    printf '%s' "$key" | vault operator unseal - >/dev/null
    log_ok "applied share $((i + 1))/${KEY_THRESHOLD}  ($(redact "$key"))"
  done
}

unseal_peer() {
  local pod="$1" i key
  for (( i = 0; i < KEY_THRESHOLD; i++ )); do
    key="$(jq -r ".unseal_keys_b64[$i]" "$KEYS_FILE")"
    printf '%s' "$key" \
      | kubectl -n "$K8S_NS" exec -i "$pod" -- vault operator unseal - >/dev/null
  done
  log_ok "${pod} unsealed"
}

if vault_is_sealed; then
  unseal_via_addr
else
  log_skip "the node behind ${VAULT_ADDR} is already unsealed"
fi

if (( ALL_PEERS )); then
  # Phase A4 step 3 — EVERY PEER SEALS INDEPENDENTLY. This surprises people:
  # unsealing the leader does not unseal the followers, and a sealed follower
  # still passes its readiness probe, so nothing looks wrong.
  log_step "Unseal remaining peers (A4)"
  require_cmd kubectl
  mapfile -t PODS < <(
    kubectl -n "$K8S_NS" get pods \
      -l app.kubernetes.io/name=vault,component=server \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
  )
  for pod in "${PODS[@]}"; do
    if kubectl -n "$K8S_NS" exec "$pod" -- vault status -format=json 2>/dev/null \
         | jq -e '.sealed == false' >/dev/null 2>&1; then
      log_skip "${pod} already unsealed"
    else
      unseal_peer "$pod"
    fi
  done
fi

# ---------------------------------------------------------------------------
log_step "Verify"

require_vault_unsealed
STATUS="$(vault_status_json)"
log_ok "initialized : $(jq -r '.initialized' <<<"$STATUS")"
log_ok "sealed      : $(jq -r '.sealed'      <<<"$STATUS")"
log_ok "storage     : $(jq -r '.storage_type' <<<"$STATUS")"
log_ok "HA mode     : $(jq -r '.ha_mode // "n/a"' <<<"$STATUS")"

cat >&2 <<'EOF'

  Next:
    export VAULT_TOKEN="$(jq -r .root_token "$HOME/.credentials/vault-poc/vault-init.json")"
    ./10-enable-kubernetes-auth.sh

  Still owed by this phase's exit gate:
    - Password-manager copy of vault-init.json
    - A RESTORE TEST: seal a node and unseal it using a share retrieved from that
      copy rather than the working file. A backup you have never read from is a
      hypothesis, not a backup.
    - documents/key-custody.md recording the METHOD and HOLDER — never the
      location, never the shares.
EOF
