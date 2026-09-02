---
description: _targets.R is the default expectation for R-package/analysis projects — absence must be a declared, reviewable exemption, never a silent pass
paths:
  - "_targets.R"
  - ".claude/CLAUDE.md"
  - ".claude/scripts/check_targets_presence.sh"
---

# Rule: Pipeline Validation (ALL PROJECTS)

## When This Applies

Every R-package or analysis project under `~/docs_gh/`, at every commit.
Applies whether or not the project currently has a `_targets.R`.

## CRITICAL: A parse-only check on a file that might not exist is vacuous

The prior wording of this rule ("Before every commit: `parse("_targets.R")`
MUST succeed") is a **parse-validity** check, not a **presence** mandate. A
project with no `_targets.R` at all satisfies it trivially — `parse()` is
never called, so nothing can fail. The rule's own heading ("ALL PROJECTS")
implied a usage mandate that the wording never actually enforced.

Discovered [JohnGavin/llm#539](https://github.com/JohnGavin/llm/issues/539),
2026-06-06: a premortem session asked to "tabulate targets grouped by plan"
in a project with no `_targets.R`. The literal rule was satisfied; the user's
expectation was not. Per `checks-must-distinguish-unknown`, a check whose
output does not vary with the thing it claims to check is not a check.

## The Decision (Reading C)

Four readings were on the table (see the issue for the full comparison table:
A parse-only / B hard usage mandate / C opt-out with a declared reason / D a
trigger-conditional threshold). **C is canonical:**

> `_targets.R` is the **default expectation** for R-package and analysis
> projects. A project without one is not silently fine — it MUST declare the
> exemption explicitly in its `.claude/CLAUDE.md`, with a reason.

B was rejected — genuinely non-pipeline projects exist (knowledge-base repos,
config-only repos, this repo's own `.claude/` tooling layer) and a hard
mandate would force a token `_targets.R` nobody uses. D was rejected — a
usage-threshold ("mandatory iff ≥N artifacts...") hides the actual decision
inside a number nobody will keep current. C is the reading that makes the
check non-vacuous without over-constraining real exceptions: absence stops
being invisible and becomes either a declared, reviewable choice or a
reported defect.

## Required Pattern

1. **`_targets.R` exists** → `parse("_targets.R")` MUST succeed before every
   commit. Code-as-string targets MUST `parse(text=code)` for R or `bash -n`
   for bash (unchanged from the prior wording).
2. **`_targets.R` absent** → the project's `.claude/CLAUDE.md` MUST contain a
   declared exemption row:

   ```markdown
   | Targets pipeline | none — <reason> |
   ```

   Same table-row convention as the `Environment` field in
   `permission-discipline` Part 3 — one line, in the project's existing
   "Project Identity" (or equivalent) table. `<reason>` MUST be non-empty
   prose, e.g. `none — local git-only knowledge base, no build artifacts`.
3. **`_targets.R` absent AND no declared exemption** → this is a **defect**,
   reported distinctly from both a genuine pass and a parse failure — never a
   silent pass. See the Check below.

## The Check

`.claude/scripts/check_targets_presence.sh` distinguishes four states, per
`checks-must-distinguish-unknown`:

| State | `_targets.R` | Exemption declared | Result |
|---|---|---|---|
| Parses | present | n/a | **PASS** (exit 0) |
| Parse error | present | n/a | **FAIL** (exit 1) — genuine defect |
| Declared exempt | absent | yes | **PASS — exempt** (exit 0, labeled) |
| Undeclared absence | absent | no | **FAIL — undeclared** (exit 2) — the bug this rule exists to close |

Exit code 2 is deliberately distinct from exit 1: a caller that wants to
distinguish "the pipeline is broken" from "there is no pipeline and nobody
said why" can branch on it. Usage errors (bad path, missing tools) exit 3 —
never folded into either FAIL state.

```bash
.claude/scripts/check_targets_presence.sh [project-dir]   # default: cwd
.claude/scripts/check_targets_presence.sh --selftest
```

This is a checker script, not a hook — it is **not** wired into the
pre-commit path as a hard gate in this change. Wiring it in (a session-init
warn phase, per the issue's Acceptance criteria, or a pre-commit block) is a
follow-up; see the PR that shipped this rule.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| No `_targets.R`, no exemption row, nobody notices | Exactly the vacuous-pass bug this rule replaces | Declare the exemption or add a pipeline |
| Exemption row present but `<reason>` is empty or a placeholder | Same defect wearing a different shape — see `checks-must-distinguish-unknown`'s placeholder corollary | Write the actual reason |
| Treating "no `_targets.R`" as automatically fine because the project is "just docs" | That is a real exemption reason — but it still has to be **declared**, not inferred | Add the row |
| Checker exit 2 (undeclared) silently mapped to exit 0 by a caller | Reintroduces the vacuous pass one layer up | Branch on the distinct exit code |

## Related

- `checks-must-distinguish-unknown` — the three/four-state discipline this rule's checker follows
- `permission-discipline` Part 3 — the `| Environment | ... |` table-row convention this rule's exemption syntax mirrors
- [JohnGavin/llm#539](https://github.com/JohnGavin/llm/issues/539) — origin issue, full reading comparison (A/B/C/D)
- `targets-pipeline-spec` skill — how to structure `_targets.R` once a project adopts one
