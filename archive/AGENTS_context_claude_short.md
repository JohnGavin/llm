# Agent Guide for R Package Development

**Full documentation**: https://github.com/JohnGavin/claude_rix/wiki

This document provides essential guidelines for R package development with Nix, rix, and reproducible workflows.

## Quick Start

✅ **Environment:** `caffeinate -i ~/docs_gh/rix.setup/default.sh` (single persistent nix shell)
✅ **Context:** Read `.claude/CURRENT_WORK.md` if exists
✅ **Verify:** `R --version`, `which R` (should be `/nix/store/...`)

**Key References:**
- **Workflow:** This file (essential steps only)
- **Nix Details:** https://github.com/JohnGavin/claude_rix/wiki/Nix-Environment-Setup
- **Troubleshooting:** `NIX_TROUBLESHOOTING.md`

---

# 🚨 CRITICAL: MANDATORY 9-STEP WORKFLOW 🚨

**NO EXCEPTIONS. NO SHORTCUTS. EVERY CHANGE MUST FOLLOW THIS.**

```
┌────────────────────────────────────────────────────────────────┐
│ 1. Create GitHub Issue (#123)                                 │
│ 2. Create dev branch (usethis::pr_init())                     │
│ 3. Make changes locally                                       │
│ 4. Run all checks (devtools::check(), etc.)                   │
│                                                                │
│ 5. 🚨 VERIFY CACHE LOCALLY TWICE, THEN PUSH TO CACHIX 🚨      │
│    ⛔ ONLY IF PACKAGE CODE CHANGED ⛔                           │
│    First run: ~20m (source) → Second run: ~2m (cache)        │
│    LOG THE SPEEDUP, then push to johngavin cachix            │
│                                                                │
│    💰 SKIPPING COSTS 2+ HOURS OF GITHUB ACTIONS               │
│                                                                │
│ 6. Push to GitHub (usethis::pr_push()) - ONLY AFTER Step 5   │
│ 7. Wait for GitHub Actions (pulls from cachix - FAST!)       │
│ 8. Merge PR (usethis::pr_merge_main())                       │
│ 9. Log everything (R/setup/fix_issue_123.R)                  │
└────────────────────────────────────────────────────────────────┘
```

---

## Step 5 Details: Verify Cache Locally TWICE

**⛔ ONLY RUN IF PACKAGE CODE CHANGED ⛔**

```bash
# FIRST RUN - Build from source (~20min)
START1=$(date +%s)
nix-build default-ci.nix
END1=$(date +%s)
TIME1=$((END1 - START1))
echo "First run: ${TIME1}s (~$((TIME1/60))m)"

# SECOND RUN - Verify cache (~2min)
rm result
START2=$(date +%s)
nix-build default-ci.nix
END2=$(date +%s)
TIME2=$((END2 - START2))
echo "Second run: ${TIME2}s (~$((TIME2/60))m)"

# DISPLAY SPEEDUP
SPEEDUP=$((100 - (TIME2 * 100 / TIME1)))
echo "Speedup: ${SPEEDUP}% (${TIME1}s → ${TIME2}s)"

# PUSH TO CACHIX (only if package changed)
../push_to_cachix.sh

# Verify: https://app.cachix.org/cache/johngavin
```

**Why Run TWICE:**
- ✅ **PROVE** caching works locally
- ✅ **LOG** exact speedup (e.g., "90% faster")
- ✅ **VERIFY** GitHub Actions will also be fast

---

## Essential Commands

**FORBIDDEN:**
- ❌ `git add/commit/push` (use gert package)
- ❌ `gh pr create` (use usethis/gh package)

**REQUIRED:**
```r
# GitHub/Git (use R packages ONLY)
usethis::pr_init("fix-issue-123")
gert::git_add("."); gert::git_commit("msg")
usethis::pr_push()  # ONLY after cachix push
usethis::pr_merge_main(); usethis::pr_finish()

# Quality
devtools::document(); devtools::test(); devtools::check()

# GitHub API
gh::gh("POST /repos/owner/repo/issues", title = "...", body = "...")
```

---

## Nix Environment

**Start shell:**
```bash
cd /Users/johngavin/docs_gh/claude_rix/project_name
caffeinate -i ~/docs_gh/rix.setup/default.sh
```

**Verify you're in nix:**
```bash
R --version  # Should show R 4.4.1 or 4.5.1
which R      # Should be /nix/store/...
```

**Degradation fix:**
```bash
exit
nix-shell default.nix
```

---

## Package Development

**Add dependency:**
```r
usethis::use_package("dplyr")  # Adds to Imports
usethis::use_package("ggplot2", "Suggests")  # Adds to Suggests

# Regenerate nix files
source("R/setup/generate_nix_files.R")
update_nix_files()

# Restart nix shell to get new package
```

**Reload after code changes:**
```r
devtools::load_all(".")  # ALWAYS after editing R/ files
```

---

## Workflow Logging

**ALWAYS log in `R/setup/`:**
```r
# R/setup/fix_issue_123.R
library(gert)
library(usethis)

# Step 1: Created issue #123
# Step 2: Created branch
usethis::pr_init("fix-issue-123")

# Step 3: Made changes
# ... document changes ...

# Step 4: Ran checks
devtools::document()
devtools::test()
devtools::check()

# Step 5: Verified cache locally, pushed to cachix
# ... log timing results ...

# Step 6: Push to GitHub
usethis::pr_push()
```

**Include session log in PR before merge** (not after!)

---

## File Structure

- `R/` - Package code
- `R/setup/` - Workflow scripts (logged commands)
- `R/tar_plans/` - Targets plans
- `inst/qmd/` - Source Quarto files
- `vignettes/` - Pre-built HTML from inst/qmd/

**Minimize top-level files** - use `inst/` for non-essentials

---

## Targets Package

Pre-calculate vignette objects:
```r
# vignette.qmd just loads pre-built objects
targets::tar_load(my_plot)
targets::tar_load(my_table)
```

---

## GitHub Actions & Nix

**For Quarto vignettes:**
- ❌ **Nix + pkgdown + Quarto + bslib = IMPOSSIBLE** (bslib can't write to read-only `/nix/store`)
- ✅ **Solution:** Pre-build vignettes with targets, commit HTML, use native R for pkgdown

**Details:** https://github.com/JohnGavin/claude_rix/wiki/GitHub-Actions-Workflows

---

## Troubleshooting Quick Reference

- **"Command not found"** → Exit and restart nix-shell
- **Package conflicts** → Check `r_ver` in `default.R`
- **Forgot task** → Read `.claude/CURRENT_WORK.md`, `git log --oneline -10`
- **CI fails locally works** → Ensure `default.nix` committed

**Full guide:** `NIX_TROUBLESHOOTING.md`

---

## Session Continuity

**End of session:**
```r
gert::git_add("."); gert::git_commit("WIP: checkpoint")
gert::git_push()
# Update .claude/CURRENT_WORK.md
```

**Start of session:**
```
"Read .claude/CURRENT_WORK.md and git log --oneline -5.
Continue [task]."
```

**Template:** `.claude/CURRENT_WORK.md`

---

## Additional Resources

- **Nix Setup:** https://github.com/JohnGavin/claude_rix/wiki/Nix-Environment-Setup
- **Workflow Examples:** https://github.com/JohnGavin/claude_rix/wiki/Workflow-Examples
- **Troubleshooting:** `NIX_TROUBLESHOOTING.md`
- **rix documentation:** https://docs.ropensci.org/rix/

---

**This is a streamlined version. Full details at: https://github.com/JohnGavin/claude_rix/wiki**
