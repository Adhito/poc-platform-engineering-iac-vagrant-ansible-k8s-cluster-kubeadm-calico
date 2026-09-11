# Licensing

Phase A0 deliverable — PRD §5.1 outcome, plus the organisational confirmation it
requires.

> **Not legal advice.** This records an engineering decision and the reasoning
> behind it. Whether BUSL 1.1 is acceptable is a question for whoever owns your
> organisation's open-source policy, not for this document.

---

## Decision

**Proceed with HashiCorp Vault Community Edition under BUSL 1.1.**

## Status: ORG POLICY CONFIRMATION OUTSTANDING

This is an A0 exit-gate item and it has **not** been done.

- [ ] BUSL 1.1 checked against the organisation's OSS policy
- [ ] Outcome recorded below with a date and a name

**Confirm this now, not at Phase A7.** The substitution to OpenBao is cheap today
— chart coordinates and a binary name — and expensive once Vault has initialised
Raft storage, seeded secrets, and had four Stage B applications written against
it.

| Date | Checked by | Outcome |
|---|---|---|
| ______ | ______ | ______ |

If the answer is "blocked", stop and go to [Substitution](#if-busl-is-blocked)
before running `00-init-unseal.sh`.

---

## What changed

In **August 2023**, HashiCorp relicensed Vault from the **Mozilla Public License
2.0** to the **Business Source License 1.1**. HashiCorp is now an IBM company.

BUSL 1.1 is **not an OSI-approved open source licence**. It is a source-available
licence with a time delay: each release converts to MPL 2.0 four years after its
release date.

## What BUSL permits and restricts

| | |
|---|---|
| **Permitted** | Use, copy, modify, and redistribute — including in production, for most purposes |
| **Restricted** | Offering a competing commercial product or hosted service built on the Vault codebase |
| **Time-limited** | Each release becomes MPL 2.0 four years after it ships |

The practical line is roughly: *are you running Vault, or are you selling Vault?*

## Does it affect this POC?

**No.** An internal learning POC falls clearly on the permitted side. So does
internal production use.

The restriction targets organisations building a SaaS platform on the codebase or
offering secrets management to customers as a product. Neither describes this
work.

### When it *would* matter

- Offering Vault-as-a-service to external customers
- Embedding Vault in a commercial product you distribute
- Any managed-hosting model built on the codebase
- Organisational policy that simply forbids non-OSI licences regardless of use —
  **this is the realistic blocker, and it is a policy question, not a legal one**

---

## The alternative: OpenBao

The fork that resulted from the relicensing.

| | |
|---|---|
| Origin | Forked from Vault **1.14.0** — the last MPL-2.0 release — before the licence change |
| Licence | MPL 2.0 |
| Governance | Linux Foundation, with IBM engineers among the contributors |
| Compatibility | Speaks the same API; the same command surface |
| Maturity | Per the PRD's research, at 2.5.0 in early 2026 and a credible production-ready alternative rather than an experiment |
| Trade-off | No first-party commercial vendor for support |

> **Verify the maturity and version claims at implementation time.** They are the
> PRD author's research as of early 2026, restated here, not something this
> document independently confirms. The same applies to anything else in this file
> that is a point-in-time fact rather than a licence term.

**The reason to choose between them is almost entirely licence and governance,
not features.** Everything this POC exercises — Raft, Kubernetes auth, KV v2, the
database engine, ESO integration — exists in both.

---

## Why Vault for this POC anyway

Documentation, the Helm chart, and the ecosystem you hit when troubleshooting are
all Vault-first.

**Troubleshooting friction is precisely what you do not want in a learning
exercise.** The point of Stage A is to understand seal lifecycles, Raft
behaviour, and the Kubernetes auth handshake — not to be the first person to
write up an OpenBao-specific failure mode. When something breaks at 22:00, the
search results should be about the thing you are running.

That reasoning is specific to a *learning* POC. It carries much less weight for a
production selection, where governance and licence terms deserve more room than
the density of Stack Overflow answers.

Logged as a **backlog evaluation item**: revisit OpenBao when this stops being a
learning exercise.

---

## If BUSL is blocked

The substitution is genuinely cheap, and cheapest before Phase A2.

**What changes:**

| Thing | Vault | OpenBao |
|---|---|---|
| Helm repo | `https://helm.releases.hashicorp.com` | OpenBao's chart repository |
| Chart / image | `vault` · `hashicorp/vault` | `openbao` · the OpenBao image |
| CLI binary | `vault` | `bao` |

**What does not change:** the architecture, the PRD's ten phases, the policies,
the Kubernetes auth model, the bootstrap sequence, the runbooks, or anything in
Stage B. The API paths are the same.

**Where the work actually lands in this repo:**

- `helm/vault/values-onprem.yaml` — chart values and image
- `argocd/applications/vault.yaml` — chart coordinates and `targetRevision`
- `bootstrap/*.sh` — the `vault` binary name (`require_cmd vault`, every call)
- `documents/*` — names and URLs

Both are pinned, never `latest`, either way (D16).

> One caution if substituting: because the two are independently maintained with
> separate release cycles, **compatibility may diverge over time** in particular
> areas. A migration between them — in either direction — needs version-specific
> validation rather than an assumption of drop-in equivalence.

---

## Other licensing in this stack

Worth a glance during the same policy check, since they ship in the same cluster:

| Component | Licence |
|---|---|
| cert-manager | Apache 2.0 |
| External Secrets Operator | Apache 2.0 |
| PostgreSQL | PostgreSQL Licence (permissive) |
| Calico, MetalLB, ArgoCD | Apache 2.0 |

**Vault Enterprise features** — namespaces, replication, HSM support, control
groups — are separately licensed and **out of scope permanently**. Nothing in
Stage A or Stage B uses them.

---

## Related

| Document | Covers |
|---|---|
| [`architecture.md`](architecture.md) | What is built, and what is deliberately absent |
| [`environment.md`](environment.md) | Pinned versions and outstanding A0 items |
| [`runbooks/upgrade.md`](runbooks/upgrade.md) | Version bumps; downgrades are not supported |
