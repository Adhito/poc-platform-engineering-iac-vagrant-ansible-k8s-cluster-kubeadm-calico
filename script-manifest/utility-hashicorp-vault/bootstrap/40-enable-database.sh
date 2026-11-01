#!/usr/bin/env bash
#
# Phase A7 steps 3–4 — the database secrets engine against the POC PostgreSQL.
#
# This is the engine that makes dynamic secrets concrete. Each read of
# database/creds/level3-app causes Vault to CREATE ROLE a fresh PostgreSQL user
# with a random password and an expiry, hand it back under a lease, and DROP
# ROLE it when that lease is revoked or expires. Nothing is stored.
#
# ############################################################################
# THIS SCRIPT ROTATES THE POSTGRES ADMIN PASSWORD — A ONE-WAY DOOR.
#
# `database/rotate-root` replaces the vaultadmin password with one that Vault
# alone knows. That is the point (after it, no human holds the credential), but
# the consequences are real:
#
#   - The `postgres-admin` Kubernetes Secret is STALE from that moment on. It
#     is not updated, and it cannot be used to log in again.
#   - PostgreSQL only reads that Secret when initialising an EMPTY data
#     directory. So the running instance is fine — but if the PVC is ever lost
#     and Postgres re-initialises, it comes back with the OLD password while
#     Vault still holds the rotated one. Symptom: every dynamic credential
#     request fails to authenticate. Fix: re-run this script, which detects the
#     mismatch and reconfigures.
#   - Rotation is therefore guarded to run ONCE, when the connection is first
#     created. A re-run of this script will not rotate again.
# ############################################################################

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

MOUNT="database"
CONN="poc-postgres"
ROLE="level3-app"
APP_NS="poc-hashicorp-vault-application"
PG_SECRET="postgres-admin"
PG_HOST="postgres.${APP_NS}.svc"
PG_DB="appdb"
PG_ADMIN_USER="vaultadmin"
PG_POD="postgres-0"

require_cmd vault jq kubectl
require_vault_env
require_vault_authenticated

# ---------------------------------------------------------------------------
log_step "Enable the database secrets engine"

if secrets_engine_enabled "$MOUNT"; then
  log_skip "${MOUNT}/"
else
  vault secrets enable "$MOUNT" >/dev/null
  log_ok "${MOUNT}/ enabled"
fi

# ---------------------------------------------------------------------------
log_step "Configure the connection to ${PG_HOST}"

if vault read "${MOUNT}/config/${CONN}" >/dev/null 2>&1; then
  log_skip "${MOUNT}/config/${CONN} already configured"
  log_warn "not re-writing the connection: its password has already been rotated"
  log_warn "and the ${PG_SECRET} Secret no longer holds a working credential."
  ROTATE=0
else
  kubectl -n "$APP_NS" get secret "$PG_SECRET" >/dev/null 2>&1 \
    || die "Secret ${APP_NS}/${PG_SECRET} not found.
     It is deliberately not in git (Rule 1). Create it before first sync:
       kubectl -n ${APP_NS} create secret generic ${PG_SECRET} \\
         --from-literal=POSTGRES_PASSWORD=\"\$(openssl rand -base64 24)\""

  PG_PW="$(kubectl -n "$APP_NS" get secret "$PG_SECRET" \
    -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
  [[ -n "$PG_PW" ]] || die "${PG_SECRET} has no POSTGRES_PASSWORD key"
  log_ok "admin credential read from Secret  ($(redact "$PG_PW"))"

  # allowed_roles is an allow-list, not decoration: without level3-app named
  # here, the role below can be created and will still refuse to issue.
  vault write "${MOUNT}/config/${CONN}" \
    plugin_name=postgresql-database-plugin \
    allowed_roles="$ROLE" \
    connection_url="postgresql://{{username}}:{{password}}@${PG_HOST}:5432/${PG_DB}?sslmode=disable" \
    username="$PG_ADMIN_USER" \
    password="$PG_PW" >/dev/null

  log_ok "connection ${CONN} configured"
  log_warn "sslmode=disable — POC shortcut. The traffic is pod-to-pod inside the"
  log_warn "cluster; a real deployment terminates TLS on the database connection."
  ROTATE=1
fi

# ---------------------------------------------------------------------------
log_step "Create the ${ROLE} role"

# creation_statements run as vaultadmin, per generated credential.
# GRANT SELECT covers tables existing at that moment — the seed ConfigMap also
# sets ALTER DEFAULT PRIVILEGES so later tables are not invisible to new roles.
#
# revocation_statements must undo that GRANT before dropping the role: PostgreSQL
# refuses to DROP a role that still holds privileges ("cannot be dropped because
# some objects depend on it"). Vault runs revocation in the background, so with
# a bare DROP ROLE `vault lease revoke` still reports success while the user
# stays alive until its VALID UNTIL, and Vault retries and logs the error.
vault write "${MOUNT}/roles/${ROLE}" \
  db_name="$CONN" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  revocation_statements="REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h" >/dev/null

log_ok "role ${ROLE} (default_ttl=1h max_ttl=24h)"

# ---------------------------------------------------------------------------
if (( ROTATE )); then
  log_step "Rotate the admin password (one-way)"
  vault write -f "${MOUNT}/rotate-root/${CONN}" >/dev/null
  log_ok "rotated — the ${PG_ADMIN_USER} password is now known to NO PERSON"
  log_warn "${APP_NS}/${PG_SECRET} is stale from here on. Leave it: PostgreSQL"
  log_warn "reads it only when initialising an empty data directory."
else
  log_step "Rotate the admin password"
  log_skip "already rotated on a previous run"
fi

# ---------------------------------------------------------------------------
# Rule 6 — prove the engine issues credentials, do not assume it.
# The full proof (connect, then revoke, then fail to connect) is Phase A7 step 4
# and needs psql; this confirms issuance, which is what the script can own.
log_step "Verify issuance"

CRED="$(vault read -format=json "${MOUNT}/creds/${ROLE}" 2>/dev/null)" \
  || die "could not issue a credential from ${MOUNT}/creds/${ROLE}.
     Check Vault can reach ${PG_HOST}:5432 and that vaultadmin can CREATE ROLE."

GEN_USER="$(jq -r '.data.username' <<<"$CRED")"
LEASE_ID="$(jq -r '.lease_id'      <<<"$CRED")"
LEASE_TTL="$(jq -r '.lease_duration' <<<"$CRED")"

# Rule 2: username and lease id are safe to log; the password is not.
log_ok "issued user=${GEN_USER} lease=${LEASE_ID} ttl=${LEASE_TTL}s"

vault lease revoke "$LEASE_ID" >/dev/null

# A successful `lease revoke` only means Vault accepted it; the DROP ROLE runs in
# the background and a failure there is only logged. Check PostgreSQL itself.
# (Over the pod's local socket, which the image trusts: anyone who can exec into
# the pod is a database admin. Acceptable for the POC.)
role_count() {
  kubectl -n "$APP_NS" exec "$PG_POD" -- \
    psql -U "$PG_ADMIN_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM pg_roles WHERE rolname = '${GEN_USER}'"
}
for _ in 1 2 3 4 5; do
  [[ "$(role_count)" == "0" ]] && break
  sleep 2
done
[[ "$(role_count)" == "0" ]] \
  || die "lease ${LEASE_ID} was revoked but role ${GEN_USER} still exists in PostgreSQL.
     Look for 'failed to revoke lease' in: kubectl -n vault logs vault-0"
log_ok "revoked the test lease, and role ${GEN_USER} is gone from PostgreSQL"

cat >&2 <<EOF

  Still owed by A7's exit gate — the part this script cannot prove alone:
  watch a revoked credential stop WORKING, not just disappear. psql has to run
  inside the cluster (the Service is ClusterIP); use kubectl exec into ${PG_POD}
  and connect over the pod IP, since localhost is trusted without a password:
    vault read ${MOUNT}/creds/${ROLE}          # note username + lease_id
    psql -h <pod-ip> -U <generated-user> ${PG_DB}  # must SUCCEED
    vault lease revoke <lease_id>
    psql -h <pod-ip> -U <generated-user> ${PG_DB}  # must now FAIL
    # then as an admin:  \\du   -> the role must be GONE

  A revocation you have not watched fail is not a proven revocation.

  Next: ./50-seed-secrets.sh
EOF
