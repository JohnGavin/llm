# Plan: #163 Slice 3 — Auto-Verifier (Component 4)

**Issue:** [JohnGavin/llm#163](https://github.com/JohnGavin/llm/issues/163)
**Slice:** 3 of 4 (DB migration + post-commit auto-verifier)
**Status:** Implementation complete — pilot pending
**Depends on:** Slice 1 (Components 1 + 3) merged to main
**Author:** fixer agent (claude-sonnet-4-6), 2026-05-23

---

## 1. Scope

Slice 3 ships **Component 4 only** (the auto-verifier), gated safely:

| Deliverable | File | Mutations? |
|---|---|---|
| DB migration SQL | `.claude/scripts/roborev_schema_migration_v2.sql` | Additive only (IF NOT EXISTS) |
| Auto-verifier script | `.claude/scripts/roborev_auto_verify.sh` | DB writes gated behind `--apply` |
| Install helper | `.claude/scripts/roborev_install_auto_verify_hook.sh` | Manual invocation only |
| Rule update | `.claude/rules/roborev-resolution.md` | Append-only |
| This plan | `plans/163-slice-3-auto-verifier.md` | — |

**NOT shipped in Slice 3:**
- No auto-installation of hooks into any project
- No changes to existing scripts (roborev_project_backlog.sh, roborev_commit_msg_validator.sh)
- No launchd plists
- No expansion beyond t_demos during pilot

---

## 2. Pilot procedure

**Target:** `t_demos` — chosen because it has a high approval rate, low finding density,
and no Critical/High severity open findings. If the auto-verifier wrongly closes a
finding here, the consequence is recoverable (reopen via `roborev reopen <id>`).

### Step 1: Apply the DB migration

```bash
sqlite3 ~/.roborev/reviews.db < ~/.claude/scripts/roborev_schema_migration_v2.sql
```

Verify:
```bash
sqlite3 ~/.roborev/reviews.db "SELECT label, closures_exists, frq_exists FROM (
  SELECT 'migration_v2' AS label,
    (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='closures') AS closures_exists,
    (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='fix_rejected_queue') AS frq_exists
);"
# Expected: migration_v2|1|1
```

### Step 2: Verify self-test passes

```bash
time SELFTEST=1 bash ~/.claude/scripts/roborev_auto_verify.sh
# Expected: 10/10 PASS, elapsed <5s
```

### Step 3: Dry-run smoke test

In the t_demos repo, make a test commit referencing a known open finding:
```bash
git -C <t_demos-path> log -1 --format='%B'  # see if any roborev IDs cited already
```

Run dry-run against the commit:
```bash
bash ~/.claude/scripts/roborev_auto_verify.sh --dry-run --commit <SHA> --repo t_demos
```

Expected: exits 0, prints the `[dry-run]` plan without mutating DB.

### Step 4: Install the hook into t_demos

```bash
bash ~/.claude/scripts/roborev_install_auto_verify_hook.sh --repo <t_demos-path> --dry-run
# review output
bash ~/.claude/scripts/roborev_install_auto_verify_hook.sh --repo <t_demos-path>
```

### Step 5: Pilot commit

Make a real fix commit in t_demos:
- Fix something that was flagged by roborev
- Use the commit message convention: `fix(<scope>): <summary> (closes roborev #<id>)`
- The post-commit hook fires automatically; observe the log:

```bash
tail -f ~/.claude/logs/roborev_auto_verify.log
```

### Step 6: Acceptance criteria for pilot completion

| # | Criterion | How to verify |
|---|---|---|
| P1 | ≥3 auto-closures recorded in `closures` table | `sqlite3 reviews.db "SELECT COUNT(*) FROM closures WHERE closure_type='approved'"` |
| P2 | 0 wrong-closures | Spot-check each closure: re-open, re-review manually |
| P3 | fix_rejected_queue entries look correct | Query the table for rejected fixes |
| P4 | Hook exits 0 and does not block commits | Observe all commit operations succeed |
| P5 | Self-test still passes after pilot commits | `SELFTEST=1 bash roborev_auto_verify.sh` |

---

## 3. Rollout criteria (Slice 4)

After the pilot passes P1–P5:

- Expand to `llm` project (highest finding density, many open findings)
- Then `llmtelemetry`, then `historical`
- Run `--dry-run` on each project before installing the hook
- Never install on a project with open Critical findings before adding the
  human-gate guardrail (Slice 4 / Component 7)

---

## 4. Monitoring

### Log

`~/.claude/logs/roborev_auto_verify.log` — one line per event:

```
2026-05-23T10:00:00Z INFO: abc1234 cites 3 finding(s): 1551,1545,1536
2026-05-23T10:00:05Z APPROVED: job=9001 commit=abc1234 closing 1551,1545,1536
2026-05-23T10:00:05Z CLOSED finding_id=1551 type=approved commit=abc1234
```

### DB query: closures dashboard

```sql
-- Closures this week
SELECT
    closure_type,
    COUNT(*) AS n,
    MIN(created_at) AS first,
    MAX(created_at) AS last
FROM closures
WHERE created_at >= date('now', '-7 days')
GROUP BY closure_type;
```

### DB query: pending rejections (triage queue)

```sql
SELECT
    id,
    finding_ids_json,
    fix_commit_sha,
    rejection_summary,
    attempted_at
FROM fix_rejected_queue
WHERE resolved = 0
ORDER BY attempted_at DESC
LIMIT 20;
```

---

## 5. Kill switch

If the auto-verifier causes any problems:

**Immediate (no commit needed):**
```bash
# Disable for one session
SKIP_ROBOREV_VALIDATOR=1 git commit ...

# Uninstall from t_demos
bash ~/.claude/scripts/roborev_install_auto_verify_hook.sh --repo <t_demos-path> --uninstall
```

**If wrong closures land:**
```bash
# Reopen a wrongly closed finding
roborev reopen <finding_id>

# Check what the closures table recorded
sqlite3 ~/.roborev/reviews.db \
  "SELECT * FROM closures WHERE finding_id = <id>"
```

**Nuclear option (revert to pre-Slice-3 state):**
```bash
# Drop the new tables (all closure history lost — only after confirming no useful data)
sqlite3 ~/.roborev/reviews.db "DROP TABLE IF EXISTS closures; DROP TABLE IF EXISTS fix_rejected_queue;"
```

---

## 6. Risks and mitigations

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | Auto-closes a finding that is NOT fixed | Low (re-review must approve) | Medium | Only `--apply` mutates; re-review is the gate; reversible via `roborev reopen` |
| 2 | Polling blocks the post-commit hook too long | Low | High (frustrating) | POLL_TIMEOUT_SECS=120 hard cap; hook exits 0 on timeout (fail-open) |
| 3 | roborev review job ID cannot be parsed from CLI output | Medium (CLI output format may change) | Low | DB fallback query finds the latest job for the commit SHA |
| 4 | Multi-finding commit: partial approval (some IDs pass, some fail) | Medium | Medium | All-or-nothing rule: any rejection queues ALL cited IDs for triage |
| 5 | DB schema not yet migrated (tables missing) | Medium (until operator runs migration) | Low | Fail-open: verifier exits 0 with a clear message pointing to migration SQL |
| 6 | Pilot project (t_demos) doesn't have roborev findings | Low | Trivial | Check `roborev_project_backlog.sh t_demos` before installing |

---

## 7. Integration with related issues

| Issue | Interaction |
|---|---|
| [#181](https://github.com/JohnGavin/llm/issues/181) | The closures table feeds the `addressed-rate` metric that #181 tracks |
| [#241](https://github.com/JohnGavin/llm/issues/241) | Merge-gate PR will query `closures` to verify claims before merging |
| [#217](https://github.com/JohnGavin/llm/issues/217) | Poller covers remote-merged PRs; auto-verifier covers local commits. Both needed. |

---

## 8. Next slice (Slice 4)

| Component | Description | Dependencies |
|---|---|---|
| 5 — Full scheduler | launchd for all projects + weekly digest | Slice 3 pilot passed |
| 7 — Safety guardrails | Human gate for Critical/High auto-close | Slice 3 stable |
| 8 — Full rollout | Expand to all 12+ projects | Guardrails in place |
