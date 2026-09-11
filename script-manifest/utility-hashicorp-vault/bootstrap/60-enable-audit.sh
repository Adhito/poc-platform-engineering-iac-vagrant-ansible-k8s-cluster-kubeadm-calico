#!/usr/bin/env bash
#
# Phase A9.1 — enable the audit device (D14).
#
# ############################################################################
# RUN THIS BEFORE STAGE B DEPLOYS.
#
# Audit is not retroactive. Every Stage B request made before this point is
# simply unrecorded, and the whole reason Stage B exists is to exercise four
# access patterns — which is exactly what you want an audit trail of.
#
# WHY stdout AND NOT A PVC (D14):
# Vault refuses to serve requests it cannot audit. An audit file on a PVC that
# fills up therefore does not degrade Vault — it BLOCKS IT ENTIRELY. Writing to
# stdout removes that availability hazard for free. The cost is retention:
# pod log rotation is the retention policy, which is NOT adequate for a real
# environment, and the runbook must say so.
# ############################################################################

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DEVICE="file"
K8S_NS="${VAULT_NAMESPACE_K8S:-vault}"

require_cmd vault jq
require_vault_env
require_vault_authenticated

log_step "Enable the audit device"

if audit_device_enabled "$DEVICE"; then
  log_skip "audit device ${DEVICE}/"
else
  vault audit enable "$DEVICE" file_path=stdout >/dev/null
  log_ok "audit device enabled -> stdout"
fi

# ---------------------------------------------------------------------------
log_step "Verify"

vault audit list -format=json | jq -r 'to_entries[] | "  \(.key) type=\(.value.type) path=\(.value.options.file_path // "-")"' >&2

# Generate one auditable event so there is something to look at.
vault kv get -mount=secret level1/app >/dev/null 2>&1 || true

if command -v kubectl >/dev/null 2>&1; then
  log_ok "sample audit lines (last 3):"
  kubectl -n "$K8S_NS" logs --tail=200 -l app.kubernetes.io/name=vault,component=server 2>/dev/null \
    | grep -c '"type":"request"' >/dev/null 2>&1 \
    && kubectl -n "$K8S_NS" logs --tail=200 -l app.kubernetes.io/name=vault,component=server 2>/dev/null \
       | grep '"type":"' | tail -3 | cut -c1-160 >&2 \
    || log_warn "no audit lines found yet in pod logs — check 'kubectl logs -n ${K8S_NS} vault-0'"
fi

cat >&2 <<EOF

  CONFIRM BY EYE (A9.1 step 3): secret values in those lines must be HMAC'd,
  not plaintext. Read a KV secret and find its audit line:

    kubectl logs -n ${K8S_NS} vault-0 | grep level1 | tail -1 | jq .

  Every value should look like "hmac-sha256:...". If you can read an actual
  secret in the audit log, stop — that is a finding, not a curiosity.

  Retention: pod log rotation. Not adequate for production; record that in the
  runbook rather than leaving it implied. Shipping to Loki would mean editing
  the observability team's log pipeline, which Rule 8 forbids (backlog).

  Next: ./70-verify-access.sh
EOF
