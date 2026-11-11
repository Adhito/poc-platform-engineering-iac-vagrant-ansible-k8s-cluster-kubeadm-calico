# Onboarding other teams after root is revoked. Used by 80-onboard-team.sh
# through the `platform-admin` userpass login from 96-create-operators.sh.
#
# Everything a team gets is named `team-<name>`: a policy, a Kubernetes auth
# role, and the KV prefix secret/teams/<name>/. This policy reaches those names
# and nothing else. It can't touch the Stage B levels, ESO's role, the audit
# device, the seal, root generation, or any mount.
#
# ############################################################################
# THIS IS STILL CLOSE TO ADMIN-EQUIVALENT. READ BEFORE GRANTING.
#
# Whoever can write a policy AND a role can grant themselves anything:
#   - write a `team-x` policy with `path "*"` in it, or
#   - bind role `team-x` to an existing policy such as `level4-pgp`,
# then log in as a ServiceAccount they control. Vault Community has no way to
# restrict what a policy SAYS, only which names it may be written under
# (Sentinel, which can, is Enterprise).
#
# What limits it here:
#   - 80-onboard-team.sh writes policies only from its template, and
#     `80-onboard-team.sh --verify` diffs every team-* policy and role
#     against that template, which catches exactly the two moves above
#   - the audit device logs every write, with the identity that made it
#   - the password is held like break-glass's (key-custody.md)
# ############################################################################

# Team policies: write, read back, list.
path "sys/policies/acl/team-*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "sys/policies/acl" {
  capabilities = ["list"]
}

# Team Kubernetes auth roles.
path "auth/kubernetes/role/team-*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "auth/kubernetes/role" {
  capabilities = ["list"]
}

# Team secrets: WRITE-ONLY. Platform seeds a team's values on its behalf, but
# cannot read them back. `delete` on data/ is a soft delete of the latest
# version, so a mistyped seed can be withdrawn.
path "secret/data/teams/*" {
  capabilities = ["create", "update", "delete"]
}

# Metadata: see which keys and versions exist, without the values. That's
# enough to confirm a seed landed.
path "secret/metadata/teams/*" {
  capabilities = ["read", "list"]
}
