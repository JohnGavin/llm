# llmtelemetry dashboard v2: a parallel, static-HTML, cross-project overview page

## Context

The user wants two things bundled into one plan:

1. Adopt a specific reference design (a Claude Artifact, "Tennis Trends" — Oswald/Public Sans/IBM Plex Mono type system, CSS-custom-property light+dark theming, sticky pill-nav, tabset-within-page pattern, `<details>` disclosure blocks, `.chart-img`/`.card`/`.tbl-scroll` component classes) as the style/layout template for a NEW llmtelemetry dashboard.
2. Use that rebuild as the opportunity to simplify the dashboard's information architecture (move detail into tabs-within-tabsets) and to start fresh on "the most critical results to monitor telemetry/metadata activity related to all projects, such as GH activity."

Both are to happen in a NEW page built and iterated **in parallel** with `vignettes/dashboard_shinylive.qmd`, not as an in-place reskin, until an explicit later decision to switch over.

This session's research (cited inline below, not re-derived) already established the two premises this plan is built on:

- **Reskinning the existing Shiny dashboard in place is a rebuild of its theming layer, not a config change.** `dashboard_shinylive.qmd:661-665` hardcodes a single permanent dark `bs_theme(bg="#1a1a1a", fg="#e0e0e0", primary="#377eb8", secondary="#555555", font_scale=0.85)` — no light/dark toggle, no `font_google()`, no CSS custom properties, duplicated verbatim in `roborev_resolution.qmd:118-121` and a generated WebR copy (`vignettes/.quarto/_webr/appdir/app.R:129`). Custom styling is large `tags$style(HTML(...))` blocks of hardcoded hex with `!important` (`dashboard_shinylive.qmd:674-701`, `:1200-1246`), not variable-driven. This is why the user is right to build new rather than reskin in place.
- **The "GH activity" ask is mostly a data-ingestion gap, not a styling gap.** `inst/schema/v1/git_commits.sql:6-7` already has `project`/`canonical_project` columns (cross-project-ready) but only commit-level fields — no PR, issue-detail, or CI-run columns anywhere in either repo. `inst/scripts/poll_github_events.R` already polls 5 repos' issue-scope-change events but is unscheduled (manual-only; `export_dashboard_data.R:1355-1357` falls back to an empty placeholder with the comment "run poll_github_events.R to populate"). Cross-project commit history today comes from **local git checkouts** via `git -C <path> log --numstat` (`export_dashboard_data.R:778-819`, `tracked_repos` = llm, llmtelemetry, irishbuoys, mycare, footbet), not the GitHub API, so it cannot regenerate in CI. No PR ingestion, no CI-run-status ingestion exists anywhere (confirmed via grep for `gh pr list`/`gh run list`/`workflow_run`/`ci_status`/`pr_merged` — no table-populating use, only scoped operational one-offs).

Grounded via direct file reads this session (line numbers below are current, not estimated; two claims independently re-verified: `Makefile:19-27`'s `make dashboard` target, and `dashboard_v1_pilot.qmd`'s header confirming it's a distinct DuckDB-WASM-in-browser pilot, not a predecessor to this plan's new page).

## Explicit non-goals / boundaries

- **Reskinning or replacing `dashboard_shinylive.qmd` in place** is out of scope. It keeps its current hardcoded dark theme and Shinylive/WASM architecture untouched until a switchover decision is made (see "Switchover criteria" below).
- **[llm#1063](https://github.com/JohnGavin/llm/issues/1063)** ("adopt the reference design as the template for future Quarto vignettes generally") is a separate, broader-scoped initiative. This plan is llmtelemetry-dashboard-specific; it produces one artifact (the shared stylesheet, Phase A) that #1063 can also consume, but does not itself decide #1063's scope.
- **llmtelemetry#352** ("Going private broke the daily report, the Pages deploy, and ~8 hardcoded URLs" — GitHub Pages disabled once the repo went private, on a free-plan account) is a named dependency, not something this plan resolves. Both dashboards share this hosting gap. *Correction: `deploy-dashboard.yaml`'s own header comment cites "llmtelemetry#349" for this, but #349 is actually a different, unrelated issue (a premortem-data git-history-rewrite decision) — verified directly by reading both issues before citing either here. #352 is the issue that actually documents the Pages-deploy consequence; the workflow file's own comment appears to be a stale/incorrect cross-reference, worth a one-line fix in that file separately from this plan.*
- **`roborev_metrics_schema.sql`** stays frozen (per llmtelemetry#144/llm#226) — nothing here touches it.
- **The QA-check-reliability initiative's "Reliability" sub-tab** (`docs/qa-check-reliability-plan` branch / [#1062](https://github.com/JohnGavin/llm/pull/1062), Phase E — not yet merged; confirmed absent from `export_dashboard_data.R` today via grep) is explicitly scoped to the OLD dashboard only for now. See Phase B below for the concrete recommendation and why.
- **Adding a new cross-repo git symlink for the shared stylesheet is explicitly rejected.** `cross-repo-symlink-check.yml` exists specifically because tracked cross-repo symlinks are a sandbox-escape hazard (llm#692) — the existing symlink allowlist is being shrunk, not extended. Phase A uses the codebase's own alternative convention instead (absolute-path reference, same as `check_dark_contrast.sh`).

## Phase 0 — Close the live-issue-tracker gap (do first, cheap)

This session's research could not query `gh issue list` (auth blocked in the research sandbox), so it only checked local git history/files for prior art. Before treating this as greenfield:

```bash
gh issue list --repo JohnGavin/llm --search "dashboard"
gh issue list --repo JohnGavin/llmtelemetry --search "dashboard"
```

**Run now — results below.** No issue proposes exactly this ask (a new parallel static dashboard styled after a specific reference design), so the greenfield conclusion for the CORE proposal stands. Three adjacent items were found, none a duplicate, all worth reconciling rather than ignoring:

- **[llm#963](https://github.com/JohnGavin/llm/issues/963)** (OPEN) — "Dashboard/site nav convention: adopt a Changelog+Contributing+Build+Acknowledgements tabset (pyfixest as reference), applied globally." A narrower, different-reference proposal for the same MECHANISM (a tabset nav convention). Reconciliation: Phase D's `.tabset-nav`/`.tab`/`.tabpanel` mechanism should be built generically enough to also host #963's four specific tab types when that work happens — one tabset implementation serving both asks, not two competing ones. Not folded into this plan's scope; cited so Phase D's implementer builds the generic version, not a Tennis-Trends-specific one.
- **[llmtelemetry#175](https://github.com/JohnGavin/llmtelemetry/issues/175)** (CLOSED) — "Replan dashboard layout: consolidate pages with tabsets (Git page as template)." Prior art confirming the OLD dashboard's existing Reviews-tab sub-structure (Pulse/Quality/Operations/Cost/Detail) already came from a validated tabset-consolidation effort. Relevant context for Phase B: "simplify via tabs" is continuing a pattern already proven once in this dashboard, not introducing an unfamiliar one.
- **[llmtelemetry#74](https://github.com/JohnGavin/llmtelemetry/issues/74)** (CLOSED) — "Git tab layout — tabsets or split into 2 panels" — same lineage as #175, further confirming tabsets are the established house answer to "too much on one page" in this specific dashboard.

## Phase A — Shared design-token stylesheet + font decision (cross-repo coordinated)

**Extraction scope:** the reference design's CSS custom properties (`--paper`, `--surface`/`--surface-2`, `--ink`/`--ink-soft`/`--ink-faint`, `--line`/`--line-strong`, 3 accent triples, `--shadow`, `--radius`/`--radius-sm`) plus its component classes (`.card`, `.tabset-nav`/`.tab`/`.tabpanel`, `.chart-img`/`.cimg-light`/`.cimg-dark`, `.callout`, `.tbl-scroll`, `<details>`/`<summary>` styling, the sticky `nav.top`/`.navlink` pill-nav, the A−/A+ text-size toggle) into ONE reusable stylesheet, with both the `prefers-color-scheme` media-query path and the explicit `data-theme="dark"`/`"light"` override path.

**Ownership call:** the canonical copy lives in `llm` (it is the broader-scoped initiative per #1063), alongside the other single-global-script assets already living under `~/docs_gh/llm/.claude/scripts/` (e.g. `check_dark_contrast.sh`) — call it `~/docs_gh/llm/.claude/scripts/dashboard-design-tokens.css`.

**Consumption call:** llmtelemetry's new `.qmd` (Phase D) references this file **by absolute path at render time**, not via a git symlink and not via a committed duplicate. This directly follows an existing, explicitly-stated convention in `accessibility.md` Clause 5 for `check_dark_contrast.sh`: reference by absolute path, never copy per-project. Because the qmd sets `embed-resources: true` (Phase D), Quarto inlines the file's contents into the single rendered HTML at build time — no runtime dependency on the `llm` checkout existing, only a **build-time** one.

- **Caveat to state, not hide:** this build-time absolute-path dependency only works because the current dashboard build is already local-only (`deploy-dashboard.yaml` is disabled per llmtelemetry#352; `make dashboard` is the actual build path today, per `Makefile:19-27`, confirmed). If CI rendering of llmtelemetry is ever resumed, this reference would need either a checkout-both-repos CI step or a vendored/synced copy — flag this as a revisit trigger tied to #352's resolution, not solved here.
- **Which PR owns what:** this phase is genuinely two small, separately-landed PRs — one in `llm` adding the stylesheet file itself (consumable by both this plan and #1063), one in `llmtelemetry` wiring the new `.qmd`'s render to reference it. Per this session's "never bundle an llm change with an llmtelemetry change in one PR" convention, these are not merged into one PR even though they're tightly coupled.

**Font decision (self-hosted, not a live CDN link):** neither repo currently loads Google Fonts live (zero `fonts.googleapis.com` hits); `~/docs_gh/llm/_brand.yml:50-64` deliberately uses `source: system` fonts only. Recommend: download Oswald/Public Sans/IBM Plex Mono `.woff2` files once, commit them next to the shared stylesheet (`~/docs_gh/llm/.claude/scripts/fonts/`), and reference them via `@font-face` with relative `url()` paths in the same stylesheet — NOT a live `<link href="fonts.googleapis.com">` tag. Rationale: a durably-committed dashboard file shouldn't depend on a live third-party CDN indefinitely; this is a different, more durable loading strategy than an ephemeral-Artifact's Google-Fonts `<link>` convention, which is a distinct, non-applicable policy for this committed-repo case. Bonus: because the new `.qmd` uses `embed-resources: true` (Phase D), Quarto will base64-inline these locally-referenced font files into the single output HTML automatically — the rendered dashboard ends up with zero external font dependency at view time, for free.

## Phase B — New dashboard's MVP scope (Overview page v1 panel list)

Concrete v1 panel list for "most critical results to monitor telemetry/metadata activity related to all projects":

| Panel | Data source | New ingestion needed? |
|---|---|---|
| Per-project commit count (last 30d) | `git_commits` table / `tracked_repos` cross-repo export (`export_dashboard_data.R:778-819`) | No — already exported |
| Per-project cost + session summary | `costs.sql`, `sessions.sql` (both keyed on `canonical_project`) | No — already exported |
| Per-project open PR count | new PR-activity table | **Yes — Phase C2** |
| Per-project open issue count / recent issue scope-changes | `github_issue_events.json` (already produced by `poll_github_events.R`, currently unscheduled) | Partially — needs Phase C1 (scheduling) only, not new schema |
| Per-project latest CI run status | new CI-run-status table | **Yes — Phase C3** |

**Reliability-tab decision:** the QA-check-reliability initiative's "Reliability" sub-tab (its Phase E, targeting the OLD dashboard's Reviews section) stays **old-dashboard-only for this plan's v1**. It is not yet merged, and duplicating its ETL into a second consumer before it has landed once would invert the dependency (this plan would be blocking on an unlanded branch). Revisit adding it to the new dashboard only after both (a) that initiative lands in the old dashboard, and (b) this new dashboard's own Overview panels above are stable — not before.

## Phase C — GH-activity ingestion, sequenced by cost

Reuses the existing 5-repo `tracked_repos` set (llm, llmtelemetry, irishbuoys, mycare, footbet — `export_dashboard_data.R:778-785`, same list `poll_github_events.R:12-18` already hardcodes) as the initial project set; no new project-discovery mechanism.

**C1 — cheapest: schedule the existing `poll_github_events.R`.** It already works (`poll_issue_events()`, paginated `gh api /repos/{owner}/{repo}/issues/events`) but has never been wired into automation — absent from every `.github/workflows/*.yaml` and every `~/Library/LaunchAgents/*.plist`. Extends the existing scheduling convention directly: `~/Library/LaunchAgents/com.johngavin.llmtelemetry.refresh.plist` already runs `exec/refresh_and_preserve.sh` on a `StartInterval` (12h) + `RunAtLoad` pattern. Add `Rscript inst/scripts/poll_github_events.R` as a step inside that same script (or a new sibling plist following its exact shape) rather than inventing a new scheduling mechanism.

**C2 — new PR-activity table + poller.** New schema (new file, `inst/schema/v1/git_pull_requests.sql`, additive — does not touch the frozen `git_commits.sql`), columns modeled on `git_commits.sql`'s existing shape (`project`, `canonical_project`, `pr_number`, `state`, `created_at`, `merged_at`, `title`). New poller script, `inst/scripts/poll_github_prs.R`, extending `poll_github_events.R`'s exact `gh api` calling convention (paginated calls, same non-zero-exit-preserves-previous-data guard).

**C3 — new CI-run-status table + poller.** Same shape as C2: new schema (`inst/schema/v1/ci_runs.sql`), new poller (`inst/scripts/poll_github_ci_runs.R`) hitting `gh api /repos/{owner}/{repo}/actions/runs`, extending the same convention. Lowest priority of the three new-ingestion items — "latest CI status per project" is a single most-recent-row lookup, not a trend, so it tolerates being added last.

**C4 — commit-puller architecture decision: keep local-git-log for now, do not switch to GitHub API.** The existing local-checkout `git log --numstat` puller (`export_dashboard_data.R:787-819`) stays as-is. Switching to a GitHub-API-based commit puller would trade a real capability (CI-renderability) for a real cost (GitHub API rate limits + a token to commit/rotate) for data already fully available locally at zero API cost. Since llmtelemetry#352 already means the dashboard isn't CI-rendered/deployed today anyway (`make dashboard` is the actual build path), CI-renderability is not currently a live constraint this trade-off would resolve. Revisit only if/when #352 is resolved.

## Phase D — The new dashboard's Quarto file

**Name:** `vignettes/dashboard_overview.qmd`. Deliberately not `dashboard_v2_*` — `dashboard_v1_pilot.qmd` already exists (confirmed: its own header reads "v1 Telemetry — DuckDB-WASM Pilot (Phase 2A)", `embed-resources: false`) for a different, unrelated architecture experiment (DuckDB-WASM-in-browser), and naming the new file "v2" would incorrectly imply it succeeds that pilot rather than being a separate, simpler, server-rendered-at-build-time page.

**Architecture:** `embed-resources: true`, following the precedent already in this repo — `vignettes/self_review.qmd` (confirmed: `embed-resources: true`) and `vignettes/roborev_summary.qmd` are both already single self-contained HTML files, in direct contrast to `dashboard_shinylive.qmd`/`roborev_resolution.qmd` (`embed-resources: false`, because those ship Shinylive's WASM bundle + `_files/` directories). The new page needs none of that — it is a plain rendered Quarto document, not a Shiny app.

**Data path — simpler than the existing dashboard's, say so explicitly:** because this is a plain rendered `.qmd` (not Shinylive/WASM), data can be inlined via R **at render time** (`readRDS()`/`jsonlite::fromJSON()` in a code chunk) rather than needing the existing dashboard's client-side `load_json()` JS pattern (`dashboard_shinylive.qmd:371-380`). This satisfies `quarto-vignettes.md`'s "No Computation in Vignettes" rule (data from pre-saved JSON/RDS artifacts only, no ad-hoc DB queries inline) the same way the existing dashboard already does — just resolved server-side instead of client-side.

**ETL wiring call:** append new numbered sections to the EXISTING `export_dashboard_data.R` (it already owns the `tracked_repos` cross-repo commit export, the cost/session export, and the GH-issue-events copy step) rather than forking a new sibling script. This follows the same decision already made and justified in `plans/qa-check-reliability-design.md` Phase E for its own two new sections — reuse the single ETL source of truth, its existing `write_json()`/`tryCatch`-with-empty-fallback idiom, and its existing dual-output-directory convention (`inst/extdata/` committed + `vignettes/data/` preview), rather than duplicating that machinery in a second script. New sections here cover: the Phase C2 PR-activity rollup, the Phase C3 CI-run-status rollup, and a small Overview-specific per-project join across commits+costs+sessions+PRs+CI-status.

**Section/tab structure — this is the "moving details into tabs in tabsets" mechanism the user asked for**, taken directly from the reference design's two-level pattern: top-level SECTIONS (Overview, and later ones added as the dashboard grows) via the sticky pill-nav + `showPage()` JS toggle, and, WITHIN a section, a `.tabset-nav`/`.tab`/`.tabpanel` pill-button set (`wireTabset()` JS) for detail views that would otherwise all compete for space on one page — e.g. an Overview section with tabs for "Activity" (commits/PRs/issues), "Cost & Sessions," and "CI Health," rather than one long scrolling page. `<details>`/`<summary>` blocks carry the methodology/caveat text per claim (e.g. "PR counts as of last poll, not live" for the C2 data) — this already matches this codebase's own narrative-evidence-block / confidence-markers house rules, so no new writing convention is introduced, only the reference design's disclosure widget.

**Accessibility/dark-mode gate is unaffected:** `check_dark_contrast.sh` (via `quarto_post_render_contrast.sh`) works by static-HTML regex against the rendered output with no Shiny/JS runtime dependency — it applies identically to this new plain static Quarto page as to every other vignette in scope of `quarto-vignettes.md` (`paths: ["*.qmd", "vignettes/**"]`, which covers this file automatically, Shiny or not).

## Phase E — Interim viewing path (hosting blocker acknowledged, not solved)

`llmtelemetry#352` (GitHub Pages disabled — private repo, free-plan account) applies identically to the new dashboard: there is nowhere to host/view it for anyone but the user locally, until that issue is resolved. This plan does not attempt to resolve #352.

**Recommended interim path**, matching the existing dashboard's own current actual workflow: extend the `Makefile` with a `dashboard-overview` target mirroring the existing `dashboard` target (confirmed: `Makefile:19-27`, `quarto render` + copy to `_site/`, printing a `file://` URL) — i.e. the same local-build-and-open convention already in production use for `dashboard_shinylive.qmd` today, applied to the new file. If the user wants to share a snapshot out-of-band before #352 is resolved, the rendered self-contained HTML file (a direct benefit of `embed-resources: true`) can be shared as a single file, consistent with this session's own Max-plan-artifact-sharing precedent (self-contained HTML shared out-of-band rather than a hosted URL).

## Switchover criteria (explicit, not left open)

"Parallel until we decide to switch over" needs a stated exit condition or it risks running forever. Recommend switching only once ALL of the following hold:

1. The new dashboard's Overview section covers every panel in Phase B's table (commits, costs/sessions, PR counts, issue activity, CI status) for all 5 tracked projects, not a subset.
2. At least one full iteration cycle has passed where the user checks the new dashboard AS their primary daily reference for a stated trial period (e.g. two consecutive weeks) rather than falling back to the old one, self-reported.
3. `check_dark_contrast.sh` and the existing QA render gates pass clean on the new page, same bar as any other vignette.
4. Any panel the user identifies as "the one I actually check regularly" from the old dashboard (Sessions/Head-to-head/Details-equivalent sections, to be named explicitly by the user, not assumed) has an equivalent in the new one.
5. `llmtelemetry#352`'s hosting question has either been resolved, or explicitly decided to remain local-only for both dashboards indefinitely (so switching isn't blocked on an orthogonal unresolved issue).

Until all five hold, `dashboard_shinylive.qmd` remains the dashboard-of-record and is not touched by this plan.

## Sequencing

```
0 (issue-tracker check) ── cheap, do first, no dependency
A (shared stylesheet + fonts, llm PR + llmtelemetry PR) ── no dependency on 0
B (MVP panel-list decision) ── no dependency, informs C and D's scope
C1 (schedule poll_github_events.R) ── cheapest of C, no dependency beyond B
C2 (PR table + poller) ── independent of C1/C3
C3 (CI-run-status table + poller) ── independent of C1/C2, lowest priority
C4 (commit-puller decision) ── decision only, no implementation change
A, B, C1(minimum) ── D (new .qmd + ETL sections) ── needs A's stylesheet reference
                                                  ── needs B's panel list
                                                  ── needs at least C1 live so Overview isn't empty on day one (C2/C3 can land after D as additive tabs)
D ── E (Makefile target, interim viewing) ── trivial once D exists
```

## Per-phase landing summary

| Phase | Scope | PR scope | Depends on |
|---|---|---|---|
| 0 | `gh issue list --search "dashboard"` in both repos | none (research only) | none |
| A | Shared `dashboard-design-tokens.css` + self-hosted font files | 1 llm PR (canonical file) + 1 llmtelemetry PR (absolute-path reference wiring) | none |
| B | MVP Overview panel-list decision, Reliability-tab deferral decision | none (design decision only) | none |
| C1 | Schedule `poll_github_events.R` via existing plist/refresh-script convention | 1 llmtelemetry PR | none |
| C2 | New `git_pull_requests` schema + `poll_github_prs.R` | 1 llmtelemetry PR | none |
| C3 | New `ci_runs` schema + `poll_github_ci_runs.R` | 1 llmtelemetry PR | none |
| C4 | Commit-puller architecture decision (keep local-git-log) | none (design decision only) | none |
| D | `vignettes/dashboard_overview.qmd` + new ETL sections in `export_dashboard_data.R` | 1 llmtelemetry PR | A, B, C1 minimum |
| E | `Makefile` `dashboard-overview` target | 1 llmtelemetry PR (can bundle with D) | D |

Cross-repo PR count: 1 llm PR (Phase A canonical stylesheet); everything else is llmtelemetry-only, matching this session's established cross-repo discipline (never bundle an llm change with an llmtelemetry change in one PR) — Phase A is the one deliberate, explicitly-flagged exception, landed as two separately-reviewed PRs rather than one.

## Verification per phase

- **0**: manual — paste both `gh issue list` outputs into the plan's Context section before proceeding; if a hit is found, this plan gets a "prior art" addendum, not a rewrite.
- **A**: `check_dark_contrast.sh` run against a throwaway render that includes the new stylesheet in both `data-theme="light"` and `data-theme="dark"` states — both must exit 0. Manual: confirm the absolute-path `css:` reference resolves and inlines correctly under `embed-resources: true` (inspect rendered HTML for `<style>` contents, not just an unresolved `<link>`).
- **B**: no code — reviewed as a design decision; verification is the user confirming the panel list matches what they actually want monitored before Phase D starts building against it.
- **C1**: confirm a log entry (or the plist's own `StandardOutPath` log) shows `poll_github_events.R` actually ran at the next scheduled interval; confirm `github_issue_events.json`'s `created_at` timestamps advance past the previous manual-run watermark without a human re-running it by hand.
- **C2/C3**: new `tests/testthat/test-poll-github-prs.R` / `test-poll-github-ci-runs.R` using a `gh api` mock/fixture (check `poll_github_events.R`'s own tests first, extend rather than invent a new mocking convention). Manual: run once against the real `gh api` for one repo, confirm the exported JSON's row count is plausible against `gh pr list`/`gh run list` run manually side-by-side.
- **C4**: no code change — verification is documenting the decision and its revisit trigger (llmtelemetry#352 resolution) in this plan file itself.
- **D**: `check_dark_contrast.sh` exit 0 on the rendered `dashboard_overview.html`; manual visual check that the pill-nav section-switch and tabset-within-section both work with JS only (no Shiny runtime) after a full render+open in a browser; confirm `quarto-vignettes.md`'s DT-only-tables and mandatory-build-info-footer rules are satisfied same as any other vignette.
- **E**: `make dashboard-overview` produces a `file://` URL that opens and matches the `quarto render` output exactly (parity check against the existing `dashboard` target's own output convention).

## Critical Files for Implementation

- `~/docs_gh/llmtelemetry/inst/scripts/export_dashboard_data.R`
- `~/docs_gh/llmtelemetry/inst/scripts/poll_github_events.R`
- `~/docs_gh/llmtelemetry/vignettes/self_review.qmd`
- `~/docs_gh/llmtelemetry/inst/schema/v1/git_commits.sql`
- `~/docs_gh/llmtelemetry/Makefile`
- `~/docs_gh/llm/.claude/scripts/check_dark_contrast.sh`
- `~/docs_gh/llm/_brand.yml`
