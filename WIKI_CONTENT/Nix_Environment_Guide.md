# Nix vs Native R: Quick Reference

> **Related Claude Skills**:
> - [`.claude/skills/nix-rix-r-environment/SKILL.md`](https://github.com/JohnGavin/llm/blob/main/.claude/skills/nix-rix-r-environment/SKILL.md) - Core Nix/rix setup
> - [`.claude/skills/pkgdown-deployment/SKILL.md`](https://github.com/JohnGavin/llm/blob/main/.claude/skills/pkgdown-deployment/SKILL.md) - Hybrid Nix + Native R for pkgdown

Links:

- README: https://github.com/JohnGavin/llm#documentation
- Wiki: https://github.com/JohnGavin/llm/wiki/Nix-Environment-Guide
- Repo source: https://github.com/JohnGavin/llm/blob/main/WIKI_CONTENT/Nix_Environment_Guide.md

> **Quick Decision Guide**: Choose the right environment for each CI/CD task
> **For Details**: Prefer this project's wiki pages (linked above). If you see links to other repos' wikis in this doc, they should be migrated here over time.

---

## Quick Decision Matrix

| Task | Environment | CI Workflow | Why |
|------|-------------|-------------|-----|
| **R CMD check** | Nix | `rix` + cachix | Exact same env as local dev |
| **Unit tests** | Nix | `rix` + cachix | Reproducibility |
| **Data pipelines** | Nix | `rix` + cachix | Reproducibility |
| **pkgdown (no Quarto)** | Nix | `rix` + cachix | Works fine |
| **pkgdown + Quarto** | Native R | r-lib/actions | Nix incompatible with bslib |
| **Vignette rendering** | targets | Both | Depends on approach |
| **Documentation** | Native R | r-lib/actions | Flexibility |

---

## The Fundamental Incompatibility

### ❌ Nix + pkgdown + Quarto + bslib = IMPOSSIBLE

```
Quarto vignettes → require Bootstrap 5 → require bslib →
requires file copying from /nix/store → BLOCKED (read-only) → FAILS
```

**This is not a bug** - it's a fundamental design conflict.

**→ For full explanation**: [Wiki: Pkgdown + Quarto + Nix Issue](https://github.com/JohnGavin/claude_rix/wiki/Pkgdown-Quarto-Nix-Issue)

---

## Common Scenarios

### Scenario 1: R Package with Quarto Vignettes

**Challenge**: pkgdown + Quarto + bslib incompatible with Nix

**Solution**: Hybrid approach

```yaml
# R-CMD-check.yml - Use Nix (reproducibility)
- uses: cachix/install-nix-action@v20
- run: nix-shell --run "Rscript -e 'devtools::check()'"

# targets-pkgdown.yml - Use Native R (compatibility)
- uses: r-lib/actions/setup-r@v2
- run: Rscript -e 'targets::tar_make()'  # Renders vignettes + builds site
```

**Why this works**:
- R CMD check uses Nix (same as local dev)
- pkgdown uses native R (avoids bslib issue)
- targets renders vignettes (works in either env)

**→ See**: [TARGETS_PKGDOWN_SOLUTION.md](./TARGETS_PKGDOWN_SOLUTION.md)

### Scenario 2: Data Processing Pipeline

**Challenge**: Need reproducible data processing

**Solution**: Pure Nix

```yaml
name: Data Pipeline
jobs:
  pipeline:
    steps:
      - uses: cachix/install-nix-action@v20
      - uses: cachix/cachix-action@v12
        with:
          name: johngavin
      - run: nix-shell --run "Rscript -e 'targets::tar_make()'"
      - run: nix-store -qR --include-outputs result | cachix push johngavin
```

**Why this works**:
- Complete reproducibility via Nix
- Fast CI via cachix
- Same environment locally and in CI

### Scenario 3: Simple Package (No Quarto, No Nix)

**Challenge**: Simple package, no special requirements

**Solution**: Pure r-lib/actions

```yaml
name: R-CMD-check
jobs:
  check:
    steps:
      - uses: r-lib/actions/setup-r@v2
      - uses: r-lib/actions/setup-r-dependencies@v2
      - run: Rscript -e 'devtools::check()'
```

**Why this works**:
- Simple, fast, standard workflow
- No Nix overhead
- Works for 90% of R packages

---

## Decision Criteria

### Criterion 1: Reproducibility Requirements

**High reproducibility needed** → **Use Nix**
- R CMD check
- Unit tests
- Data processing
- Scientific computing
- Publication-quality results

**Medium reproducibility acceptable** → **Use Native R**
- Documentation websites
- Preview builds
- Development iterations

### Criterion 2: Runtime File Modifications

**Package needs to modify itself at runtime** → **Use Native R**
- bslib (copies JS/CSS files)
- pkgdown with Quarto + bslib
- Packages with post-install scripts

**No runtime modifications** → **Use Nix**
- Standard R packages
- Pure computation
- Read-only operations

### Criterion 3: Local Development Environment

**Local uses Nix** → **Prefer Nix in CI**
- Maintains consistency
- Same bugs/features locally and CI
- Easier debugging

**Local uses standard R** → **Use Native R in CI**
- No advantage to Nix
- Simpler workflow

---

## Understanding the Options

### Option 1: Nix Environment

**Advantages**:
- ✅ **Perfect reproducibility**: Identical env everywhere
- ✅ **Version pinning**: Exact package versions guaranteed
- ✅ **Cacheable**: Use cachix for fast CI

**Limitations**:
- ❌ **Read-only**: Can't modify installed packages
- ❌ **bslib incompatibility**: Can't copy files at runtime
- ❌ **Setup time**: Initial cache miss is slow

**When to Use**:
- Package development
- R CMD check
- Unit testing
- Data processing pipelines

### Option 2: Native R (r-lib/actions)

**Advantages**:
- ✅ **Fast setup**: RSPM binaries install quickly
- ✅ **Writable**: Packages can modify themselves
- ✅ **Compatible**: Works with all R packages

**Limitations**:
- ⚠️ **Less reproducible**: Package versions may drift
- ⚠️ **Platform differences**: Local (Nix) ≠ CI (native R)

**When to Use**:
- pkgdown with Quarto vignettes
- Tasks requiring runtime file modifications
- Quick prototypes

---

## Best Practices

### 1. Match Local and CI for Critical Tasks

**Rule**: R CMD check MUST use same environment as local development

✅ **Good**:
```
Local: Nix shell with default.nix
CI: Nix shell with same default.nix
```

❌ **Bad**:
```
Local: Nix shell
CI: r-lib/actions (different environment!)
```

### 2. Use Native R for Non-Critical Tasks

**Rule**: Documentation doesn't need perfect reproducibility

✅ **Acceptable**:
```
R CMD check: Nix (reproducible)
pkgdown: Native R (fast, flexible)
```

### 3. Document Your Choice

**Rule**: Explain why you chose Nix vs native R

✅ **Good**:
```yaml
# Use Nix for R CMD check to match local development environment
# Use native R for pkgdown due to bslib incompatibility with Nix
```

---

## Workflow Templates

### Template 1: Pure Nix Project

**When**: Maximum reproducibility, no Quarto vignettes

```yaml
# R-CMD-check-nix.yml
- uses: cachix/install-nix-action@v20
- uses: cachix/cachix-action@v12
  with:
    name: johngavin
- run: nix-build package.nix
- run: nix-store -qR --include-outputs result | cachix push johngavin
- run: nix-shell --run "Rscript -e 'rcmdcheck::rcmdcheck()'"
```

**→ See**: [Wiki: Workflow Templates Library](https://github.com/JohnGavin/claude_rix/wiki/Workflow-Templates-Library)

### Template 2: Hybrid Nix + Native R

**When**: Nix locally, Quarto vignettes, need fast CI

```yaml
# R-CMD-check-nix.yml
- uses: cachix/install-nix-action@v20
- run: nix-shell --run "Rscript -e 'devtools::check()'"

# targets-pkgdown.yml
- uses: r-lib/actions/setup-r@v2
- run: Rscript -e 'targets::tar_make()'
```

**→ See**: [TARGETS_PKGDOWN_SOLUTION.md](./TARGETS_PKGDOWN_SOLUTION.md)

### Template 3: Pure r-lib/actions

**When**: No Nix, standard R package

```yaml
# R-CMD-check.yml
- uses: r-lib/actions/setup-r@v2
- uses: r-lib/actions/setup-r-dependencies@v2
- uses: r-lib/actions/check-r-package@v2
```

**→ See**: [Wiki: Workflow Templates Library](https://github.com/JohnGavin/claude_rix/wiki/Workflow-Templates-Library)

---

## Decision Flowchart

```
Start: Need to choose workflow
    ↓
[Q1] Using Nix for local development?
    ├─ No → Use r-lib/actions (Template 3)
    └─ Yes → Continue
        ↓
[Q2] Does task require runtime file modifications?
    ├─ Yes (e.g., pkgdown + Quarto + bslib)
    │   └─ Use Native R (Template 2, hybrid)
    └─ No → Continue
        ↓
[Q3] Is reproducibility critical?
    ├─ Yes (R CMD check, tests, data)
    │   └─ Use Nix (Template 1 or 2)
    └─ No (documentation, previews)
        └─ Use Native R or Nix (either works)
```

---

## Summary

**Golden Rules**:

1. **R CMD check = Local environment** (Nix if local uses Nix)
2. **Documentation = Flexible** (Native R acceptable)
3. **Data pipelines = Nix** (reproducibility critical)
4. **bslib + Nix = Incompatible** (use native R)
5. **Hybrid = Okay if documented**

**Default Recommendations**:

- **New project, no Nix**: Use r-lib/actions for everything
- **Existing Nix project**: Use Nix for checks, consider hybrid for docs
- **Quarto vignettes**: Use targets + native R workflow

---

## Related Documentation

### Main Repository
- [NIX_WORKFLOW.md](./NIX_WORKFLOW.md) - General Nix workflow guide
- [TARGETS_PKGDOWN_OVERVIEW.md](./TARGETS_PKGDOWN_OVERVIEW.md) - Detailed solution for Quarto vignettes
- [AGENTS.md](./AGENTS.md) - Core principles and rules

### Wiki (Complete Guides)
- **[Nix vs Native R: Complete Guide](https://github.com/JohnGavin/claude_rix/wiki/Nix-vs-Native-R-Complete-Guide)** - Detailed decision criteria
- **[Workflow Templates Library](https://github.com/JohnGavin/claude_rix/wiki/Workflow-Templates-Library)** - Copy-paste ready templates
- **[When to Use Hybrid Workflows](https://github.com/JohnGavin/claude_rix/wiki/When-to-Use-Hybrid-Workflows)** - Best of both worlds
- **[FAQs](https://github.com/JohnGavin/claude_rix/wiki/FAQs)** - Common questions answered

---

**Created**: December 2, 2025
**Purpose**: Quick decision guide for R package CI/CD workflows
**Questions?** See [Wiki: FAQs](https://github.com/JohnGavin/claude_rix/wiki/FAQs) or open an [issue](https://github.com/JohnGavin/claude_rix/issues)
# Nix Environment: Quick Reference

> **Quick Fixes**: Top 5 issues and immediate solutions
> **For Details**: See [Wiki: Complete Troubleshooting Guide](https://github.com/JohnGavin/claude_rix/wiki/Troubleshooting-Complete-Guide)

---

## Quick Diagnosis

Run this to identify your issue:

```bash
# Check if in nix shell
echo $IN_NIX_SHELL  # Should output: 1 or impure

# Check for broken paths
which git gh R  # Should output: /nix/store/.../bin/...

# Test R packages
Rscript -e "library(devtools); library(usethis); library(gert)"
```

---

## Top 5 Issues & Quick Fixes

### 1. "command not found" Errors

**Symptoms**:
```bash
$ gh run list
bash: gh: command not found

$ R
bash: R: command not found
```

**Quick Fix**:
```bash
# Exit and re-enter shell (takes seconds)
exit
nix-shell default.nix
```

**Why this happens**: Environment degradation during long sessions

**→ Details**: [Wiki: Environment Degradation](https://github.com/JohnGavin/claude_rix/wiki/Troubleshooting-Environment-Degradation)

---

### 2. R Package Won't Load

**Symptoms**:
```r
library(dplyr)
# Error in library(dplyr): there is no package called 'dplyr'
```

**Quick Fix**:
```r
# 1. Check if package is in default.nix
# Edit default.R to add package:
rix::rix(
  r_ver = "4.4.1",
  r_pkgs = c("dplyr", "tidyr", "ggplot2"),  # Add here
  project_path = "."
)

# 2. Restart nix shell
exit
nix-shell default.nix
```

**Why this happens**: Package not included in Nix environment

**→ Details**: [Wiki: Package Installation](https://github.com/JohnGavin/claude_rix/wiki/Troubleshooting-Package-Installation)

---

### 3. `/nix/store/xxx: No such file or directory`

**Symptoms**:
```bash
$ git status
/nix/store/abc123-git-2.42.0/bin/git: No such file or directory
```

**Quick Fix**:
```bash
# Restart shell immediately
exit
nix-shell default.nix
```

**Why this happens**: Garbage collection deleted paths during active session

**→ Details**: [Wiki: Garbage Collection Issues](https://github.com/JohnGavin/claude_rix/wiki/Troubleshooting-Complete-Guide#garbage-collection-issues)

---

### 4. pkgdown Fails with Quarto Vignettes

**Symptoms**:
```r
pkgdown::build_site()
# Error: [EACCES] Failed to copy
#   '/nix/store/.../bslib/lib/bs5/dist/js/bootstrap.bundle.min.js'
#   Permission denied
```

**Quick Fix**: Use targets-based solution (cannot fix in Nix)

```r
# This is a fundamental incompatibility - see solution below
```

**Why this happens**: Nix + pkgdown + Quarto + bslib = fundamentally incompatible

**→ Solution**: [TARGETS_PKGDOWN_OVERVIEW.md](./TARGETS_PKGDOWN_OVERVIEW.md)
**→ Details**: [Wiki: Pkgdown + Quarto + Nix Issue](https://github.com/JohnGavin/claude_rix/wiki/Pkgdown-Quarto-Nix-Issue)

---

### 5. nix-shell Takes Forever to Start

**Symptoms**:
```bash
$ nix-shell default.nix
these 47 derivations will be built:
...
(waits 20+ minutes)
```

**Quick Fix**:
```bash
# Use cachix to speed up future runs
nix-shell --option binary-caches "https://cache.nixos.org https://johngavin.cachix.org"

# OR: Set up cachix permanently (one-time setup)
cachix use johngavin
```

**Why this happens**: Building packages from source (first time or cache miss)

**→ Details**: [Wiki: Performance Issues](https://github.com/JohnGavin/claude_rix/wiki/Troubleshooting-Performance)

---

## Prevention Best Practices

### ✅ DO

1. **Restart shell every 2-3 hours** during long sessions
2. **Use cachix** for fast CI builds
3. **Use `nix-collect-garbage --delete-older-than 30d`** (not `-d`)
4. **Push to cachix BEFORE git push**
5. **Keep default.nix up to date**

### ❌ DON'T

1. **Never use `nix-collect-garbage -d`** during active sessions
2. **Don't use `install.packages()`** in Nix (read-only store)
3. **Don't skip cachix** if you care about CI speed
4. **Don't commit directly to main** (use PR workflow)

---

## Essential Commands

### Check Environment

```bash
# Verify you're in nix shell
echo $IN_NIX_SHELL  # Should output: 1 or impure

# Check R version
R --version

# Check which R
which R  # Should output: /nix/store/.../bin/R

# List available R packages
Rscript -e ".libPaths()"
```

### Enter/Exit Environment

```bash
# Enter
cd /Users/johngavin/docs_gh/claude_rix/project_name
nix-shell default.nix

# Exit
exit

# OR use persistent shell (recommended)
caffeinate -i ~/docs_gh/rix.setup/default.sh
```

### Update Environment

```r
# 1. Regenerate default.nix
source("default.R")

# 2. Restart shell
exit; nix-shell default.nix
```

---

## When Things Go Wrong

### Immediate Recovery Steps

```bash
# 1. Save any unsaved work
# 2. Exit shell
exit

# 3. Re-enter shell
nix-shell default.nix

# 4. Verify it works
which R git gh
R --version
```

### If That Doesn't Work

```bash
# Clean nix store (use with caution)
nix-collect-garbage --delete-older-than 7d

# Rebuild environment
nix-shell default.nix

# If still broken, regenerate default.nix
Rscript -e 'source("default.R")'
nix-shell default.nix
```

### Still Broken?

**→ See**: [Wiki: Complete Troubleshooting Guide](https://github.com/JohnGavin/claude_rix/wiki/Troubleshooting-Complete-Guide)
**→ Or**: [Open an issue](https://github.com/JohnGavin/claude_rix/issues)

---

## Long Session Management

### Session Hygiene

```bash
# Every 2-3 hours:
# 1. Commit or stash work
gert::git_add(".")
gert::git_commit("WIP: checkpoint")

# 2. Exit and re-enter shell
exit
nix-shell default.nix

# 3. Resume work
# (Your files are unchanged, environment is fresh)
```

### Warning Signs

Restart immediately if you see:
- ⚠️ "command not found" for tools that worked earlier
- ⚠️ Unusual slowness
- ⚠️ `/nix/store/xxx: No such file` errors
- ⚠️ R packages that won't load

---

## GitHub Actions Quick Fixes

### Builds Taking Too Long

**Problem**: Packages building from source (20+ minutes)

**Fix**: Use cachix

```yaml
# Add to workflow:
- uses: cachix/cachix-action@v12
  with:
    name: johngavin
    authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}

# And push to cachix BEFORE git push:
nix-build package.nix
nix-store -qR --include-outputs result | cachix push johngavin
```

**→ See**: [NIX_WORKFLOW.md](./NIX_WORKFLOW.md)

### Workflow Failing with "Package not found"

**Problem**: Package in DESCRIPTION but not available in CI

**Fix**: Regenerate nix files

```r
# Ensure package is in default.nix
source("R/setup/generate_nix_files.R")
generate_all_nix_files()

# Commit updated files
gert::git_add(c("package.nix", "default-ci.nix"))
gert::git_commit("Update Nix files after DESCRIPTION change")
```

---

## Related Documentation

### Main Repository
- [NIX_WORKFLOW.md](./NIX_WORKFLOW.md) - Complete development workflow
- [TARGETS_PKGDOWN_OVERVIEW.md](./TARGETS_PKGDOWN_OVERVIEW.md) - pkgdown + Quarto solution
- [NIX_VS_NATIVE_R_QUICKREF.md](./NIX_VS_NATIVE_R_QUICKREF.md) - When to use Nix vs native R
- [AGENTS.md](./AGENTS.md) - Core principles and rules

### Wiki (Detailed Guides)
- **[Complete Troubleshooting Guide](https://github.com/JohnGavin/claude_rix/wiki/Troubleshooting-Complete-Guide)** - All issues covered in depth
- **[Environment Degradation](https://github.com/JohnGavin/claude_rix/wiki/Troubleshooting-Environment-Degradation)** - Detailed diagnosis and prevention
- **[Complete Nix Setup Guide](https://github.com/JohnGavin/claude_rix/wiki/Complete-Nix-Setup-Guide)** - First-time setup
- **[FAQs](https://github.com/JohnGavin/claude_rix/wiki/FAQs)** - Common questions answered

---

## Emergency Contact

If you're completely stuck:

1. **Check the wiki**: [Complete Troubleshooting Guide](https://github.com/JohnGavin/claude_rix/wiki/Troubleshooting-Complete-Guide)
2. **Search issues**: https://github.com/JohnGavin/claude_rix/issues
3. **Open new issue**: https://github.com/JohnGavin/claude_rix/issues/new

Include:
- What you were trying to do
- Error messages (full text)
- Output of: `echo $IN_NIX_SHELL; which R; R --version`

---

**Created**: December 2, 2025
**Purpose**: Quick reference for common Nix environment issues
**Questions?** See [Wiki: FAQs](https://github.com/JohnGavin/claude_rix/wiki/FAQs)
# Nix Workflow Quick Start Guide

**For setting up a new R package project with reproducible Nix workflow**

---

## Prerequisites

- ✅ Running inside nix shell: `caffeinate -i ~/docs_gh/rix.setup/default.sh`
- ✅ Cachix configured: `cachix authtoken <YOUR_TOKEN>`
- ✅ R package with DESCRIPTION file
- ✅ GitHub repository created

---

## Setup Steps (One-Time Per Project)

### 1. Copy R Setup Script

```bash
# From project root (e.g., /Users/johngavin/docs_gh/claude_rix/mypackage/)
mkdir -p R/setup
cp ../random_walk/R/setup/generate_nix_files.R R/setup/
```

### 2. Generate Nix Files

```r
# In R (inside nix shell)
source("R/setup/generate_nix_files.R")

# Generate all three files (package.nix, default-ci.nix, default.nix)
generate_all_nix_files()

# Verify syntax (optional but recommended)
generate_all_nix_files(verify = TRUE)
```

This creates:
- `package.nix` - Package derivation (runtime deps)
- `default-ci.nix` - CI/dev environment (all deps + tools)
- `default.nix` - Symlink to default-ci.nix

### 3. Copy GitHub Actions Workflow

```bash
mkdir -p .github/workflows
cp ../random_walk/.github/workflows/nix-ci.yml .github/workflows/
```

### 4. Configure GitHub Repository

**a) Add Cachix Token Secret:**
1. Go to: `https://github.com/YOUR_USERNAME/YOUR_REPO/settings/secrets/actions`
2. Click: "New repository secret"
3. Name: `CACHIX_AUTH_TOKEN`
4. Value: Your cachix token (from `cachix authtoken`)

**b) Enable GitHub Pages:**
1. Go to: `https://github.com/YOUR_USERNAME/YOUR_REPO/settings/pages`
2. Source: Select "GitHub Actions"
3. Save

### 5. Initial Commit

```r
# Using R packages (NOT bash git commands)
gert::git_add(c(
  "R/setup/generate_nix_files.R",
  "package.nix",
  "default-ci.nix",
  "default.nix",
  ".github/workflows/nix-ci.yml"
))

gert::git_commit("Setup: Add nix workflow files")

# Push to cachix FIRST (mandatory!)
system("../push_to_cachix.sh")

# Then push to GitHub
gert::git_push()
```

---

## Daily Development Workflow

### Making Changes

```r
# 1. Create issue & branch
gh::gh("POST /repos/{owner}/{repo}/issues",
  owner = "YOUR_USERNAME",
  repo = "YOUR_REPO",
  title = "Feature X",
  body = "Description"
)  # Note issue number, e.g., #42

usethis::pr_init("fix-issue-42-feature-x")

# 2. Make changes
# Edit R/your_code.R
# Edit tests/testthat/test-your_code.R

# 3. Commit locally
gert::git_add(c("R/your_code.R", "tests/testthat/test-your_code.R"))
gert::git_commit("Add feature X for #42")

# 4. Run checks
devtools::load_all()
devtools::test()
devtools::check()

# 5. If DESCRIPTION changed, regenerate nix files
source("R/setup/generate_nix_files.R")
update_nix_files()

# 6. Push to cachix (MANDATORY!)
system("../push_to_cachix.sh")

# 7. Push to GitHub
usethis::pr_push()

# 8. Wait for CI to pass, then merge
usethis::pr_merge_main()
usethis::pr_finish()
```

---

## When to Regenerate Nix Files

Regenerate whenever you modify DESCRIPTION:

```r
# After usethis::use_package("newpkg")
# After removing a dependency
# After changing R version requirements

source("R/setup/generate_nix_files.R")
update_nix_files()

# Commit the updated files
gert::git_add(c("package.nix", "default-ci.nix"))
gert::git_commit("Update nix files for new dependencies")
```

---

## Troubleshooting

### "Nix files out of date" in CI

```r
source("R/setup/generate_nix_files.R")
generate_all_nix_files()
gert::git_add(c("package.nix", "default-ci.nix"))
gert::git_commit("Update nix files")
```

### Cachix Push Fails

```bash
# Re-authenticate
cachix authtoken <YOUR_TOKEN>

# Verify
cat ~/.config/cachix/cachix.dhall
```

### Package Build Fails

```bash
# Build locally to debug
nix-build package.nix

# Check for uncommitted files
git status

# Verify DESCRIPTION dependencies match code
devtools::check()
```

### Environment Degradation

```bash
# Exit and re-enter nix shell
exit
caffeinate -i ~/docs_gh/rix.setup/default.sh
```

---

## Key Commands Reference

### R Commands (Use These!)

```r
# Package development
devtools::load_all()     # Reload after code changes
devtools::test()         # Run tests
devtools::check()        # R CMD check
pkgdown::build_site()    # Build website

# Nix file generation
source("R/setup/generate_nix_files.R")
generate_all_nix_files()
update_nix_files()

# Git/GitHub (R packages, NOT bash)
usethis::pr_init("branch-name")
gert::git_add("file.R")
gert::git_commit("message")
usethis::pr_push()
usethis::pr_merge_main()

# GitHub API
gh::gh("POST /repos/{owner}/{repo}/issues", ...)
```

### Bash Commands (Minimal Use)

```bash
# Enter nix environment
nix-shell default.nix

# Build package
nix-build package.nix

# Push to cachix (MANDATORY before git push!)
../push_to_cachix.sh
```

---

## File Checklist

### Files You Must Create
- ✅ `R/setup/generate_nix_files.R` (copy from template)
- ✅ `.github/workflows/nix-ci.yml` (copy from template)

### Files Auto-Generated (Don't Edit Manually)
- ✅ `package.nix` (generated by R/setup/generate_nix_files.R)
- ✅ `default-ci.nix` (generated by rix::rix())
- ✅ `default.nix` (symlink to default-ci.nix)

### Files to Commit
- ✅ All above files
- ✅ `R/setup/*.R` (session logs)
- ✅ `.gitignore` (add: `result`, `result-*`, `.nix-*`)

### Files to Ignore
- ❌ `result` (nix-build output)
- ❌ `result-*` (nix build variants)
- ❌ `.nix-shell-*` (nix shell temp)

---

## The 9-Step Workflow (Summary)

```
1. Create Issue (#42)
   ↓
2. Create Branch (usethis::pr_init())
   ↓
3. Make Changes (edit code, commit locally)
   ↓
4. Run Checks (devtools::check(), etc.)
   ↓
5. ⚠️ Push to Cachix (../push_to_cachix.sh) ⚠️
   ↓
6. Push to GitHub (usethis::pr_push())
   ↓
7. Wait for CI (GitHub Actions)
   ↓
8. Merge PR (usethis::pr_merge_main())
   ↓
9. Log Everything (R/setup/ files)
```

**Remember**: Step 5 (cachix push) is **MANDATORY** before Step 6 (git push)!

### Understanding Cachix Push (rix Philosophy)

From [rix documentation](https://cran.r-project.org/web/packages/rix/vignettes/z-binary_cache.html):

**What happens when you push**:
- 📦 Your package (randomwalk) gets pushed
- 📦 ALL dependencies (ggplot2, logger, crew, etc.) also get pushed

**This is expected and correct!** Cachix cannot selectively exclude dependencies.

**Why it's not a problem**:
- Users pulling get dependencies from `rstats-on-nix` cache (fast!)
- Only your unique package (randomwalk) is actually downloaded from `johngavin` cache
- Automatic GC cleans up duplicate dependencies when storage limit reached
- Your packages are **pinned** (protected from GC) by `push_to_cachix.sh`

**See**: `docs/CACHIX_WORKFLOW.md` for detailed explanation

---

## Next Steps

1. ✅ Setup complete? Test the workflow with a small change
2. 📖 Read [NIX_WORKFLOW.md](NIX_WORKFLOW.md) for detailed explanations
3. 📚 Bookmark [rix documentation](https://docs.ropensci.org/rix/)
4. 🔧 Customize workflow as needed (but maintain reproducibility!)

---

**Last updated**: December 2025
**Version**: 1.0
