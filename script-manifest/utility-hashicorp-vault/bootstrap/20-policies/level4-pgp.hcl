# Stage B Level 4 — PGP private key retrieval and in-memory decryption.
#
# Note how narrow this is: ONE path, not a wildcard. Level 4 needs exactly one
# secret, so it is granted exactly one secret.
#
# This narrowness is what makes the Phase A6 negative test meaningful — a
# level1-reader token attempting this path must return 403. All four Stage B
# apps share a namespace, so the ServiceAccount name bound to the role is the
# ENTIRE isolation boundary between them.

path "secret/data/level4/pgp" {
  capabilities = ["read"]
}
