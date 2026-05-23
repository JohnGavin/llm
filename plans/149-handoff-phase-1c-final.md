# Closure Doc: Issue #149 — Phase 1c Verification + Weekly-Chain Plist Wiring

**Issue:** [JohnGavin/llm#149](https://github.com/JohnGavin/llm/issues/149)
**Date:** 2026-05-23
**PR:** feat/149-phase-1c-and-wiring

---

## Phase Rollout Summary

| Phase | Behaviour | Status | PR |
|---|---|---|---|
| 1a | verdict=fail → per-commit GH issue (label `roborev-handoff`) | Shipped + verified | #254 |
| 1b | verdict=pass+comments → weekly digest issue (label `roborev-digest`) | Shipped | #260 |
| 1c | verdict=pass clean → silent roborev close (nothing surfaces) | Verified + SELFTEST extended | this PR |
| Plist wiring | weekly chain: handoff first, autoclose second | Wired | this PR |

---

## Phase 1c Verification

### Code location

`~/.claude/scripts/roborev_handoff.sh` lines 346–357 (`pass-clean` case block):

```bash
pass-clean)
  if [ "$APPLY" -eq 0 ]; then
    echo "[dry] $repo_name: would close pass-clean (job $job_id)"
  else
    if "$ROBOREV" close "$job_id" >/dev/null 2>&1; then
      log "1c: closed pass-clean job=$job_id repo=$repo_name"
    else
      log "fail: roborev close $job_id (1c)"
    fi
  fi
  act_1c=$((act_1c + 1))
  ;;
```

### Classification logic

"pass clean" = `verdict_bool=1` AND `output` starts with `"No issues found."`.

The `classify_review` function (line 278) implements this. Any job with
`verdict_bool=0` is routed to `fail` regardless of output text — this prevents
a fail job from being silently closed if its review body happened to start with
"No issues found." by coincidence.

### SELFTEST coverage (extended in this PR)

The SELFTEST block now exercises 11 assertions (was 7). Tests 8–11 are Phase 1c:

| Test | What it checks |
|---|---|
| 8 | Dry-run path emits `[dry] ... would close pass-clean (job N)` |
| 9 | End-to-end: classify step routes `verdict_bool=1 + "No issues found."` → `pass-clean` |
| 10 | Guard: `verdict_bool=0` is NOT silently closed even if output looks clean |
| 11 | Guard: `pass-comments` is NOT silently closed |

Run with:
```bash
HANDOFF_SELFTEST_FULL=1 bash ~/.claude/scripts/roborev_handoff.sh
# or equivalently:
ROBOREV_HANDOFF_SELFTEST=1 bash ~/.claude/scripts/roborev_handoff.sh
```

Expected: `11 PASS, 0 FAIL`, runtime < 10s.

Verified: **11/11 PASS in 0.09s** on 2026-05-23.

---

## Weekly Chain Design

### Problem

The plist previously ran `roborev_autoclose.sh --apply` directly. This meant
handoff never ran automatically — it had to be triggered manually. Pass-clean
jobs accumulated without being silently closed, and fail jobs accumulated
without becoming GH issues.

### Solution

New wrapper script `~/.claude/scripts/roborev_weekly_chain.sh` called by the
plist instead. It invokes handoff then autoclose **in sequence**:

```
1. roborev_handoff.sh --apply   ← Phase 1a/1b/1c: convert findings to GH artifacts
2. roborev_autoclose.sh --apply ← safety net: close anything still stale after handoff
```

**Why order matters:** handoff closes jobs only after successfully creating
the GH artifact (issue, digest entry). Autoclose runs afterwards and handles
any remaining stale jobs that handoff could not convert (e.g., repos not on
GitHub, jobs with no review attached). Running autoclose first would
pre-close jobs before handoff could convert them to GH issues — lost findings.

**Fail-loud behaviour:** if handoff fails (exit ≠ 0), autoclose does NOT run.
The chain exits 1. This prevents autoclose from destroying evidence for a
transient handoff failure (e.g., GH API rate limit).

**Depth guard:** `_RWC_DEPTH` prevents recursive invocation (max depth 2).

### Files changed

| File | Change |
|---|---|
| `~/.claude/scripts/roborev_handoff.sh` | SELFTEST extended: +4 Phase 1c tests, `HANDOFF_SELFTEST_FULL` alias added |
| `.claude/scripts/roborev_weekly_chain.sh` | NEW: weekly wrapper (handoff → autoclose) |
| `~/Library/LaunchAgents/com.claude.roborev-autoclose.plist` | ProgramArguments updated to call `roborev_weekly_chain.sh` |
| `plans/149-handoff-phase-1c-final.md` | This closure doc |

---

## Plist Reload (User Action Required)

The plist is wired but NOT reloaded in this PR. After merging, the user must
run:

```bash
launchctl unload ~/Library/LaunchAgents/com.claude.roborev-autoclose.plist
launchctl load   ~/Library/LaunchAgents/com.claude.roborev-autoclose.plist
```

Or to test the chain manually without waiting for Monday 09:15:

```bash
DRY_RUN=1 bash ~/.claude/scripts/roborev_weekly_chain.sh
```

---

## Rollout State Across Repos

All repos registered in the roborev DB are handled automatically. No
per-repo configuration is required for Phase 1c (silent close of pass-clean
jobs). Repos that opted into Mechanism B (inbox mode via
`.claude/.roborev-handoff-mode`) are also handled correctly — pass-clean jobs
from inbox-mode repos are still silently closed (inbox mode only affects fail
and pass-comments routing).

Phase 1a + 1b were verified against `randomwalk` during manual `--apply` runs
on 2026-05-23 (7 fail issues created, 5 pass-clean jobs silently closed). The
weekly chain inherits the same verification.

---

## Acceptance Criteria (from issue #149)

- [x] Phase 1a: verdict=fail → GH issue per commit, label `roborev-handoff` (verified PR #254)
- [x] Phase 1b: verdict=pass+comments → weekly digest issue (shipped PR #260)
- [x] Phase 1c: verdict=pass clean → silent close, SELFTEST covers all guard conditions
- [x] Handoff script runs before autoclose in the weekly plist
- [x] Weekly chain fails loud if handoff fails (autoclose not run)
- [x] `bash -n` passes for all scripts
- [x] `plutil -lint` passes for the plist
- [x] `HANDOFF_SELFTEST_FULL=1` exits 0 with 11 PASS in < 10s
