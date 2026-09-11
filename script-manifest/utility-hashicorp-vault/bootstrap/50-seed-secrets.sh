#!/usr/bin/env bash
#
# Phase A7 steps 1 & 5 — seed every secret Stage B expects, including the PGP
# key material for Level 4 (D13).
#
# On D13: Vault has no PGP secrets engine. PGP appears in Vault only as an
# OUTPUT wrapper (for encrypting unseal key shares). A PGP private key is just
# bytes Vault custodies, so KV v2 is the correct home for it. Transit is
# Vault-native crypto and a genuinely different pattern — it would not satisfy
# Level 4's "pull the key out and use it" requirement.
#
# ############################################################################
# THE PRIVATE KEY EXISTS ON DISK FOR A FEW SECONDS AND THEN MUST NOT.
#
# Generation happens in a temp GNUPGHOME that the EXIT trap wipes, whether this
# script succeeds, fails, or is interrupted. Phase B4 measures the "PGP key
# on-disk window" as a deliverable — this script keeps that window to the
# span between `gpg --export-secret-keys` and the trap firing.
# ############################################################################

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

MOUNT="secret"
PGP_PATH="level4/pgp"
KEY_NAME="Vault POC Level 4"
KEY_EMAIL="level4@vault-poc.local"

require_cmd vault jq gpg openssl
require_vault_env
require_vault_authenticated

secrets_engine_enabled "$MOUNT" \
  || die "${MOUNT}/ is not mounted. Run 30-enable-kv.sh first."

# ---------------------------------------------------------------------------
log_step "Seed KV secrets for Levels 1 and 2"

# `vault kv put` replaces by path and creates a new version — inherently
# idempotent, and the version history is a feature of KV v2 rather than clutter.
vault kv put -mount="$MOUNT" level1/app \
  greeting="hello from vault" \
  api_key="static-poc-key-001" >/dev/null
log_ok "${MOUNT}/level1/app  (greeting, api_key)"

vault kv put -mount="$MOUNT" level2/app \
  message="fetched via direct k8s auth" \
  tier="gold" >/dev/null
log_ok "${MOUNT}/level2/app  (message, tier)"

# ---------------------------------------------------------------------------
log_step "PGP key material for Level 4"

if kv_path_exists "$MOUNT" "$PGP_PATH"; then
  log_skip "${MOUNT}/${PGP_PATH} already exists"
  log_warn "NOT regenerating. A new keypair would orphan every fixture already"
  log_warn "encrypted to the old one, including whatever Stage B has committed."
  log_warn "To rotate deliberately: 'vault kv delete -mount=${MOUNT} ${PGP_PATH}',"
  log_warn "re-run this, then re-encrypt and re-ship the fixture."
else
  ARTIFACT_DIR="$(vault_poc_keys_dir)/level4-artifacts"
  assert_path_outside_repo "$ARTIFACT_DIR"
  mkdir -p "$ARTIFACT_DIR"; chmod 0700 "$ARTIFACT_DIR"

  TMP="$(mktemp -d)"
  # The trap is the control that enforces the on-disk window. It fires on
  # success, failure, and interrupt.
  trap 'rm -rf "$TMP"; log_ok "temp GNUPGHOME wiped: $TMP"' EXIT
  chmod 0700 "$TMP"
  export GNUPGHOME="${TMP}/gnupg"
  mkdir -p "$GNUPGHOME"; chmod 0700 "$GNUPGHOME"

  PGP_PASSPHRASE="$(openssl rand -base64 32)"
  log_ok "passphrase generated  ($(redact "$PGP_PASSPHRASE"))"

  log "  generating RSA-4096 keypair (this takes a moment — it needs entropy)"
  cat > "${TMP}/keyparams" <<EOF
%echo generating
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: ${KEY_NAME}
Name-Email: ${KEY_EMAIL}
Expire-Date: 0
Passphrase: ${PGP_PASSPHRASE}
%commit
%echo done
EOF
  gpg --batch --quiet --gen-key "${TMP}/keyparams" 2>/dev/null
  rm -f "${TMP}/keyparams"   # it contains the passphrase in cleartext
  log_ok "keypair generated"

  gpg --batch --quiet --armor --export "$KEY_EMAIL" > "${TMP}/public.asc"
  gpg --batch --quiet --yes --pinentry-mode loopback \
      --passphrase "$PGP_PASSPHRASE" \
      --armor --export-secret-keys "$KEY_EMAIL" > "${TMP}/private.asc"

  [[ -s "${TMP}/public.asc"  ]] || die "public key export produced nothing"
  [[ -s "${TMP}/private.asc" ]] || die "private key export produced nothing"
  log_ok "exported  public=$(wc -c < "${TMP}/public.asc")B  private=$(wc -c < "${TMP}/private.asc")B"

  # ---- the fixture Stage B Level 4 decrypts -------------------------------
  cat > "${TMP}/fixture.txt" <<'EOF'
Vault POC — Stage B Level 4 fixture.

If you can read this, the application successfully:
  1. authenticated to Vault with its Kubernetes ServiceAccount
  2. read the PGP private key and passphrase from secret/level4/pgp
  3. decrypted this file IN MEMORY, without writing the key to disk
EOF

  gpg --batch --quiet --yes --trust-model always \
      --recipient "$KEY_EMAIL" \
      --armor --output "${ARTIFACT_DIR}/fixture.txt.pgp" \
      --encrypt "${TMP}/fixture.txt"
  log_ok "fixture encrypted -> ${ARTIFACT_DIR}/fixture.txt.pgp"

  # ---- upload -------------------------------------------------------------
  vault kv put -mount="$MOUNT" "$PGP_PATH" \
    private_key=@"${TMP}/private.asc" \
    public_key=@"${TMP}/public.asc" \
    passphrase="$PGP_PASSPHRASE" >/dev/null
  log_ok "uploaded to ${MOUNT}/${PGP_PATH}"

  # ---- prove it round-trips before destroying the only copy ---------------
  # Rule 6. If the upload were wrong, the trap below would delete the sole
  # remaining private key and the keypair would be unrecoverable.
  RB="$(vault kv get -mount="$MOUNT" -format=json "$PGP_PATH")"
  for k in private_key public_key passphrase; do
    v="$(jq -r ".data.data.${k} // empty" <<<"$RB")"
    [[ -n "$v" ]] || die "readback failed: ${k} is missing from ${MOUNT}/${PGP_PATH}"
    log_ok "readback ${k}: $(redact "$v")"
  done

  # ---- destroy the local private key --------------------------------------
  shred -u "${TMP}/private.asc" 2>/dev/null || rm -f "${TMP}/private.asc"
  [[ ! -e "${TMP}/private.asc" ]] || die "the private key is STILL on disk at ${TMP}/private.asc"
  log_ok "local private key destroyed — Vault now holds the only copy"

  cat >&2 <<EOF

  Artifact for the apps team:
    ${ARTIFACT_DIR}/fixture.txt.pgp

  That file is CIPHERTEXT and safe to commit — it ships with Stage B Level 4.
  It is written outside the repo only because it is produced alongside key
  material; move it deliberately rather than leaving it here.

  Note it is named .pgp, not .asc: the repo .gitignore excludes *.asc to catch
  exported KEYS, and this ciphertext is meant to be committed.
EOF
fi

# ---------------------------------------------------------------------------
log_step "Verify what Stage B will read"

for p in level1/app level2/app "$PGP_PATH"; do
  if kv_path_exists "$MOUNT" "$p"; then
    keys="$(vault kv get -mount="$MOUNT" -format=json "$p" | jq -r '.data.data | keys | join(", ")')"
    log_ok "${MOUNT}/${p}  ->  ${keys}"
  else
    log_err "${MOUNT}/${p} MISSING"
  fi
done

log ""
log "  Next: ./60-enable-audit.sh  (before Stage B, so its requests are captured)"
