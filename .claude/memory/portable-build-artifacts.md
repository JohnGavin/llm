---
name: portable-build-artifacts
description: "A committed artifact must not depend on the checkout that built it. Two shapes: absolute paths serialised inside objects (repair on READ, not by regenerating), and path filters matched against absolute paths that swallow their own scan root (match relative)."
metadata:
  node_type: memory
  type: feedback
---

Any build that **writes a file which gets committed** and is later read by a different machine or checkout must produce a location-independent artifact. Two distinct failure shapes, both observed in `llm` within 48 hours, both merged green, both found days later.

**Shape 1 — absolute paths serialised inside the object.** `saveRDS()` preserves internals verbatim. A `DT::datatable()` records its JS assets as an *absolute* `html_dependency` path, so the committed `.rds` carries the exporting machine's `/nix/store/…` prefix. Renders locally, dies in CI with `path for html_dependency not found`.

**Why:** regenerating does NOT fix it — it only re-acquires whichever path the *new* exporting machine has, so it returns on the next export from anywhere else. Repair at **read** time: for each dependency whose path is absent, re-resolve `…/library/<PKG>/<rest>` → `system.file(<rest>, package = <PKG>)`. Must be a no-op when the path resolves, must skip `package`-relative deps, and must leave unresolvable paths intact so failure stays visible.

**Shape 2 — a path filter matched against absolute paths.** An exclusion meant to skip *nested* subtrees (`grepl("/(archive|worktrees)/", files)`) also matches when the **scan root itself** contains the token. Every worktree path does — both `.claude/worktrees/` (dispatched agents) and `~/docs_gh/worktrees/` (manual, per [[worktree-location]]). So a target built anywhere but the main checkout scanned 377 files and kept 0.

**Why it is worse than Shape 1:** it does not error. It returns a well-formed *empty* result that flows downstream and surfaces somewhere unrelated — here, a `facet_wrap()` in a vignette that killed the whole site build. Fix: `fs::path_rel(files, scan_root)` then match `(^|/)token/`.

**How to apply:**
1. Treat "regenerate the artifact" as a **suspect** fix for any path-not-found error — ask whether the path is environment-specific first.
2. Before committing a regenerated artifact, **diff its content against the prior version** — row count, category coverage, non-NA share. Existence and mtime are not evidence. A regeneration that shrinks it by orders of magnitude is a defect until proven otherwise.
3. Regenerate committed artifacts from the **main checkout** until the exporter is proven location-independent; otherwise have it print the checkout it ran from so a worktree build is visible in review.
4. Grep for the Shape-2 pattern wherever a scan root is user- or environment-derived: `grepl("/<token>/", <absolute paths>)`.

**Origin (2026-08-03):** [llm#883](https://github.com/JohnGavin/llm/issues/883)/[#885](https://github.com/JohnGavin/llm/pull/885) — 13 snapshots carried absolute DT paths, blocking all publishing for 2 days. [llm#889](https://github.com/JohnGavin/llm/issues/889)/[#890](https://github.com/JohnGavin/llm/pull/890) — [#868](https://github.com/JohnGavin/llm/pull/868) regenerated `vig_scrolly_config` from a worktree, replacing 222 rows with 0, and it shipped silently. Neither was visible to `qa_no_nulls` (tests NULL; a zero-row tibble passes) or `qa_rds_freshness` (compares mtimes, never content).

Related: [[deploy-trigger-excludes-vignette-data]], [[prerendered-docs-deploy-verification]], [[worktree-location]], rule `portable-build-artifacts`.
