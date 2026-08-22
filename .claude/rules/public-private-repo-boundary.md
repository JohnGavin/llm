# Rule: Public/Private Repo Boundary (Safety-Critical)

## When This Applies

Every decision about **which repo** a file, script, config, or dataset belongs in, and
every decision to create a repo or change a repo's visibility. Also applies when adding
a capability to an existing repo — a repo's correct visibility can change when what it
*does* changes.

## CRITICAL: Classify by what the system TOUCHES, not by whether a value looks secret

The failed instinct is "does this string look sensitive?" That question is answered
per-value, per-commit, by whoever happens to be looking — and it fails silently the
first time nobody looks.

The durable question is:

> **Does this code touch the owner's phone, home, health, or money?**

If yes, it belongs in a **private** repo, regardless of whether any particular file in
it currently contains a sensitive literal.

This boundary is stable. "Is this string secret?" is not — a file that is harmless today
acquires a phone number, an address, or an account balance the moment someone wires it to
something real, and nothing re-asks the question at that point.

## The four triggers

| Trigger | Examples |
|---|---|
| **Phone** | Signal/SMS/WhatsApp integrations, 2FA flows, contact lists, anything with an account identifier |
| **Home** | Home automation, energy/utility accounts, address-derived data, local network topology |
| **Health** | Medical records, condition-specific analysis, prescriptions, appointments, genomic data |
| **Money** | Bank/broker statements, estate and tax modelling, expenses, holdings, payment plans |

Any one trigger is sufficient. They do not need to co-occur.

## Decision table

| Situation | Repo |
|---|---|
| Generic tooling with no personal wiring (a linter, a plotting helper, a nix template) | Public |
| Tooling that *could* be wired to personal data but is not, and has no such config | Public |
| Anything reading a personal account, credential, or identifier at runtime | **Private** |
| Anything whose test fixtures would be realistic only if they contained real personal data | **Private** |
| Estate/tax/expense modelling | **Private** (or local-only) |
| Health/condition analysis | **Private** (or local-only) |
| Uncertain | **Private** — see below |

## Default to private when uncertain

The two errors are not symmetric.

- Wrongly private: someone cannot see your code. Reversible in one command.
- Wrongly public: personal data is exposed, indexed, forked, and cached. **A public
  repo cannot be un-published.** Making it private later does not retract what was
  already fetched, and if the exposed value cannot be rotated — a home address, a
  primary phone number — the exposure is permanent.

So the tie-break is always private. Making a private repo public is a deliberate,
reversible act; the reverse is neither.

## Enforcement is scripts, not this file

**This rule is documentation. It is not a control.**

A `.md` rule forbidding PII in public repos already existed when a personal phone number
sat in a public repo for four months across nine commits. It was read, understood, and
a PR containing the number was merged anyway. Rules require a reader who applies them;
that reader is fallible and is sometimes in a hurry.

The controls that actually hold the boundary are mechanical and auto-triggered:
pre-commit, pre-push, CI on PR, and a scheduled history audit. See
[`private-data-gates`](private-data-gates.md) (llm#946) for the enforcement layers.

If you find yourself relying on *this file* to prevent a leak, the enforcement is
missing and that is the bug to fix.

## Splitting an existing repo

When a public repo has accreted personal wiring:

1. **Inventory by trigger**, not by intuition — grep for the account identifiers, config
   paths, and secret-file references actually in use.
2. **Move the wiring, not just the values.** Extracting a phone number while leaving the
   Signal integration public just means the next contributor re-adds an identifier.
3. **Assume the public history is permanent.** A history rewrite scrubs branches and tags;
   it does **not** remove GitHub's `refs/pull/*`, which stay publicly fetchable and can
   only be purged by GitHub Support. Plan on the assumption the old value is still out
   there.
4. **Rotate what can be rotated.** Where a value cannot be rotated (a primary phone
   number, a home address), containment is the only remaining lever — which is precisely
   why the boundary must be drawn before exposure, not after.

## Forbidden patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| "There's no secret in this file, so public is fine" | Classifies the file, not the system; the file acquires one later | Classify by the four triggers |
| "I'll redact the value and keep the repo public" | The wiring remains, so the next identifier lands in the same place | Move the capability, not the literal |
| "It's been public for ages and nothing happened" | Absence of a known incident is not evidence of non-exposure | Treat public as permanent |
| "Making it private later is easy" | Retracts nothing already fetched, forked, or cached | Default private *first* |
| Relying on a rule file to stop a leak | Requires a reader who applies it | Mechanical gate; see `private-data-gates` |

## Origin

[llm#946](https://github.com/JohnGavin/llm/issues/946). A personal phone number was
present in the public `JohnGavin/llm` repo in 8 files across 9 commits for four months.
Every preventive layer was advisory: a rule forbidding it, an open issue naming the exact
risk, an agent's own PII self-check (which swept for the wrong pattern and truthfully
reported "clean"), and a careful manual check that was simply never run on the PR that
mattered. The credential scanner in use detected credentials, not PII, and had no phone
pattern at all.

The number could not be rotated — it is the owner's primary phone number — so the
exposure is permanent. That is the cost this rule exists to avoid paying again.

## Related

- [`private-data-gates`](private-data-gates.md) — the mechanical enforcement (llm#946)
- [`secrets-single-source`](secrets-single-source.md) — runtime secret sourcing; the
  Layer-0 control that keeps values out of repos entirely
- [`credential-management`](credential-management.md) — credential handling posture
- [`data-privacy`](data-privacy.md) — PHI/confidential data policy
