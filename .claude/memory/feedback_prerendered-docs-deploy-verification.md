---
name: prerendered-docs-deploy-verification
description: "For repos that commit pre-rendered docs/ (deploy CI only publishes, doesn't render), a source/.qmd fix is inert until docs/ is re-rendered + committed — \"PR merged + deploy green\" ≠ live. Verify the deployed artifact."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 98de5127-e879-4d56-a9a2-d27782fe5087
---

When a repo **commits pre-rendered `docs/`** and its deploy CI only *verifies + publishes* that committed `docs/` (it renders nothing), a fix to a source file (`.qmd` vignette, `.R`) is **INERT until `docs/` is re-rendered locally and the rebuilt HTML committed.** Merging a source-only PR and seeing the deploy go green does **NOT** mean the live site changed — the deploy just re-served the stale pre-rendered artifact.

**Why:** the rendered output (e.g. a shinylive app's `app.R` embedded in `articles/foo_shinylive.html`) is a committed build product, decoupled from the source. Fixing the source without rebuilding the product leaves the product stale. "Source parses" + "deploy succeeded" both pass while the live app is still broken.

**How to apply:**
1. **Detect the pattern before claiming a fix is live.** Read the deploy workflow. Tells: a `paths: docs/**` push trigger, a "Verify pre-built docs exist" step, or literal text like *"build locally with pkgdown::build_site() and commit docs/"*. If present, `docs/` is pre-built and committed.
2. **Never verify a Pages/pkgdown/shinylive fix by "deploy green" or by the source `.qmd`.** Verify the **actual deployed artifact**: `curl -sL <live-url> -o /tmp/x.html` then grep the rendered HTML for the real fix. For shinylive, the app code is embedded in the HTML — check the *embedded* app, not the vignette. (Confirm on `origin/main`: `git grep -l '<stale-pattern>' origin/main -- 'docs/**'`.)
3. **The fix path** for such repos: re-render locally in the project env (`pkgdown::build_site()`, `quarto render`, or the project's `tar_make()`/build step) → commit the updated `docs/` → push (that's what triggers the real deploy).
4. **CI gate gap to watch:** a pre-deploy `check-html` gate that greps committed `docs/*.html` for *placeholder*/`tar_make()` text will NOT catch a broken shinylive app (R-parse / WebR `preload error` / `unrecognized escape`). Extending the gate to grep committed shinylive HTML for those signatures stops a broken app reaching the live site.

**Origin (the mistake, 2026-07-27):** micromort `quiz_shinylive` (+chronic/ranking) apps were blank live with `Error : '\d' is an unrecognized escape ... app.R:286`. Fixed the escape in the source vignettes ([micromort#129](https://github.com/JohnGavin/micromort/pull/129)), merged, triggered the pkgdown `workflow_dispatch` (went green), and I told the user it was live. It was NOT: micromort commits pre-rendered `docs/`, the deploy only publishes it, and the committed `docs/articles/*_quiz_shinylive.html` still embedded the buggy app (`/^\d+$/`, single backslash — confirmed in the live bytes via curl). The real fix required re-rendering the vignettes and committing `docs/`.

Related: [[deploy-gap-stale-main-checkout]] (a different "merged ≠ live": stale local main checkout for cron), [[shinylive-issues]], readme-qmd-standard / shinylive-deployment skills.
