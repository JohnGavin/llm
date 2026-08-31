---
description: How to correctly filter AgentsView session data to substantive human coding sessions before quoting a project's health score — raw session counts wildly overstate scoreable data
paths:
  - ".claude/scripts/agentsview_quality_baseline.sh"
---

# Rule: AgentsView Quality Baseline — Substantive-Session Filtering

## Source

[JohnGavin/llm#1115](https://github.com/JohnGavin/llm/issues/1115) — a first-pass
survey across 15 actively-developed projects on this machine, verified live
(re-run and cross-checked against the issue's own claims) before this rule was
written.

## When This Applies

Any time an AgentsView session count, health score, or grade mix is quoted,
compared across projects, or used to decide whether a project's dashboard signal
is trustworthy yet.

## CRITICAL: `session_count` and `agentsview projects` Are Not Proxies for Data Quality

Across the surveyed projects, AgentsView logged 15,646 raw sessions; only 191
represented actual substantive human coding work — an 81.9x compression. Raw
count and real signal are close to uncorrelated: the largest project on record
(10,000+ logged sessions) has exactly **one** substantive session; a mid-sized
project with 448 logged sessions has **zero**.

## Substantive-Session Definition

```
message_count >= 30  AND  is_automated == false
```

**Both conditions are required independently.** `message_count >= 30` alone, on
the most-automated project surveyed, returns 210 "substantive" sessions
clustered at 30-59 messages, avg health 99.6 — all automated cron/data-refresh
runs. Adding `is_automated == false` drops that to 1.

## The Filtering Recipe

```bash
# Raw total -- everything AgentsView logged
agentsview session list --project <bucket> --limit 500 \
  --include-automated --include-one-shot --format json | jq '.total'

# Substantive human sessions -- what the dashboard's Quality tab scores
agentsview session list --project <bucket> --min-messages 30 --limit 500 \
  --include-one-shot --format json \
  | jq '{n: (.sessions|length),
         avg_health: ([.sessions[].health_score] | add / length),
         grades: (.sessions | group_by(.health_grade)
                            | map({(.[0].health_grade): length}) | add)}'
```

Prefer `.claude/scripts/agentsview_quality_baseline.sh <bucket>` over hand-typing
this — it also resolves the multi-bucket case below automatically.

### Three default exclusions, and why the default is usually right anyway

| Flag | Default | Effect when enabled |
|---|---|---|
| `--include-automated` | excluded | Adds cron/hook/scripted runs — can be a 200x swing on a heavily-automated project |
| `--include-one-shot` | excluded | Adds single-turn invocations (slash commands, `-p` calls) |
| `--include-children` | excluded | Adds subagent sessions — can change which quality tier a project falls into |

The *visible* N, the *logged* N, and the *scored* N are three different numbers.
State which one you're quoting.

## Four Caveats (Verified, Not Assumed)

1. **`agentsview projects` counts disagree with `session list` counts, in either
   direction, by 3x-17x.** Checked directly against the SQLite table. Never quote
   a `projects` count as "how many sessions this project has" — always derive the
   count from `session list`.
2. **A session too short to accumulate any negative signal scores a perfect
   100/grade-A by default**, `outcome` "unknown". Every non-substantive session
   checked in the survey behaved this way. Any average that includes them is
   meaningless — this is precisely why the `message_count >= 30` floor exists.
3. **One project can occupy several AgentsView buckets** — the bucket name is
   derived from the session's `cwd`, so a directory rename or move forks the
   history silently. 4 of 15 surveyed projects were split this way. Resolve every
   bucket for a directory name before trusting an N:
   ```bash
   sqlite3 -readonly ~/.agentsview/sessions.db \
     "SELECT project, count(*), max(cwd) FROM sessions WHERE cwd LIKE '%<dirname>%' GROUP BY project;"
   ```
4. **`--min-messages` is unreliable when combined with `--include-children`** —
   verified: sessions well under the stated floor were returned anyway. Without
   `--include-children`, the filter is exact (cross-checked client-side against
   12 full project session lists — all 12 matched). **Do not combine these two
   flags** until this is confirmed as an upstream bug or fixed
   (`agentsview.io`'s own docs returned HTTP 403 during the original research
   pass, so this was never confirmable against upstream documentation — only
   against the CLI's own live behaviour).

## Trust Tiers

| Tier | Meaning |
|---|---|
| **baseline-ready** (≥10 substantive sessions) | Average score and grade mix mean something; a session well below the project's own average is worth investigating |
| **building** (3-9) | A trend is forming; individual sessions still dominate the average |
| **too-thin** (0-2) | Do not read the score as a quality signal at all yet |

## Per-Project Detail

Per [`private-repo-detail-locality`](private-repo-detail-locality.md), per-project
numeric detail for private/local-only repos lives only in this machine's local,
never-pushed knowledge base — never in a public issue or this rule file. `llm`
and other fully public repos may be named and quoted directly (see #1115 for the
worked `llm` and `JohnGavin.github.io` examples).

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Quoting `agentsview projects`' `session_count` as "how much data this project has" | Off by 3x-17x from the real `session list` count, in either direction | Derive the count from `session list` with the substantive filter |
| Averaging health scores without filtering `is_automated` | Automated runs cluster near-perfect and dilute the real signal | Always apply `is_automated == false` |
| Querying one bucket for a renamed/moved project | Silently halves (or worse) the real N | Resolve every bucket via the `sqlite3` query above first |
| Combining `--min-messages` with `--include-children` | Returns sessions under the stated floor | Filter client-side instead, or omit `--include-children` |
| Treating a `too-thin` or `building` tier project's average as a real quality signal | N=2-9 average is dominated by individual sessions, not a trend | State the tier and N alongside any score |
| Publishing per-project detail for a private/local-only repo in a public issue | Violates `private-repo-detail-locality`; see #794 for the prior incident this rule prevents repeating | Alias + tier only in public issues; full detail in the local knowledge base |

## Related

- `private-repo-detail-locality` — governs what per-project detail may be published where
- `checks-must-distinguish-unknown` — the "short session scores 100" trap is the same class of defect: a check that cannot distinguish "no signal yet" from "genuinely good"
- `zero-metric-evidence-or-defect` (referenced by #932) — this rule exists precisely to keep an AgentsView score from becoming a monitor that reports success while broken
- `P0-blind-spots` — #1115 is labelled in this tier, not the P6 self-improvement/eval tier #932 marks blocked-on-P0, because establishing trust in the metric comes before building on it
- [JohnGavin/llm#1115](https://github.com/JohnGavin/llm/issues/1115) — origin survey, worked `tennis`/`llm`/`JohnGavin.github.io` examples, verification log
- [JohnGavin/llm#932](https://github.com/JohnGavin/llm/issues/932) — priority taxonomy this issue is classified against
