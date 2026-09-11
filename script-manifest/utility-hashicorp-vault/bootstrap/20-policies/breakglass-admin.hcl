# Break-glass administration — the recovery identity that Vault 2.0 made necessary.
#
# ############################################################################
# WHY THIS EXISTS
#
# Vault 2.0 made sys/generate-root and sys/rekey AUTHENTICATED by default. In 1.x
# they were unauthenticated, gated only by the unseal shares. D10 says: revoke
# the root token at the end of A6, and regenerate it from the shares on demand.
# On 2.x, once root is revoked, generate-root needs a token of its own — so
# without an identity like this one, revoking root is a lockout, not a hardening.
#
# The cluster owner chose to KEEP the new authenticated default, rather than set
# `enable_unauthenticated_access` to restore the 1.x behaviour. This policy is
# the other half of that decision.
#
# WHAT IT GRANTS — AND WHAT IT DELIBERATELY DOES NOT
#
# It can START a root generation or a rekey. It cannot FINISH either: both still
# require 3 of the 5 unseal shares. So this identity is one factor of two, not a
# root token in disguise. It has no access to any secret, auth method, mount, or
# policy — 95-create-breakglass.sh proves those denials before root is revoked.
#
# ON `sudo`: whether these endpoints require sudo under 2.0 could not be confirmed
# from the docs at build time. A recovery path that fails with "permission
# denied" in the middle of an incident is the worst possible outcome here, and
# sudo scoped to these two path trees is still narrow. 95- exercises the path
# end-to-end; if sudo proves unnecessary it can be dropped and re-verified.
# ############################################################################

path "sys/generate-root/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

path "sys/rekey/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}
