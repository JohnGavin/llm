# Plan: Merge Gate MVP — Dry-Run + Ack CLI (#241)

**Status:** MVP shipped (PR #TBD). Enforcement deferred pending week-1 signal.

## What shipped

| Deliverable | File | Status |
|-------------|------|--------|
| Merge gate script | `.claude/scripts/roborev_merge_gate.sh` | Done |
| Ack CLI | `.claude/scripts/roborev_ack.sh` | Done |
| Rule update | `.claude/rules/roborev-resolution.md` | Done |
| PR template | `.github/PULL_REQUEST_TEMPLATE.md` | Done |
| This plan | `plans/241-merge-gate-mvp.md` | Done |

## What is NOT shipped (deferred)

- `--enforce` enabling in any CI or gh-merge wrapper
- GH Actions workflow (Alternative G in #241)
- git pre-merge hook

## Dry-run usage

Run before every PR merge during week-1 signal gathering:

```bash
# Standard usage
~/.claude/scripts/roborev_merge_gate.sh 253

# Explicit dry-run
~/.claude/scripts/roborev_merge_gate.sh --dry-run 253

# From branch name
~/.claude/scripts/roborev_merge_gate.sh --branch feat/my-feature
```

Expected output patterns:

```
[gate-pass] PR #253: 0 open findings at >= medium severity
[gate-warn] PR #253: 2 unresolved Medium findings (non-blocking)
[gate-block] PR #253: 1 unresolved High/Critical + 0 Medium at >= medium. Run: roborev_ack.sh ...
```

Log location: `~/.claude/logs/merge_gate.log` — one JSON line per invocation.

## Week-1 data-collection plan

**Goal:** gather signal on how many PRs would have been blocked by enforce mode.

1. Run `roborev_merge_gate.sh <pr#>` on every PR before merging to main.
2. Let it log to `~/.claude/logs/merge_gate.log` automatically.
3. After 7 days, review the log:

```bash
# Count gate-block verdicts
grep '"verdict":"gate-block"' ~/.claude/logs/merge_gate.log | wc -l

# Count gate-warn verdicts  
grep '"verdict":"gate-warn"' ~/.claude/logs/merge_gate.log | wc -l

# Summarise by pr
python3 -c "
import json
with open('/Users/johngavin/.claude/logs/merge_gate.log') as f:
    for line in f:
        d = json.loads(line)
        print(d['ts'][:10], 'PR#'+str(d['pr']), d['verdict'], 'unresolved='+str(d['unresolved_count']))
"
```

4. If `gate-block` count per week > 3: open a follow-up issue with enforce decision.
5. If `gate-block` count == 0 (all findings were already cited): consider lowering threshold from `high` to `medium` for enforcement.

## What triggers move to `--enforce`

Enforce mode is appropriate when:

- Week-1 data shows < 50% of PRs would have been blocked (gate-pass or gate-warn)
- The ack flow is working (findings that are genuine false positives get acked)
- The #181 backlog for llm has been reduced (main-branch findings won't affect gate since gate is commit-scope)
- #163 auto-verifier is operational (closes finding when fix-commit is reviewed)

Enforce mode is NOT appropriate when:

- Week-1 data shows gate-block on > 50% of PRs (indicates too much open debt)
- The roborev poller (#217) is still racing with merges (late-arriving reviews)

## Kill switch

To skip the gate for one session:

```bash
export SKIP_MERGE_GATE=1
```

To disable enforcement permanently (once enabled):
- Edit the gate invocation in the gh-merge wrapper and remove `--enforce`
- OR set `session_end_refine = false` in `.roborev.toml` (adjacent opt-out)

## Ack flow user guide

### When to ack

Use `roborev_ack.sh` when a finding is:
- A confirmed false positive (roborev misunderstood the context)
- Wontfix (deprecated module, known pattern, architectural decision)
- Out of scope for this PR (tracked separately as a future issue)

### How to ack

```bash
# Step 1: Dry-run to see what would be written
~/.claude/scripts/roborev_ack.sh 42 \
  --reason "false positive: nix-only path never runs on macOS CI" \
  --pr 253

# Step 2: Apply to write the record
~/.claude/scripts/roborev_ack.sh 42 \
  --reason "false positive: nix-only path never runs on macOS CI" \
  --pr 253 \
  --apply

# Step 3: Include the printed line in your next commit message
# e.g.: acks roborev #42 --reason "false positive: nix-only path never runs on macOS CI"
```

### What ack does NOT do

- Does NOT close the finding in `reviews.db` (it stays at `closed=0`)
- Does NOT prevent roborev from re-reviewing on future commits to the same file
- Does NOT satisfy the gate permanently — the ack is checked per-PR by reading `acks.jsonl`

### Ack ledger location

`~/.roborev/acks.jsonl` — one JSON object per line, append-only.

## Related issues

- #241 — parent issue (this plan)
- #163 — closure loop automation (commit-citation convention the gate uses)
- #224 — severity autoclose (sibling policy; aged findings only)
- #181 — 92-review llm backlog (main-branch debt; not blocked by gate in commit-scope mode)
- #217 — poller redesign (race-condition mitigation; needed before enforce)
- #223 — agent verification block (complementary enforcement)
