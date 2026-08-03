---
name: deploy-trigger-excludes-vignette-data
description: "A publish workflow's `paths:` filter can omit the data files the vignettes actually read (inst/extdata/vignettes/**), so a data-only fix merges green and never deploys. Check the trigger paths AND recent run history before claiming a fix is live."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 92dd2058-9694-4ebc-a815-163d88d8b4de
  modified: 2026-08-03T10:11:15.018Z
---

A repo can render in CI (so [[prerendered-docs-deploy-verification]]'s "committed `docs/`" tell is absent) and **still** strand a fix, because the publish workflow's `on.push.paths:` filter does not list the files that changed.

In `llm`, `.github/workflows/quarto-publish.yaml` triggers on `vignettes/**`, `_quarto.yml`, `_brand.yml`, `_includes/**`, `index.qmd`, `R/ccusage.R`, `inst/extdata/ccusage_*.json`, `DESCRIPTION`. The telemetry vignettes read their plots and tables from `inst/extdata/vignettes/vig_*.rds` via `safe_tar_read()` — **and that path is not in the filter.** A snapshot-only fix therefore merges, goes green, and never publishes.

**Why:** the trigger filter encodes an assumption that only `.qmd`/config changes affect output. Once vignettes read committed *data artifacts*, that assumption is false — the data is as much an input to the rendered page as the source is.

**How to apply:**
1. Before claiming any vignette/site fix is live, read the publish workflow's `paths:` list and ask whether the files you changed are in it. Merging is not deploying.
2. Confirm empirically, not by inference: `gh run list --workflow <wf> --limit 5 --json headSha,conclusion` — check a run exists **at your merge SHA** and that it succeeded. No run at your SHA = the filter excluded you.
3. Also check the *recent* run history, not just your own. Consecutive failures mean the live site is pinned at the last green SHA, so the defect you are "fixing" may not even be live yet — verify with `curl` + `grep` against the deployed URL before describing live symptoms.
4. Fixes: add the data glob to `paths:`, or drop `paths:` entirely and rely on the render being cheap/cached.

**Origin (2026-08-03, llm#881 / [PR #882](https://github.com/JohnGavin/llm/pull/882)):** the `qa_no_nulls` gate found `vig_codexbar_project_cost_plot.rds` committed as NULL and the PR body asserted "that chart is blank on the deployed site right now." Both halves needed correcting. The snapshot really was NULL (44 bytes), but the chart was **not live**: `quarto-publish` had failed three consecutive runs since 2026-08-02 with `path for html_dependency not found: /nix/store/…-r-DT-0.34.0/library/DT/htmlwidgets/lib/datatables`, so the site was pinned at 2026-08-01 — before the codexbar targets existed. `curl` of the live `session-efficiency.html` returned **0 matches** for "codexbar", proving the section had never shipped. Merging the fix also triggered **no** publish run, because only `.rds` files under `inst/extdata/vignettes/` changed.

Related: [[prerendered-docs-deploy-verification]] (the committed-`docs/` variant of "merged ≠ live"), [[deploy-gap-stale-main-checkout]] (the stale-local-checkout variant).
