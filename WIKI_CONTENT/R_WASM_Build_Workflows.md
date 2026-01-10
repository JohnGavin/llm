# R-WASM Build Workflows for Interactive Vignettes

> **Related Claude Skill**:
> - [`.claude/skills/shinylive-quarto/SKILL.md`](https://github.com/JohnGavin/llm/blob/main/.claude/skills/shinylive-quarto/SKILL.md) - WebAssembly workflow, R-Universe setup, and GitHub Pages deployment

Links:

- README: https://github.com/JohnGavin/llm#documentation
- Wiki: https://github.com/JohnGavin/llm/wiki/R-WASM-Build-Workflows
- Repo source: https://github.com/JohnGavin/llm/blob/main/WIKI_CONTENT/R_WASM_Build_Workflows.md

This page describes a workflow for building R packages as WebAssembly (WASM) binaries for use in browser-based Shinylive vignettes. The goal is fast iteration (minutes) vs waiting for r-universe sync (hours).

If you’re reading this in-repo (`WIKI_CONTENT/`), it is intended to be published to the project wiki at `https://github.com/JohnGavin/llm/wiki`.

---

## Problem Statement

**Challenge**: r-universe syncs package repositories periodically (often 1–4 hours), creating slow feedback loops when developing interactive vignettes.

**Solution**: GitHub Actions builds R-WASM binaries on every push (~5–10 minutes), enabling rapid testing.

---

## Architecture

### Three-Tier Package Distribution

```
┌─────────────────────────────────────────────────────────────┐
│ 1. GitHub Pages (johngavin.github.io/PACKAGE/wasm/)        │
│    • Built on every push (5-10 min)                         │
│    • Fast development iteration                             │
│    • Latest commits immediately                             │
│    • Primary source for vignette testing                    │
└─────────────────────────────────────────────────────────────┘
                              ↓ fallback
┌─────────────────────────────────────────────────────────────┐
│ 2. R-Universe (johngavin.r-universe.dev)                   │
│    • Synced periodically (1-4 hours)                        │
│    • Stable, tested builds                                  │
│    • Multi-platform binaries                                │
│    • Secondary fallback for vignettes                       │
└─────────────────────────────────────────────────────────────┘
                              ↓ fallback
┌─────────────────────────────────────────────────────────────┐
│ 3. CRAN/Other R-Universe Repos                             │
│    • Standard package repositories                          │
│    • For dependencies (nanonext, mirai, crew, etc.)         │
│    • e.g., https://r-lib.r-universe.dev                     │
└─────────────────────────────────────────────────────────────┘
```

### Vignette Repository Configuration

Shinylive vignettes install packages from multiple sources with fallback:

```r
webr::install(
  "randomwalk",
  repos = c(
    "https://johngavin.github.io/randomwalk/wasm",  # primary (5-10 min)
    "https://johngavin.r-universe.dev",             # fallback (1-4 hours)
    "https://r-lib.r-universe.dev"                  # dependencies
  ),
  verbose = TRUE
)
```

---

## GitHub Actions Workflow

### File: `.github/workflows/build-wasm.yaml`

**Triggers:**

- Every push to `main`
- Manual workflow dispatch

**High-level steps:**

1. Checkout & set up R
2. Install `rwasm` (`remotes::install_github("r-wasm/rwasm")`)
3. Extract package dependencies from `DESCRIPTION`
4. Build a WASM library via `rwasm::make_library()`
5. Create repository metadata (`PACKAGES`)
6. Upload artifact
7. Deploy to GitHub Pages under `wasm/`

Example:

```r
rwasm::make_library(
  packages = c(
    "logger", "ggplot2",
    "nanonext", "mirai", "crew",
    "shiny",
    "."
  ),
  repos = c(
    "https://cran.r-project.org",
    "https://r-lib.r-universe.dev"
  ),
  lib_dir = "wasm-library",
  compress = TRUE
)
```

---

## Development Workflow

1. Make changes (R code, vignettes, etc.)
2. Local testing:

   ```r
   devtools::document()
   devtools::test()
   devtools::check()
   pkgdown::build_site()
   ```

3. Push to GitHub (via `gert` / `usethis` workflow)
4. Wait ~5–10 minutes for GitHub Actions
5. Test vignettes on GitHub Pages

---

## Troubleshooting

### Build Fails: “Package XXX not found”

Add the repo that contains the missing dependency to `repos` in `make_library()` (e.g. an r-universe).

### Vignette Can’t Load Package

Check:

1. GitHub Actions finished successfully
2. The deployed repo exists: `https://USER.github.io/PACKAGE/wasm/PACKAGES`
3. `webr::install()` uses the correct repo URL
4. Browser console errors

### WASM Binary Out of Date

1. Verify Actions run is complete
2. Hard refresh / clear cache
3. Wait for CDN propagation

---

## References

- rwasm: https://github.com/r-wasm/rwasm
- WebR: https://docs.r-wasm.org/webr/latest/
- Shinylive for R: https://posit-dev.github.io/r-shinylive/
- R-universe: https://r-universe.dev/
