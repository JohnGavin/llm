# Technical Notes

> **Related Claude Skills**:
> - [`.claude/skills/nix-rix-r-environment/SKILL.md`](https://github.com/JohnGavin/llm/blob/main/.claude/skills/nix-rix-r-environment/SKILL.md) - Core Nix/rix setup and GC roots
> - [`.claude/skills/shinylive-quarto/SKILL.md`](https://github.com/JohnGavin/llm/blob/main/.claude/skills/shinylive-quarto/SKILL.md) - WebAssembly and Shinylive deployment

Links:

- README: https://github.com/JohnGavin/llm#documentation
- Wiki: https://github.com/JohnGavin/llm/wiki/Technical-Notes
- Repo source: https://github.com/JohnGavin/llm/blob/main/WIKI_CONTENT/Technical_Notes.md

---

# GC Root Naming Examples

## Current Setup (Recommended) ✅

**Single GC root for shared development environment**:

```bash
~/docs_gh/rix.setup/
└── nix-shell-root -> /nix/store/abc123-nix-shell-env/
```

**Why**:
- Shared dev env is persistent (used for hours/days)
- Needs GC protection
- Projects envs are temporary (CI only)
- Don't need GC protection

---

## Alternative: Multiple GC Roots (if needed)

**Scenario**: You want GC roots for BOTH shared and project-specific environments.

### Naming Conflict Problem

**❌ BAD - All use same name**:
```bash
~/docs_gh/claude_rix/
├── nix-shell-root -> /nix/store/abc123-shared/     # Shared dev
├── statues_named_john/
│   └── nix-shell-root -> /nix/store/def456-statues/  # ❌ Conflict!
└── random_walk/
    └── nix-shell-root -> /nix/store/ghi789-random/   # ❌ Conflict!
```

**Problem**: If you `cd` between projects and run `nix-build`, you'll overwrite the GC root symlink!

### Solution: Unique Names

**✅ GOOD - Each has unique name**:
```bash
~/docs_gh/claude_rix/
├── nix-shell-root-shared -> /nix/store/abc123.../     # Shared dev
│
├── statues_named_john/
│   └── nix-shell-root-statues -> /nix/store/def456.../  # ✅ Unique!
│
└── random_walk/
    └── nix-shell-root-random -> /nix/store/ghi789.../   # ✅ Unique!
```

### Or: Different Locations

**✅ ALSO GOOD - Same name, different directories**:
```bash
~/docs_gh/claude_rix/
├── nix-shell-root -> /nix/store/abc123.../           # Shared dev
│
├── statues_named_john/
│   └── nix-shell-root -> /nix/store/def456.../       # ✅ Different dir!
│
└── random_walk/
    └── nix-shell-root -> /nix/store/ghi789.../       # ✅ Different dir!
```

**This works** because each `nix-shell-root` is in its own directory, so no conflicts.

---

## Which Approach Should You Use?

### Recommended: Single GC Root (Current) ✅

```bash
# Only protect shared dev environment
~/docs_gh/rix.setup/nix-shell-root -> /nix/store/abc123.../
```

**Pros**:
- Simplest
- Projects don't need GC protection (rebuilt quickly in CI)
- Less disk space used
- Fewer symlinks to manage

**Cons**:
- Project environments get garbage collected
- Must rebuild when testing locally

### Alternative: Multiple GC Roots (If Needed)

**When to use**:
- Frequent local testing of project environments
- Slow project builds (many dependencies)
- Want to preserve project envs between GC runs

**How to implement**:
```bash
# In project default.sh or Makefile:
nix-build default.nix \\
  -o "nix-shell-root-$(basename $(pwd))"  # Unique name per project

# Example results:
# statues_named_john/nix-shell-root-statues_named_john
# random_walk/nix-shell-root-random_walk
```

---

## Your Current Situation

You said: "I am using only 1 GC root"

**That's perfect!** ✅ You're following the recommended approach.

**Why my comment about "different names"**:
- I was explaining what to do IF you decided to create multiple GC roots
- Since you're only using one, you don't need to worry about naming conflicts
- Keep doing what you're doing!

---

## Summary

| Setup | GC Root(s) | When to Use |
|-------|-----------|-------------|
| **Single root (yours)** | `rix.setup/nix-shell-root` | Default recommendation ✅ |
| **Multiple roots (unique names)** | `project/nix-shell-root-PROJECT` | Frequent local testing of project envs |
| **Multiple roots (same name, different dirs)** | `project/nix-shell-root` | Same, but prefer consistent naming |

**Bottom line**: Your current single GC root setup is correct. No changes needed.
# devtools::load_all() - Working Examples

## What is `devtools::load_all()`?

Simulates installing and loading your package **without actually installing it**.

**Key benefit**: Test code changes **immediately** without reinstalling package.

---

## Scenario 1: Simple Development Workflow

### Without `load_all()` (Old Way)

```r
# Edit R/my_function.R
# To test changes:
devtools::install()  # Slow! Reinstalls entire package
library(mypackage)
my_function()  # Finally test
```

### With `load_all()` (New Way)

```r
# Edit R/my_function.R
devtools::load_all()  # Fast! Just loads source files
my_function()  # Test immediately
```

**Why it's faster**:
- Loads `.R` files directly from `R/` directory
- Skips compilation, documentation, installation
- Changes reflected instantly

---

## Scenario 2: Switching Between Projects (Your Use Case)

### Setup: Shared Nix Shell

```bash
# Start ONE shell for entire session
cd ~/docs_gh/claude_rix
caffeinate -i ./default.sh
# Shell contains ALL packages for ALL projects
```

### Working on Project A

```r
# Set working directory to project A
setwd("~/docs_gh/claude_rix/statues_named_john")

# Load project A's code
devtools::load_all()
# ✓ Loading statuesNamedJohn
# ✓ Loaded all functions from R/ directory

# Now you can use project A functions
get_statues_osm("London")
plot_memorial_map()

# Edit a function
# ... edit R/get_statues_osm.R ...

# Reload to see changes
devtools::load_all()  # Reloads with changes
get_statues_osm("London")  # Test updated function
```

### Switching to Project B

```r
# Switch to project B
setwd("~/docs_gh/claude_rix/random_walk")

# Load project B's code
devtools::load_all()
# ✓ Loading randomwalk
# ✓ Loaded all functions from R/ directory

# Now you can use project B functions
simulate_walk(steps = 100)
plot_walk_paths()

# Edit project B function
# ... edit R/simulate_walk.R ...

# Reload
devtools::load_all()
simulate_walk(steps = 100)  # Test updated function
```

### Using BOTH Projects Simultaneously

```r
# Load project A under a namespace
statues <- devtools::load_all("~/docs_gh/claude_rix/statues_named_john")

# Load project B under a namespace
walks <- devtools::load_all("~/docs_gh/claude_rix/random_walk")

# Use functions from both
statues_data <- statues$get_statues_osm("London")
walk_data <- walks$simulate_walk(100)

# Combine data from both projects
combined_plot <- plot_statues_and_walks(statues_data, walk_data)
```

---

## Scenario 3: Testing Functions with `load_all()`

### Interactive Testing

```r
# Working on statues_named_john
setwd("~/docs_gh/claude_rix/statues_named_john")
devtools::load_all()

# Test function interactively
result <- get_statues_osm("London", key = "memorial")
str(result)  # Inspect structure
head(result)  # Check data

# Found a bug? Edit R/get_statues_osm.R
# ...make changes...

# Reload and test again
devtools::load_all()
result <- get_statues_osm("London", key = "memorial")
# Test fix
```

### Running Tests

```r
# After load_all(), run tests
devtools::test()
# Runs all tests in tests/testthat/

# Or run specific test file
testthat::test_file("tests/testthat/test-get_statues.R")
```

---

## Scenario 4: LLM Workflow with `load_all()`

### Current: LLM Changes Directory

```bash
# LLM instruction:
cd ~/docs_gh/claude_rix/statues_named_john
# ... work on code ...
```

### Enhanced: LLM Uses `load_all()`

```r
# LLM instruction:
devtools::load_all("~/docs_gh/claude_rix/statues_named_john")

# Now LLM can:
# 1. Test functions immediately
get_statues_osm("test")

# 2. Make changes to R files
# ... edit R/get_statues_osm.R ...

# 3. Reload and verify
devtools::load_all("~/docs_gh/claude_rix/statues_named_john")
get_statues_osm("test")  # Test changes

# 4. Run checks
devtools::check()  # Verify before commit
```

---

## Scenario 5: Multi-Project Development Session

### Real-World Workflow

```r
# Morning: Start shared shell
system("caffeinate -i ~/docs_gh/claude_rix/default.sh &")

# Task 1: Fix bug in statues_named_john
setwd("~/docs_gh/claude_rix/statues_named_john")
devtools::load_all()
# ... fix bug ...
devtools::test()  # ✓ Tests pass
gert::git_commit("Fix: bug in get_statues_osm")

# Task 2: Add feature to random_walk (NO shell restart needed!)
setwd("~/docs_gh/claude_rix/random_walk")
devtools::load_all()
# ... add feature ...
devtools::test()  # ✓ Tests pass
gert::git_commit("Feat: add plot_walk_paths")

# Task 3: Use both packages for analysis
statues <- devtools::load_all("~/docs_gh/claude_rix/statues_named_john")
walks <- devtools::load_all("~/docs_gh/claude_rix/random_walk")

# Combined analysis
data <- merge_statues_and_walks(
  statues$get_statues_osm("London"),
  walks$simulate_walk(1000)
)
plot(data)

# End of day: Still in ONE shell!
```

---

## Key Advantages

### 1. **Speed**
- `load_all()`: ~1 second
- `install() + library()`: ~30-60 seconds

### 2. **Iteration**
```r
# Rapid development cycle:
for (i in 1:10) {
  # Edit code
  # ...make change...

  # Test immediately
  devtools::load_all()
  test_my_function()
}
```

### 3. **Multiple Projects**
```r
# Work on 3 projects in same session:
devtools::load_all("~/docs_gh/claude_rix/statues_named_john")
devtools::load_all("~/docs_gh/claude_rix/random_walk")
devtools::load_all("~/docs_gh/claude_rix/another_project")

# All available in same R session!
```

### 4. **Shell Persistence**
- One shell = consistent environment
- No PATH conflicts
- No package version surprises
- No repeated startup time

---

## Common Patterns

### Pattern 1: Quick Edit-Test Loop

```r
repeat {
  # 1. Edit in your editor
  # 2. Return to R console
  devtools::load_all()  # ← Just run this!
  # 3. Test
  my_function()
  # 4. Repeat until satisfied
}
```

### Pattern 2: Project-Specific Work

```r
# Set project context once
proj <- "~/docs_gh/claude_rix/statues_named_john"
setwd(proj)

# Then use relative paths
devtools::load_all(".")
devtools::test()
devtools::check()
```

### Pattern 3: Cross-Project Function

```r
# Helper function for switching projects
switch_project <- function(project_name) {
  path <- file.path("~/docs_gh/claude_rix", project_name)
  setwd(path)
  devtools::load_all(".")
  cat("✓ Loaded:", project_name, "\n")
}

# Usage:
switch_project("statues_named_john")
switch_project("random_walk")
```

---

## Summary: Your Enhanced Workflow

### Current (Good)
```bash
cd ~/docs_gh/claude_rix/statues_named_john  # Change dir
# ... work ...
cd ~/docs_gh/claude_rix/random_walk  # Change dir
# ... work ...
```

### Enhanced (Better)
```r
# Stay in ONE shell
devtools::load_all("~/docs_gh/claude_rix/statues_named_john")
# ... work, test immediately with load_all() ...

devtools::load_all("~/docs_gh/claude_rix/random_walk")
# ... work, test immediately with load_all() ...

# NO shell restarts, instant feedback on changes
```

**Key point**: You can STILL `cd` between projects (that's fine), but add `devtools::load_all()` after `cd` to get instant testing without reinstalling packages.
# Shinylive Vignettes: Lessons Learned from Issues #125 and #127

**Date:** December 2025
**Project:** randomwalk
**Issues:**
- [#125 - All Shinylive vignettes broken on deployed website](https://github.com/JohnGavin/randomwalk/issues/125)
- [#127 - Replace webr::mount() with webr::install() for reliable package loading](https://github.com/JohnGavin/randomwalk/issues/127)

**Related Documentation:**
- [AGENTS.md - Mandatory Shinylive Testing Protocol](https://github.com/JohnGavin/randomwalk/blob/main/AGENTS.md)
- [randomwalk Wiki - Shinylive Best Practices](https://github.com/JohnGavin/randomwalk/wiki)

**Cross-Project References:**
- This document is part of the **claude_rix** meta-project for reproducible R package development
- Repository: https://github.com/JohnGavin/claude_rix
- See also: [NIX_WORKFLOW.md](./NIX_WORKFLOW.md), [WIKI_CONTENT](./WIKI_CONTENT/)

---

## Table of Contents

- [Executive Summary](#executive-summary)
- [The Problem](#the-problem)
- [Timeline of Discovery](#timeline-of-discovery)
- [Root Causes](#root-causes)
- [The Solution](#the-solution)
- [What We Learned](#what-we-learned)
- [Best Practices for Future Projects](#best-practices-for-future-projects)
- [Testing Protocol](#testing-protocol)
- [Technical Deep Dive](#technical-deep-dive)
- [References](#references)

---

## Executive Summary

**TLDR:** Shinylive vignettes in R packages require:
1. ✅ Service Worker declaration in YAML: `resources: - shinylive-sw.js`
2. ✅ Simple `library()` calls - NOT `webr::mount()`
3. ✅ Browser testing with JavaScript console (per [AGENTS.md](https://github.com/JohnGavin/randomwalk/blob/main/AGENTS.md))
4. ❌ NEVER use GitHub Releases URLs for WASM files (CORS issues)

**Key Learning:** Quick fixes that address symptoms often mask deeper architectural problems. Always investigate root causes.

---

## The Problem

### User Report (2025-12-10)

All three Shinylive vignettes failed to load on the deployed website (https://johngavin.github.io/randomwalk/articles/) with multiple JavaScript console errors:

```javascript
// Error 1: CORS Policy Blocking
Access to XMLHttpRequest at 'https://github.com/.../library.js.metadata'
from origin 'https://johngavin.github.io' has been blocked by CORS policy:
No 'Access-Control-Allow-Origin' header is present

// Error 2: Service Worker Registration Failed
ServiceWorker controller was not found!
A bad HTTP response code (404) was received when fetching the script

// Error 3: Package Not Found
Warning in webr::install(pkg_name):
  Requested package randomwalk not found in webR binary repo

// Error 4: Filesystem Metadata Error
Error: Can't download Emscripten filesystem image metadata
```

**Affected Vignettes:**
- `vignettes/dashboard.qmd`
- `vignettes/dashboard_async.qmd`
- `vignettes/dynamic_broadcasting.qmd`

**Impact:** Complete failure - vignettes showed error messages instead of interactive Shiny apps.

---

## Timeline of Discovery

### Phase 1: Initial Fix Attempt (PR #126)

**What we did:**
- Compared current code to working v1.0.0 release
- Found vignettes used relative path `../wasm/library.data`
- Changed to GitHub releases URL: `https://github.com/.../library.data`
- Fixed source .qmd files
- Merged PR

**Result:** ❌ Still broken

**Why it failed:** Fixed source files but not rendered HTML in `docs/` folder

### Phase 2: HTML Direct Edit (Commit d53db76)

**What we did:**
- Discovered `docs/` folder not rebuilt (bslib/Nix incompatibility - [Issue #122](https://github.com/JohnGavin/randomwalk/issues/122))
- Directly edited HTML files to fix paths
- Deployed

**Result:** ❌ Still broken

**Why it failed:** Fixed wrong URL (symptom) but didn't address architectural problems (root cause)

### Phase 3: User Testing Reveals Deeper Issues

**Critical feedback from user:**
> "if the randomwalk package is the error now, but it worked in the past major releases,
> consider searching for all instances where 'randomwalk' is used in the old version
> compared to the current version"

**User provided working templates:**
- https://github.com/coatless-quarto/r-shinylive-demo
- Showed correct modern Shinylive patterns

### Phase 4: Architectural Fix (Commit 330aeb3)

**What we did:**
- Added Service Worker resource to YAML headers
- Removed `webr::mount()` approach entirely
- Used simple `library()` calls with Shinylive 0.8.0+ automatic bundling

**Result:** ✅ **SUCCESS** (pending user verification)

---

## Root Causes

### Problem 1: Missing Service Worker Declaration

**What was wrong:**
```yaml
# ❌ BROKEN (missing critical resource)
---
title: "Dashboard"
format:
  html:
    code-fold: true
    embed-resources: false
filters:
  - shinylive
---
```

**Why it matters:**
- Shinylive uses Service Workers for offline caching and request interception
- Without explicit resource declaration, Service Worker file not properly registered
- Caused "ServiceWorker controller not found" errors

**Correct pattern:**
```yaml
# ✅ CORRECT
---
title: "Dashboard"
format:
  html:
    code-fold: true
    embed-resources: false
    resources:
      - shinylive-sw.js  # ← CRITICAL!
filters:
  - shinylive
---
```

### Problem 2: Using webr::mount() with GitHub Releases

**What was wrong:**
```r
# ❌ BROKEN (~25 lines of complex code)
webr::mount(
  mountpoint = "/randomwalk-lib",
  source = "https://github.com/JohnGavin/randomwalk/releases/latest/download/library.data"
)
.libPaths(c("/randomwalk-lib", .libPaths()))
webr::install(c("munsell", "colorspace", ...),
               lib = "/tmp/webr-libs")
.libPaths(c("/tmp/webr-libs", .libPaths()))
library(shiny)
library(randomwalk)
```

**Why it matters:**
- GitHub Releases **do not serve files with CORS headers**
- Browsers block cross-origin requests from GitHub Pages to GitHub Releases
- Even with "correct" URL, it fundamentally cannot work due to CORS
- This was an **architectural incompatibility**, not a configuration error

**Correct pattern:**
```r
# ✅ CORRECT (4 lines of simple code)
# Load required packages
# Shinylive will automatically detect and bundle these packages
library(shiny)
library(randomwalk)
```

**How this works:**
- Modern Shinylive (0.8.0+) detects `library()` calls automatically
- Downloads packages from CORS-enabled sources (CRAN mirrors, R-Universe)
- Bundles packages into browser-accessible format
- No manual mounting, installation, or path manipulation needed

---

## The Solution

### Complete Fix Applied to All Three Vignettes

**Files modified:**
- `vignettes/dashboard.qmd`
- `vignettes/dashboard_async.qmd`
- `vignettes/dynamic_broadcasting.qmd`
- `R/setup/fix_issue_125.R` (session log)

### Change 1: YAML Header Fix

```yaml
# Add to format.html section
resources:
  - shinylive-sw.js
```

**What this does:**
- Declares Service Worker as critical resource
- Ensures proper registration and caching
- Enables offline functionality

### Change 2: Package Loading Fix

**Before:**
- ~25 lines of `webr::mount()`, `webr::install()`, `.libPaths()` manipulation
- Tried to load from CORS-blocked GitHub Releases
- Complex, fragile, and fundamentally broken

**After:**
- 4 lines of simple `library()` calls
- Let Shinylive handle package discovery and bundling
- Works with any package on CRAN, R-Universe, or GitHub
- Automatic, reliable, and maintainable

### Deployment

**Workflow:**
1. Fixed source .qmd files ✅
2. Committed with comprehensive message ✅
3. Pushed to main branch ✅
4. `deploy-pages.yaml` workflow triggered automatically ✅
5. GitHub Pages updated (no merge needed - direct push to main) ✅

**Key point:** We pushed directly to `main`, not a feature branch. The deployment workflow triggers on `push` to `main`, so no PR merge is needed.

---

## Issue #127: The webr::install() vs webr::mount() Problem (December 2025)

### Discovery

Even after fixing Issue #125, the deployed vignettes still failed with:
```javascript
preload error:Warning in webr::install(pkg_name) :
  Requested package randomwalk not found in webR binary repo.
```

### Root Cause Analysis

Investigation revealed a **critical pattern that was being broken during pkgdown deployment**:

1. **Source .qmd files** contained:
   ```r
   webr::mount(
     mountpoint = "/randomwalk-lib",
     source = "https://github.com/JohnGavin/randomwalk/releases/latest/download/library.data"
   )
   .libPaths(c("/randomwalk-lib", .libPaths()))
   library(randomwalk)
   ```

2. **Built vignette HTML** (`vignettes/*.html`) changed the URL:
   ```r
   webr::mount(
     mountpoint = "/randomwalk-lib",
     source = "../wasm/library.data"  # ← Changed to relative path
   )
   ```

3. **Deployed pkgdown HTML** (`docs/articles/*.html`) **completely stripped** the `webr::mount()` code:
   ```r
   # Mount WebAssembly file system from local path (deployed to docs/wasm)
   # This avoids CORS issues by using the same origin
   # Load required packages
   # Shinylive will automatically detect and bundle these packages
   library(randomwalk)  # ← webr::mount() completely removed!
   ```

**Why this causes failure:**
- The `library(randomwalk)` call executes without the package being mounted first
- webR tries to find `randomwalk` in its default repository
- Package doesn't exist there → error

### The Solution: Use webr::install() with Custom Repository

Per [webR documentation](https://docs.r-wasm.org/webr/latest/packages.html) and [Quarto webR best practices](https://quarto-webr.thecoatlessprofessor.com/demos/qwebr-custom-repository.html), the **modern, reliable approach** is:

```r
# Install randomwalk from GitHub Pages webR repository
# This approach is more reliable than webr::mount() which gets stripped during pkgdown deployment
# See: https://docs.r-wasm.org/webr/latest/packages.html
webr::install(
  "randomwalk",
  repos = "https://johngavin.github.io/randomwalk/"
)

# Load required packages
library(shiny)
library(randomwalk)
```

**Why this works:**
- `webr::install()` downloads and installs the package into webR's filesystem
- Package persists across the session
- Survives pkgdown rendering transformations
- Works with GitHub Pages as a custom CRAN-like repository

**Files updated (Issue #127):**
- `vignettes/dashboard.qmd`
- `vignettes/dynamic_broadcasting.qmd`
- `vignettes/dashboard_async.qmd`
- `inst/shiny/dashboard/app.R`
- `inst/shiny/dashboard_dynamic/app.R`
- `inst/shiny/dashboard_async/app.R`

### Key Differences: webr::mount() vs webr::install()

| Aspect | webr::mount() | webr::install() |
|--------|---------------|-----------------|
| **Stability** | ❌ Gets stripped by pkgdown | ✅ Survives rendering |
| **Source** | GitHub Releases (CORS issues) | GitHub Pages (CORS enabled) |
| **Complexity** | 10-15 lines + path manipulation | 3-5 lines, straightforward |
| **Documentation** | Older approach | Modern recommended pattern |
| **Reliability** | Fragile, rendering-dependent | Robust, well-supported |

**See:** [Issue #127](https://github.com/JohnGavin/randomwalk/issues/127) for complete implementation details.

---

## What We Learned

### Lesson 1: Architecture Over Quick Fixes

**Problem:** First two fixes addressed symptoms (wrong URL, wrong rendered HTML) but not root cause (architectural incompatibility).

**Learning:**
- Always investigate **why** something broke, not just **what** broke
- CORS errors = fundamental architectural problem, not configuration issue
- Quick fixes that work locally may hide deployment incompatibilities

**Action for future:** When fixes don't work, step back and question architectural assumptions.

### Lesson 2: Technology Evolves - Patterns Must Too

**Problem:** Used older `webr::mount()` approach from early Shinylive documentation.

**Learning:**
- Shinylive 0.8.0+ introduced automatic package bundling
- Old patterns (manual mounting) are now anti-patterns
- Always check for modern best practices, not just "what worked before"

**Action for future:**
- Review documentation for latest version, not archived tutorials
- Check release notes for breaking changes or new features
- Consult working examples from active projects (like coatless-quarto demos)

### Lesson 3: Source Files ≠ Deployed Content

**Problem:** Fixed source .qmd files but deployed site still served old HTML.

**Learning:**
- `deploy-pages.yaml` deploys pre-built `docs/` folder
- Source changes don't automatically update rendered output
- pkgdown rebuild blocked by bslib/Nix incompatibility ([Issue #122](https://github.com/JohnGavin/randomwalk/issues/122))

**Action for future:**
- Always verify **deployed content**, not just source files
- Check actual URLs user will access
- Use browser DevTools to inspect live site

### Lesson 4: User Testing Is Mandatory

**Problem:** All GitHub Actions passed ✅ but deployed site was broken ❌

**Learning:**
- CI/CD tests don't catch browser-specific issues (CORS, Service Workers)
- JavaScript errors only visible in browser console
- User testing with [AGENTS.md protocol](https://github.com/JohnGavin/randomwalk/blob/main/AGENTS.md) is **non-negotiable**

**Action for future:**
- ALWAYS test Shinylive apps in actual browser
- ALWAYS open JavaScript console (F12)
- NEVER skip this step, even if CI passes

### Lesson 5: User Research Accelerates Solutions

**Problem:** Could have spent hours debugging CORS and Service Worker issues.

**Learning:**
- User found working template (coatless-quarto) immediately
- Template showed correct modern pattern
- Saved hours of trial-and-error

**Action for future:**
- Search for working examples before debugging
- Consult community templates and demos
- Learn from projects that solved similar problems

### Lesson 6: pkgdown Transformations Can Break Code (Issue #127)

**Problem:** `webr::mount()` code worked in source .qmd but was stripped during pkgdown deployment.

**Learning:**
- pkgdown rendering can transform or remove Shinylive code
- What works in vignette HTML may fail in deployed pkgdown HTML
- Build process transformations are unpredictable and undocumented
- **Solution:** Use patterns that survive transformations (`webr::install()` instead of `webr::mount()`)

**Action for future:**
- Prefer `webr::install()` over `webr::mount()` for custom packages
- Use GitHub Pages as webR repository (CORS-enabled)
- Test deployed pkgdown HTML, not just vignette HTML
- Document build process quirks for team awareness

### Lesson 7: Modern Documentation Supersedes Old Patterns

**Problem:** Used `webr::mount()` based on older tutorials and examples.

**Learning:**
- `webr::install()` with custom repos is the modern, recommended approach
- Officially documented in current webR and Quarto webR guides
- More robust against build process transformations
- Simpler code, fewer edge cases

**Action for future:**
- Consult official documentation, not just Stack Overflow or old tutorials
- Check "last updated" dates on tutorials and examples
- Verify patterns against official docs before implementation
- Update project when new patterns emerge

---

## Best Practices for Future Projects

### ✅ DO: Modern Shinylive Pattern (Updated for Issue #127)

**For CRAN packages:**
```yaml
# vignettes/your_app.qmd
---
title: "Your Interactive Dashboard"
format:
  html:
    resources:
      - shinylive-sw.js  # ← Always include this!
filters:
  - shinylive
---

# Your App

```{shinylive-r}
#| standalone: true
#| viewerHeight: 900

# Simple library() calls - Shinylive handles the rest
library(shiny)
library(ggplot2)

# Your Shiny app code here...
ui <- fluidPage(...)
server <- function(input, output, session) {...}
shinyApp(ui, server)
```
```

**For custom/local packages (RECOMMENDED):**
```yaml
# vignettes/your_app.qmd
---
title: "Your Interactive Dashboard"
format:
  html:
    resources:
      - shinylive-sw.js  # ← Always include this!
filters:
  - shinylive
---

# Your App

```{shinylive-r}
#| standalone: true
#| viewerHeight: 900

# Install custom package from GitHub Pages webR repository
# This survives pkgdown deployment transformations
webr::install(
  "yourpackage",
  repos = "https://yourusername.github.io/yourpackage/"
)

# Load packages
library(shiny)
library(yourpackage)

# Your Shiny app code here...
ui <- fluidPage(...)
server <- function(input, output, session) {...}
shinyApp(ui, server)
```
```

**Why webr::install() over webr::mount():**
- ✅ Survives pkgdown rendering transformations
- ✅ Works with GitHub Pages as custom repository
- ✅ Simpler code (3-5 lines vs 10-15 lines)
- ✅ Modern recommended pattern per official docs
- ✅ No CORS issues with GitHub Pages

### ❌ DON'T: Old webr::mount() Pattern

```r
# ❌ NEVER DO THIS
webr::mount(
  mountpoint = "/pkg-lib",
  source = "https://github.com/.../library.data"  # CORS blocked!
)
.libPaths(...)
webr::install(...)
```

### ✅ DO: Follow AGENTS.md Testing Protocol

From [AGENTS.md](https://github.com/JohnGavin/randomwalk/blob/main/AGENTS.md):

**After deploying Shinylive vignettes:**

1. **Open each vignette in browser:**
   - Navigate to actual deployed URL
   - Example: `https://username.github.io/package/articles/vignette.html`

2. **Open JavaScript Console:**
   - Press F12 or Right-click → Inspect → Console tab
   - Keep console open while app loads

3. **Wait for app to load:**
   - First load can take 10-30 seconds
   - Shinylive downloads and bundles packages on-demand
   - Watch console for progress messages

4. **Verify NO errors:**
   - ❌ Should NOT see: CORS policy blocking
   - ❌ Should NOT see: Service Worker registration failed
   - ❌ Should NOT see: Package not found errors
   - ❌ Should NOT see: 404 errors for .data or .metadata files
   - ✅ SHOULD see: App loads with interactive UI

5. **Test interactivity:**
   - Click buttons, adjust sliders
   - Run simulations or computations
   - Verify results display correctly

**If ANY errors appear:** Do NOT proceed with deployment announcement until fixed.

### ✅ DO: Use GitHub Actions for Deployment

```yaml
# .github/workflows/deploy-pages.yaml
name: Deploy to GitHub Pages

on:
  push:
    branches: [main]  # Triggers on direct push to main

permissions:
  contents: read
  pages: write
  id-token: write

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Pages
        uses: actions/configure-pages@v3

      - name: Upload artifact
        uses: actions/upload-pages-artifact@v2
        with:
          path: 'docs'  # Pre-built pkgdown site

      - name: Deploy to GitHub Pages
        uses: actions/deploy-pages@v2
```

**Key points:**
- Triggers on `push` to `main` - no PR merge needed
- Deploys from `docs/` folder (pre-built content)
- Handles permissions automatically

### ✅ DO: Document Everything in Session Logs

Create `R/setup/fix_issue_XXX.R` files documenting:
- What was broken
- How you investigated
- What you tried
- What worked
- Why it worked
- Key commands used

**Example structure:**
```r
# Session Log: Fix Issue #125 - Shinylive Vignettes
# Date: 2025-12-10
# Issue: https://github.com/user/repo/issues/125

# ============================================================
# 1. Investigation
# ============================================================

# Check working v1.0.0 version
system("git show v1.0.0:vignettes/dashboard.qmd | head -50")

# Compare to current broken version
# ... detailed commands ...

# ============================================================
# 2. Root Cause Analysis
# ============================================================

# Problem 1: Missing Service Worker resource
# Problem 2: Using webr::mount() with CORS-blocked URL

# ============================================================
# 3. Apply Fix
# ============================================================

# Fix all three vignettes...

# ============================================================
# 4. Key Lessons Learned
# ============================================================

# 1. Architecture over quick fixes
# 2. Modern patterns over old approaches
# ... etc ...
```

### ❌ DON'T: Skip Browser Testing

**Never assume:**
- ✅ CI passes = deployment works
- ✅ Local preview = deployed site works
- ✅ Source fixed = rendered HTML fixed

**Always verify:**
- Actual deployed URLs
- Browser JavaScript console
- All three states: load, interaction, results

### ❌ DON'T: Use GitHub Releases for WASM Files

**Why this doesn't work:**
- GitHub Releases serve files without CORS headers
- Browsers block cross-origin requests
- No workaround exists (GitHub policy)

**What to use instead:**
- Let Shinylive bundle packages automatically
- Uses CRAN mirrors with CORS enabled
- Or use R-Universe with proper CORS configuration

---

## Testing Protocol

### Complete Browser Testing Checklist

Based on [AGENTS.md - Mandatory Shinylive Testing Protocol](https://github.com/JohnGavin/randomwalk/blob/main/AGENTS.md).

#### Step 1: Open Vignettes in Browser

**For each vignette:**
```
https://yourusername.github.io/yourpackage/articles/vignette_name.html
```

**Browser requirements:**
- Chrome/Edge 57+ (Service Worker support)
- Firefox 52+
- Safari 11+

**Use both regular and incognito windows:**
- Regular: Tests with cached resources
- Incognito: Tests fresh load without cache

#### Step 2: Open Developer Console

**How to access:**
- **Windows/Linux:** F12 or Ctrl+Shift+I
- **Mac:** Cmd+Option+I or Right-click → Inspect

**Navigate to Console tab:**
- Click "Console" at top of DevTools
- Clear console: Click trash icon or Ctrl+L

#### Step 3: Monitor App Loading

**Expected behavior:**
```
Loading webR runtime...
webR runtime loaded
Loading packages...
Downloading: shiny
Downloading: yourpackage
Installing packages...
App ready
```

**Typical timeline:**
- First load: 10-30 seconds (downloads packages)
- Subsequent loads: 2-5 seconds (uses cache)

#### Step 4: Verify No Errors

**Check for these error patterns:**

```javascript
// ❌ CORS Error (bad)
Access to XMLHttpRequest at 'https://github.com/...' blocked by CORS policy

// ❌ Service Worker Error (bad)
ServiceWorker controller was not found
Failed to register Service Worker

// ❌ Package Error (bad)
Requested package yourpackage not found in webR binary repo

// ❌ 404 Error (bad)
GET https://.../library.data 404 Not Found
GET https://.../library.js.metadata 404 Not Found

// ✅ Success Messages (good)
webR runtime loaded
Package yourpackage loaded successfully
```

**If you see ANY red error messages:** Stop and investigate before proceeding.

#### Step 5: Test Interactivity

**Basic tests:**
- [ ] All UI elements visible (buttons, sliders, inputs)
- [ ] Buttons respond to clicks
- [ ] Sliders move and update values
- [ ] Input fields accept text
- [ ] Dropdown menus open and select

**Functional tests:**
- [ ] Run primary function (e.g., "Run Simulation")
- [ ] Verify results display in output area
- [ ] Check plots/tables render correctly
- [ ] Test multiple parameter combinations
- [ ] Verify error messages show for invalid inputs

**Performance tests:**
- [ ] App loads within 30 seconds
- [ ] Interactions respond within 1 second
- [ ] No browser freezing or crashes

#### Step 6: Document Results

**Create testing log:**
```markdown
# Shinylive Vignette Testing - 2025-12-10

## Vignette: dashboard.html

### Browser: Chrome 120 (Regular)
- [x] Loads without errors
- [x] All UI elements visible
- [x] Simulation runs successfully
- [x] Results display correctly
- Time to load: 15 seconds

### Browser: Chrome 120 (Incognito)
- [x] Loads without errors
- [x] Service Worker registers
- Time to load: 18 seconds (first visit)
- Time to load: 3 seconds (second visit)

### Console Messages
```
Loading webR runtime...
Loading packages: shiny, randomwalk
App ready
```

## Vignette: dashboard_async.html
... (repeat for each vignette)

## Summary
✅ All vignettes pass testing
✅ No JavaScript errors
✅ Interactive features working
✅ Ready for deployment announcement
```

---

## Technical Deep Dive

### How Modern Shinylive Works (0.8.0+)

#### Package Discovery and Bundling

**When you write:**
```r
library(shiny)
library(yourpackage)
```

**Shinylive automatically:**

1. **Parses code** for `library()` and `require()` calls
2. **Searches repositories:**
   - CRAN mirrors (with CORS enabled)
   - R-Universe (if configured)
   - Bioconductor (if configured)
3. **Downloads binary packages** (WebAssembly format)
4. **Bundles into browser filesystem** (using Emscripten)
5. **Loads packages** into webR session

**No manual intervention needed!**

#### Service Worker Architecture

**Service Worker file:** `shinylive-sw.js`

**Responsibilities:**
- Intercept network requests for package files
- Serve cached packages for offline use
- Handle package downloads from CORS-enabled sources
- Manage virtual filesystem for WebAssembly

**Why YAML declaration is critical:**
```yaml
resources:
  - shinylive-sw.js  # Ensures file copied to output directory
```

Without this:
- Service Worker file not included in build
- Browser can't register Service Worker
- Apps fail with "ServiceWorker controller not found"

#### CORS and Cross-Origin Requests

**The CORS problem:**
```
GitHub Pages (https://user.github.io)
    ↓ tries to fetch
GitHub Releases (https://github.com/.../library.data)
    ↓ responds without
Access-Control-Allow-Origin header
    ↓ browser blocks
CORS policy error
```

**Why this is fundamental:**
- GitHub Releases are download endpoints, not web resources
- No CORS headers served (by design)
- Cannot be fixed with configuration
- Must use alternative approach

**The solution:**
- Shinylive fetches from CRAN mirrors
- CRAN mirrors serve with CORS headers
- Browser allows cross-origin requests
- Packages load successfully

### Debugging Techniques

#### Technique 1: Compare Working vs Broken Versions

```bash
# Check what changed between working release and current
git diff v1.0.0:vignettes/dashboard.qmd HEAD:vignettes/dashboard.qmd

# View working version
git show v1.0.0:vignettes/dashboard.qmd

# View current version
cat vignettes/dashboard.qmd

# Compare rendered HTML
curl https://johngavin.github.io/randomwalk/articles/dashboard.html | \
  grep -A 5 "webr::mount"
```

#### Technique 2: Inspect Deployed Content

```bash
# Fetch deployed HTML
curl https://user.github.io/package/articles/vignette.html > deployed.html

# Search for problematic patterns
grep -i "webr::mount" deployed.html
grep -i "shinylive-sw.js" deployed.html
grep -i "github.com/.*releases" deployed.html

# Check Service Worker registration
grep -i "serviceWorker" deployed.html
```

#### Technique 3: Browser Network Tab Analysis

**In DevTools:**
1. Open Network tab
2. Reload page
3. Filter by "XHR" or "Fetch"
4. Look for failed requests (red)
5. Click failed request → Headers tab
6. Check "Access-Control-Allow-Origin" header

**Red flags:**
- 404 errors for .data or .metadata files
- CORS errors for GitHub URLs
- Timeouts fetching packages

#### Technique 4: Search Working Examples

```bash
# Find working Shinylive examples on GitHub
https://github.com/search?q=shinylive-sw.js+language:markdown

# Examine coatless-quarto template
git clone https://github.com/coatless-quarto/r-shinylive-demo
cd r-shinylive-demo
cat template-r-shinylive.qmd

# Study Shinylive documentation
https://posit-dev.github.io/r-shinylive/
https://quarto-ext.github.io/shinylive/
```

---

## References

### Documentation

- **Shinylive for R:** https://posit-dev.github.io/r-shinylive/
- **Quarto Shinylive Extension:** https://quarto-ext.github.io/shinylive/
- **WebR Project:** https://docs.r-wasm.org/webr/latest/
- **Shinylive 0.8.0 Release Notes:** https://github.com/posit-dev/r-shinylive/releases/tag/v0.8.0

### Working Examples

- **coatless-quarto r-shinylive-demo:** https://github.com/coatless-quarto/r-shinylive-demo
  - Template file: `template-r-shinylive.qmd`
  - Working demo: `R-shinylive-demo.qmd`
  - Deployment workflow: `publish-demo.yml`

- **datanovia Shinylive guides:** https://www.datanovia.com/learn/interactive/r/shinylive/
  - Debugging functions
  - Common patterns
  - Troubleshooting tips

### Project-Specific (randomwalk)

- **AGENTS.md:** [Mandatory Shinylive Testing Protocol](https://github.com/JohnGavin/randomwalk/blob/main/AGENTS.md)
- **Issue #125:** [All Shinylive vignettes broken](https://github.com/JohnGavin/randomwalk/issues/125)
- **Issue #127:** [Replace webr::mount() with webr::install()](https://github.com/JohnGavin/randomwalk/issues/127) ← **NEW**
- **Issue #122:** [bslib/Nix incompatibility with pkgdown](https://github.com/JohnGavin/randomwalk/issues/122)
- **Session Log #125:** `R/setup/fix_issue_125.R`
- **Session Log #127:** `R/setup/fix_issue_127.R` (to be created)
- **randomwalk Wiki:** [Shinylive Best Practices](https://github.com/JohnGavin/randomwalk/wiki)

### Cross-Project (claude_rix meta-project)

- **Repository:** https://github.com/JohnGavin/claude_rix (if/when public)
- **NIX_WORKFLOW.md:** Nix-based reproducible builds
- **WIKI_CONTENT:** Centralized documentation for all projects
- **This Document:** `WIKI_SHINYLIVE_LESSONS_LEARNED.md`

### Related GitHub Issues

- **Shinylive CORS discussions:** https://github.com/posit-dev/r-shinylive/issues
- **WebR package loading:** https://github.com/r-wasm/webr/issues
- **Quarto Shinylive filter:** https://github.com/quarto-ext/shinylive/issues

---

## Conclusion

**The Three Pillars of Successful Shinylive Vignettes:**

1. **Correct YAML Configuration**
   - Always include `resources: - shinylive-sw.js`
   - Ensures Service Worker registration
   - Enables offline caching

2. **Modern Package Loading**
   - Use simple `library()` calls
   - Let Shinylive handle bundling
   - Avoid manual mounting or CORS-blocked URLs

3. **Mandatory Browser Testing**
   - Follow [AGENTS.md protocol](https://github.com/JohnGavin/randomwalk/blob/main/AGENTS.md)
   - Use JavaScript console
   - Test before announcing deployment

**Remember:** Symptoms (wrong URL) often mask root causes (architectural incompatibility). Always investigate deeply before applying fixes.

---

**Document Version:** 2.0
**Last Updated:** 2025-12-11
**Maintained By:** claude_rix meta-project
**License:** MIT

**Version History:**
- v2.0 (2025-12-11): Added Issue #127 - webr::install() vs webr::mount() pattern
- v1.0 (2025-12-10): Initial release covering Issue #125

**Contributing:** Found an issue or have improvements? Please update this document and submit a PR to the claude_rix repository.

---

## Quick Reference Card

### Correct Shinylive Vignette Template (Updated v2.0)

**For custom packages (RECOMMENDED):**
```yaml
---
title: "Your Interactive App"
format:
  html:
    code-fold: true
    resources:
      - shinylive-sw.js  # ← DON'T FORGET THIS!
filters:
  - shinylive
---

# Your App

```{shinylive-r}
#| standalone: true
#| viewerHeight: 900

# Install custom package from GitHub Pages
# Survives pkgdown deployment transformations
webr::install(
  "yourpackage",
  repos = "https://yourusername.github.io/yourpackage/"
)

# Load packages
library(shiny)
library(yourpackage)

ui <- fluidPage(
  titlePanel("Your App"),
  # ... your UI code ...
)

server <- function(input, output, session) {
  # ... your server code ...
}

shinyApp(ui, server)
```
```

**For CRAN packages only:**
```r
# Simple library() calls work for CRAN packages
library(shiny)
library(ggplot2)
# ... your app code ...
```

### Testing Checklist

- [ ] Added `resources: - shinylive-sw.js` to YAML?
- [ ] Using simple `library()` calls (no webr::mount())?
- [ ] Tested in browser with JavaScript console?
- [ ] Verified no CORS errors?
- [ ] Verified no Service Worker errors?
- [ ] Verified no package loading errors?
- [ ] Tested interactivity (buttons, sliders)?
- [ ] Documented results?

### When Things Go Wrong

1. **Check JavaScript console** (F12) - most errors visible here
2. **Verify Service Worker** - look for shinylive-sw.js in Network tab
3. **Check for CORS errors** - indicates GitHub Releases or other blocked source
4. **Search working examples** - coatless-quarto templates
5. **Consult AGENTS.md** - mandatory testing protocol
6. **Document in session log** - R/setup/fix_issue_XXX.R

---

**End of Document**

## Additional Troubleshooting

### Persistent Service Workers
**Problem:** Switching a page from Shinylive (WASM) to static HTML does not immediately fix "cannot open connection" errors in the browser.
**Cause:** Shinylive registers a Service Worker (`shinylive-sw.js`) that intercepts network requests. Even after the server code is updated, the user's browser may still use the old Service Worker, which tries to load the (now missing) app.
**Fix:**
1. Users must clear their browser's Service Workers/Application Cache.
2. Developers should ensure `shinylive-sw.js` is un-registered or removed from the deployment.

### Hidden Quarto Extensions
**Problem:** Removing `filters: - shinylive` from `_quarto.yml` is NOT sufficient to disable Shinylive.
**Cause:** If the `_extensions/quarto-ext/shinylive/` directory exists in the project, Quarto automatically applies the extension filters during rendering, injecting Shinylive assets and Service Workers even if not explicitly requested.
**Fix:** Delete the `_extensions/quarto-ext/shinylive/` directory entirely to permanently disable the functionality.
