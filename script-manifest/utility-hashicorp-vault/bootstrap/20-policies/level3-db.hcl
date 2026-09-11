# Stage B Level 3 — dynamic database credentials.
#
# No KV path at all. This level reads a CREDENTIAL GENERATOR: each read of
# database/creds/level3-app makes Vault connect to PostgreSQL, CREATE ROLE a
# brand-new user with a random password and an expiry, and hand it back with a
# lease. Nothing is stored; the credential did not exist before the read.
#
# This is where Vault stops being "a nicer etcd". Teams that only ever use KV
# never enable dynamic secrets, leases, or revocation — which is where the
# actual security value lives.

path "database/creds/level3-app" {
  capabilities = ["read"]
}

# ############################################################################
# LEASE MANAGEMENT — load-bearing for Phase B3.
#
# The credential above expires (default_ttl 1h, max_ttl 24h). The app must
# renew its lease before expiry or its database connection dies mid-request.
# B3's acceptance criterion is ZERO request errors across a rotation, which is
# only achievable if the app can renew — so these are not optional extras.
#
# Both are POST endpoints, hence `update` rather than `read`.
# ############################################################################

path "sys/leases/renew" {
  capabilities = ["update"]
}

path "sys/leases/lookup" {
  capabilities = ["update"]
}
