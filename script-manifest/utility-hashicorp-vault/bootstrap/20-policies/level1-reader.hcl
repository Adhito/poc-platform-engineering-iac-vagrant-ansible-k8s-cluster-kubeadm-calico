# Stage B Level 1 — static secret delivered by ESO as an env var.
#
# ############################################################################
# THE KV v2 PATH TRAP — the single most common Vault policy mistake.
#
# The CLI shows   secret/level1/app
# The API path is secret/data/level1/app        (read/write)
#             and secret/metadata/level1/app    (list, delete, versions)
#
# A policy written against the path the CLI displays — "secret/level1/*" —
# applies without error and then DENIES EVERYTHING, because no request ever
# has that path. The failure looks like a broken role, not a broken policy.
# ############################################################################

path "secret/data/level1/*" {
  capabilities = ["read"]
}
