# Plan 235 — Overnight Self-Review, Stage 1 MVP

**Issue:** [#235](https://github.com/JohnGavin/llm/issues/235)
**PR:** feat/235-self-review-stage1
**Scope:** Stage 1 only. Stage 2 (LLM proposer) deferred.

---

## What Stage 1 Detects

Stage 1 is a deterministic SQL gate. It reads `~/.claude/logs/unified.duckdb`
and emits zero or more rows to `self_review_findings_stage1`. No LLM is
involved. No issues are filed. No files are edited.

| Detector | Finding type | Threshold | Severity |
|---|---|---|---|
| Repeated identical agent dispatches (stuck loop proxy) | `stuck_loop` | same `(session_id, agent_type, status)` ≥ 3 times | major |
| Permission/guard blocks | `excessive_guard_blocks` | > 5 blocks from any guard hook in one hour | major |
| Tool error rate | `high_tool_error_rate` | error_count / total_calls > 20% per tool per day | minor (20-50%) / major (≥50%) |
| Agent dispatch isolation violations | `isolation_violation` | any hook_events row with `output_preview ILIKE '%ISOLATION%VIOLATION%'` | critical |
| Pivot-signal rule threshold | `pivot_signal_threshold` | ≥ 3 errors from same tool in one session (3=minor, 5=major, 7=critical) | minor/major/critical |

### Thresholds — rationale

- **Stuck loop ≥ 3:** the `pivot-signal` rule treats 3 consecutive failures as the first signal. Below 3, variation is normal; at 3 the agent is expected to pause and pivot.
- **Guard blocks > 5/hour:** individual blocks are expected (hooks are working). Five+ in an hour indicates a systematic issue (bad dispatch pattern, missing bypass flag, or hook misconfiguration).
- **Error rate > 20%:** one-in-five failures is the standard alert threshold in production SRE practice. Below 20% is within operational noise.
- **Isolation violations:** zero tolerance. A single confirmed violation means an agent wrote to the main checkout — immediate surfacing required.
- **Pivot signal 3/5/7:** maps directly to the rule's three-tier escalation table.

---

## What Stage 1 Does NOT Do (deferred to Stage 2 / Stage 3)

| Excluded from Stage 1 | Reason |
|---|---|
| LLM analysis of findings | Stage 2: only runs when Stage 1 finds rows above threshold |
| Filing GitHub issues from findings | Stage 2 output; requires human review gate |
| Proposing edits to rules/skills/CLAUDE.md | Stage 2 output; PR-only, no direct commits |
| Phase 13d surfacing in `session_init.sh` | Stage 3: reads pending self-review issues |
| Dedup check against open issues | Stage 2: prevents re-proposing already-open findings |
| Per-finding metric (accepted/modified/rejected) | Stage 3: write-back after human triage |
| Privacy boundary enforcement (cross-project-scope) | Stage 2: query scoping by `sessions.project` |

---

## Findings Table Schema

```sql
CREATE TABLE IF NOT EXISTS self_review_findings_stage1 (
    finding_id      VARCHAR PRIMARY KEY,    -- md5 hash of key fields; stable across re-runs
    finding_type    VARCHAR NOT NULL,       -- see detector table above
    session_id      VARCHAR,               -- NULL for day-level findings
    severity        VARCHAR NOT NULL,       -- critical | major | minor | info
    evidence        JSON,                  -- structured evidence dict
    detected_at     TIMESTAMP NOT NULL     -- time of detection (not time of event)
);
```

`finding_id` is deterministic (md5 hash of key fields) so re-running the job
on the same data is idempotent — `ON CONFLICT DO NOTHING` prevents duplicates.

### How to read the findings table

```sql
-- All critical and major findings from the last 7 days
SELECT finding_type, session_id, severity, evidence, detected_at
FROM self_review_findings_stage1
WHERE severity IN ('critical', 'major')
  AND detected_at > current_timestamp - INTERVAL 7 DAY
ORDER BY
    CASE severity WHEN 'critical' THEN 1 WHEN 'major' THEN 2 ELSE 3 END,
    detected_at DESC;

-- Count by type
SELECT finding_type, severity, COUNT(*) AS n
FROM self_review_findings_stage1
GROUP BY finding_type, severity;
```

---

## Files Delivered (Stage 1 MVP)

| File | Purpose |
|---|---|
| `.claude/scripts/self_review_stage1.sql` | 5 detector CTEs + table create + summary query |
| `.claude/scripts/self_review_stage1.sh` | Bash wrapper: args, lock, dry-run, selftest |
| `.claude/launchd/com.claude.self-review-stage1.plist` | 02:30 daily schedule |
| `plans/235-self-review-stage1.md` | This document |

---

## Installation (Manual — not from this dispatch)

1. Copy (or symlink) the plist to `~/Library/LaunchAgents/`:
   ```bash
   cp .claude/launchd/com.claude.self-review-stage1.plist \
      ~/Library/LaunchAgents/
   plutil -lint ~/Library/LaunchAgents/com.claude.self-review-stage1.plist
   launchctl load -w ~/Library/LaunchAgents/com.claude.self-review-stage1.plist
   ```
2. Verify it is loaded:
   ```bash
   launchctl list | grep self-review-stage1
   ```
3. First dry-run:
   ```bash
   bash .claude/scripts/self_review_stage1.sh --dry-run
   ```
4. First live run (after 1 week of dry-run observation per issue acceptance criteria):
   ```bash
   bash .claude/scripts/self_review_stage1.sh --write
   ```

---

## Stage 2 — How It Will Consume This (Future PR)

Stage 2 will:
1. Query `self_review_findings_stage1 WHERE severity IN ('critical','major')` for
   findings in the last 24 hours.
2. If zero rows → skip LLM invocation entirely.
3. For each finding group, invoke Sonnet (not Opus) with the evidence JSON and
   a constrained output schema (one of: `file_issue | propose_pr | no_action`).
4. `file_issue` → `gh issue create --label self-review --draft`.
5. `propose_pr` → create a `chore/self-review-*` branch + commit the proposed
   diff + open a PR for human review.
6. No direct commits to `main` from Stage 2 (enforced by `agent_push_guard.sh`).

Stage 3 will add Phase 13d to `session_init.sh` to surface pending `self-review`
labelled issues/PRs at session start (analogous to Phase 13c for dated issues).

---

## Acceptance Criteria (from Issue #235)

- [x] Stage 1 SQL views defined and tested against real session data
- [x] `--dry-run` default; `SELFTEST=1` mode with depth guard
- [x] launchd plist at 02:30; `RunAtLoad=false`; `TimeOut=120`
- [ ] Stage 2 LLM proposer (deferred)
- [ ] Phase 13d surfacing (deferred)
- [ ] Per-finding metric write-back (deferred)
- [ ] Dedup check (deferred)
- [ ] Privacy scoping (deferred)
- [ ] 1-week dry-run before enabling --write in launchd
