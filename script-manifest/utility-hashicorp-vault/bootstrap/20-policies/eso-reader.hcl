# External Secrets Operator — the Level 1 delivery path (Phase A8).
#
# ESO authenticates as its own ServiceAccount, reads from Vault, and writes an
# ordinary Kubernetes Secret into the application namespace. The Level 1 app
# then reads a Secret and never knows Vault exists.
#
# Scoped to level1 only. ESO is infrastructure with broad reach — it can write
# Secrets into any namespace — so its READ scope is kept as narrow as the job
# requires. It has no business seeing level2, level3, or the PGP key.

path "secret/data/level1/*" {
  capabilities = ["read"]
}

# ############################################################################
# WHY `metadata` AND WHY `list` — the other half of the KV v2 path trap.
#
# Reads go to secret/data/<path>; LISTING goes to secret/metadata/<path>.
# They are different API paths backed by different capabilities, even though
# the CLI hides the distinction. ESO enumerates keys when resolving a
# dataFrom/find selector, so without this it fails on discovery while
# succeeding on a direct key reference — an inconsistency that looks like an
# ESO bug and is a policy gap.
# ############################################################################

path "secret/metadata/*" {
  capabilities = ["list"]
}
