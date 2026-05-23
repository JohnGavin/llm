# Parallel Agent Cap Investigation — Issue #236

**Date:** 2026-05-23
**Author:** fixer agent (claude-sonnet-4-6)
**Issue:** JohnGavin/llm#236

## Question

Does performance degrade beyond N=7 parallel agent dispatches, as the Towards Data Science article claims? Should `auto-delegation` rule add a numeric cap?

## Data Source

`~/.claude/logs/unified.duckdb` → `agent_runs` table.

Schema:
```
id, session_id, agent_type, model, started_at, ended_at, duration_sec, prompt_preview, status
```

## What the Data Shows

### Row count

48 rows total. Data spans 2026-04-24 to 2026-05-23.

### Status distribution

| agent_type | model   | status  | n  |
|------------|---------|---------|-----|
| unknown    | unknown | running | 47 |
| quick-fix  | haiku   | running | 1  |

All 48 rows have `status = 'running'`. Zero rows have `ended_at` populated.

### Concurrent dispatch analysis

Sessions with more than one agent row:

| session_id (prefix)  | agents_in_session | time span |
|----------------------|-------------------|-----------|
| 1435338d…            | 4                 | ~2 min    |
| 60d99efa…            | 3                 | ~1 min    |
| a21dc0d5…            | 3                 | ~5 min    |
| ed8f9e53…            | 3                 | ~41 sec   |
| 7181170a…            | 2                 | ~20 sec   |
| (8 others)           | 2                 | various   |

Maximum observed parallel dispatch count in a single session: **4 agents**.

The article's claimed degradation threshold of N=7 has never been reached in recorded history. The highest observed value is 4.

## Root Cause of Incomplete Data

The ETL pipeline records `started_at` via `log_agent_run.sh` on agent dispatch, but **never records `ended_at`** or updates `status` from `'running'` to `'completed'`/`'failed'`. This means:

- Duration computation (`ended_at - started_at`) is impossible for all rows.
- Success vs failure cannot be distinguished from the DB.
- Cost-per-success across N parallel dispatches cannot be computed.
- `agent_type` is populated as `'unknown'` for 47/48 rows — the ETL call site is not passing agent type correctly.

The ETL was added recently (2026-05-xx as part of the `agent_runs` infrastructure in #226). The completion-recording half was not yet implemented at the time of this analysis.

## Recommendation: No Cap at This Time

**Recommendation: do NOT add a numeric cap to `auto-delegation`.**

Rationale:

1. **No empirical support for the article's claim.** The article asserts "performance degrades beyond 7" without citing data. Our own telemetry shows we have never dispatched more than 4 parallel agents in a session. We have no evidence of degradation at any count we have actually used.

2. **Our isolation model differs from the article's.** The article's parallel agents share context (Warp panes in the same terminal session). Our agents use `isolation: "worktree"` — each runs in an isolated checkout with its own branch. Resource contention, context collision, and coordination overhead are structurally different problems in our architecture.

3. **The right constraint is already in `auto-delegation`.** The `burn-rate-aware escalation` section scales down parallel dispatch when burn rate is WARN/CRITICAL. That is a cost-informed cap, more appropriate than an arbitrary numeric limit.

4. **A cap would be premature optimisation.** Given max observed N=4, adding a N=7 cap would be a no-op today. Adding a lower cap (e.g. N=3) without evidence would reduce throughput without measurable benefit.

## What Should Be Fixed Instead

The telemetry ETL needs a completion-recording step before this analysis is feasible. Specifically:

- `log_agent_run.sh` should be called a second time on agent completion (or a separate `log_agent_complete.sh` should be created) that writes `ended_at` and updates `status`.
- `agent_type` population needs investigation — 47/48 rows show `'unknown'`.

These are tracked separately from this issue.

## Evidence Summary

| Signal | Value | Source |
|--------|-------|--------|
| Max observed parallel agents in one session | 4 | `agent_runs` GROUP BY session_id |
| Rows with `ended_at` populated | 0/48 | `DESCRIBE + SELECT` |
| Rows with `status != 'running'` | 0/48 | GROUP BY status |
| Article's claimed degradation threshold | 7 | TDS article (no citation) |
| Our architecture's isolation model | worktree per agent | `auto-delegation` rule |

## Decision

No cap added to `auto-delegation` rule. Absence of cap is deliberate: we lack evidence to justify one, and our isolation model differs from the article's. This decision should be revisited when `agent_runs` ETL records completions and we have per-dispatch cost/success data across N >= 7 concurrent dispatches.
