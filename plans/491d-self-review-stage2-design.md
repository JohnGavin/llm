# Plan: Stage 2 of Self-Review (LLM Proposer + Transcript Mining)

> **Parent issue:** [#491](https://github.com/JohnGavin/llm/issues/491) (lessons-learnt pipeline starved)
> **Related issue:** [#235](https://github.com/JohnGavin/llm/issues/235) (overnight self-improvement loop; Stage 2 deferred)
> **Status:** Design + decomposition (this file). Implementation work in sub-issues.

## Context

Stage 1 of the self-review job runs nightly at 02:30 (`com.claude.self-review-stage1.plist`)
and writes findings to `unified.duckdb::self_review_findings_stage1`. It is operational
(11 cumulative findings as of 2026-06-02). However:

1. **Three of its five source tables are starved** (#491 covers the ETL fix): `hook_events`
   stuck at 1 row since 2026-04-24; `errors` stuck at 1 row since 2026-04-20; `agent_runs`
   undercount (~3.5 rows/day vs expected ≥10).
2. **Even when sources are fixed**, Stage 1 only catches 5 narrow operational anomalies
   (stuck loops, excessive hook blocks, error rates, isolation violations, pivot-signal
   bursts). The "real" lessons-learnt signals — false-positive subagent findings, premature
   parent-issue closures, repeated rule violations, user pushback — are not in any current
   DuckDB table because they live in **conversation content**.

The session transcripts at `~/.claude/projects/<project>/<session-id>.jsonl` ARE the missing
signal source. They contain user prompts, assistant responses, tool calls, and tool results
— the actual narrative of where Claude got things wrong. This design defines how Stage 2
extracts lessons from those transcripts.

## CRITICAL framing decision (per `skills-vs-mcp` rule)

Each proposed Stage 2 detector is classified before implementation:

| Surface | What it does | Examples in this plan |
|---|---|---|
| **Deterministic SQL/regex** (script) | DOES detection — adds rows to a findings table | Premature-issue-closure detector; SaaS-quarantine-repeat detector; HEAD_MOVED_SAME_BRANCH-noise filter |
| **LLM-proposer** (Bash + Sonnet API) | STEERS the next step — proposes a PR or issue draft from findings | One LLM call per finding cluster; output constrained to issue/PR draft |
| **Rule / skill** | STEERS how humans/agents respond to findings | `lessons-learnt-triage` skill (future, out of scope here) |

We start with deterministic detectors where the signal is regex-extractable from the
transcript text. We add LLM only on top of structured findings (Option B from #235) —
never as the first-line classifier. This honours `verification-before-completion` and
`analytical-review-checklist`.

---

## Design decisions

### 1. Stage 2 form: hybrid (SQL-over-transcripts + bounded LLM proposer)

**Decision: hybrid.** Three distinct layers:

- **Layer 2a — transcript mining** (deterministic): a `transcripts` ETL parses
  `~/.claude/projects/*/<session-id>.jsonl` into a new DuckDB table. SQL detectors
  (regex over `transcript_segments.text`) catch the structured-text signals.
- **Layer 2b — LLM proposer** (Sonnet, bounded): consumes findings from Stage 1 +
  Layer 2a; emits ONE of (issue draft, PR draft, no-op) per finding cluster.
  Strict cost/turn cap. Always dry-run for the first week.
- **Layer 2c — Stage-1 false-positive filters**: small additions to
  `self_review_stage1.sql` that subtract known-noise patterns (e.g.
  `HEAD_MOVED_SAME_BRANCH` on legit fixer commits).

Pure LLM ("Option A" in #235) was rejected — too easy to hallucinate problems and amplify
drift. Pure SQL ("just add more detectors") is preferred where the signal IS extractable
deterministically; LLM is reserved for cluster-summarisation and proposal generation.

### 2. Transcript source of truth

**Schema (confirmed from a sample of `~/.claude/projects/-Users-johngavin-docs-gh-llm/9d2c2663-...jsonl`):**

Each line is one JSON record. Record types observed:

| `.type` | Fields populated | Use for Stage 2 |
|---|---|---|
| `user` | `.message.role`, `.message.content` (string OR array), `.timestamp`, `.sessionId` | User prompts incl. pushback signals |
| `assistant` | `.message.model`, `.message.usage`, `.message.stop_reason`, `.message.content` (array of blocks: text, tool_use, ...) | Tool calls, reasoning, stop reasons |
| `attachment` | `.path`, `.bytes` | Generally skip; can flag large attachments |
| `last-prompt` | `.content` | Session-final prompt state |
| `queue-operation` | `.operation` (enqueue/dequeue), `.timestamp`, `.content` (for enqueue) | Identifies subagent dispatches |

**Decision: keep raw `.jsonl` on disk; parse incrementally into a new `transcripts` table
in `unified.duckdb`.** Schema sketch:

```sql
CREATE TABLE transcripts (
  session_id   VARCHAR,
  project      VARCHAR,         -- derived from parent dir name
  seq          INTEGER,         -- line number within the .jsonl
  ts           TIMESTAMP,
  record_type  VARCHAR,         -- user|assistant|tool_use|tool_result|...
  role         VARCHAR,         -- user|assistant|system|null
  model        VARCHAR,         -- only for assistant rows
  tool_name    VARCHAR,         -- for tool_use blocks
  text         VARCHAR,         -- prose / tool input summary
  tokens_in    INTEGER,
  tokens_out   INTEGER,
  PRIMARY KEY (session_id, seq)
);
```

Parser walks `~/.claude/projects/*/`, skips already-loaded `(session_id, max_seq)` pairs,
flattens nested content arrays into one row per text/tool_use block.

### 3. What to detect — concrete categories

Each row below is a CANDIDATE Stage 2 detector. The sub-issues filed cover the ones marked
**P0** and **P1**. P2 are documented but deferred.

| ID | Detector | Class | Priority | Signal source |
|---|---|---|---|---|
| **D-A** | Premature parent-issue closure | SQL regex | P0 | transcripts: assistant `gh issue close ...` followed within N tool calls by user prompt containing "reopen" or "premature" |
| **D-B** | Subagent false-positive finding | SQL regex | P0 | transcripts: subagent reports "issue X" → user replies "false positive" / "not a bug" / "actually safe" |
| **D-C** | Rule violation repeated across sessions | SQL aggregation | P0 | hook_events block-log entries (once #491 ETL fixed); cluster by hook_name + rule context |
| **D-D** | User pushback on previously-accepted approach | SQL regex | P1 | transcripts: user prompts containing "we already said", "I told you before", "stop doing X", "you reverted my X" |
| **D-E** | SaaS-quarantine warning repeated ≥2/week | SQL aggregation | P1 | hook_events for `webfetch_saas_quarantine.sh` |
| **D-F** | HEAD_MOVED_SAME_BRANCH false-positive filter | SQL filter | P0 | `worktree_post_verify.log`: subtract verdicts where the new commit is a fixer-agent-attributed commit on a feature branch |
| **D-G** | Tool-call retry loop (same tool same args N times) | SQL aggregation | P1 | transcripts: 3+ identical tool_use blocks in a row from same assistant |
| **D-H** | Subagent dispatch missing both prefixes | SQL regex | P2 | transcripts: assistant Agent tool_use without the verbatim "CRITICAL — Bash discipline" or "CRITICAL — Worktree isolation" strings |
| **D-I** | Cross-project edit from non-llm session | SQL join | P2 | transcripts × sessions: writes outside session's project tree |
| **D-J** | Compound-command blocks per session | SQL aggregation | P2 | compound_guard.log + transcripts session context |

P0 = ships in initial Stage 2. P1 = next iteration. P2 = deferred (gather data first).

### 4. Cost model

**Decision: strict daily and per-finding token budget; circuit breaker on the launchd job.**

If Layer 2b uses Sonnet (model `claude-sonnet-4-7`, ~$3/Mtok input, ~$15/Mtok output):

- Average finding cluster = ~10k input tokens (system prompt + finding evidence + relevant transcript excerpts)
- Per cluster proposal = ~2k output tokens (issue/PR body draft)
- Per-call cost ≈ $0.06

Caps:
- Max **10 clusters/night** → ≤ $0.60/day → ≤ $4.20/week → ≤ $18/month
- **Circuit breaker:** if `unified.duckdb::stage2_run_log.tokens_billed_today > $5`, the job
  exits early and emails the user
- **Dry-run mode** is the default for the first 7 nights. Only after 7 consecutive clean
  dry-runs (no malformed output, no off-target proposals) does `--write` get flipped on.

### 5. Privacy

**Decision: opt-in per-project + LLM call only on excerpted, redacted segments.**

- Transcripts contain conversation content. Some projects (e.g. `mycare`) carry medical
  context; some sessions deal with credentials. Sending raw transcripts to the Anthropic
  API would breach `credential-management` and `permission-discipline` Part 4.
- The parser **stays local** — only writes to `unified.duckdb` (local DuckDB file).
- The LLM proposer (Layer 2b) sends only:
  - Finding rows from `self_review_findings_stage1` and `self_review_findings_stage2`
  - **Excerpted** transcript segments (max 500 chars around the matched regex), with
    automated redaction of common credential patterns (`gh[psr]_[A-Za-z0-9]+`,
    `sk-ant-[A-Za-z0-9-]+`, `Bearer [A-Za-z0-9._-]+`, email addresses, `~/.Renviron` content)
- Projects can opt OUT by adding `self_review_stage2: false` to `.claude/CLAUDE.md`. Default
  is opt-IN for `llm` (the meta-config project) and opt-OUT for everything else, mirroring
  the `cross-project-scope` rule.
- For now, only `llm` project transcripts flow to Layer 2b. Other projects' transcripts
  stay in the local `transcripts` table for SQL detection only (Layer 2a).

### 6. Output

**Decision: new table `self_review_findings_stage2` + an OUTBOX of issue/PR drafts.**

- `self_review_findings_stage2(finding_id, finding_type, severity, evidence, ...)` mirrors
  Stage 1's schema; adds `transcript_excerpt`, `proposed_action` (issue|pr|noop|deferred),
  `proposed_target_file`, `proposed_body_md_sha256`.
- Linkage: `stage2.linked_stage1_id` → `stage1.finding_id` when Stage 2 builds on top of a
  Stage 1 finding. A Stage 2 finding can also be standalone (transcript-only).
- **OUTBOX:** proposed issue/PR bodies are written to
  `~/.claude/state/stage2_outbox/<finding_id>.md` as markdown. The launchd job NEVER calls
  `gh issue create` directly; that requires explicit user authorisation (per
  `pr-shipping-discipline` rule, "ship it" is not in the loop).
- **Surfacing:** a new `session_init.sh` Phase 13e reads the OUTBOX, prints count + 3 most
  recent drafts inline, and points the user at `~/.claude/scripts/stage2_outbox_review.sh`
  to triage.

---

## Decomposition into sub-issues

Each sub-issue is independently shippable. The umbrella issue (491-D-0) tracks the lot.

| Sub-issue tag | Title | Class (per skills-vs-mcp) | Depends on |
|---|---|---|---|
| 491-D-0 | umbrella: track Stage 2 design + sub-issues | n/a | — |
| 491-D-1 | transcript ETL → `unified.duckdb::transcripts` | script (deterministic) | none (independent) |
| 491-D-2 | Stage 2 detectors D-A, D-B, D-F (P0 set) | script (SQL regex) | 491-D-1 (D-A/D-B); none (D-F) |
| 491-D-3 | LLM proposer Layer 2b + circuit breaker | script + bounded LLM | 491-D-2 |
| 491-D-4 | OUTBOX + Phase 13e surfacing | script + hook | 491-D-3 |
| 491-D-5 | dry-run soak (7-night observation, then enable --write) | operational | 491-D-3, 491-D-4 |

Each detector promoted from P1/P2 later becomes its own follow-on issue, not a sub of this
plan.

---

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Transcript table blows up `unified.duckdb` size | Compress text column; archive segments older than 90 days; track DB size in `roborev_metrics_etl.sh` |
| Regex detectors generate cascade of duplicates | Per-session dedup by `finding_id` (md5 hash of session_id + detector_id + evidence_hash); follow Stage 1's `ON CONFLICT DO NOTHING` pattern |
| LLM proposer drafts inflate token bill silently | Per-day circuit breaker (above); per-call hard cap on `max_tokens`; weekly mailed report listing proposals + cost |
| Credentials leak in transcript excerpts | Redaction patterns; opt-in/opt-out by project; never call API on opt-OUT projects |
| OUTBOX accumulates stale drafts | session_init Phase 13e prints staleness; nightly cleanup of drafts older than 14 days that were neither acted on nor closed |
| Stage 2 noise overwhelms signal | First 7 nights are dry-run; #235 acceptance criterion ("1 week of dry-run output reviewed before enabling auto-PR") is honoured |

---

## Acceptance for this plan (not for implementation)

- [x] Design doc exists at `.claude/plans/491d-self-review-stage2-design.md`
- [x] Decisions on all 6 design questions stated explicitly
- [x] JSONL transcript schema documented from a real sample
- [x] Each detector classified per `skills-vs-mcp` (deterministic vs LLM)
- [x] Privacy boundary documented (local-only SQL; LLM gets redacted excerpts only for opt-in projects)
- [x] Cost model with hard caps + circuit breaker
- [x] 5-6 sub-issues filed, each independently shippable, all referencing #491

Implementation acceptance lives in each sub-issue.

---

## Related

- #235 — parent self-improvement loop spec (Stage 1 done, Stage 2 deferred)
- #491 — ETL starvation (parallel work — fixing the source tables Stage 1 + Stage 2a both read)
- `skills-vs-mcp` rule — classification of each detector
- `pr-shipping-discipline` rule — why OUTBOX, not direct `gh issue create`
- `credential-management` + `permission-discipline` Part 4 — redaction + opt-in/out policy
- `verification-before-completion` — soak period before enabling --write
- `analytical-review-checklist` — review checklist applied to LLM proposer drafts before they ship
- `cross-project-scope` — Stage 2 transcripts default to opt-OUT for non-llm projects

## Out of scope

- The Codex sibling pipeline (#231 — closed; tracks its own structured JSONL source separately)
- Layer 2c rule/skill authoring (the lessons that Stage 2 finds will inform a future
  `lessons-learnt-triage` skill; that work waits for >= 10 high-confidence Stage 2 findings)
- Replacing roborev with Stage 2 (different problem class; per #235 Option C analysis)
