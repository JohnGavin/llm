# pkgctx Gotchas

## Central cache path, not per-project .claude/context/

The SKILL.md previously said "store in `.claude/context/`". Sessions followed this and found 0 files. The central cache is at `~/docs_gh/proj/data/llm/content/inst/ctx/external/`. **NEVER** create per-project `.claude/context/` directories.

## pkgctx generates from CRAN latest, not pinned nix version

`nix run github:b-rodrigues/pkgctx -- r dplyr` downloads the LATEST CRAN source, not the version pinned in your nix shell. Result: ctx file says `version: 1.2.0` but nix shell has dplyr 1.1.4. Status: `OTHER_VERSION` (usable but not exact).

## pkgctx timeout for large packages

dplyr (45KB ctx) timed out at 120s. Bumped to 300s in `generate_ctx()`. Large packages (ggplot2 at 85KB) need the full 300s on first run when the pkgctx binary itself is being built.

## Version-stamped filenames prevent cross-project overwrites

Before: `dplyr.ctx.yaml` — last project to run ctx_sync wins. After: `dplyr@1.1.4.ctx.yaml` — all versions coexist. Each project resolves the right version via `packageVersion()` in its own nix shell.

## Sessions write ad-hoc checking code instead of using ctx_audit()

Claude ignores CLAUDE.md instructions when asked "tabulate ctx coverage" — it writes its own Rscript that checks locally and finds 0. **Use `/ctx-check` command** to force the correct code path.
