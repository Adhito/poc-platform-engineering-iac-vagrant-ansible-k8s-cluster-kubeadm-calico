# Taking Raft snapshots after root is revoked (A9.2). Used by 90-snapshot.sh
# through the `snapshot-operator` userpass login from 96-create-operators.sh.
#
# ############################################################################
# SAVE, NOT RESTORE.
#
# `vault operator raft snapshot save` is a READ of sys/storage/raft/snapshot.
# Restoring is an UPDATE of that path (or of snapshot-force), and it overwrites
# the entire dataset, so it stays a root-only operation. A leaked
# snapshot-operator password lets someone copy an encrypted snapshot, which is
# unopenable without the unseal shares. It does not let them change anything.
# ############################################################################

path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

# 90-snapshot.sh records which peers existed at the time of the snapshot.
path "sys/storage/raft/configuration" {
  capabilities = ["read"]
}
