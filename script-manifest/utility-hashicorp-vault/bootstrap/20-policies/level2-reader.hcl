# Stage B Level 2 — the app performs the Kubernetes auth handshake itself and
# manages its own token lifecycle.
#
# See level1-reader.hcl for the KV v2 path trap (secret/data/... not secret/...).

path "secret/data/level2/*" {
  capabilities = ["read"]
}

# ############################################################################
# TOKEN SELF-MANAGEMENT
#
# Level 2's point is that the application owns its token lifecycle, so it must
# be able to inspect and renew its own token.
#
# NOTE: Vault's built-in `default` policy already grants both of these, and
# every token carries `default` unless created with -no-default-policy. They
# are stated explicitly here anyway — this level exists to make the handshake
# visible, and a permission that works only by inheritance teaches nothing.
#
# DEVIATION FROM THE PRD: the PRD's table says "update on auth/token/renew-self
# AND auth/token/lookup-self". lookup-self is a GET; granting only `update`
# on it would deny the lookup. Granting `read` here is what the PRD intends.
# ############################################################################

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
