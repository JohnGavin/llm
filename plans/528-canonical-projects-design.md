# 528 — canonical_projects single source of truth

Design + decomposition for [#528](https://github.com/JohnGavin/llm/issues/528).

This document is the **planning** layer. It defines the schema, source-of-truth
file, migration order, producer-side behaviour, audit script, and the 4–6
sub-issues that carry the implementation. It does **not** create the table or
migrate any consumer — those are the sub-issue deliverables.

---

## 1. Symptom

The 2026-06-06 roborev daily email's *Severity by Project (7d)* section is
dominated by non-projects. The user reported the issue in
[#528](https://github.com/JohnGavin/llm/issues/528) with verbatim rows like:

```
config_digest_git_fixture_17f2972dcd784    1    2    0    3
kb_fixture_10d3f38de3911                   0    1    0    1
repo                                       0    0    1    1
test_repo                                  0    0    1    1
tmprepo_test                               …
```

None of these are projects. They are unit-test fixtures (`config_digest_git_fixture_*`,
`kb_fixture_*`, `roborev_pmhook_test_*`, `testrepo_*`), throwaway clones
(`tlang-clone`, `tmprepo_test`, `tmp.*`), or placeholder names from tutorials
(`repo`, `repo1`, `myproject`, `hello_t`). They drown the 12-or-so projects
that actually carry meaning.

The email producer for the section is
[`send_roborev_email.R`](../.claude/scripts/send_roborev_email.R) line 524
(`snap[["severity_by_project_7d"]]`). The JSON snapshot is built by
[`roborev_daily_report.R`](../.claude/scripts/roborev_daily_report.R) line 344
(`compute_severity_by_project()`), which reads
`roborev_review_lifecycle.repo` directly without a project filter.

## 2. Scope (measured 2026-06-06)

Computed from `~/.claude/logs/unified.duckdb`:

```sql
SELECT count(*) FROM (SELECT DISTINCT repo FROM roborev_review_lifecycle);
-- 175
```

A regex tally over those 175 distinct values:

| Category | Pattern(s) | Count |
|---|---|---|
| `config_digest_git_fixture_*` | regex `^config_digest_git_fixture_` | 18 |
| `kb_fixture_*` / `kb_(debug\|e2e\|test)_*` | regex `^kb_(fixture\|debug\|e2e\|test)_` | 21 |
| `roborev_pmhook_test_*` | regex `^roborev_pmhook_test_` | 91 |
| `testrepo_*` | regex `^testrepo_` | 13 |
| Throwaway / placeholder | `repo`, `repo[0-9]+`, `repo_*`, `test_repo`, `tmp.*`, `tmprepo*`, `tlang-clone`, `my_t_project`, `myproject`, `hello_t`, `t_demos`, `main`, `content`, `knowledge`, `llmtelemetry-hook-sync`, `randomwalk-wiki` | 19 |
| **Fixture-like total** | | **162** |
| Plausibly real | `JohnGavin.github.io`, `coMMpass`, `crypto`, `crypto_solwatch`, `crypto_swarms`, `football`, `historical`, `llm`, `llmtelemetry`, `micromort`, `mycare`, `premortem`, `randomwalk` | **13** |
| **Total distinct** | | **175** |

**93% of distinct `repo` values are noise**. Of the 13 plausibly-real values,
several (`crypto`, `football`) are also short-name aliases or experiments that
need triage (see canonical list below).

## 3. Consumers of the `repo` column

`grep -ln "roborev_finding_severity_by_project\|roborev_finding_lineage_summary\|roborev_review_lifecycle"`
across `.claude/scripts/` and `R/`:

| Path | Role | Reads `repo` how |
|---|---|---|
| `.claude/scripts/roborev_daily_report.R` | Producer of JSON snapshot consumed by daily email | `compute_severity_by_project()` aggregates by `repo`, no filter |
| `.claude/scripts/send_roborev_email.R` | Daily email | Reads `snap[["severity_by_project_7d"]]` — directly displays whatever the snapshot contains |
| `.claude/scripts/roborev_weekly_rollup.R` | Weekly digest | Aggregates `roborev_review_lifecycle` by `repo` |
| `.claude/scripts/roborev_metrics_etl.R` | ETL into lifecycle | Inserts rows — producer side |
| `.claude/scripts/roborev_metrics_schema.sql` | DDL | Defines `repo VARCHAR NOT NULL` |
| `.claude/scripts/etl_freshness_check.sh` | Phase 15a session_init alarm | Counts rows / inspects last-write — not project-aware |

There is **no** existing `roborev_finding_severity_by_project` materialised
view or table. The "by-project" output is computed in R at report time. The
issue body calls it a table-like surface; for clarity this design treats it as
a logical view (function output) and filters at compute time.

## 4. Canonical seed list

Cross-referencing GitHub repos (100 listed via `gh repo list JohnGavin`), the
`~/docs_gh/` tree (including `~/docs_gh/proj/{finance,data,stats,pers}/...`),
the DB's plausibly-real values, and the user's mental model from #528:

| slug | display_name | repo | kind | is_active | notes |
|---|---|---|---|---|---|
| `llm` | LLM meta-config | `JohnGavin/llm` | `r-package` | `true` | This repo; cross-project authority |
| `llmtelemetry` | LLM Telemetry | `JohnGavin/llmtelemetry` | `r-package` | `true` | Live dashboard; production |
| `historical` | Historical (finance) | `JohnGavin/historical` | `r-package` | `true` | T-lang project; under `~/docs_gh/proj/finance/data/historical/` |
| `mycare` | MyCare (medical) | private/local | `analysis` | `true` | Local-only repo at `~/docs_/pers/NHS_health/data/antigravity/mycare/` |
| `premortem` | Premortem (planning) | `JohnGavin/premortem` ? | `analysis` | `true` | Local at `~/docs_gh/proj/pers/premortem/`, no remote origin set — verify in sub-issue 1 |
| `randomwalk` | Random Walk | `JohnGavin/randomwalk` | `analysis` | `true` | Stats simulation; under `~/docs_gh/proj/stats/simulations/randomwalk/` |
| `urban_planning` | Urban Planning | `JohnGavin/urban_planning` | `quarto-website` | `true` | Under `~/docs_gh/proj/data/urban_planning/` |
| `footbet` | Footbet | `JohnGavin/footbet` | `analysis` | `true` | Under `~/docs_gh/proj/stats/sport/footbet/` |
| `acd_area_climate_design` | ACD area climate design | `JohnGavin/acd_area_climate_design` | `analysis` | `true` | Under `~/docs_gh/proj/finance/data/acd_area_climate_design/` |
| `crypto_solwatch` | Crypto Solwatch | `JohnGavin/solwatch` | `analysis` | `true` | Under `~/docs_gh/proj/finance/data/crypto_solwatch/`; GH repo is `solwatch` (rename note) |
| `crypto_swarms` | Crypto Swarms | `JohnGavin/crypto_swarms` | `analysis` | `true` | Under `~/docs_gh/proj/finance/data/crypto_swarms/` |
| `irishbuoys` | Irish Buoys | `JohnGavin/irishbuoys` | `r-package` | `true` | Under `~/docs_gh/proj/data/weather/irish_buoy_network/irishbuoys/` |
| `rix.setup` | rix.setup | `JohnGavin/rix.setup` | `r-package` | `true` | Nix env helper |
| `JohnGavin.github.io` | Personal site | `JohnGavin/JohnGavin.github.io` | `quarto-website` | `true` | Production user-site |
| `coMMpass` | CoMMpass | `JohnGavin/coMMpass-analysis` ? | `analysis` | `true?` | DB row exists; verify in sub-issue 1 (repo on GH is `coMMpass-analysis`) |
| `micromort` | Micromort | `JohnGavin/micromort` | `analysis` | `true?` | DB row exists; recently active per GH list |
| `crypto` | Crypto (umbrella) | — | — | `false` | DB row exists but no canonical repo; likely a short-name alias for one of the crypto_* projects. **Verify in sub-issue 1** — if alias, exclude. |
| `football` | Football (umbrella) | — | — | `false` | DB row exists but no canonical repo; verify in sub-issue 1 (likely the legacy name for `footbet` or a tutorial repo) |

**Expected seed size: 13–17 entries.** `crypto` and `football` are marked `?`
and resolved before the seed CSV ships (sub-issue 1 acceptance: every row must
have a verified `repo` field OR be marked `is_active=false` with a note).

## 5. Schema

Refining the issue's draft. Keeps every column the issue proposed; adds two
that emerged during investigation.

```sql
CREATE TABLE IF NOT EXISTS canonical_projects (
  slug              VARCHAR PRIMARY KEY,
  display_name      VARCHAR NOT NULL,
  repo              VARCHAR,                    -- 'JohnGavin/foo'; NULL for local-only (e.g. premortem)
  kind              VARCHAR NOT NULL,           -- 'r-package' | 'quarto-website' | 'dashboard' | 'analysis'
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMP NOT NULL DEFAULT current_timestamp,
  updated_at        TIMESTAMP NOT NULL DEFAULT current_timestamp,
  aliases           VARCHAR,                    -- comma-separated alternative repo strings the consumer might see (e.g. 'crypto_solwatch' for slug=solwatch)
  notes             VARCHAR
);

CREATE INDEX IF NOT EXISTS idx_canonical_projects_active
  ON canonical_projects(is_active);
```

### Why `aliases`

The DB column is named `repo` everywhere but the values are heterogeneous —
sometimes a short slug (`crypto_solwatch`), sometimes a GitHub repo basename
(`historical`), occasionally an owner/repo pair. Until producers are
normalised (sub-issue #528-4) the canonical filter needs to recognise both
forms without forcing every producer to rewrite immediately. `aliases` is a
pragmatic deferral.

### Why `updated_at`

Source-of-truth lives in CSV; migration script re-syncs DB from CSV. Knowing
when each row was last touched lets the audit script flag drift between CSV
and DB.

### Out of scope (per issue)

No wholesale rewrite of `roborev_review_lifecycle`. The canonical filter
runs at consumer-compute time, not at producer-insert time (the issue is
explicit: "keep them as-is, just filter at the consumer layer").

## 6. Source-of-truth — pick one

Three candidates evaluated:

| Candidate | Pros | Cons |
|---|---|---|
| `~/docs_gh/llm/.claude/data/canonical_projects.csv` | Diff-friendly, PR-reviewable, neutral format, easy R/duckdb import, matches issue ask | None significant |
| `~/docs_gh/llm/.claude/data/canonical_projects.yaml` | Better for nested/multi-line `notes`, native Quarto/R-list parsing | Less amenable to plain-text diff review of mass changes; needs YAML parser in audit script |
| Hardcoded in R or SQL | One fewer file | Buries source-of-truth inside code; PR review noisy; the issue explicitly says "version-controlled source of truth" |

**Decision: CSV at `~/docs_gh/llm/.claude/data/canonical_projects.csv`**.

Columns: `slug,display_name,repo,kind,is_active,aliases,notes`. UTF-8, comma
quoted, one row per project. CSV chosen because (a) PR-diffs are unambiguous
for adds/removes/edits, (b) duckdb has native `read_csv_auto`, (c) the
existing `.claude/data/` precedent (other CSV/TOML fixtures live there)
favours flat formats, (d) matches the issue's wording verbatim.

`created_at`/`updated_at` are set by the migration script, not stored in
CSV — they're database metadata, not source-of-truth content.

## 7. Producer-side handling — pick one

| Candidate | Behaviour | Pros | Cons |
|---|---|---|---|
| Skip-and-warn | Producer detects non-canonical `repo`, drops the insert, logs the skip to `~/.claude/logs/canonical_projects_skipped.log` | Cleans data at source; no quarantine schema; matches issue wording ("skip the insert entirely") | Loses observability of test-fixture activity (probably fine — fixtures aren't observed anyway) |
| Quarantine table | Insert into `<table>_quarantine` instead of primary | Keeps debug data | Doubles schema; needs migration; over-engineered for fixtures (the issue itself flags this) |
| Log-only | Always insert; emit warning | Zero data change | Doesn't fix the symptom |

**Decision: skip-and-warn**. The issue body endorses this. Producers that
*can* detect their writes (the hooks under `.claude/hooks/`) get an opt-in
helper function that takes `(repo, callback)` and short-circuits when `repo`
isn't canonical. Producers that *cannot* (the lifecycle table itself, which
ingests from external roborev daemon) stay as-is — the consumer-side filter
handles them.

The opt-in surface keeps the rollout incremental: sub-issue #528-4 wires
the helper into 2–3 producers as a pilot; the rest follow when there's
appetite. The consumer-side filter (sub-issues #528-2, #528-5) is what
actually closes the user complaint.

## 8. Consumer migration order

User's complaint is specifically the daily email's *Severity by Project (7d)*
section. That gets fixed first.

| Order | Consumer | Why this order |
|---|---|---|
| 1 | `roborev_daily_report.R::compute_severity_by_project()` | The user's specific complaint. Filtering here cleans the JSON snapshot. |
| 2 | `send_roborev_email.R` | Reads from (1); inherits the filter automatically once (1) ships. Verify no display regression. |
| 3 | `roborev_weekly_rollup.R` + `send_roborev_weekly_rollup_email.R` | Same noise profile; user will notice the day a weekly email lands with fixtures. |
| 4 | KB digest scripts (`.claude/scripts/wiki_*.sh`) | Project-aggregating KB outputs surface the same fixtures. |
| 5 | Dashboards (`R/roborev_dashboard*`, `dashboard/*.qmd`) | Lower priority — less frequent reads. |

The producer-side cleanup (#528-4) is independent and can land in parallel.

## 9. Audit script — `canonical_projects_audit.sh`

Mirrors `etl_freshness_check.sh` (Phase 15a) in structure and exit-code
contract.

```
canonical_projects_audit.sh                  # normal: per-source counts
canonical_projects_audit.sh --quiet          # one-line summary for session_init
canonical_projects_audit.sh --verbose        # full per-value list with producer trace
canonical_projects_audit.sh --selftest       # runs against fixture DB
```

Default output (target):

```
canonical_projects_audit: 175 distinct repo values; 162 NON-CANONICAL
  test fixtures: 143  (config_digest_git_fixture_, kb_fixture_, roborev_pmhook_test_, testrepo_)
  throwaway/placeholder: 19
  See: ~/.claude/data/canonical_projects.csv
  Add slug or mark fixture-pattern: gh issue 528
```

Exit codes:

| Code | Meaning |
|---|---|
| 0 | All non-canonical values match known fixture patterns (test cruft — expected) |
| 1 | Found non-canonical values that DON'T match fixture patterns (a real project may be missing from canonical list) |
| 2 | DB read error or canonical_projects table missing |

Wiring: `session_init.sh` Phase 15b (insert immediately after Phase 15a).
Same `timeout 5 ... --quiet 2>/dev/null || true` fail-open pattern. Add a
matching row to `.claude/rules/session-init-phases.md`.

Selftest cases (minimum):

1. DB has only canonical values → exit 0, no output (with `--quiet`)
2. DB has 1 fixture-pattern value → exit 0, fixtures counted
3. DB has 1 non-fixture non-canonical (e.g. `myNewProject`) → exit 1, value listed
4. DB missing canonical_projects table → exit 2, clear error

## 10. Acceptance per sub-issue

| Sub-issue | Title | Acceptance summary |
|---|---|---|
| #528-1 | foundation | Schema deployed; CSV present with verified seed; migration script idempotent; CSV columns documented in README in `.claude/data/`; `crypto`/`football`/`coMMpass`/`micromort`/`premortem` ambiguities resolved before merge |
| #528-2 | first consumer migration | `compute_severity_by_project()` joined against canonical; new JSON field `severity_by_project_7d_unfiltered` preserved for debugging; email shows ~13 projects max; integration test added |
| #528-3 | audit script + session_init Phase 15b | Selftest passes 4/4 cases; Phase 15b wired with timeout + fail-open; rule file updated; quiet-mode output ≤2 lines |
| #528-4 | producer-side skip-and-warn | Helper `is_canonical_project()` in shared R lib; wired into 2–3 producer hooks; opt-in CLI flag preserves legacy behaviour for tests |
| #528-5 | remaining consumer migrations | Weekly rollup, KB digest, dashboards all filtered; visual diff documented |
| #528 (umbrella) | tracking | References #528-1 through #528-5; closes when all sub-issues close |

## 11. Rollout

Staged so the user-visible email is fixed within sub-issue #528-2, before
any deeper rewrite happens.

1. **Foundation** (#528-1) — Table + CSV + migration. No consumer changes.
   No user-visible impact. Low risk.
2. **First consumer** (#528-2) — `roborev_daily_report.R` filtered.
   Next morning's email is clean. **This is the user-visible fix.**
3. **Audit** (#528-3) — Phase 15b emits one-line health check. Catches new
   non-canonical projects within one session of their appearance.
4. **Remaining consumers** (#528-5) — weekly rollup, KB digest, dashboards.
   Incremental.
5. **Producer hygiene** (#528-4) — Skip-and-warn on the 2–3 highest-volume
   producers (the `roborev_pmhook_test_*` source is 91/175 by itself — finding
   and silencing that producer would clean ~50% of the noise at source).

Each sub-issue is independently shippable. #528-2 closes the user complaint
even if #528-3/4/5 take weeks.

## 12. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| A legitimate project is missing from the seed and gets filtered out of the email | Medium | Audit script (#528-3) catches non-canonical AND non-fixture values; user gets one-line nag in session_init until they add it to CSV |
| Producer-side skip-and-warn silences signal from a long-running test that's actually a real project | Low | Producer-side is opt-in per-call; legacy behaviour preserved by default |
| CSV becomes a merge-conflict hotspot if multiple sessions add rows simultaneously | Low | Rare adds; sort rows by `slug` alphabetically so diffs localise |
| Aliases column drifts from reality if a repo is renamed | Medium | Audit script flags `repo` values not matching any canonical `slug` or `aliases` entry — same one-line nag |
| Email QA gate (`.claude/scripts/check_dark_contrast.sh` etc.) may break if section becomes empty | Low | `roborev_daily_report.R` already handles `nrow == 0` (line 368) |

## 13. Out of scope

Explicit non-goals:

- **No rewrite of `roborev_review_lifecycle`'s `repo` column.** Filter at
  consume time.
- **No automatic detection of fixture patterns.** The canonical list inversion
  IS the fixture filter. Pattern-based fixture detection is brittle and
  inverts who the source of truth is.
- **No producer-side enforcement** (e.g. CHECK constraint on `repo`).
  Producers must be able to write test-fixture values for unit tests to
  run.
- **No automatic GH-API sync** to keep canonical list in step with
  `gh repo list`. New projects are added by PR — the audit script's nag is
  the prompt to do so.
- **No retroactive deletion of fixture rows.** Old data stays; new emails
  hide it.
- **No rename of `roborev_finding_severity_by_project` to a real table.** It
  remains a function output in `roborev_daily_report.R`.

---

## Methodology

### What this design doc computes

Inventory of fixture-noise scope in `~/.claude/logs/unified.duckdb` (175 → 162
fixture-like → 13 plausibly-real), cross-reference against the `~/docs_gh/`
tree and `gh repo list JohnGavin` to assemble a canonical project list, then
decomposition of the implementation into 5 sub-issues with clear acceptance
contracts.

### Data sources

- `~/.claude/logs/unified.duckdb` — `roborev_review_lifecycle` table, queried
  read-only on 2026-06-06 to enumerate distinct `repo` values
- `~/docs_gh/` and `~/docs_gh/proj/{finance,data,stats,pers}/` — disk
  inspection for `.git` repos
- `gh repo list JohnGavin --limit 100 --json name,description,isArchived,updatedAt`
  — 100 GitHub repos cross-referenced
- `.claude/scripts/roborev_daily_report.R` lines 339–393 — current
  `compute_severity_by_project()` implementation
- `.claude/scripts/send_roborev_email.R` line 524 — current consumer
- `.claude/scripts/etl_freshness_check.sh` and `session_init.sh` Phase 15a
  — wiring pattern for the new audit script
- GitHub issue [#528](https://github.com/JohnGavin/llm/issues/528) — the
  request and acceptance criteria

### AI disclosure

This design doc was developed with assistance from Anthropic's Claude (model:
Opus 4.7 and Sonnet 4.6). AI helped with code structure, prose drafting, and
visualization choices. All analytical decisions and data interpretations are
the author's responsibility.
