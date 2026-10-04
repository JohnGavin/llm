---
paths:
  - ".claude/rules/public-private-repo-boundary.md"
---

# Companion: Public/Private Repo Boundary

Supporting detail split out of the always-loaded [`public-private-repo-boundary`](../public-private-repo-boundary.md) rule (llm baseline trim, 2026-10-03).

## Moved from the `public-private-repo-boundary` rule body (2026-10-03, always-loaded baseline trim)

Verbatim text removed from the rule body to cut the always-loaded instruction baseline. The normative requirement is restated in the rule; this is the supporting detail.

### Enforcement: narrative

A `.md` rule forbidding PII in public repos already existed when a personal phone number
sat in a public repo for four months across nine commits. It was read, understood, and
a PR containing the number was merged anyway. Rules require a reader who applies them;
that reader is fallible and is sometimes in a hurry.

### Splitting an existing repo (full procedure)

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

### Origin narrative

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
