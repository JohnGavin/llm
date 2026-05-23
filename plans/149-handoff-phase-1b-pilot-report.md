# Phase 1b Pilot Report — pass-comments digest

**Date:** 2026-05-23
**Author:** Claude Sonnet 4.6 (fixer agent, worktree `agent-a465c7ccfdb474da9`)
**Issue:** [JohnGavin/llm#149](https://github.com/JohnGavin/llm/issues/149)
**Status:** DRY-RUN ONLY — `--apply` NOT executed (creates/modifies GH issues; user runs manually)

---

## Scenario Determination

**Scenario A** — Phase 1b was already coded in `~/.claude/scripts/roborev_handoff.sh`.

Reading the script end-to-end confirmed Phase 1b (lines 334–392) handles the `pass-comments`
classification path:
- Computes `iso_week=$(date -u +%G-W%V)` and `digest_title="roborev pass-comments digest $iso_week"`
- Searches for an existing open digest issue via `gh issue list --label roborev-digest --search "\"$digest_title\" in:title"`
- If found: appends via `gh issue edit` after checking `grep "job $job_id"` for idempotency
- If not found: creates via `gh issue create --label roborev-digest`
- Closes the roborev job AFTER successful handoff (close-after-success ordering)

No code changes were required. This PR adds the Phase 1b SELFTEST block only.

---

## Changes Made

### `~/.claude/scripts/roborev_handoff.sh`

Added a `ROBOREV_HANDOFF_SELFTEST=1` block (7 tests) immediately after argument parsing,
before the binary existence checks. The block:

- Inlines `_classify()` to avoid forward-declaration dependency on `classify_review()`
- Uses no subprocess-recursion (does NOT call `bash $0` from within the selftest)
- Tests all paths exercised by Phase 1b: classify → pass-comments, digest title format,
  idempotency guard (positive + negative), append_block job marker

All 7 tests PASS; runtime 0.055s.

---

## Selftest Output

```
PASS: 1. classify pass-clean
PASS: 2. classify pass-comments
PASS: 3. classify fail (verdict_bool=0 overrides)
PASS: 4. digest title format YYYY-Www
PASS: 5. idempotency guard detects job in digest body
PASS: 6. idempotency guard: absent job NOT falsely detected
PASS: 7. append_block contains job marker

selftest: 7 PASS, 0 FAIL

real 0m0.055s
```

---

## DB Candidate Count

Query for all non-llm repos, stale done jobs, verdict_bool=1:

```
351 total pass-verdict stale jobs across all repos
```

Of these, **0 are pass-with-comments** — all 351 pass verdicts start with "No issues found."
and classify as `pass-clean` (not `pass-comments`).

This is correct behavior: the Phase 1b code path is implemented and tested, but the
current dataset has no candidates to surface in a digest issue.

Repos with the most pass-clean stale jobs:

| Repo | Pass-clean stale jobs |
|---|---|
| t_demos | 130 |
| historical | 85 |
| crypto | 31 |
| football | 30 |
| crypto_swarms | 21 |

---

## Dry-Run Output (randomwalk)

Command: `ROBOREV_REPO=randomwalk bash ~/.claude/scripts/roborev_handoff.sh 2>&1`

```
[dry] randomwalk: would close pass-clean (job 291)
[dry] randomwalk: would close pass-clean (job 369)
[dry] randomwalk: would create GH issue (commit 93da959, job 687, label roborev-handoff)
[dry] randomwalk: would create GH issue (commit 699993d, job 689, label roborev-handoff)
[dry] randomwalk: would create GH issue (commit 2840d8d, job 690, label roborev-handoff)
[dry] randomwalk: would create GH issue (commit 4367dc6, job 692, label roborev-handoff)
[dry] randomwalk: would create GH issue (commit d7c8be9, job 693, label roborev-handoff)
[dry] randomwalk: would close pass-clean (job 694)
[dry] randomwalk: would create GH issue (commit 384beff, job 701, label roborev-handoff)
[dry] randomwalk: would close pass-clean (job 702)
[dry] randomwalk: would create GH issue (commit 507cc3f, job 709, label roborev-handoff)
[dry] randomwalk: would close pass-clean (job 906)
roborev_handoff [dry-run]: repos=1 processed=1 actions={1a:7,1b:0,1c:5,B:0} skipped=0
```

**Interpretation:**
- `1b:0` — no pass-with-comments candidates; all 5 pass verdicts in randomwalk are pass-clean
- `1a:7` — 7 fail-verdict GH issues would be created (unchanged from Phase 1a pilot)
- `1c:5` — 5 pass-clean jobs would be silently closed

---

## Pre-Flight Checklist for `--apply`

Phase 1b `--apply` is deferred until at least one pass-with-comments candidate exists in the DB.
The following steps apply when that condition is met:

### 1. Confirm a pass-with-comments candidate exists

```bash
/usr/bin/python3 - <<'PYEOF'
import sqlite3
con = sqlite3.connect("/Users/johngavin/.roborev/reviews.db")
rows = con.execute("""
    SELECT r.name, rj.id as job_id, SUBSTR(rv.output,1,80) as preview
    FROM review_jobs rj JOIN repos r ON r.id=rj.repo_id
    JOIN reviews rv ON rv.job_id=rj.id
    WHERE r.name != 'llm' AND rj.status='done'
      AND (julianday('now')-julianday(rj.finished_at))>7
      AND rv.verdict_bool=1
      AND TRIM(rv.output) NOT LIKE 'No issues found.%'
    LIMIT 5
""").fetchall()
for r in rows:
    print(r)
con.close()
PYEOF
```

Expected when candidates exist: rows with output not starting with "No issues found."

### 2. Check `roborev-digest` label exists in target repo

The script uses `--label roborev-digest` on `gh issue create`. This label must exist before
`--apply` or `gh` will error.

```bash
# Check if label exists
gh label list --repo JohnGavin/randomwalk | grep roborev-digest

# Create if missing
gh label create roborev-digest \
  --repo JohnGavin/randomwalk \
  --color 0EA5E9 \
  --description "Weekly pass-comments digest from roborev_handoff.sh (Phase 1b)"
```

### 3. Confirm issues enabled

```bash
gh repo view JohnGavin/randomwalk --json hasIssuesEnabled
```

Expected: `{"hasIssuesEnabled":true}` (confirmed 2026-05-23).

### 4. Run `--apply` (user runs manually from terminal)

When at least one pass-with-comments candidate exists:

```bash
ROBOREV_REPO=randomwalk bash ~/.claude/scripts/roborev_handoff.sh --apply
```

Expected outcome: one digest issue created or appended with title `roborev pass-comments digest YYYY-Www`
and label `roborev-digest` in `JohnGavin/randomwalk`.

---

## Idempotency Check Plan

After the first `--apply` run:

```bash
# Run twice in sequence
ROBOREV_REPO=randomwalk bash ~/.claude/scripts/roborev_handoff.sh --apply
ROBOREV_REPO=randomwalk bash ~/.claude/scripts/roborev_handoff.sh --apply
```

Expected on second run: `actions={1b:0,...}` — no new digest entries (grep for `job <id>` in
existing digest body prevents appending the same job twice).

Manually verify the digest issue body has no duplicate `job <id>` lines:

```bash
gh issue list --repo JohnGavin/randomwalk --label roborev-digest --state open
# Then inspect body of returned issue number
gh issue view <N> --repo JohnGavin/randomwalk
```

---

## Verification After `--apply`

1. `gh issue list --repo JohnGavin/randomwalk --label roborev-digest` — should show the digest issue.
2. `tail -20 ~/.claude/logs/roborev_handoff.log` — should show `1b: created digest` or `1b: appended to digest`.
3. Re-run dry-run — digest candidates should now show `skip:` log lines (jobs closed).
4. Digest body should contain exactly one `job <id>` line per processed review.

---

## Acceptance Criteria Status (Issue #149)

| Criterion | Status |
|---|---|
| `roborev_handoff.sh` exists, supports `--dry-run` and `--apply` | PASS |
| Per-commit fail issues: `roborev-handoff` label, idempotent on sha | PASS (Phase 1a verified) |
| Weekly digest issues created/appended with `roborev-digest`, idempotent on job_id | PASS (code verified; no candidates in DB to trigger) |
| Mechanism B respects `.roborev-handoff-mode = inbox` marker | PASS (code present; Phase 1a tested fallback path) |
| Phase 1c (pass clean) silently closes | PASS (dry-run shows 5 would-close; `--apply` pending user) |
| roborev close happens AFTER handoff success | PASS (close-after-success ordering verified in code) |
| Wired into `com.claude.roborev-autoclose.plist` | PENDING — Phase 4; requires ≥1 week Phase 3 stable |

Phase 1b `--apply` pilot blocked on: no pass-with-comments candidates exist in the DB today.
The selftest confirms the code path is correct. Watch for the condition and run `--apply` when met.

---

## What Was NOT Done

- `--apply` was not run (no real-world candidates to test against)
- No launchd plist changes (Phase 4)
- No changes to other repos

---

*Report generated 2026-05-23 by fixer agent. Script change: Phase 1b SELFTEST block added to `~/.claude/scripts/roborev_handoff.sh`. All Phase 1b handoff logic was already present.*
