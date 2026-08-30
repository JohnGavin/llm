---
description: Detect hand-entered literals whose comment admits they are provisional (rough/refine/placeholder/etc); graduated block/warn by whether the file feeds a published output
paths:
  - "R/plan_*/**"
  - "pipeline/**"
  - "scrapers/**"
  - "R/**"
  - "**/*.py"
  - "**/*.sql"
---

# Rule: Provisional Constants (Graduated)

## When This Applies

Every project with hand-entered literal values (scalars, `c(...)` vectors,
`list(...)` dicts, or their Python/SQL equivalents) in source code. Applies
whenever a literal assignment is co-located with a comment that admits the
value is not final — the marker vocabulary below.

## Source

[JohnGavin/llm#792](https://github.com/JohnGavin/llm/issues/792) — a
cross-project audit of 20 repos found 1,943 raw hits for provisional-marker
comments attached to literal assignments, triaged to ~180 real findings by
five parallel agents. Root incident:
[JohnGavin/historical#566](https://github.com/JohnGavin/historical/issues/566)
→ [#567](https://github.com/JohnGavin/historical/issues/567) — a strategy
registry's turnover figures were hand-typed under a comment reading "rough
first-pass; refine after a full tar_make", while the real
`calculate_turnover()` function sat with no non-test caller. This is the
`Reproducible Ingestion` rule (global `AGENTS.md`) applied specifically to
values that name their own provisionality in a comment.

## CRITICAL: A Value That Admits It Is Provisional Has No Expiry

A hand-entered literal with a `# rough first-pass` or `# TODO refine`
comment is not a stable state — it is technical debt with a timestamp. It
has no parser, no test, and no audit trail, and it silently drifts as its
real source updates. The comment is the tell: the author already knew the
value needed revisiting and the revisit never happened.

## Marker Vocabulary

A literal assignment is in scope when its attached (same-line trailing) or
immediately-preceding-line comment matches (case-insensitive):

```
refine|rough|first-pass|placeholder|for now|assumed|approx|guess|hardcod|
TODO|FIXME|user-confirmed|from statement
```

## Severity Taxonomy (P0–P3)

| Tier | Definition | Response |
|---|---|---|
| **P0** | Hand-entered value feeds a **published/deployed** number, and a machine-readable source exists or plausibly exists | Fix now — the published figure is currently wrong or unverifiable |
| **P1** | Feeds computation, source exists/plausible, not yet published or published with caveat | Fix this cycle |
| **P2** | Genuine modelling **choice** (threshold, tuning constant), but uncited and no sensitivity test | Document + cite + sweep; do not necessarily change the value |
| **P3** | Legitimately manual (no machine-readable source possible), missing marker + tracking issue | Add `# MANUAL: no source` + open an issue |

## Fix Vocabulary (F1–F4)

| Code | Fix | Applies to |
|---|---|---|
| **F1** | Write a parser + test; derive the value from the source | P0, P1 |
| **F2** | Promote to a named documented constant with a citation and a sensitivity test | P2 |
| **F3** | Add `# MANUAL: no source` marker + open a tracking issue for a parseable source | P3 |
| **F4** | Delete — the value is unused or the code path is dead | any tier |

## Not Violations

Explicitly excluded, and MUST NOT be flagged: unrelated TODO/FIXME not
attached to a literal assignment; test fixtures and expected values;
example/demo data; documented constants carrying a citation; plotting
cosmetics; loop bounds; seeds; guarded stubs that announce themselves in
output (e.g. a `using_placeholder` flag printed in the output table — see
`acd/.placeholder_joined()`, cited in llm#792 as the exemplar of a stub that
correctly self-identifies rather than silently masquerading as real data).

## Graduated Detection: Option C (Decided)

Three options were weighed in llm#792: warn-always (cheap, ignored within a
month), block-always (fires on every legitimate P2 tuning constant, gets
bypassed), and graduated. **Option C — graduated — is the decision:**

> **Block** when the marked literal is in a file that feeds a published
> output; **warn** otherwise.

"Feeds a published output" is approximated by file path (documented
approximation, not a full dependency graph — see llm#792's own proposed
approximation):

- File is under `R/plan_*/**`, `pipeline/**`, or `scrapers/**`, OR
- File is read/sourced by a `.qmd` under `docs/**` or `vignettes/**`
  (approximated as: the file's basename appears in a `.qmd` under either
  directory)

| Tier match | Behaviour |
|---|---|
| Graduated path (above) | **Block** — commit fails until fixed or explicitly waived |
| Any other path | **Warn** — printed, does not block |

The detector (an ast-grep structural rule) always fires at `warning`
severity; `r_code_check.sh` re-checks the match's file path and escalates
to a block only for the graduated tier. See
`.claude/ast-grep-rules/provisional-constants.yml` for the structural match
definition and its documented false-positive mitigation (a text-based
re-check that the line immediately above the match is a comment-only line,
which excludes the case where an unrelated trailing comment on a PRIOR
statement happens to contain a marker word).

## The `# MANUAL: no source` Marker Requires an Issue Reference

F3's marker is not a permanent exemption — it defers the debt to an issue,
not away from one. Per llm#792: **"a marker with no expiry becomes a lie"**
— one private repo carried a `# MANUAL: ... no parser exists yet` marker for
a value whose parser had since been written, and the code and the comment
had silently diverged.

Two enforcement halves, split by what each tool can check:

1. **Missing issue reference — unconditional error, regardless of graduated
   tier.** A `# MANUAL:` comment with no `#<number>` citation is flagged by
   the `manual-marker-no-issue-ref` ast-grep rule
   (`.claude/ast-grep-rules/manual-marker-staleness.yml`) as a hard error on
   every commit, in every file — this does not wait for Option C's
   path-based graduation, because an uncited marker can never be verified
   against a source that has since become available, in any file.
2. **Cited issue has since closed — staleness check.** `r_code_check.sh`
   greps for `# MANUAL:.*#[0-9]+`, resolves each cited issue via
   `gh issue view <N> --json state`, and flags any marker whose issue is
   `CLOSED` as stale. If `gh` cannot resolve the issue's state (auth
   failure, wrong repo, network), the check reports **INDETERMINATE** — it
   does not silently pass as clean and does not silently block (see
   `checks-must-distinguish-unknown`).

Required marker form: `# MANUAL: no source (see #123)`.

## Decision Table

| Situation | Response |
|---|---|
| Literal + marker comment, in `R/plan_*/**` etc. | **Block** — F1 (parser) or F2 (cite as P2) before commit |
| Literal + marker comment, elsewhere | **Warn** — triage to P1/P2/P3, fix this cycle or document |
| `# MANUAL: no source` with no issue ref | **Block, unconditionally** — add `(see #N)` |
| `# MANUAL: no source (see #N)`, issue #N closed | **Block** — marker is stale; update the code or delete the marker |
| `# MANUAL: no source (see #N)`, issue #N open | Pass — debt is tracked and current |
| Documented constant with citation + sensitivity test | Pass — this is F2's target state, not a violation |
| Stub that sets a `using_placeholder`-style flag and surfaces it in output | Pass — self-identifying, not a silent violation |

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `# rough first-pass` literal shipped unchanged for months | The comment is a promise that was never kept | F1/F2/F3 within the cycle it was added |
| `# user-confirmed` or `# from statement` on a hand-typed figure | This is a violation, not a confirmation — no parser, no test, no audit trail (global `Reproducible Ingestion` rule) | Write the parser (F1) |
| `# MANUAL: no source` with no issue number | Cannot be checked for staleness, ever | Cite a tracking issue |
| A closed-issue `# MANUAL:` marker left in place | The marker becomes a lie once the blocking reason (no source) is resolved | Re-derive via F1, or delete per F4 |
| Comment names the real source of truth on the line above a hand-copied value (e.g. `# Source of truth: R/foo.R -> bar()` then hardcoding a stale copy) | The instrument exists and is unplugged | Call the named function instead of copying its output |
| Two hand-maintained copies of the same figure in different files | They will drift; nothing enforces agreement | Single source of truth, referenced from both call sites |
| Suppressing the ast-grep warning instead of fixing the literal | Treats the symptom, not the debt | Apply F1–F4; do not add an exclude pattern for source code |

## Related

- `data-glossary-and-entity-resolution` — same single-source-of-truth
  discipline, applied to join keys and entity identifiers rather than
  standalone literals
- `roborev-exclude-patterns` — the exclude-pattern mechanism this rule
  deliberately does NOT use for source files (only session-ledger and
  generated-data paths are legitimate exclusions)
- `checks-must-distinguish-unknown` — the INDETERMINATE behaviour of the
  MANUAL-marker staleness check when `gh` cannot resolve an issue's state
- Global `AGENTS.md` — `Reproducible Ingestion (ALL PROJECTS)` bullet,
  which this rule's marker vocabulary and F1–F4 verbs are cross-referenced
  from
- `.claude/ast-grep-rules/provisional-constants.yml` — the structural
  detector (staged in-repo; requires a one-time manual copy to
  `~/.config/ast-grep/rules/` per that file's header — see
  `feedback_ast-grep-lessons.md`)
- `.claude/ast-grep-rules/manual-marker-staleness.yml` — the missing-issue-
  reference detector (same deploy requirement)
- `.claude/scripts/r_code_check.sh` — the graduated block/warn logic and
  the MANUAL-marker closed-issue staleness check
- [JohnGavin/llm#792](https://github.com/JohnGavin/llm/issues/792) — origin
  issue: taxonomy, fix vocabulary, and the friction-question decision (C)
- [JohnGavin/llm#793](https://github.com/JohnGavin/llm/issues/793) — this
  project's own per-repo findings from the llm#792 audit
- [JohnGavin/llm#590](https://github.com/JohnGavin/llm/issues/590) — rule
  path-scoping discipline this rule follows
