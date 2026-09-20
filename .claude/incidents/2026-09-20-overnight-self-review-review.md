# Critical review: the Overnight Self-Review process

**Date:** 2026-09-20
**Trigger:** the 2026-09-20 email read `1 new findings across 4 session(s) · 0 of 3 source
tables stale or dead` and `✓ All clear — nothing needs action`, carrying one `fixer_heavy_day`
INFO finding. The suspicion raised: *the report is not capturing lessons learnt in individual
conversations from yesterday.*

**Verdict: the suspicion is correct, and it is structural, not a gap in coverage.** The review
observes telemetry exclusively. Nothing in it can see a conversation, a correction, a rule
amendment or a memory file. Separately, the green verdict has been unable to go red since
2026-08-26.

**Premise correction:** the job fires at **08:45**, not 06:30 (`com.claude.overnight-self-review-email.plist:9`,
moved by llm#1122). Several notes in this repo still say 06:30.

---

## 1. What it observes

Stage 1 (`self_review_stage1.sql`) is ten detectors over four tables. No detector reads any
conversation content — no transcript, no user message, no tool argument, no file diff.

| # | Detector | Reads | Signal | Severity |
|---|---|---|---|---|
| 1 | `stuck_loop` | `agent_runs` | ≥3 rows per (session, agent_type) with `status='running' AND ended_at IS NULL` >1h | major |
| 2 | `excessive_guard_blocks` | `hook_events` | >5 `%guard%` blocks in one hour bucket | major |
| 3 | `high_tool_error_rate` | `errors`, `agent_runs` | error_count / daily agent calls > 20% | major/minor |
| 4 | `isolation_violation` | `hook_events` | `output_preview ILIKE '%ISOLATION%VIOLATION%'` | critical |
| 5 | `pivot_signal_threshold` | `errors` | ≥3 errors per (session, source) | minor/major/critical |
| 6 | `parallel_session_sprawl` | `sessions` | ≥4 concurrent sessions in a day | info |
| 7 | `subagent_heavy_session` | `agent_runs` | ≥10 dispatches per session | info |
| 8 | `marathon_session` | `sessions` | duration ≥8h | info |
| 9 | `fixer_heavy_day` | `agent_runs` | fixer ≥40% of ≥5 daily dispatches | info |
| 10 | `data_gap` | — | static row documenting a missing column | info |

Columns read are timestamps, counts, statuses and a truncated `output_preview`. That is the
whole observable surface.

The email layer (`send_overnight_self_review_email.R`, 2646 lines) adds 14 further sections
over `worktree_gc_events`, `config_events`, `kb_events`, `launchd_health_events`,
`branch_gc_events`, `secret_scan_findings`, `staleness_status` and `settings.json`. Still no
conversation content, and — before this PR — no git.

---

## 2. The lessons-capture gap — **CONFIRMED**

Evidence, not inference:

```
$ git log --since=2026-09-18 --until=2026-09-21 --no-merges -- .claude/memory/ .claude/rules/
d14365f 2026-09-19 docs(changelog): session-end 2026-09-11..13 + two memory lessons …(#1197)
2901194 2026-09-19 docs(rules): propagate two lessons from a stray-worktree incident (#1219)
```

Those two commits, both landed 2026-09-19 10:58, added **four written lessons**:

- `.claude/memory/feedback_agent-worktree-pinning.md` (new, 35 lines)
- `.claude/memory/feedback_shared-fixture-keys-make-tests-nondeterministic.md` (new, 35 lines)
- `.claude/rules/worktree-location.md` (+41 lines)
- `.claude/rules/checks-must-distinguish-unknown.md` (+27 lines)

The 2026-09-20 report mentioned none of them. It could not have: a repo-wide grep of the sender
for `lesson`, `CHANGELOG`, `git log`, `memory/` and `rules/` returns **zero matches**. There is
no code path by which a written lesson could reach the report.

So the report's own scope banner — *"a quiet morning here is not evidence that nothing needs
changing"* — was literally true on a day that produced four lessons and one of the largest
working sessions of the week (an 18.5 MB transcript in
`-Users-johngavin-docs-gh-worktrees-llm-feat-cc-20260913-122624`, last written 2026-09-19 23:23).

> ⚠ AI-inferred: that those four lessons were the *most important* thing about 2026-09-19. I
> verified they were written and that the report omitted them; I did not read the transcripts to
> judge whether other, unwritten lessons also occurred. By construction an unwritten lesson
> cannot be detected by any git-based mechanism — see §5 for what that limit means.

---

## 3. Errors found

### E1 — The verdict cannot go red on findings alone *(major; wording fixed, logic not)*

`action_items` is built from `n_critical`, `n_major`, cron failures and stale tables only
(`send_overnight_self_review_email.R:1665-1690`). `info` and `minor` findings never reach it.

```
$ duckdb -readonly ~/.claude/logs/unified.duckdb \
    -c "SELECT finding_type, severity, count(*), max(detected_at) FROM self_review_findings_stage1 GROUP BY 1,2"
marathon_session        info      118   2026-09-16
parallel_session_sprawl info      107   2026-09-18
fixer_heavy_day         info       47   2026-09-20
subagent_heavy_session  info       17   2026-09-19
stuck_loop              major      13   2026-08-10   ← last major
high_tool_error_rate    major       3   2026-06-08
pivot_signal_threshold  critical    3   2026-08-26   ← last critical
```

**Every finding emitted since 2026-08-26 has been `info`.** For 25 days the verdict has been
green by construction. A green that cannot go red trains the reader to skip it
(`checks-must-distinguish-unknown`, "too quiet").

**Fixed here:** wording only — the box now says what it checked and names the non-action
findings. **Not fixed:** whether `info` volume should escalate at all (see F1).

### E2 — "All clear — nothing needs action" contradicted its own scope banner *(major; FIXED)*

Two overclaims in one line: it asserted across the whole system while reading four telemetry
tables, and it said "nothing needs action" on a day that logged a finding. It sat directly below
a banner saying a quiet morning proves nothing. Now renders:

> ✓ No action-level findings — 1 info/minor finding(s) logged, not action-rated.
> Checked: session telemetry, cron health, source-table freshness. Not checked: config, rules,
> code, or anything said in a conversation.

The subject line keeps `✓ all clear` (stable for filters; the existing verdict-parity test at
`test-overnight-self-review-email.R:198` pins that string).

### E3 — Lessons invisible *(major; FIXED — see §5)*

### E4 — Coverage denominator excluded ClaudeProbe in one place but not the other *(minor, latent; FIXED)*

Every detector filters `project = 'ClaudeProbe'` (llm#812), and Section 2's sessions-volume row
does too (`:445`) — but `n_sessions_in_window`, the number printed in the header as "across N
session(s)", did not (`:198`). The header could credit the detectors with sessions they never
examined.

**Currently latent, and the email's "4" was correct:**

```
$ duckdb -readonly … "SELECT CAST(started_at AS DATE) d,
    sum(CASE WHEN project='ClaudeProbe' THEN 1 ELSE 0 END) probe_n, … FROM sessions …"
2026-09-19 │ probe_n 0 │ real_n 4
```

ClaudeProbe has written **zero** session rows on every one of the last 21 days. Fixed now rather
than when the probe restarts, because the failure mode is silent.

> ⚠ AI-inferred: that ClaudeProbe is *dead* rather than merely idle. I observed 21 days of zero
> rows; I did not inspect the probe itself. Worth its own look (F5).

### E5 — Detector 3 is structurally incapable of firing *(major; NOT fixed)*

Detector 3 excludes seven by-design blocking hooks from `errors`. Every row in `errors` for the
last 45 days is one of them:

```
$ duckdb -readonly … "SELECT CAST(logged_at AS DATE) d, source, count(*) FROM errors
                      WHERE logged_at >= now() - INTERVAL '45' DAY GROUP BY 1,2"
2026-09-13 agent_push_guard 1 · 2026-09-06 agent_push_guard 3 · 2026-09-05 agent_push_guard 1
2026-09-04 agent_push_guard 4 · 2026-09-02 agent_push_guard 1 · 2026-08-27 agent_push_guard 1
2026-08-25 compound_guard  16 · 2026-08-23 agent_push_guard 1 · 2026-08-21 agent_push_guard 3
2026-08-14 agent_push_guard 1 · 2026-08-14 compound_guard 33 · 2026-08-06 agent_push_guard 1
```

Numerator is always zero after exclusion. Last fired 2026-06-08. Not fixed: making it fire again
requires the `hook_action` column the SQL's own TODO names (llm#573 Path C).

### E6 — Detectors 3 and 5 disagree about what an error is *(major; NOT fixed)*

Detector 3 excludes `compound_guard`/`agent_push_guard` as intended blocks. Detector 5
(`pivot_signal_threshold`, the only `critical`-capable detector still reachable) applies **no
such exclusion** to the same table. The 16 `compound_guard` rows of 2026-08-25 are "not errors"
to one detector and a potential `critical` pivot signal to the other. Not fixed here: it changes
severity semantics on the last critical-capable detector and deserves its own PR with its own
historical falsification.

### E7 — `errors` is read by two detectors but monitored by none, on a stale comment *(major; NOT fixed)*

`source_tables <- c("sessions", "agent_runs", "hook_events")` (`:400`), above a comment:

> `errors: retired from this DEAD/STALE flagging set — no producer (llm#784)`

**The comment is false.** `errors` has a live producer — 79 rows in the last 60 days, latest
2026-09-13 (query in E5). So the header's "0 of 3 source tables stale" understates the input
surface: four tables feed the detectors, three are watched. Not fixed because naively adding
`errors` to a 24h-window staleness check would flag DEAD on most days (it is legitimately
low-volume) — a permanent red, which is the "too loud" failure. It needs a cadence first (F3).

### E8 — `sessions.project` holds branch slugs, not projects *(major; NOT fixed)*

```
$ duckdb -readonly … "SELECT project, count(*) FROM sessions WHERE started_at >= now() - INTERVAL '30' DAY GROUP BY 1 ORDER BY 2 DESC"
tennis 53 · llmtelemetry 49 · cc-20260903-092257 47 · cc-20260829-145653 35 · historical 31
… · agent-a8f9c6e8d6e448d79 11 · cc-20260913-183633 10
```

Worktree sessions record the branch slug, and agent worktrees record the harness directory name.
The three "projects" in the 2026-09-19 window (`cc-20260913-183633`, `cc-20260913-122624`,
`cc-20260919-204132`) are really `tennis`, `llm` and `historical` — confirmed against the
transcript directory names. Any project-level grouping is wrong, and the ClaudeProbe exclusion
survives only because that one name happens to be clean.

### E9 — `fixer_heavy_day` fired at its own floor *(minor; NOT fixed)*

The finding that prompted this review:

```
$ duckdb -readonly … "SELECT json_extract_string(evidence,'day'), …total_runs, …fixer_runs …"
2026-09-19 │ total 5 │ fixer 2
```

The detector requires ≥5 total dispatches and ≥40% fixer share. This instance is exactly 5 and
exactly 40% — **two fixer dispatches in a day**, reported as a "fixer-heavy day". The threshold
comment concedes it is a guess ("~90th-percentile heuristic based on observed usage patterns…
Lower this constant if real data shows…"). It has fired 47 times and has never been actionable.

### E10 — A test asserts the wrong property *(minor; NOT fixed)*

`test-overnight-self-review-email.R:153`, "dry-run output contains all 4 source table names in
Section 2", greps the whole document for the substring `errors`. `errors` is not in Section 2 and
the word appears in many unrelated places. It passes regardless of E7 — a Trap-C wrong-property
check. Renaming it to what it actually asserts would be honest (F6).

### E11 — `launchd-health-weekly` is daily *(minor; NOT fixed, different script)*

`com.claude.launchd-health-weekly.plist` has no `Weekday` key and fires daily at 08:00; its own
plist comment says "every day", while `bin/launchd_health_weekly_cron.sh:15` still says
"(Sunday 09:00)". One of the three is wrong and a reader cannot tell which without `launchctl`.

---

## 4. What to delete or merge

### Six emails land in 75 minutes

| Time | Job | Sections |
|---|---|---|
| 08:00 | `launchd-health-weekly` (daily, despite the name) | 4 |
| 08:03 | `roborev-daily-email` | 6 |
| 08:05 | `config-digest-email` | ~4 |
| 08:05 | `kb-digest-email` | ~11 |
| **08:45** | **`overnight-self-review-email`** | **14 → 15** |
| 09:15 Sun | `roborev-weekly-rollup-email` | 1 |

Three overnight sections re-read tables whose dedicated email was sent minutes earlier:

| Overnight section | Table | Already emailed by |
|---|---|---|
| Config changes (24h) | `config_events` | config-digest, 08:05 |
| Knowledge base (24h) | `kb_events` | kb-digest, 08:05 |
| Cron health (last fire) | `launchd_health_events` | launchd-health, 08:00 |

`housekeeping-framework` says extend the digest rather than add emails. What happened instead is
both: the digest grew to 14 sections *and* the separate emails stayed. Dropping those three
sections from the overnight digest (or retiring the two 08:05 emails into it) is the largest
available simplification. Not done here — it is a product decision about which of two
overlapping surfaces survives, not a correctness fix.

### Dead code, verified

`send_stage1_findings_email.R` (358 lines) and `bin/stage1_findings_daily_cron.sh` (177 lines)
are orphaned: the plist was deprecated 2026-06-07
(`com.claude.stage1-findings-email.plist.deprecated-2026-06-07`) and their content was folded
into the overnight digest's Section 1.

Chesterton guard, per the global rule — `grep -rl … ~/docs_gh/` (worktrees excluded):

```
.claude/incidents/queued-issues/secrets-single-source.md      (mention)
.claude/launchd/com.claude.stage1-findings-email.plist.deprecated-2026-06-07
.claude/rules/_companions/exit-code-conventions-audit-1140.md (mention)
.claude/rules/cron-auto-pull-discipline.md:119                (table row, not a call)
.claude/scripts/send_stage1_findings_email.R                  (itself)
.claude/scripts/wait_for_resolvable_host.sh:76                (comment, not a call)
.claude/skills/duckdb-patterns/SKILL.md                       (mention)
bin/stage1_findings_daily_cron.sh                             (itself)
CHANGELOG.md, llmtelemetry/**/git_commits_by_project.json     (history)
```

No live invoker. Both conditions met: unused **and** covered elsewhere. **Not deleted in this
PR** — 535 lines across `bin/` and `.claude/scripts/` deserves its own reviewable change, and
bundling a deletion with a verdict-semantics change would make a single green run prove them
jointly (`verification-before-completion`, one change per verification run). Filed as F2.

### Ordering note

"Worktree footprint (24h)" and "Branch GC (last 24h)" read tables written by jobs at 09:06 and
09:08 — *after* the 08:45 email. Their 24h windows still catch yesterday's run, so the sections
are not empty, but they can never reflect the current morning. Low severity; worth knowing before
anyone debugs an apparent lag.

---

## 5. What was added

One section, derived from git alone — **no transcript mining, no model**:

> **Lessons captured (memory + rules commits, 24h)**

`git log --since=24.hours.ago --no-merges --format=%h\t%s -- .claude/memory/ .claude/rules/`,
rendered as a commit table. Repo root is `$LLM_REPO_ROOT` (default `~/docs_gh/llm`).

Three outcomes, never two:

| State | Renders |
|---|---|
| commits found | `N commit(s)` + table of `sha subject` |
| none in window | "No commit touched `.claude/memory/` or `.claude/rules/` in the last 24h" |
| repo missing / `git log` non-zero | **amber** "⚠ Could not determine — … This is NOT the same as 'no lessons captured'" |

**It measures capture, not insight.** A lesson nobody wrote down stays invisible. That limit is
stated in the section body rather than papered over — the section answers "did yesterday's
lessons get recorded?", which is a question git can answer honestly, not "what did I learn
yesterday?", which it cannot.

### The implementation failed first, and the check caught it

The first version passed `--format=%h\t%s` unquoted. `system2()` pastes args into one shell
command line without quoting, so the literal tab split it into `--format=%h` and `%s`; git read
`%s` as a revision and exited **128**. The section rendered `indeterminate` — which is how I
found it. Had it degraded to "none in 24h" the bug would have shipped looking exactly like a
quiet day. Fixed by `shQuote()`-ing every argument.

An indeterminate summary is also amber, not the default green — an unknown painted the same
colour as a pass is how "I could not check" gets read as "I checked and it was fine".

---

## 6. Verification

| Check | Result |
|---|---|
| `parse()` on the edited sender | `PARSE OK` |
| `EMAIL_DRY_RUN=1` before changes | `SUBJECT: [llm] Overnight ✓ all clear — 2026-09-20` / `All clear — nothing needs action.` (reproduces the reported email) |
| `EMAIL_DRY_RUN=1` after changes | `No action-level findings — 1 info/minor finding(s) logged, not action-rated.` / `Not checked: config, rules, code…` / `Lessons captured … none in 24h` |
| `testthat::test_file(...)` | `[ FAIL 0 \| WARN 0 \| SKIP 0 \| PASS 44 ]` |
| **Falsification** — `if (FALSE)` on both error branches, so a git failure degrades to the "none" path | `[ FAIL 2 \| WARN 0 \| SKIP 0 \| PASS 42 ]` at lines 585 and 589 |
| Probes reverted, re-run | `[ FAIL 0 \| WARN 0 \| SKIP 0 \| PASS 44 ]`, no `FALSIFY-PROBE` residue |

No email was sent; every run used the `EMAIL_DRY_RUN=1` path, which `quit()`s before
`blastula::smtp_send`.

Three tests added: indeterminate-not-none on a broken repo; a fixture repo with a real memory
commit proving the section can go non-empty; and an assertion that the string "nothing needs
action" never returns.

---

## 7. Proposed follow-ups (not implemented)

| # | Scope |
|---|---|
| F1 | Decide whether `info` volume should ever escalate the verdict — e.g. "N info findings, unchanged for D days" as a distinct non-green state, so 25 quiet days is itself reportable. |
| F2 | Delete `send_stage1_findings_email.R`, `bin/stage1_findings_daily_cron.sh` and the deprecated plist (Chesterton evidence in §4). |
| F3 | Assign `errors` a cadence in `staleness`, then add it to `source_tables` so all four detector inputs are watched; fix the false "no producer" comment either way. |
| F4 | Give detector 5 the same by-design-block exclusion list as detector 3, or give both the `hook_action` column from llm#573 Path C and delete both allow-lists. |
| F5 | **Corrected, see "Corrections".** ClaudeProbe has an external producer (CodexBar); why it stopped is not established. Exclusion clauses (8 in SQL + 2 in the sender) are KEPT. Open: find out why the probe stopped writing. |
| F6 | Rename the "all 4 source table names in Section 2" test to what it asserts, or make it assert Section-2 membership. |
| F7 | Fix `sessions.project` at the writer (`log_session.sh`) so worktree and agent sessions record the project, not the branch slug or harness dir. |
| F8 | **Blocked, needs a decision (see "Corrections").** Removing overnight sections 3c/3d would contradict `housekeeping-framework` component 4 and its checklist line ("Digest email section added to `send_overnight_self_review_email.R`"). Either amend that rule or retire the standalone 08:05 emails instead. Cron health (3e) is not proposed for removal (llm#1145 tests; duplication of the 08:00 email unproven). |
| F9 | **Withdrawn, see "Corrections".** `fixer_heavy_day` is actionable on 45 of 47 firings; detector KEPT. |
| F10 | Reconcile `com.claude.launchd-health-weekly`: daily schedule, "weekly" label, "Sunday 09:00" script header. |

---

## Corrections (2026-09-20, later the same day)

Findings above are left as written; these items were re-verified afterwards and four were wrong
or imprecise. Each was re-checked against code or a READ-ONLY copy of `unified.duckdb`
(`/tmp` copy) before this section was written.

### F9 / E9 (`fixer_heavy_day`) — the audit was wrong; detector KEPT

The audit claimed the detector fires at its own floor and is never actionable. It generalised from
the single 2026-09-19 row shown in that morning's email. The data:

```
47 findings, all severity=info
  at the floor (total 5, fixer 2 = 40%):  2 of 47  (2026-09-19, 2026-06-08)
  not at the floor:                       45 of 47
daily dispatch totals: 5..52; fixer share: 0.40..1.00
  2026-08-29  39 of 52     2026-09-02  30 of 34     2026-09-13  9 of 9
```

Nothing filters on this finding type (only the detector, two comments in
`send_overnight_self_review_email.R`, this document and exported finding rows). The
"never actionable" claim and F9's proposal to raise the guard are withdrawn.

> ⚠ AI-inferred: that 39-of-52 and 30-of-34 days were "actionable" in any operational sense. It
> is verified only that they are far from the floor; whether a reader acts on them is unmeasured.

### F5 (ClaudeProbe) — not "dead"; exclusions stay

A producer exists outside this repo: CodexBar's working directory
`~/Library/Application Support/CodexBar/ClaudeProbe/` (CodexBar is a third-party app loaded via
launchd, treated as external). It wrote 3166 `sessions` rows (2026-05..08), last row 2026-08-16
21:50; `agent_runs` last row 2026-07-14. **Why it stopped is not established.** Zero rows for 21
days is compatible with "retired" and with "broken and about to resume"; the exclusions guard the
second case (on 2026-07-24, 107 of 108 new session rows were synthetic).

Exclusion count, re-derived on current main: **8 SQL clauses** in
`.claude/scripts/self_review_stage1.sql` (lines 102, 228, 241, 344, 449, 527, 582, 638) and
**2 filters** in `.claude/scripts/send_overnight_self_review_email.R` (lines 211, 470), not
"four". A further hit at sender line 691 is a display flag, not a filter.

### launchd-health has 8 sections, not 4

`.claude/scripts/launchd_health_report.R` declares Sections 1-8 (plist inventory, run metrics,
suggestions, cloud crons, stale/wedged processes, braindumps freshness, missing-timeout,
failing-job). The "4" in the §4 table was wrong.

### F8 wording

The §4 table says config-digest and kb-digest "already emailed `config_events`/`kb_events`".
Imprecise: those digests read git directly. What repeats is the same *subject*, in tables that
their own crons populate (`bin/config_digest_cron.sh` `INSERT OR IGNORE INTO config_events`,
`bin/kb_digest_daily_cron.sh` `INSERT OR IGNORE INTO kb_events`). The only reader of those two
tables is the overnight sender itself (grep over `bin/`, `.claude/scripts/`, `tests/`, `.github/`,
`.claude/rules/`); no test asserts the 3c/3d headers.

**Removal of 3c/3d was attempted and NOT done.** Chesterton guard: sections 3c/3d were added by
f9fbd66 (#578, llm#552/#553 Phase C) to satisfy `housekeeping-framework` component 4 and its
checklist ("Digest email section added to `send_overnight_self_review_email.R`"; Forbidden
Patterns: "New email digest job instead of extending the 06:30 email"). The rule does not name
these two sections, but it requires a section per housekeeping task, so deleting them would
leave the config and KB tasks non-compliant and the rule self-contradictory (two standalone
08:05 emails remain). Whether to amend the rule or retire the 08:05 emails is a policy decision
for the owner, so 3c/3d, 3e and the Section-3 table-health list (which also names
`config_events`/`kb_events`) are all left unchanged.
