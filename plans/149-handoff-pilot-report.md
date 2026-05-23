# Phase 1a Pilot Report — randomwalk

**Date:** 2026-05-23
**Author:** Claude Sonnet 4.6 (fixer agent, worktree `agent-a5ad23a4d7c46563f`)
**Issue:** [JohnGavin/llm#149](https://github.com/JohnGavin/llm/issues/149)
**Status:** DRY-RUN ONLY — `--apply` NOT executed (creates irreversible GH issues; user runs manually)

---

## Pilot Target

**Repo:** `randomwalk` (substituted for inactive `crypto` per user decision 2026-05-23)

---

## Candidate Count Query

Query run:
```sql
SELECT COUNT(*)
FROM review_jobs rj
JOIN repos r ON r.id = rj.repo_id
JOIN reviews rv ON rv.job_id = rj.id
WHERE r.name = 'randomwalk'
  AND rj.status = 'done'
  AND (julianday('now') - julianday(rj.finished_at)) > 7
  AND rv.verdict_bool = 0
```

Result: **7 stale verdict=fail candidates** (confirmed 2026-05-23)

---

## Script Portability Fix Applied

During dry-run inspection, a portability bug was found and fixed:

**Before:** `GH="${GH:-/usr/bin/gh}"` — hardcoded path, fails in Nix environments where `gh` lives in the Nix store.

**After:** `GH="${GH:-$(command -v gh 2>/dev/null || echo /usr/bin/gh)}"` — resolves `gh` from `$PATH` at script start, falls back to `/usr/bin/gh` on macOS without Nix.

Without this fix, the script exits early with `"roborev_handoff: skipped (/usr/bin/gh missing)"` in any Nix shell session. The fix makes the script work without requiring the caller to set `GH=` manually.

---

## Dry-Run Output

Command: `ROBOREV_REPO=randomwalk bash ~/.claude/scripts/roborev_handoff.sh 2>&1`

```
[dry] randomwalk: would close pass-clean (job 291)
[dry] randomwalk: would close pass-clean (job 369)
[dry] randomwalk: would create GH issue (commit 93da959, job 687, label roborev-handoff)
[dry] randomwalk: would create GH issue (commit 699993d, job 689, label roborev-handoff)
[dry] randomwalk: would create GH issue (commit 2840d8d, job 690, label roborev-handoff)
[dry] randomwalk: would create GH issue (commit 4367dc6, job 692, label roborev-handoff)
[dry] randomwalk: would create GH issue (commit d7c9be9, job 693, label roborev-handoff)
[dry] randomwalk: would close pass-clean (job 694)
[dry] randomwalk: would create GH issue (commit 384beff, job 701, label roborev-handoff)
[dry] randomwalk: would close pass-clean (job 702)
[dry] randomwalk: would create GH issue (commit 507cc3f, job 709, label roborev-handoff)
[dry] randomwalk: would close pass-clean (job 906)
roborev_handoff [dry-run]: repos=1 processed=1 actions={1a:7,1b:0,1c:5,B:0} skipped=0
```

**Interpretation:**
- 7 Phase 1a actions: 7 GH issues would be created (one per fail commit)
- 5 Phase 1c actions: 5 pass-clean jobs would be silently closed
- 0 Phase 1b actions: no pass-with-comments jobs (all passes are clean)
- 0 Mechanism B: issues enabled on randomwalk, no inbox fallback needed

---

## Pre-Flight Checklist for `--apply`

Run these from a terminal (NOT from a Claude Code dispatch — `--apply` is irreversible):

### 1. Create the `roborev-handoff` label in randomwalk

```bash
gh label create roborev-handoff \
  --repo JohnGavin/randomwalk \
  --color 8B5CF6 \
  --description "Findings surfaced by roborev_handoff.sh (Phase 1a)"
```

If the label already exists, this will error — ignore the error and proceed.

### 2. Confirm issues are enabled

```bash
gh repo view JohnGavin/randomwalk --json hasIssuesEnabled
```

Expected output (confirmed 2026-05-23):
```json
{"hasIssuesEnabled":true}
```

### 3. Run `--apply` (user runs this manually from terminal)

```bash
ROBOREV_REPO=randomwalk bash ~/.claude/scripts/roborev_handoff.sh --apply
```

Expected outcome: 7 issues created in `JohnGavin/randomwalk`, 5 pass-clean jobs closed in the roborev DB.

---

## Idempotency Check Plan

After the first `--apply` run, wait 60 seconds then run again:

```bash
ROBOREV_REPO=randomwalk bash ~/.claude/scripts/roborev_handoff.sh --apply
```

Expected: `actions={1a:0,1b:0,1c:0,B:0}` — no new issues created (idempotency gate). The `gh issue list --search "$commit_sha in:body"` guard in the script prevents duplicates.

---

## Verification After `--apply`

1. Check GitHub: `gh issue list --repo JohnGavin/randomwalk --label roborev-handoff` — should show 7 new issues.
2. Check log: `tail -20 ~/.claude/logs/roborev_handoff.log` — should show 7 `1a: created issue` lines and 7 `1a: closed job=` lines.
3. Check DB: the 7 fail jobs should now be closed in the roborev DB. Run the candidate count query again — result should be 0.

---

## Rollback If It Goes Wrong

If spurious issues are created:

```bash
# List issues created by the handoff
gh issue list --repo JohnGavin/randomwalk --label roborev-handoff --state open

# Close each spurious one (replace N with the issue number)
gh issue close N --repo JohnGavin/randomwalk --comment "Closed by rollback — roborev_handoff.sh pilot cleanup"
```

Leave roborev jobs OPEN in the DB (do not close them) — the next `--apply` will re-process them.

---

## Acceptance Criteria Status (Plan §5)

| Criterion | Status |
|---|---|
| `--dry-run` runs without error; prints `[dry] ... would create GH issue` lines | PASS — 7 lines printed, exit 0 |
| `ROBOREV_REPO=randomwalk --apply` creates ≥1 GH issue OR exits with "nothing to do" | PENDING — user runs `--apply` manually |
| Re-running `--apply` within 60s produces zero new issues | PENDING — verify after first `--apply` |
| Log contains `1a: created issue` AND `1a: closed job=` for same job_id | PENDING — verify after first `--apply` |
| If `gh issue create` forced to fail, roborev job stays open | NOT TESTED in this PR — requires manual test with `GH=/usr/bin/false` |

Phase 1b, 1c, and plist wiring are NOT acceptance criteria for this PR.

---

*Report generated 2026-05-23 by fixer agent. Script fix applied to `~/.claude/scripts/roborev_handoff.sh` (GH path portability). All other script logic unchanged.*
