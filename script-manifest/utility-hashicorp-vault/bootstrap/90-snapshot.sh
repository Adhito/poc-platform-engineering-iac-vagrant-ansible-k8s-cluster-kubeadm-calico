#!/usr/bin/env bash
#
# Phase A9.2 — take a Raft snapshot.
#
# ############################################################################
# THE MOST MISUNDERSTOOD POINT IN VAULT DR:
#
#   A SNAPSHOT IS ENCRYPTED UNDER THE SEAL OF THE CLUSTER IT CAME FROM.
#
# It is not a portable export. Without the original unseal shares it is an
# unopenable blob. vault-init.json and the snapshots are a MATCHED PAIR —
# losing either loses both.
#
# That is why snapshots are written next to the keys, outside the repo, and not
# into the working tree where `git clean -xfd` would take them.
#
# Also worth knowing before the restore drill (A9.3):
#   - `snapshot restore -force` OVERWRITES the target's entire dataset. It is
#     not a merge, and there is no partial restore.
#   - After restoring you unseal with the ORIGINAL shares. The keys from any
#     fresh `operator init` on the target are discarded — the restore brings
#     the old seal back with it.
# ############################################################################

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd vault jq
require_vault_env
require_vault_authenticated

SNAP_DIR="${VAULT_POC_SNAPSHOTS:-$(vault_poc_keys_dir)/snapshots}"
assert_path_outside_repo "$SNAP_DIR"
mkdir -p "$SNAP_DIR"; chmod 0700 "$SNAP_DIR"

STAMP="$(date +%F-%H%M%S)"
SNAP="${SNAP_DIR}/vault-${STAMP}.snap"

log_step "Take the snapshot"

STORAGE="$(vault_status_json | jq -r '.storage_type')"
[[ "$STORAGE" == "raft" ]] \
  || die "storage type is '${STORAGE}', not raft. The snapshot API is Raft-only."

umask 077
vault operator raft snapshot save "$SNAP"
chmod 0600 "$SNAP"

[[ -s "$SNAP" ]] || die "snapshot file is empty: ${SNAP}"
log_ok "saved ${SNAP} ($(du -h "$SNAP" | cut -f1))"

# ---------------------------------------------------------------------------
log_step "Peers at time of snapshot"
vault operator raft list-peers -format=json 2>/dev/null \
  | jq -r '.data.config.servers[] | "  \(.node_id)  leader=\(.leader)  \(.address)"' >&2 \
  || log_warn "could not list peers (single-node clusters may not report any)"

# ---------------------------------------------------------------------------
log_step "Retention"
# Deliberately simple: keep the last 10. A real environment ships these
# off-host, because a snapshot stored only on the machine that also holds the
# unseal keys survives neither a disk failure nor a stolen laptop.
mapfile -t OLD < <(ls -1t "${SNAP_DIR}"/vault-*.snap 2>/dev/null | tail -n +11)
if (( ${#OLD[@]} )); then
  for f in "${OLD[@]}"; do rm -f "$f"; log_ok "pruned $(basename "$f")"; done
else
  log_skip "nothing to prune (keeping the 10 most recent)"
fi

cat >&2 <<EOF

  Snapshots: ${SNAP_DIR}
  Keys:      $(vault_poc_keys_dir)/vault-init.json

  These two are a matched pair. A snapshot without its shares is unopenable.

  A9.3 is the drill that turns this from a file into a proven capability —
  and its real output is a NUMBER: wall-clock time from destroying Vault to
  serving reads again. That is your actual RTO. It belongs in the runbook,
  not in a terminal you will close.
EOF
