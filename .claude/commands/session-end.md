# /session-end - End Development Session

**Alias: `/bye`** — `~/.claude/commands/bye.md` mirrors this file. This is canonical; update here and copy to `bye.md`.

Run the end-of-session checklist from AGENTS.md Section 6.

## First: Write the /bye sentinels (llm#273 — per-session)

Before any other step, run this shell command so session_stop.sh and
llmtelemetry_emit.sh know this Stop event comes from /bye (not a normal reply).
Both hooks now use per-session sentinels to prevent concurrent sessions from
consuming each other's sentinels. The legacy global sentinels are also written
for backward compatibility with any consumer not yet updated.

```bash
# Resolve session ID (mirrors llmtelemetry_emit.sh resolution)
_bye_sid="${CLAUDE_SESSION_ID:-}"
if [ -z "$_bye_sid" ] && [ -f "${HOME}/.claude/logs/.llmtelemetry_ppid_session.${PPID:-0}" ]; then
  _bye_sid=$(cat "${HOME}/.claude/logs/.llmtelemetry_ppid_session.${PPID:-0}" 2>/dev/null || echo "")
fi
if [ -z "$_bye_sid" ] && [ -f "${HOME}/.claude/logs/.current_session" ]; then
  _bye_sid=$(cat "${HOME}/.claude/logs/.current_session" 2>/dev/null || echo "")
fi

# Write per-session sentinels (primary — llm#273)
if [ -n "$_bye_sid" ]; then
  touch "${HOME}/.claude/.bye-requested.${_bye_sid}"
  touch "${HOME}/.claude/.bye-session-end-refine.${_bye_sid}"
fi
# Write legacy global sentinels (backward-compat for hooks not yet updated)
touch "${HOME}/.claude/.bye-requested"
touch "${HOME}/.claude/.bye-session-end-refine"
```

## Steps

1. Check for uncommitted changes
2. Check for unresolved roborev findings
3. Prompt to commit or stash
4. Append to `CHANGELOG.md` — completed work, failed approaches, accuracy changes, new limitations
5. Update `.claude/CURRENT_WORK.md` with session summary (ephemeral)
6. Push to remote
7. Sync ctx.yaml cache (verify, regenerate if needed)
8. Report session summary

## Commands to Execute

```r
library(gert)
library(usethis)

# Check status
status <- git_status()
branch <- git_branch()

cat("## Session End Checklist\n\n")
cat("Branch:", branch, "\n")

if (nrow(status) > 0) {
  cat("\n### Uncommitted Changes\n")
  print(status)
  cat("\nAction needed: commit or stash these changes\n")
} else {
  cat("Working tree clean\n")
}

# Check if ahead of remote
cat("\n### Remote Sync\n")
# Would need to check git_ahead_behind()
```

## Roborev Findings Check

Before committing, verify no unresolved roborev findings remain.

**IMPORTANT:** `roborev summary --json` has two independent sections that must both be checked. Crashed reviews never produce a verdict, so `verdicts.failed` alone is insufficient:
- `.verdicts` — only counts reviews that produced a pass/fail result. If a review job **crashes** (e.g. agent `IneligibleTierError`), it never reaches a verdict, so `verdicts.failed` stays 0 even when all jobs crashed (#676).
- `.overview` — job-level outcomes (`total`, `done`, `failed`). Real job failures live here.
- `.failures` — crash and quota counts: `{total, errors: {crash, quota}}`.
- `.agents[]` — per-agent stats: `{agent, total, errors, pass_rate}`.

Check ALL of the following and report NOT-CLEAN if ANY condition is true:

```bash
/usr/local/bin/roborev summary --json | jq '{
  verdicts_failed: .verdicts.failed,
  verdicts_addressed: .verdicts.addressed,
  overview_failed: .overview.failed,
  failures_total: (.failures.total // 0),
  failures_crash: (.failures.errors.crash // 0),
  failures_quota: (.failures.errors.quota // 0),
  agent_errors: [.agents[] | select(.errors > 0) | {agent, errors}]
}'
```

Report NOT-CLEAN and ask the user if ANY of:
- `verdicts.failed > 0` AND `verdicts.addressed < verdicts.failed` — unaddressed verdict failures
- `overview.failed > 0` — job-level failures (includes crashes that never produce a verdict)
- `failures.total > 0` — any crash or quota errors recorded
- any `.agents[] | .errors > 0` — an agent is failing systematically

If NOT-CLEAN:
- Report the failing category (verdict / job / crash / agent)
- Ask user: "Proceed with commit despite unresolved roborev findings? (Y/N)"
- If no, do NOT commit; suggest fixing failures first or investigating agent health (`roborev_agent_health.sh --status`)

## ctx.yaml Cache Verification

After commit/push, verify all ctx files are current:

```r
source("~/docs_gh/llm/R/tar_plans/plan_pkgctx.R")
audit <- ctx_audit("DESCRIPTION")
```

If any MISSING or OTHER_VERSION remain (background sync from session start didn't finish), run `ctx_sync("DESCRIPTION")` now.

## CHANGELOG.md Update (MANDATORY)

Append a new dated entry to `CHANGELOG.md` with:
- **Completed:** what was done this session
- **Failed Approaches:** what was tried and didn't work (and why) — prevents future sessions retrying dead ends
- **Accuracy / Metrics:** any measurable changes (test count, coverage, quality score)
- **Known Limitations:** issues discovered but not yet fixed

```markdown
## YYYY-MM-DD

### Completed
- [what was done]

### Failed Approaches
- Tried X because Y. Failed because Z. Workaround: W.

### Accuracy / Metrics
- Tests: N passing, coverage: X%

### Known Limitations
- [issues for next session]
```

## Telemetry Data Export

After committing and pushing, export local telemetry data to the dashboard:

```bash
~/.claude/scripts/export_and_deploy_data.sh
```

This exports predictions, unified.duckdb sessions, and cmonitor-rs data to
`llmtelemetry/vignettes/data/`, commits, and pushes. CI then deploys the
updated data to the live dashboard. Only runs if data actually changed.

## Prompt User

After running checks, ask:
1. "Should I commit these changes with message: [suggested message]?"
2. "Should I append to CHANGELOG.md?" (show draft entry)
3. "Should I push to remote?"
4. "Should I export telemetry data to dashboard?" (runs export_and_deploy_data.sh)
5. "Should I sync ctx.yaml cache?" (if audit showed gaps)

## Output Format

```
## Session End Summary

### Changes
- [X files modified / committed / pushed]

### CURRENT_WORK.md Updated
[Yes/No - contents if updated]

### Next Session
- Continue on branch: [branch]
- Open issue: #[num]
- Next task: [description]
```
