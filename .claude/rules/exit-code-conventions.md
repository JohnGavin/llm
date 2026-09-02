---
description: Every check, gate, probe or health script reserves exit codes 0/1/2/3 for PASS/FAIL/usage-error/INDETERMINATE — new scripts inherit this mapping rather than each picking their own
paths:
  - ".claude/scripts/**"
  - ".claude/hooks/**"
  - "bin/**"
---

# Rule: Exit-Code Conventions for Checks, Gates, Probes and Health Scripts

## When This Applies

Any script under `.claude/scripts/**`, `.claude/hooks/**`, or `bin/**` whose
exit code is read by a caller to decide something — a merge gate, a
pre-commit hook, a health report, a selftest, a dashboard panel. Not every
script in these directories is a "check" (some are one-shot migrations or
CLI utilities with their own action-specific failure taxonomy — see
"Scripts Out of Scope" below); this rule governs the ones whose job is to
answer PASS / FAIL / could-not-tell about a subject.

## CRITICAL: Reserve exit codes 0-3 for exactly one meaning each, repo-wide

`INDETERMINATE` is a sanctioned, first-class check outcome
(`checks-must-distinguish-unknown`), and it is now surfaced at the top of
the AgentsView dashboard. A dashboard panel that aggregates across scripts
can only read that signal correctly if every script uses the same exit code
for it. By 2026-09-02 three scripts had already drifted apart — two used
exit 3 for INDETERMINATE, one used exit 3 for "usage error" and exit 2 for a
determinate FAIL, silently inverting the pair
([JohnGavin/llm#1140](https://github.com/JohnGavin/llm/issues/1140)).

| Code | Meaning |
|---|---|
| `0` | PASS — determinate positive |
| `1` | FAIL — determinate negative (the check *did* reach a verdict) |
| `2` | Usage error — the caller invoked the script wrongly (bad args, bad path, `--help`) |
| `3` | INDETERMINATE — the check could not evaluate its subject at all (missing tool, unreachable DB, auth failure, timeout) |

A script MAY use fewer than all four codes (many checks have no usage-error
path worth distinguishing, or genuinely can never be indeterminate), but
whichever codes it uses MUST mean what this table says. A script needing to
distinguish more than one *kind* of FAIL or more than one *kind* of
INDETERMINATE encodes that distinction in the printed message, not in a
new exit code — see `check_targets_presence.sh`'s `FAIL parse-error:` vs
`FAIL undeclared-absence:` for the pattern.

## Relationship to `checks-must-distinguish-unknown`

That rule's "Required pattern" section documents a simpler three-value
scheme (`0` = clear, `1` = found something, `2` = could not run) for checks
that never need to separate "you called this wrong" from "I could not tell
whether your subject is compliant". That scheme remains valid for scripts
that only ever need those three states — it is a special case of the table
above with `2` reinterpreted narrowly as "could not run" (this rule's `3`)
rather than "wrong invocation" (this rule's `2`). A script that DOES need
both distinctions (most gates that take a path argument AND wrap an
external tool) MUST use the four-code table above, not the three-code one.
When in doubt, use the four-code table — it is never wrong to reserve a
code you don't currently need.

## Required Pattern

```bash
check_one() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        echo "USAGE-ERROR: not a directory: $dir"
        return 2                      # caller invoked this wrongly
    fi
    if ! command -v some_tool >/dev/null 2>&1; then
        echo "INDETERMINATE: some_tool not on PATH — cannot evaluate $dir"
        return 3                      # could not evaluate; never a FAIL
    fi
    if ! subject_is_compliant "$dir"; then
        echo "FAIL: $dir is not compliant"
        return 1                      # determinate negative
    fi
    echo "PASS: $dir is compliant"
    return 0                          # determinate positive
}
```

## A Determinate Negative Is Not an Unknown

The most common drift observed so far: a script that successfully determines
"the subject is non-compliant" (e.g. no `_targets.R` and no declared
exemption) gets coded as something other than `1`, on the reasoning that the
subject "doesn't have" the thing being checked for. That reasoning is
backwards — the check ran, inspected the subject, and reached a real
verdict. It belongs at `1` (FAIL) precisely because it is NOT an unknown.
Reserve `3` for cases where the check genuinely could not look — an
unavailable tool, an unreachable database, a network timeout — not for
"looked, and the answer was no".

## Selftest Requirement

Every check with more than a binary pass/fail MUST assert the *exact* exit
code for every state it distinguishes, not merely `[ "$rc" -ne 0 ]`. An
assertion that only checks non-zero cannot tell FAIL from usage-error from
INDETERMINATE, and would pass unchanged if two codes were swapped — the
exact failure mode this rule exists to prevent. Falsify each assertion at
least once (temporarily mutate the return value, confirm the assertion goes
red, then confirm green again) before trusting it — see
`verification-before-completion`. `check_targets_presence.sh --selftest` is
the reference implementation: it asserts all four codes explicitly,
including a dedicated INDETERMINATE case that narrows `PATH` for one call
so the "tool unavailable" branch is exercised regardless of the ambient
shell.

## Scripts Out of Scope

Action/utility scripts (worktree creation, secret rotation, migrations) have
their own failure taxonomy — "branch already exists" is not comparable to
"PASS/FAIL/usage/indeterminate" because the script is *performing an
action*, not *evaluating a subject*. Do not force these into the four-code
table; document their own codes locally instead. `cc-worktree.sh` (exit
codes 0-5, each a distinct creation-failure reason) is the reference example
of a script correctly outside this rule's scope.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Using exit 2 for "could not run" | Collides with usage-error in any caller that follows this table | Move to exit 3 |
| Using exit 3 for a more-severe FAIL (e.g. "safety violation" vs "warning-only FAIL") | Collides with INDETERMINATE in any caller that follows this table | Encode severity in the message or a second field, not a new exit code |
| A recursion/depth guard exiting with a different code in different scripts | The same failure mode should read the same way everywhere | Standardise: it is a usage error (the caller/environment misconfigured a re-entry), exit 2 |
| An assertion that only checks `[ "$rc" -ne 0 ]` for a 4-state script | Cannot distinguish which of 1/2/3 fired; masks a swapped mapping | Assert the exact code |
| A new check picking its own scheme "because it's simple" | The scheme only has value in aggregate — one exception breaks every dashboard rollup | Use the table above, even for a 2-state check |

## Related

- [`checks-must-distinguish-unknown`](checks-must-distinguish-unknown.md) — why INDETERMINATE must never collapse into PASS or FAIL; this rule adds the *code* convention on top of that *behavioural* requirement
- [`verification-before-completion`](verification-before-completion.md) — falsify every selftest assertion before trusting it
- `.claude/scripts/check_targets_presence.sh` — reference implementation (JohnGavin/llm#1140)
- `bin/roborev_merge_gate.sh` — pre-existing conformant example (1=BLOCK, 2=usage, 3=INDETERMINATE)
- [`_companions/exit-code-conventions-audit-1140.md`](_companions/exit-code-conventions-audit-1140.md) — full per-script audit of every checker under `.claude/scripts/**` and `bin/**`: 7 confirmed DRIFT, 7 confirmed CONFORMS, 162 not individually reviewed (auto-classified by code-set only)
- [JohnGavin/llm#1140](https://github.com/JohnGavin/llm/issues/1140) — origin issue
