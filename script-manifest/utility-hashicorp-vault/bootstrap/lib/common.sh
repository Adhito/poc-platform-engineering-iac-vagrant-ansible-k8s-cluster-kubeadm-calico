#!/usr/bin/env bash
# Shared helpers for the Stage A bootstrap scripts. SOURCED, not executed.
#
# Two rules from CLAUDE.md are enforced mechanically here rather than left to
# discipline, because both fail silently when a human forgets:
#
#   Rule 2 — never log secret VALUES. Use redact(); it prints length and a
#            4-char prefix, which is enough to tell "parsed" from "empty" and
#            useless to anyone reading a terminal over your shoulder.
#   Rule 3 — never disable TLS verification. require_vault_env() refuses to run
#            without VAULT_CACERT and rejects VAULT_SKIP_VERIFY=true outright.

# ---------------------------------------------------------------- logging ---
_c_reset=$'\033[0m'; _c_red=$'\033[31m'; _c_grn=$'\033[32m'
_c_ylw=$'\033[33m';  _c_blu=$'\033[34m'; _c_dim=$'\033[2m'
if [[ ! -t 2 ]]; then _c_reset=; _c_red=; _c_grn=; _c_ylw=; _c_blu=; _c_dim=; fi

log()      { printf '%s\n' "$*" >&2; }
log_step() { printf '\n%s==>%s %s\n' "$_c_blu" "$_c_reset" "$*" >&2; }
log_ok()   { printf '  %s+%s %s\n' "$_c_grn" "$_c_reset" "$*" >&2; }
log_skip() { printf '  %s.%s %s %s(already done)%s\n' "$_c_dim" "$_c_reset" "$*" "$_c_dim" "$_c_reset" >&2; }
log_warn() { printf '  %s!%s %s\n' "$_c_ylw" "$_c_reset" "$*" >&2; }
log_err()  { printf '  %sx%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; }
die()      { log_err "$*"; exit 1; }

# Rule 2. Never print a secret; print enough to prove it is non-empty and looks
# like the right shape.
redact() {
  local v="${1:-}"
  if [[ -z "$v" ]]; then printf '<empty>'; return 0; fi
  if (( ${#v} <= 8 )); then printf 'len=%d' "${#v}"; return 0; fi
  printf 'len=%d prefix=%s..' "${#v}" "${v:0:4}"
}

# --------------------------------------------------------- prerequisites ---
require_cmd() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { log_err "missing required command: $c"; missing=1; }
  done
  (( missing == 0 )) || die "install the missing commands and re-run"
}

# Rule 3, enforced. A TLS failure here means a missing SAN or an unmounted CA —
# fix that. Reaching for the bypass invalidates the exercise, and the bypass
# never gets removed.
require_vault_env() {
  [[ -n "${VAULT_ADDR:-}" ]] || die "VAULT_ADDR is not set (e.g. https://192.168.56.241:8200)"

  case "${VAULT_ADDR}" in
    https://*) ;;
    *) die "VAULT_ADDR must be https:// — TLS is on from Phase A2 onward (D7). Got: ${VAULT_ADDR}" ;;
  esac

  if [[ "${VAULT_SKIP_VERIFY:-false}" == "true" || "${VAULT_SKIP_VERIFY:-0}" == "1" ]]; then
    die "VAULT_SKIP_VERIFY is set. Rule 3: never disable TLS verification.
     A failure here means a missing SAN or an unmounted CA. Fix that instead —
     the node IPs are the usual omission (see base/vault-extras/certificate.yaml)."
  fi

  [[ -n "${VAULT_CACERT:-}" ]] || die "VAULT_CACERT is not set. Point it at the CA that issued Vault's cert."
  [[ -r "${VAULT_CACERT}" ]]   || die "VAULT_CACERT is not readable: ${VAULT_CACERT}"
}

# --------------------------------------------------------- vault state -----
vault_status_json() { vault status -format=json 2>/dev/null || true; }

vault_is_initialized() {
  local j; j="$(vault_status_json)"
  [[ -n "$j" ]] && [[ "$(jq -r '.initialized // false' <<<"$j")" == "true" ]]
}

vault_is_sealed() {
  local j; j="$(vault_status_json)"
  [[ -z "$j" ]] && return 0          # unreachable counts as "not usable"
  # NOT `.sealed // true`: jq's `//` falls back on false as well as null, so that
  # turned "sealed": false into true and every unsealed Vault read as sealed.
  # Only a MISSING field should default to sealed.
  [[ "$(jq -r 'if .sealed == null then true else .sealed end' <<<"$j")" == "true" ]]
}

require_vault_reachable() {
  vault_status_json | jq -e . >/dev/null 2>&1 \
    || die "cannot reach Vault at ${VAULT_ADDR}.
     Try the break-glass path if MetalLB is suspect (D8):
       VAULT_ADDR=https://192.168.56.10:30004 vault status"
}

require_vault_unsealed() {
  require_vault_reachable
  vault_is_sealed && die "Vault is sealed. Run 00-init-unseal.sh first."
  return 0
}

require_vault_authenticated() {
  require_vault_unsealed
  vault token lookup >/dev/null 2>&1 \
    || die "not authenticated to Vault. Export VAULT_TOKEN, or 'vault login'.
     During bootstrap this is the root token from vault-init.json; after
     99-revoke-root.sh it must be regenerated with 'vault operator generate-root'."
}

# ------------------------------------------------- idempotency (Rule 9) ----
# Everything in bootstrap/ WILL be re-run. Re-running must produce no errors and
# no drift, so every enable is guarded by one of these.
secrets_engine_enabled() {
  vault secrets list -format=json 2>/dev/null \
    | jq -e --arg p "${1%/}/" 'has($p)' >/dev/null 2>&1
}

auth_method_enabled() {
  vault auth list -format=json 2>/dev/null \
    | jq -e --arg p "${1%/}/" 'has($p)' >/dev/null 2>&1
}

policy_exists() {
  vault policy list -format=json 2>/dev/null \
    | jq -e --arg n "$1" 'index($n) != null' >/dev/null 2>&1
}

audit_device_enabled() {
  vault audit list -format=json 2>/dev/null \
    | jq -e --arg p "${1%/}/" 'has($p)' >/dev/null 2>&1
}

kv_path_exists() {
  # $1 = mount (e.g. secret), $2 = path below it (e.g. level1/app)
  vault kv get -mount="$1" -format=json "$2" >/dev/null 2>&1
}

# ------------------------------------------------------- key custody (D20) --
# Unseal keys live OUTSIDE the repo tree. In-repo + .gitignore is not enough:
# `git clean -xfd` deletes gitignored files by design — that is what -x means —
# and it is exactly what gets run when resetting a working tree.
vault_poc_keys_dir() {
  local dir="${VAULT_POC_KEYS:-$HOME/.credentials/vault-poc}"
  mkdir -p "$dir"
  chmod 0700 "$dir"
  (cd "$dir" && pwd -P)
}

# Resolve to an absolute, symlink-free path. Works on paths that do not exist
# yet (90-snapshot.sh asserts before mkdir) by resolving the deepest existing
# ancestor and re-appending the rest.
#
# Normalising BOTH sides of the comparison is load-bearing, not tidiness: on
# Git-Bash `git rev-parse --show-toplevel` prints `C:/path` while `pwd -P`
# prints `/c/path`, so comparing a raw target against a resolved repo root
# silently never matches — and this guard would wave through exactly the
# in-repo write it exists to prevent.
_abs_path() {
  local p="$1" tail="" head
  while [[ -n "$p" && "$p" != "/" && "$p" != "." && ! -e "$p" ]]; do
    tail="/$(basename "$p")${tail}"
    p="$(dirname "$p")"
  done
  if [[ -d "$p" ]]; then head="$(cd "$p" && pwd -P)"; else head="$p"; fi
  printf '%s' "${head%/}${tail}"
}

# D20 guard: a path that will hold secret material must never be committable.
#
# Outside the repo: always fine. Inside the repo: allowed ONLY if git ignores the
# path AND nothing under it is tracked. Keys inside the repo were the owner's
# explicit choice on 2026-10-05 (documents/key-custody.md records why and the risks
# accepted). This guard keeps the part that matters: the keys can never be
# committed by an ordinary `git add`. What it cannot prevent, and what is accepted:
#   - `git clean -xfd` deletes ignored files, the keys included. Never run it here.
#   - `git add -f` bypasses .gitignore.
#   - Vagrant mounts this repo into every cluster node at /vagrant.
assert_keys_path_safe() {
  local target="$1" repo_root rel
  repo_root="$(git -C "${SCRIPT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$repo_root" ]] || return 0
  repo_root="$(_abs_path "$repo_root")"
  target="$(_abs_path "$target")"
  case "${target%/}/" in
    "${repo_root}"/* | "${repo_root}/")
      rel="${target#"${repo_root}"/}"
      [[ "$target" != "$repo_root" && -n "$rel" ]] \
        || die "REFUSING TO USE THE REPO ROOT ITSELF FOR SECRET MATERIAL (D20): ${target}"
      # A probe file name under the directory: ignored-ness of the directory
      # itself is what we need, and this works whether or not it exists yet.
      git -C "$repo_root" check-ignore -q -- "${rel%/}/.d20-probe" \
        || die "REFUSING TO WRITE KEYS TO A PATH GIT DOES NOT IGNORE (D20).
     resolved: ${target}
     repo:     ${repo_root}
     Add it to .gitignore (the repo ignores .credentials/), or repoint VAULT_POC_KEYS."
      [[ -z "$(git -C "$repo_root" ls-files -- "$rel")" ]] \
        || die "REFUSING: files under ${rel} are TRACKED by git (D20). Untrack them first."
      log_warn "keys path is inside the repo (gitignored): never run 'git clean -xfd' here"
      ;;
  esac
}
