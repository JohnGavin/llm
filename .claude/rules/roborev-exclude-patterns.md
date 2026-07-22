---
description: Require per-repo .roborev.toml to exclude session-ledger files (CHANGELOG.md, .claude/CURRENT_WORK.md) from automated code review
paths:
  - "**/.roborev.toml"
---

# Rule: roborev exclude_patterns for Session-Ledger Files

## Source

JohnGavin/llm#198. Reference implementation: commit `4906b6d` in the
`historical` project — first `.roborev.toml` with
`exclude_patterns = ["CHANGELOG.md", ".claude/CURRENT_WORK.md"]`.

Diagnosis: between 2026-05-13 and 2026-05-20 those two files in the
`historical` project produced ~50+ Medium-severity roborev reviews that
all said the same five things (audit count off by 2, SHA stale, "13 closed"
vs "15 closed" breakdown, etc.). Not one surfaced a real bug. The root cause
is that session-ledger files record facts **about themselves** (issue counts,
commit SHAs) — every fix triggers the same finding wave on the next commit.

## When This Applies

Any project that has **both**:

1. A `.roborev.toml` (roborev is enabled for the repo), AND
2. One or more session-ledger files committed to git

A session-ledger file is any file that records operational/audit state that
is guaranteed to change on every session-end commit:

| File | Why it is self-referential |
|------|---------------------------|
| `CHANGELOG.md` | Contains commit SHAs and issue counts about the project |
| `.claude/CURRENT_WORK.md` | Contains issue IDs and task counts for the active session |

Other candidates to assess per project: `plans/CURRENT_PLAN.md`,
`knowledge/wiki/*.md` that tabulate open-issue counts.

## CRITICAL: Self-Referential Files Create Review Cascade Noise

A reviewer looking at a diff to `CHANGELOG.md` will see: new SHA, updated
count, changed "N closed" line. It will flag "SHA is stale", "count off by
2", "inconsistent closed/open breakdown". The fixer commit changes the SHA
and count — which creates a new diff — which triggers another review — which
flags the same issues on the new values.

Excluding these files from review diffs breaks the cascade without
suppressing legitimate reviews on source code.

## Required Pattern

Every project with roborev enabled MUST have a `.roborev.toml` in the repo
root that lists session-ledger files in `exclude_patterns`:

```toml
# ── Review-exclusion for session-ledger files ─────────────────────────────────
# These files record audit counts and commit SHAs about themselves.
# Every fix-commit triggers another wave of the same findings (SHA stale,
# count off by N). Excluding them breaks the cascade without hiding real bugs.
# See JohnGavin/llm#198.
exclude_patterns = [
  "CHANGELOG.md",
  ".claude/CURRENT_WORK.md",
]
```

### Minimum file contents

A `.roborev.toml` that only adds `exclude_patterns` is valid. Other fields
are optional:

```toml
exclude_patterns = [
  "CHANGELOG.md",
  ".claude/CURRENT_WORK.md",
]
```

### Adding to an existing .roborev.toml

If the file already exists, locate the `exclude_patterns` field (it may
already be present as `exclude_patterns = []`) and replace the empty list
with the required entries.

## Second Category: High-Volume Automated / Generated-Data Commits

The session-ledger case above is one instance of a broader principle: **exclude
paths whose diffs a code-review agent cannot usefully review.** The second, larger
instance is a repo whose commits are dominated by *machine-generated data*.

### Case study — llmtelemetry (2026-07-22)

`llmtelemetry` receives ~400 commits/week, effectively **100% bot-authored**:
`data: update telemetry data` (regenerated JSON/parquet under `inst/extdata/**`)
and `chore: Auto-refresh ccusage cache`. roborev reviewed every one. Result over
7 days: **234 findings (104 High, 103 Medium) at a 16.7% close rate** — vs single
digits for every other repo. None were real bugs; a reviewer pointed at
regenerated data flags spurious churn ("value changed", "count differs").

Fix applied — a `.roborev.toml` excluding the generated-data paths, so a
data-only commit presents an empty diff and produces no findings, while real
`R/`/`scripts/` commits are still reviewed:

```toml
exclude_patterns = [
  "inst/extdata/**",     # automated telemetry data + ccusage cache
  "vignettes/data/**",   # dashboard data exports
  "CHANGELOG.md",
  ".claude/CURRENT_WORK.md",
]
```

~230 already-accumulated open **single-data-commit** findings were bulk-closed
as won't-fix (`roborev close <id>` per review). **Left untouched — verify before
mass-closing:**

- `range` batch-reviews (`job_type=range`, `commit_subject=null`, `git_ref=SHA..SHA`):
  these span a *range* of commits — inspect the range (`git log A..B`) before
  assuming noise. In llmtelemetry the range reviews covered mostly **real code**
  (fixes/features from an earlier dev period), not data refreshes — closing them
  blindly would have destroyed legitimate findings.
- Single real-code reviews (`fix:`/`feat:`/merges) — genuine triage.
- Crashed jobs (`verdict=null status=failed`) — the gemini-crash artifacts;
  `roborev close` cannot address them (no verdict to resolve). They are a
  separate problem (agent health), not findings, and clear via re-run/purge.

### How to spot this category

`git log --since="7 days ago" --pretty='%s' | sed -E 's/[0-9].*//' | sort | uniq -c | sort -rn`

If one or two automated subjects dominate (data refresh, cache, snapshot,
leaderboard, auto-format) and touch a stable data/output directory, exclude that
directory. **Only exclude generated-output paths — never `R/`, `scripts/`, or
other human-authored source.**

## Forbidden Patterns

| Pattern | Why wrong |
|---------|-----------|
| No `.roborev.toml` in a roborev-enabled repo | exclude_patterns cannot be set |
| Reviewing bot-authored generated-data commits (data refresh, cache, snapshot) as if code | Floods the queue with noise findings at a near-zero close rate; exclude the generated-data path instead |
| `exclude_patterns = []` when CHANGELOG.md is committed | Cascade will occur |
| Excluding only CHANGELOG.md but not `.claude/CURRENT_WORK.md` | Partial — second file still triggers cascade |
| Suppressing the reviews without excluding the files | Treats symptoms, not root cause |
| Adding project source files to `exclude_patterns` | Hides real bugs; only self-referential ledger files belong here |

## How to Add to a New Repo

1. Confirm roborev is enabled: `ls .roborev.toml` should exist or be created.
2. Confirm session-ledger files are committed: `git ls-files CHANGELOG.md .claude/CURRENT_WORK.md`
3. Add `exclude_patterns` as shown above.
4. Commit: `git commit -m "chore(roborev): exclude session-ledger files from review [skip review]"`
   (The `[skip review]` tag prevents roborev from reviewing the toml change itself.)

## Audit Results — 2026-05-21

Repos checked for `.roborev.toml` + CHANGELOG.md status:

| Repo | `.roborev.toml` | `CHANGELOG.md` | `exclude_patterns` covers CHANGELOG? | Action needed |
|------|----------------|----------------|--------------------------------------|---------------|
| `historical` (reference) | Yes | Yes | Yes — `4906b6d` | None — compliant |
| `llm` | Yes | Yes | No — `exclude_patterns = []` | Add entries |
| `crypto_solwatch` | Yes | No | n/a | No CHANGELOG to exclude |
| `llmtelemetry` | Yes | Yes | Yes — `inst/extdata/**` + `vignettes/data/**` + ledger (2026-07-22) | None — compliant |
| `mycare` | No | No | n/a | No action needed |
| `irishbuoys` | No | No | n/a | No action needed |
| `footbet` | No | No | n/a | No action needed |
| `randomwalk` | No | No | n/a | No action needed |
| `urban_planning` | No | No | n/a | No action needed |
| `acd_area_climate_design` | No | No | n/a | No action needed |
| `crypto_swarms` | No | No | n/a | No action needed |

**Priority actions from this audit:**
1. `llm` — has both files; `exclude_patterns = []` → needs the two entries added.
2. `llmtelemetry` — has CHANGELOG.md; check if roborev is enabled and add toml if so.

## Related

- `roborev-resolution` rule — how to close/comment on individual roborev findings
- `roborev-setup` skill — `/roborev-setup` configures roborev for a new project
- JohnGavin/llm#198 — issue tracking this rule's acceptance criteria
- Reference `.roborev.toml`: `historical` commit `4906b6d`
