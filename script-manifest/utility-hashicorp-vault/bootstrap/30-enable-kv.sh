#!/usr/bin/env bash
#
# Phase A7 step 1 — enable the KV v2 secrets engine at secret/ (D11).
#
# v2 rather than v1 for versioning, soft delete, and metadata — the things that
# make KV usable operationally. The cost is the split API surface
# (secret/data/... vs secret/metadata/...), which is a well-known stumbling
# block and is hit deliberately here so it is recognised in Stage B.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

MOUNT="secret"

require_cmd vault jq
require_vault_env
require_vault_authenticated

log_step "Enable KV v2 at ${MOUNT}/"

if secrets_engine_enabled "$MOUNT"; then
  # Guarded, not blindly re-run: `vault secrets enable` on an existing path
  # fails with "path is already in use", which on a re-run is noise that hides
  # real errors (Rule 9).
  log_skip "${MOUNT}/ is already mounted"

  VERSION="$(vault read -format=json "sys/mounts/${MOUNT}" 2>/dev/null \
    | jq -r '.data.options.version // "1"')"
  if [[ "$VERSION" == "2" ]]; then
    log_ok "confirmed KV version 2"
  else
    die "${MOUNT}/ is mounted as KV v${VERSION}, not v2.
     Every policy in 20-policies/ is written against v2 paths (secret/data/...)
     and will deny everything against a v1 mount. This needs deciding, not
     patching: an in-place v1->v2 upgrade rewrites paths under existing data."
  fi
else
  vault secrets enable -path="$MOUNT" -version=2 kv >/dev/null
  log_ok "${MOUNT}/ enabled as KV v2"
fi

# ---------------------------------------------------------------------------
log_step "Record lease TTLs (Phase A7 step 6)"

# Level 3's renewal behaviour depends on these, and Stage B Phase B3
# deliberately shortens them to force rotation inside a test window. Recording
# the starting values here means B3 has something to restore to.
SYS_TTL="$(vault read -format=json sys/config/state/sanitized 2>/dev/null \
  | jq -r '.data.default_lease_ttl // "unknown"')"
SYS_MAX="$(vault read -format=json sys/config/state/sanitized 2>/dev/null \
  | jq -r '.data.max_lease_ttl // "unknown"')"

log_ok "system default_lease_ttl : ${SYS_TTL}"
log_ok "system max_lease_ttl     : ${SYS_MAX}"
log_warn "record these in documents/environment.md — B3 changes them and needs a baseline"

log ""
log "  Next: ./40-enable-database.sh"
