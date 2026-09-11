#!/usr/bin/env bash
#
# Phase A6 steps 3–4 — enable and configure the Kubernetes auth method (D6).
#
# This is the trust anchor for the entire scheme. After this, a pod's identity
# IS its ServiceAccount: it presents its projected SA JWT, Vault validates it
# with the TokenReview API using the reviewer token, and mints a Vault token
# carrying the role's policies. The pod never holds a Vault credential at rest.
#
# ############################################################################
# THE FOOTGUN THIS SCRIPT EXISTS TO AVOID
#
# Vault reads `token_reviewer_jwt` ONCE, here, and never re-reads it. Point it
# at a PROJECTED ServiceAccount token and everything works perfectly — until
# that token rotates about an hour later, at which point every login fails with
# an error that says nothing about rotation.
#
# So the JWT is taken from the `vault-reviewer-token` Secret
# (type kubernetes.io/service-account-token), which is not rotated. That Secret
# is created by base/vault-extras/reviewer-token.yaml in sync wave 0.
# ############################################################################

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

K8S_NS="${VAULT_NAMESPACE_K8S:-vault}"
REVIEWER_SECRET="vault-reviewer-token"

require_cmd vault jq kubectl
require_vault_env
require_vault_authenticated

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
chmod 0700 "$TMP"

# ---------------------------------------------------------------------------
log_step "Enable the kubernetes auth method"

if auth_method_enabled kubernetes; then
  log_skip "auth/kubernetes"
else
  vault auth enable kubernetes >/dev/null
  log_ok "auth/kubernetes enabled"
fi

# ---------------------------------------------------------------------------
log_step "Collect the reviewer JWT and cluster CA"

kubectl -n "$K8S_NS" get secret "$REVIEWER_SECRET" >/dev/null 2>&1 \
  || die "Secret ${K8S_NS}/${REVIEWER_SECRET} not found.
     It comes from sync wave 0 (base/vault-extras/reviewer-token.yaml).
     Confirm the vault-extras Application has synced."

REVIEWER_JWT="$(kubectl -n "$K8S_NS" get secret "$REVIEWER_SECRET" \
  -o jsonpath='{.data.token}' | base64 -d)"
[[ -n "$REVIEWER_JWT" ]] || die "the reviewer Secret has no .data.token yet.
     The controller populates it once the 'vault' ServiceAccount exists (wave 1).
     Wait for the Vault Application to sync, then re-run."

# Rule 2 — shape only, never the value.
log_ok "reviewer JWT retrieved  ($(redact "$REVIEWER_JWT"))"

# Confirm it is genuinely long-lived. A projected token carries a short `exp`;
# this one should carry none. Catching that here beats catching it in an hour.
JWT_PAYLOAD="$(cut -d. -f2 <<<"$REVIEWER_JWT" | tr '_-' '/+')"
case $(( ${#JWT_PAYLOAD} % 4 )) in 2) JWT_PAYLOAD+='==' ;; 3) JWT_PAYLOAD+='=' ;; esac
if JWT_EXP="$(printf '%s' "$JWT_PAYLOAD" | base64 -d 2>/dev/null | jq -r '.exp // "none"')"; then
  if [[ "$JWT_EXP" == "none" || "$JWT_EXP" == "null" ]]; then
    log_ok "reviewer JWT has no expiry — correct (D6)"
  else
    log_warn "reviewer JWT carries exp=${JWT_EXP}. If this is a projected token,"
    log_warn "Kubernetes auth will break silently when it rotates."
  fi
fi

kubectl -n "$K8S_NS" get secret "$REVIEWER_SECRET" \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > "${TMP}/ca.crt"
[[ -s "${TMP}/ca.crt" ]] || die "could not read ca.crt from ${REVIEWER_SECRET}"
log_ok "cluster CA retrieved ($(wc -c < "${TMP}/ca.crt") bytes)"

# ---------------------------------------------------------------------------
log_step "Look up the cluster's real OIDC issuer"

# Do not guess this, and do not copy it from a PRD example.
OIDC_ISSUER="$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null \
  | jq -r '.issuer // empty')"

if [[ -z "$OIDC_ISSUER" ]]; then
  die "could not read the OIDC issuer from /.well-known/openid-configuration.
     The PRD lists this under 'when to stop and ask' — do not substitute a
     plausible value. Investigate the endpoint first."
fi
log_ok "issuer: ${OIDC_ISSUER}"

if [[ "$OIDC_ISSUER" != "https://kubernetes.default.svc"* ]]; then
  log_warn "issuer is not the in-cluster default. That may be correct for this"
  log_warn "cluster, but confirm it before treating auth failures as a Vault bug."
fi

# ---------------------------------------------------------------------------
log_step "Write auth/kubernetes/config"

# `kubernetes_host` is the address VAULT uses to reach the API server, from
# inside the cluster — not an address reachable from this workstation.
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert=@"${TMP}/ca.crt" \
  token_reviewer_jwt="$REVIEWER_JWT" \
  issuer="$OIDC_ISSUER" >/dev/null

log_ok "configured"

# "Applied cleanly" is not "working" (Rule 6) — read it back.
log_step "Verify"
CFG="$(vault read -format=json auth/kubernetes/config)"
log_ok "kubernetes_host : $(jq -r '.data.kubernetes_host' <<<"$CFG")"
log_ok "issuer          : $(jq -r '.data.issuer // "(default)"' <<<"$CFG")"
log_ok "CA configured   : $(jq -r 'if (.data.kubernetes_ca_cert | length) > 0 then "yes" else "NO" end' <<<"$CFG")"

log ""
log "  Next: ./20-apply-policies.sh"
log "  Nothing can log in yet — roles and policies do not exist until that runs."
