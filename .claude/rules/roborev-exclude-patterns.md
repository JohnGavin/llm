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

A `.roborev.toml` that only adds `exclude_patterns` is valid — other fields
are optional. A minimal worked example is in the companion doc.

### Adding to an existing .roborev.toml

If the file already exists, locate the `exclude_patterns` field (it may
already be present as `exclude_patterns = []`) and replace the empty list
with the required entries.

## Second Category: High-Volume Automated / Generated-Data Commits

The session-ledger case above is one instance of a broader principle: **exclude
paths whose diffs a code-review agent cannot usefully review.** The second, larger
instance is a repo whose commits are dominated by *machine-generated data*.

### Case study — llmtelemetry (2026-07-22)

`llmtelemetry` receives ~400 commits/week, effectively **100% bot-authored**.
roborev reviewed every one. Result over 7 days: **234 findings (104 High, 103
Medium) at a 16.7% close rate** — vs single digits for every other repo. None
were real bugs. The fix, the resulting `.roborev.toml`, and the bulk-close
caveats (range batch-reviews, crashed jobs) are in the companion doc.

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

Full per-repo audit table and priority actions are in the companion doc.

## Related

- [`_companions/roborev-exclude-patterns-details.md`](_companions/roborev-exclude-patterns-details.md) — case-study detail and the dated audit split out of this rule
- `roborev-resolution` rule — how to close/comment on individual roborev findings
- `roborev-setup` skill — `/roborev-setup` configures roborev for a new project
- JohnGavin/llm#198 — issue tracking this rule's acceptance criteria
- Reference `.roborev.toml`: `historical` commit `4906b6d`
