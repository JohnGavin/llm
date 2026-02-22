# Agent Guide for R Package Development

Essential rules for R package development with Nix, rix, and
reproducible workflows. For detailed guidance, invoke the relevant
skill.

## Session Start

``` bash
# Verify nix shell
echo $IN_NIX_SHELL  # Should be 1 or impure
which R             # Should be /nix/store/...
```

If not in nix: `caffeinate -i ~/docs_gh/rix.setup/default.sh`

Check: `.claude/CURRENT_WORK.md`, `git status`, open issues.

## Project-Specific Nix Environments (UPDATED)

**For each R package project**, create a project-specific Nix
environment with persistent GC root:

1.  **Create `default.R`** - Generates `default.nix` from DESCRIPTION:

    ``` r
    # Reads DESCRIPTION and creates default.nix with rix()
    source("default.R")
    ```

2.  **Create `default.sh`** with GC root - Fast, persistent Nix shell:

    ``` bash
    chmod +x default.sh
    ./default.sh  # First run: builds and creates nix-shell-root
    ./default.sh  # Subsequent runs: FAST (seconds, not minutes!)

    # To force rebuild:
    rm nix-shell-root && ./default.sh
    ```

3.  **Key Features**:

    - **Persistent GC root** (`nix-shell-root`) prevents garbage
      collection
    - **Fast subsequent runs** - packages cached in `/nix/store/`
    - All DESCRIPTION dependencies available
    - No missing package errors in Shiny apps
    - Reproducible across machines

4.  **Files created**:

        project/
        ├── default.R          # Generates default.nix from DESCRIPTION
        ├── default.sh         # Enters Nix shell with GC root
        ├── default.nix        # Generated Nix configuration
        └── nix-shell-root     # Symlink to /nix/store (GC protection)

5.  **CRITICAL: Always exclude Nix files from git and R builds**:

    **Add to `.gitignore`:**

        nix-shell-root

    **Add to `.Rbuildignore`:**

        ^nix-shell-root$
        ^default\.R$
        ^default\.nix$
        ^default\.sh$
        ^default-ci\.nix$

    Why: nix-shell-root is a symlink to /nix/store that doesn’t exist in
    CI/other machines

6.  **Testing examples in Nix**:

    ``` bash
    ./default.sh  # Enter Nix environment
    R
    > library(randomwalk)  # Latest version from johngavin cachix cache
    > # Or for development:
    > devtools::load_all()
    > # Run your examples here - all packages available!
    ```

    **Note**: Project-specific default.nix automatically uses johngavin
    cachix cache (second priority after rstats-on-nix cache) for
    pre-built packages

**Reference implementations**: - Simple version:
`millsratio/default.sh` - Advanced version:
`/Users/johngavin/docs_gh/llm/default.sh`

## Critical Nix Rules (MUST READ)

**See `NIX_RULES.md` for detailed explanation**

### NEVER Install Packages Inside Nix

``` r
# ✗ FORBIDDEN - Breaks Nix immutability
install.packages()       # NO!
devtools::install()      # NO!
pak::pkg_install()       # NO!

# ✓ ALLOWED - Safe operations
devtools::load_all()     # YES - temporary load
devtools::document()     # YES - updates docs
devtools::test()         # YES - runs tests
```

**To add packages:** Edit DESCRIPTION → Run `Rscript default.R` → Exit →
Re-enter Nix

### DESCRIPTION is the Single Source of Truth for Nix (MANDATORY)

**CRITICAL: NEVER maintain a separate package list for Nix.**

All R package dependencies MUST be extracted from DESCRIPTION by
`default.R` using `read.dcf("DESCRIPTION")`. Manual package lists (like
`R/dev/nix/packages.R`) cause drift where packages exist in DESCRIPTION
but are missing from `default.nix`.

**Mandatory pattern for `default.R`:**

``` r
library(rix)
desc_raw <- read.dcf("DESCRIPTION")
parse_field <- function(field) {
  if (!field %in% colnames(desc_raw)) return(character())
  pkgs <- strsplit(desc_raw[, field], ",\\s*|\n\\s*")[[1]]
  gsub("\\s*\\([^)]+\\)", "", trimws(pkgs)) |>
    (\(x) x[nzchar(x) & !is.na(x)])()
}
desc_deps <- unique(c(parse_field("Imports"), parse_field("Suggests")))
dev_extras <- c("mirai", "nanonext", "usethis", "gert", "gh",
                "pkgdown", "styler", "air", "spelling")
r_pkgs <- unique(c(desc_deps, dev_extras)) |> sort()
```

**Forbidden patterns:** - `source("R/dev/nix/packages.R")` – manual
list, drifts from DESCRIPTION - Hardcoded `r_pkgs <- c(...)` in
`default.R` – same problem - Any package list not derived from
DESCRIPTION

**Drift detection (targets pipeline):** Every project MUST include
`R/tar_plans/plan_nix_sync.R` with targets that: 1. Track DESCRIPTION as
a file dependency 2. Extract deps via
[`get_description_deps()`](https://johngavin.github.io/coMMpass/reference/get_description_deps.md)
3. Compare against packages in `default.nix`, warning on drift

**Safe regeneration in `default.sh`:** NEVER use `curl -sl` to fetch a
remote rix expression for regeneration. Use:

``` bash
nix-shell \
  --expr "let pkgs = import <nixpkgs> {}; in pkgs.mkShell {
    buildInputs = [ pkgs.R pkgs.rPackages.rix pkgs.rPackages.cli
                    pkgs.rPackages.curl pkgs.curlMinimal pkgs.cacert ]; }" \
  --command "Rscript --vanilla default.R"
```

Why: `import <nixpkgs> {}` uses the ambient channel, always matching
pre-built binaries. The curl-fetched expression can cause R version
mismatch segfaults.

**`default.sh` must check DESCRIPTION timestamp** (not a separate
packages.R):

``` bash
elif [ "$PROJECT_PATH/DESCRIPTION" -nt "$NIX_FILE" ]; then
    echo "DESCRIPTION has been modified since default.nix was generated."
    NEED_REGEN=true
```

**Cachix push CI:** Every project SHOULD include a CI workflow (e.g.,
`06-push-cachix.yaml`) that runs `./push_to_cachix.sh` after the package
check passes on main. This uses `cachix watch-exec` which pushes ONLY
the project derivation, not dependencies.

**Reference implementation:** coMMpass project (Feb 2026).

### NEVER Use IDE in Project-Specific Nix Shells

**CRITICAL:** Project-specific `default.R` must ALWAYS use
`ide = "none"`.

``` r
# ✗ FORBIDDEN - Builds RStudio/VS Code from source (30+ minutes!)
rix(..., ide = "rstudio", ...)   # NO!
rix(..., ide = "code", ...)      # NO!
rix(..., ide = "positron", ...)  # NO!

# ✓ CORRECT - IDE comes from the development shell, not the project shell
rix(..., ide = "none", ...)      # YES - always use this
```

**Why:** - The **development shell** (`~/docs_gh/rix.setup/default.sh`)
already provides RStudio/IDE - Project shells only need R + packages
from DESCRIPTION - Building an IDE in each project shell wastes 30+
minutes compiling from source - Project shells are entered via
`nix-shell --run` by agents (non-interactive, no IDE needed)

**If you see `ide = "rstudio"` or any other IDE value in a project’s
`default.R`, fix it immediately.**

### ⚠️ Nix Segfaults - RECURRING ISSUE (MUST READ)

**CRITICAL:** `dyn.load` segfaults in Nix shells are a **PERSISTENT
RECURRING ISSUE** caused by R version mismatches!

**The Error:**

    *** caught segfault ***
    address 0x0, cause 'invalid permissions'
    Traceback:
     1: dyn.load(file, DLLpath = DLLpath, ...)
     2: library.dynam(lib, package, package.lib)
     3: loadNamespace(...)

**Root Cause:** Binary incompatibility between R version in
`default.nix` date and pre-built packages in cachix. - Example: Date
`2025-10-27` uses R 4.5.1, but cachix has R 4.5.2 binaries → SEGFAULT

### Fix Pattern (MANDATORY)

1.  **Use
    [`rix::available_dates()`](https://docs.ropensci.org/rix/reference/available_dates.html)
    to find compatible dates:**

    ``` r
    library(rix)
    dates <- available_dates()
    tail(dates, 10)  # See most recent dates
    ```

2.  **Select date with R version matching cachix binaries:**

    - Check cachix for current R version (usually 4.5.2 as of Feb 2026)
    - Use matching date in `default.R` (e.g., `2026-01-05` for R 4.5.2)

3.  **Regenerate and test:**

    ``` bash
    # Regenerate default.nix
    Rscript default.R

    # Test ALL packages load
    nix-shell default.nix --run "Rscript -e 'library(ggplot2); library(dplyr); library(targets)'"
    ```

### Rollback Strategy

If newest rix date doesn’t have all packages built:

1.  **List available dates:**

    ``` r
    dates <- rix::available_dates()
    ```

2.  **Test older dates until all packages load:**

    ``` r
    # In default.R, try progressively older dates
    rix(date = "2026-01-05", ...)  # If fails, try older
    rix(date = "2025-12-15", ...)  # etc.
    ```

3.  **Verify ALL DESCRIPTION packages load:**

    ``` bash
    nix-shell default.nix --run "Rscript -e '
      pkgs <- c(\"ggplot2\", \"dplyr\", \"targets\", \"crew\")
      for (pkg in pkgs) library(pkg, character.only = TRUE)
      cat(\"All packages loaded OK\\n\")
    '"
    ```

### Common Mistakes to Avoid

- ❌ Blaming macOS/OS issues (Nix is OS-independent)
- ❌ Using arbitrary rix dates without checking R version
- ❌ Not testing package loading before committing
- ❌ Assuming newest date always works (may lack pre-built packages)
- ✅ Always use
  [`rix::available_dates()`](https://docs.ropensci.org/rix/reference/available_dates.html)
  to select compatible date
- ✅ Always test [`library()`](https://rdrr.io/r/base/library.html)
  calls in temp nix shell
- ✅ Match R version in rix date to cachix binaries

## The 9-Step Workflow (MANDATORY)

**NO EXCEPTIONS. NO SHORTCUTS.** See `r-package-workflow` skill for
details.

| Step | Action | Key Command |
|----|----|----|
| 0 | Design & Plan | Create `plans/PLAN_*.md` |
| 1 | Create Issue | `gh::gh("POST /repos/...")` |
| 2 | Create Branch | `usethis::pr_init("fix-issue-123")` |
| 3 | Make Changes | Edit, test (RED-GREEN-REFACTOR) |
| 4a | Run Checks + QA | `document()`, `test()`, `check()`, adversarial QA, quality gate \>= Silver |
| 4b | Run Pipeline | [`targets::tar_make()`](https://docs.ropensci.org/targets/reference/tar_make.html) - **NEVER ask user, always run yourself** |
| 5 | Push Cachix | `./push_to_cachix.sh` (requires `package.nix`) |
| 6 | Push GitHub | [`usethis::pr_push()`](https://usethis.r-lib.org/reference/pull-requests.html) |
| 7 | Wait for CI | Monitor Nix-based workflows ONLY |
| 8 | Merge PR | [`usethis::pr_merge_main()`](https://usethis.r-lib.org/reference/pull-requests.html) |
| 9 | Log Everything | Include `R/dev/issue/fix_*.R` in PR |

## Data Privacy & Telemetry

**CRITICAL: Confidentiality Guard** - **Low-level telemetry** (e.g.,
message-level Parquet files) must **NEVER** be uploaded to a public git
repository if they contain or potentially contain confidential info. -
You must **ASK and get explicit prior approval** before uploading any
such data. - **Approval Renewal**: This approval must be renewed with
every **minor R package version upgrade** (e.g., 1.1 to 1.2). - Approval
does **NOT** need renewal for bug fixes, new features (that don’t
trigger minor version jumps), or patch increments (e.g., 1.2.3 to
1.2.4).

## Critical Rules

**Git/GitHub - Use R packages ONLY:** -
[`gert::git_add()`](https://docs.ropensci.org/gert/reference/git_commit.html),
`git_commit()`, `git_push()` -
[`usethis::pr_init()`](https://usethis.r-lib.org/reference/pull-requests.html),
`pr_push()`, `pr_merge_main()` -
[`gh::gh()`](https://gh.r-lib.org/reference/gh.html) for GitHub API

**Nix Environment:** - One persistent shell per session - Verify with
`echo $IN_NIX_SHELL` - For issues: invoke `nix-env` agent

**Errors - NEVER speculate:** 1. READ the actual error message 2. QUOTE
the error before proposing fixes 3. If you can’t access logs, ASK the
user

**R Version:** Use 4.5.x (current major). Check: `R.version.string`

## Versioning Policy

**Strict Semantic Versioning for Project R Package**: - **Bug Fixes**:
Increment the **patch** version (e.g., 1.2.4 to 1.2.5) for every bug fix
or set of fixes. - **New Features**: Increment the **minor** version
(e.g., 2.3 to 2.4) for every new feature or set of new features. -
**Releases**: Every **tagged version** must trigger a **major** release
increment (e.g., v2.1.3 to v3.0.0).

## Testing Before Commit (MANDATORY)

**NEVER commit without testing:** 1. Enter project-specific Nix
environment (./default.sh or ./default_dev.sh) 2. Run `tar_validate()` -
MUST pass 3. Run `tar_make()` - MUST run the FULL pipeline, not just one
target 4. Check GitHub CI will trigger (modify .github/workflows if
needed) 5. Include R/dev/issue/fix\_\*.R script documenting changes

**CRITICAL: tar_make() is YOUR job, NEVER the user’s:** - YOU run
`tar_make()` as part of every PR workflow. NEVER ask the user to run
it. - If it fails due to Nix segfaults, document the failure in the
commit message. - If new targets save files to `inst/extdata/`, commit
those files. - Use
`nix-shell default.nix --run "Rscript -e 'targets::tar_make()'"` or btw
tools.

**CRITICAL Testing Requirements:** 1. **Always test via subagents** -
Use `verbose-runner` for any test that produces output 2. **Verify
packages are available** - Test library() calls before claiming packages
work 3. **Test ALL README code examples** - Every command in README must
be tested before committing 4. **Check CI actually succeeds** - Use
`gh pr checks` or `gh workflow view` to verify 5. **Verify deployment
works** - For GitHub Pages, check the site actually exists after merging

**Common Testing Mistakes:** - ❌ Testing in wrong Nix environment
(e.g., llm instead of project) - ❌ Not running tar_validate() before
commit - ❌ Not running tar_make() (NEVER defer to user!) - ❌ Assuming
CI will run (check workflow triggers!) - ❌ Providing untested commands
in README - ❌ Not verifying package dependencies before use - ❌
Assuming GitHub Pages works without checking - ✅ Always test in
project-specific Nix shell - ✅ Always run tar_make() yourself before
committing - ✅ Always delegate tests to appropriate subagents - ✅
Always verify outputs before claiming success

## Mandatory QA Protocol (CRITICAL - NO EXCEPTIONS)

### Protocol Reference Table

| Protocol             | Skill File                | When Required      |
|----------------------|---------------------------|--------------------|
| 9-Step Workflow      | `r-package-workflow`      | Every PR           |
| Adversarial QA       | `adversarial-qa`          | Step 4 of every PR |
| Quality Gates        | `quality-gates`           | Steps 4, 6, 8      |
| TDD                  | `test-driven-development` | Step 3             |
| Systematic Debugging | `systematic-debugging`    | When checks fail   |

### Step 4 Expanded: The Full QA Checklist

Every PR MUST complete ALL of these before commit:

1.  [`devtools::document()`](https://devtools.r-lib.org/reference/document.html) -
    Update NAMESPACE/man
2.  [`devtools::test()`](https://devtools.r-lib.org/reference/test.html) -
    All tests pass (0 failures)
3.  `devtools::check(--as-cran)` - 0 errors, 0 warnings
4.  **Adversarial QA** - Run attack vectors against new/changed exported
    functions
    - Use `adversarial-qa` skill or `/qa-package` command
    - Must pass \>= 95% of attack vectors
    - Generate `tests/testthat/test-adversarial-*.R` for failures found
5.  **Quality Gate** - Compute numeric score
    - Bronze (\>=80) required for commit
    - Silver (\>=90) required for PR
    - Gold (\>=95) required for merge to main
6.  **Cachix Push** - `./push_to_cachix.sh` (requires `package.nix`)
    - Run directly, do NOT ask user for permission
    - Script pushes ONLY this project’s R package (1 derivation)

### NEVER Skip These

If you are about to commit or create a PR without running adversarial QA
and computing a quality gate score, STOP. This is a mandatory
requirement, not optional.

### Cachix Push Rule (ABSOLUTE - NO EXCEPTIONS)

**Only push THIS PROJECT’S R package to johngavin cachix. NEVER push
standard R packages that are already on rstats-on-nix.**

Standard R packages (dplyr, arrow, duckdb, ggplot2, targets, etc.) are
ALL available from the public `rstats-on-nix` cache. Pushing them to
johngavin wastes limited quota and is forbidden.

When running Step 5, just run `./push_to_cachix.sh` directly - do not
ask the user for confirmation. The script handles validation and errors.

#### Correct Method: `cachix watch-exec`

The script uses `cachix watch-exec` which pushes ONLY paths that Nix
actually **builds** during the wrapped command. Dependencies that are
**substituted** (downloaded from rstats-on-nix) are NOT pushed.

``` bash
# CORRECT - pushes only the built derivation (1 path)
cachix watch-exec johngavin --watch-mode auto -- nix-build package.nix --no-out-link
```

#### What NOT To Do (Anti-Patterns)

All of these push the **entire closure** (all runtime dependencies):

``` bash
# WRONG - pushes entire closure (30+ R packages)
cachix push johngavin $RESULT

# WRONG - ALSO pushes entire closure despite common misconception
echo $RESULT | cachix push johngavin

# WRONG - explicitly pushes all transitive dependencies
nix-store -qR $RESULT | cachix push johngavin
```

**Key fact**: `cachix push` has NO flag to prevent closure pushing. The
`echo $PATH | cachix push` trick does NOT limit what gets pushed. Both
`cachix push cache /path` and `echo /path | cachix push cache` resolve
and push the full runtime closure.

#### Verification

After pushing, the script counts “Pushing” lines in the log. Expected: 0
(already cached) or 1 (this package only). If \> 1: dependencies were
built locally instead of substituted. Fix: ensure
`cachix use rstats-on-nix` is configured.

## GitHub Actions CI Strategy

**CRITICAL: Strategy differs by repository visibility**

### Public vs Private Repository CI

| Repo Type | GitHub Actions Minutes | Recommended CI |
|----|----|----|
| **Public** | **Unlimited free** | Any (R-universe, r-lib/actions, Nix) |
| **Private** | Quota-limited (2,000-3,000/month) | **Nix-only** (Linux) |

**Why this matters:** - Public repos: No billing, no minute limits for
standard runners - Private repos: macOS = 10x minutes, Windows = 2x
minutes vs Linux - Source: [GitHub Actions
Billing](https://docs.github.com/en/billing/managing-billing-for-github-actions/about-billing-for-github-actions)

### Public Repositories (e.g., randomwalk, irishbuoys)

**All CI workflows are acceptable:** - ✅ R-universe workflows
(`r-universe-org/workflows`) - ✅ r-lib/actions (check-standard, etc.) -
✅ Nix-based workflows - ✅ Multi-platform builds (macOS, Windows,
Linux)

### Private Repositories

**Nix-only CI to conserve minutes:** - ❌
`usethis::use_github_action("check-standard")` - Uses macOS/Windows - ❌
Multi-platform matrix builds - ❌ r-lib/actions workflows (install
packages = slow) - ✅ **Nix-based workflows**
(`runs-on: ubuntu-latest` + `nix-shell`) - ✅ **Single platform** Linux
builds only

### Documented Exceptions (All Repos)

1.  **pkgdown website deployment**:
    - Build locally with pkgdown::build_site()
    - Push to gh-pages branch
    - Why: bslib attempts to install packages in Nix (forbidden)
    - **CRITICAL**: Remove `nix-shell-root` from gh-pages (symlinks
      break GitHub Pages builds)
2.  **Documentation-only workflows**:
    - May use r-lib/actions for non-code tasks
    - Never for package testing or building in private repos

### Test Coverage (Local Only)

Use `covr` for local test coverage analysis - no external service
needed:

``` bash
# Install covr (if not in DESCRIPTION)
install.packages("covr")

# Generate package coverage report
covr::package_coverage()

# Generate HTML report for detailed inspection
covr::report()
```

**Why local coverage only:** - Nix immutability prevents external
service uploads - Coverage reports are for development iteration, not CI
gates - No token management overhead - Faster feedback during
development

### Standard CI Environment Variables (MANDATORY)

**Every Nix-based workflow MUST set `GITHUB_PAT` at job level:**

``` yaml
jobs:
  my-job:
    env:
      GITHUB_PAT: ${{ secrets.GITHUB_TOKEN }}
```

**Why:** Prevents GitHub API rate limits in `remotes::`, `pak::`, and
`rix::` calls. Both b-rodrigues/nix_targets_pipeline and the official
ropensci/targets CI template set this.

### Nix Installer Options (MANDATORY)

**Every workflow using `DeterminateSystems/nix-installer-action` MUST
include verbose logging:**

``` yaml
      - uses: DeterminateSystems/nix-installer-action@main
        with:
          logger: pretty
          log-directives: nix_installer=trace
          backtrace: full
```

**Why:** Without these, Nix install failures produce opaque error
messages. Verbose logging enables fast CI debugging.

### Pipeline Validation (MANDATORY for targets projects)

**Every project with `_targets.R` MUST run `tar_validate()` in
R-CMD-check:**

``` yaml
      - name: Validate targets pipeline
        if: hashFiles('_targets.R') != ''
        run: |
          nix-shell default.nix -A shell --run "Rscript -e '
            targets::tar_validate()
            cat(\"Pipeline valid:\", length(targets::tar_manifest()\$name), \"targets\\n\")
          '"
```

**Why:** Catches pipeline definition errors (syntax, missing functions,
circular deps) on every push/PR. Fast (\< 5s). Full `tar_make()` runs on
schedule/manual trigger.

### Checkout Version (MANDATORY)

**Always use `actions/checkout@v6`** (latest major version as of Feb
2026).

## Tool Preferences

| Task | Tool |
|----|----|
| Parallel tasks | [`mirai::mirai_map()`](https://mirai.r-lib.org/reference/mirai_map.html) |
| Worker pools | [`crew::crew_controller_local()`](https://wlandau.github.io/crew/reference/crew_controller_local.html) |
| SQL on files | `duckdb` |
| Large data I/O | `arrow` |
| Data manipulation | `dplyr` (duckdb/arrow backend) |
| Pipelines | `targets` + `crew` |
| Package API docs | `pkgctx` (via nix run) |
| Errors & Messages | [`cli::cli_abort()`](https://cli.r-lib.org/reference/cli_abort.html), `cli_alert()` |

## Package Context for LLMs (pkgctx) - MANDATORY

**Every R package project MUST include up-to-date .ctx.yaml files.**

### What is pkgctx?

[pkgctx](https://github.com/b-rodrigues/pkgctx) generates compact YAML
files describing every function, its arguments, and purpose. These
files: - Reduce token usage by ~67% compared to full documentation -
Provide Claude with accurate API information - Enable better code
suggestions and fewer hallucinations

### Mandatory Files

Every project must have:

    inst/extdata/ctx/
    ├── <package_name>.ctx.yaml   # Current package API
    ├── dplyr.ctx.yaml            # Key dependencies
    ├── targets.ctx.yaml
    ├── ...

### Generation Commands

``` bash
# Generate context for current package
nix run github:b-rodrigues/pkgctx -- r . --compact > inst/extdata/ctx/mypackage.ctx.yaml

# Generate context for a CRAN dependency
nix run github:b-rodrigues/pkgctx -- r dplyr --compact > inst/extdata/ctx/dplyr.ctx.yaml

# Generate context for Bioconductor package
nix run github:b-rodrigues/pkgctx -- r bioc:GenomicRanges --compact > inst/extdata/ctx/GenomicRanges.ctx.yaml

# Generate context for GitHub package
nix run github:b-rodrigues/pkgctx -- r github:ropensci/rix --compact > inst/extdata/ctx/rix.ctx.yaml

# Generate context for Python package
nix run github:b-rodrigues/pkgctx -- python requests --compact > inst/extdata/ctx/requests.ctx.yaml
```

### Workflow Integration

1.  **targets pipeline**: Use `plan_pkgctx.R` to auto-generate context
    files
2.  **Session start**: Verify `.ctx.yaml` files are current
3.  **Before commit**: Regenerate if package API changed
4.  **Priority packages**: Always generate context for these
    dependencies:
    - dplyr, tidyr, purrr, ggplot2, tibble
    - targets, DBI, duckdb, arrow, pointblank
    - cli, rlang, httr2, jsonlite, lubridate

### targets Integration

Add to `R/tar_plans/plan_pkgctx.R`:

``` r
plan_pkgctx <- list(
  targets::tar_target(
    pkgctx_self,
    run_pkgctx(".", "inst/extdata/ctx/mypackage.ctx.yaml")
  ),
  targets::tar_target(
    pkgctx_deps,
    lapply(c("dplyr", "targets"), function(pkg) {
      run_pkgctx(pkg, sprintf("inst/extdata/ctx/%s.ctx.yaml", pkg))
    })
  )
)
```

### When to Regenerate

- After adding/removing exported functions
- After changing function signatures
- After updating DESCRIPTION dependencies
- Weekly (context files may become stale)

## Error Handling

**Use Tidyverse Style (cli/rlang):** - **❌ BAD:**
`stop("Error occurred")` - **✅ GOOD:**
`cli::cli_abort(c("x" = "Error message", "i" = "Context/Hint"))` -
**Why:** Structured errors are easier to debug and present better to
users.

## Agents

**Delegation saves context**: Subagents keep verbose output in their
context, returning only summaries to the main conversation.

### Common Agents

| Agent | Model | Use For |
|----|----|----|
| `general-purpose` | opus/sonnet/haiku | General tasks (specify model based on complexity) |
| `verbose-runner` | sonnet | Tests, checks, builds with verbose output |
| `r-debugger` | sonnet | R CMD check/test failures |
| `reviewer` | sonnet | Code reviews |
| `nix-env` | sonnet | Nix shell issues |
| `targets-runner` | sonnet | Pipeline debugging |
| `shinylive-builder` | sonnet | WASM builds |
| `data-engineer` | sonnet | Pipeline building (dbt/DuckDB) |
| `data-quality-guardian` | sonnet | Data validation (pointblank) |
| `claude-code-guide` | sonnet | Claude Code documentation lookup |

### MANDATORY Agent Usage Rules (CRITICAL - NO EXCEPTIONS)

#### 1. Always Use Cheaper Models Where Possible

**❌ WRONG:** Using Opus for simple tasks (wastes tokens and money)

``` python
Task(subagent_type="general-purpose", prompt="check if file exists")  # Defaults to Opus!
```

**✅ CORRECT:** Match model to task complexity

``` python
Task(subagent_type="general-purpose", model="haiku", prompt="check if file exists")  # Simple task
Task(subagent_type="verbose-runner", model="sonnet", prompt="run test suite")  # Medium complexity
Task(subagent_type="planner", model="opus", prompt="design architecture")  # Complex reasoning
```

#### 2. Run Independent Tasks in Parallel

Execute independent tasks simultaneously for efficiency:

``` python
# ✅ CORRECT - All run simultaneously
Task(model="haiku", prompt="check logs"),
Task(model="haiku", prompt="check status"),
Task(model="haiku", prompt="test endpoint")

# ❌ WRONG - Sequential (slow)
Task(prompt="check logs")     # Waits...
Task(prompt="check status")   # Then waits...
```

### Model Selection Guide (MANDATORY)

| Task Type | Model | Cost | Examples |
|----|----|----|----|
| Simple queries | `haiku` | \$ | File checks, curl, grep, counting |
| Moderate work | `sonnet` | \$\$ \| Tests, debugging, analysis \| \| Complex reasoning \| \`opus\` \| \$\$\$ | Architecture, planning, multi-file |

### When to Delegate

**Core rule:** Delegate when output \> 10 lines OR complex reasoning
needed **Never delegate:** Simple file checks (ls, cat), one-line
commands, reading files

**Common mistakes to avoid:** - Using agents to check symlinks exist
(just use `ls -la`) - Using btw tools directly for builds/tests (always
delegate) - Using wrong agent for task (e.g., haiku for complex
verification) - Not running independent tasks in parallel - Using
expensive models (opus) for simple tasks

For detailed rules → invoke `subagent-delegation` skill

## Skills

**Key skills available:** - `adversarial-qa` - MANDATORY: Attack-based
testing for exported functions (Step 4) - `quality-gates` - MANDATORY:
Numeric scoring for commit/PR/merge gates (Step 4) -
`readme-qmd-standard` - README.qmd template and requirements -
`subagent-delegation` - When and how to delegate to agents

**Note:** Additional skills may be available. Check
`/Users/johngavin/.claude/skills/` for full list.

## Common Tasks

| Task | Approach |
|----|----|
| Need package API docs | Use `nix run github:b-rodrigues/pkgctx` |
| Writing GitHub Actions | Check `.github/workflows/` for examples |
| Debugging R errors | Use `r-debugger` agent |
| Testing Shiny dashboards | Use `--chrome` option to launch Claude with browser |
| README requirements | Load `readme-qmd-standard` skill |
| Agent delegation | Load `subagent-delegation` skill |

## Testing Shiny Apps

**With Chrome Extension:**

``` bash
# Launch Claude with Chrome extension
claude --chrome

# Then in R:
launch_dashboard()  # Can interact with browser
```

**Without Chrome Extension:** - Only verify functions exist - Don’t
actually launch (will hang waiting for browser)

## Custom Commands

- `/session-start` - Initialize session
- `/session-end` - End session (commit, push)
- `/check` - Run document(), test(), check()
- `/pr-status` - Check PR and CI status
- `/cleanup` - Review and simplify work

## File Structure (CRITICAL)

    R/                    # Package functions ONLY
    ├── *.R               # Analysis functions
    ├── dev/              # Development tools
    │   └── issues/       # Fix scripts (MUST include in PRs)
    └── tar_plans/        # Modular pipeline components (MANDATORY)
        └── plan_*.R      # Each returns list of tar_target()

    _targets.R            # ONLY orchestrates plans from R/tar_plans/
    vignettes/            # Quarto documentation
    plans/                # PLAN_*.md working documents
    README.qmd            # Source for README.md (NEVER edit README.md directly)

## README Requirements (MANDATORY)

**Every project MUST include Nix installation instructions in README:**

1.  **Use README.qmd as source** - Never edit README.md directly
2.  **Include THREE installation methods:**
    - Standard R (remotes/devtools)
    - **Nix with default.sh method (CRITICAL)**
    - rix integration example (MUST specify commit SHA for git_pkgs)
3.  **Auto-generate project structure** using fs::dir_tree()
4.  **Create targets plan** for auto-regenerating README on vignette
    changes
5.  **TEST ALL CODE EXAMPLES** - Every code chunk in README.md must be
    tested as part of Step 4 in 9-step workflow

See `readme-qmd-standard` skill for complete template.

### Documentation Pipeline (MANDATORY)

**Use targets for reproducible documentation:** - Pre-compute vignette
data in Nix environment - Save results to inst/extdata/ - Vignettes load
pre-computed data (never compute on-the-fly) - This ensures CI can
render docs without package installation

### Code Examples as Targets (MANDATORY)

**All code examples in README.qmd and vignettes MUST be stored as
targets:**

1.  **Define `parse_code_example()` helper** in
    `R/tar_plans/plan_doc_examples.R`:

    ``` r
    parse_code_example <- function(code_lines) {
      code_text <- paste(code_lines, collapse = "\n")
      tryCatch(
        { parsed <- parse(text = code_text)
          list(valid = TRUE, n_expressions = length(parsed),
               code = code_lines, error = NULL) },
        error = function(e)
          list(valid = FALSE, n_expressions = 0L,
               code = code_lines, error = conditionMessage(e))
      )
    }
    ```

2.  **Store code as text** targets:

    ``` r
    targets::tar_target(
      code_example_query,
      {
        force(file.exists("R/database_parquet.R"))
        c(
          "# Example: Query data",
          "result <- query_data(con, table = 'my_table')",
          "head(result)"
        )
      }
    )
    ```

3.  **Parse to validate syntax**:

    ``` r
    targets::tar_target(
      code_parsed_query,
      parse_code_example(code_example_query)  # Returns list(valid, error, code)
    )
    ```

4.  **Evaluate with mock data** (optional – parse validation is the
    minimum):

    ``` r
    targets::tar_target(
      code_eval_query,
      eval_code_with_mock_db(code_example_query)  # Returns list(success, error)
    )
    ```

5.  **Display in .qmd vignettes**:

    ```` qmd
    ```{r}
    #| echo: false
    #| results: asis
    targets::tar_load(code_example_query)
    cat("```r\n", paste(code_example_query, collapse = "\n"), "\n```", sep = "")
    ```
    ````

6.  **Display in .Rmd vignettes** (hidden by default with `<details>`):

    ```` rmd
    ```{r code-example, results='asis'}
    code <- safe_tar_read("code_example_query")
    if (!is.null(code)) {
      cat("<details>\n<summary>Show code</summary>\n\n```r\n")
      cat(paste(code, collapse = "\n"))
      cat("\n```\n</details>\n")
    } else {
      cat("*Code example not available. Run `tar_make()` first.*\n")
    }
    ```
    ````

7.  **Validation gate** to fail pipeline if syntax errors:

    ``` r
    targets::tar_target(
      doc_examples_validation,
      {
        parse_results <- list(query = code_parsed_query, ...)
        all_valid <- all(vapply(parse_results, function(x) x$valid, logical(1)))
        if (!all_valid) {
          failed <- names(parse_results)[!vapply(parse_results, function(x) x$valid, logical(1))]
          cli::cli_abort(c("x" = "Code examples failed syntax validation",
                           "i" = "Failed: {paste(failed, collapse = ', ')}"))
        }
        list(all_valid = all_valid, n_examples = length(parse_results))
      }
    )
    ```

**Why this pattern:** - **Tested examples**: Pipeline fails if code has
syntax errors - **Single source of truth**: Code defined once, displayed
in multiple places - **DRY**: No copy-paste between README and
vignettes - **Always provide tidyverse alternative**: After SQL
examples, show dplyr/duckplyr equivalent - **Order extreme data by the
extreme column**: e.g., `ORDER BY hmax DESC` not `ORDER BY time DESC`

**Reference implementations:** -
`irishbuoys/R/tar_plans/plan_doc_examples.R` (15 code targets, 468
LOC) - `coMMpass/R/tar_plans/plan_doc_examples.R` (4 code targets)

### README Project Structure (MANDATORY)

**Always use `fs::dir_tree(recurse = 2)` in README:**

``` r
```{r}
#| echo: false
#| eval: true
fs::dir_tree(recurse = 2)
```

    **Why:** Full recursion shows hundreds of files in deps/, *_files/, etc. Limit to 2 levels for readability.

    ### Data Files (MANDATORY)

    **Prefer compressed formats:**
    - `.parquet` over `.csv` (10-50x smaller, typed columns)
    - `.csv.gz` or `.json.gz` if text format required
    - Never commit large uncompressed data files

    **For dashboards fetching data:**
    - Use parquet via JavaScript fetch() for browser dashboards
    - Sample data for interactive widgets (10K rows max)
    - Pre-aggregate where possible

    ### Code Display Best Practices (MANDATORY)

    **NEVER show code with prompts or console output markers:**
    - ❌ WRONG: `> library(millsratio)` - Cannot copy/paste
    - ✅ RIGHT: `library(millsratio)` - Clean, copyable code

    **In vignettes/examples, NEVER use:**
    - ❌ `devtools::load_all()` - Assumes devtools is installed
    - ✅ `library(package_name)` - Standard package loading

    **Why:** Users copy/paste code directly. Prompts and dev functions break their workflow.

    ### Targets Pipeline Structure (MANDATORY)

    **NEVER place pipeline definitions directly in _targets.R**

    **Correct Structure:**
    1. **R/tar_plans/plan_*.R**: Modular pipeline components
       - Each file defines one logical group (e.g., plan_data_acquisition.R)
       - Must return a list of tar_target() objects
       - Example: plan_data_acquisition, plan_quality_control

    2. **_targets.R**: Orchestrator ONLY
       ```r
       # Set global options
       tar_option_set(...)

       # Source functions (exclude R/dev/ and R/tar_plans/)
       for (file in list.files("R", pattern = "\\.R$", full.names = TRUE)) {
         if (!grepl("R/(dev|tar_plans)/", file)) source(file)
       }

       # Source and combine plans
       plan_files <- list.files("R/tar_plans", pattern = "^plan_.*\\.R$", full.names = TRUE)
       for (plan_file in plan_files) source(plan_file)

       # Combine all plans
       c(plan_data_acquisition, plan_quality_control, ...)

**Why This Matters:** - **Modularity**: Plans can be reused across
projects - **Testing**: Individual plans can be tested in isolation -
**Collaboration**: Multiple developers can work on different plans -
**Reproducibility**: Clear separation of concerns

## Two-Tier Nix Shell Architecture (CRITICAL FOR AGENTS)

Claude and its agents operate in a **two-tier Nix shell architecture**:

| Shell | Purpose | Started By | Has Project Packages? |
|----|----|----|----|
| **Development shell** | Generic R dev tools for all projects | `caffeinate -i ~/docs_gh/rix.setup/default.sh` on session start | ❌ No - only base tools |
| **Project-specific shell** | All packages from project’s DESCRIPTION | `nix-shell default.nix` in project root | ✅ Yes |

### How Agents Run Project-Specific Commands

Agents run in the development shell by default. To run commands that
need project packages (from DESCRIPTION), use `nix-shell --run`:

``` bash
# Pattern: nix-shell default.nix --run "COMMAND"
cd /path/to/project
nix-shell default.nix --run "Rscript -e 'devtools::document()'"
nix-shell default.nix --run "Rscript -e 'devtools::test()'"
nix-shell default.nix --run "Rscript -e 'devtools::check()'"
```

**Why this works:** - `nix-shell --run` enters the project shell, runs
the command, then exits - Non-interactive - agents can use this - All
packages from DESCRIPTION are available

**DO NOT use `./default.sh`** - it spawns an interactive shell that
agents cannot control.

### What Agents CAN Do

| Task | Method | Notes |
|----|----|----|
| Edit/Read files | Direct tools | No R packages needed |
| devtools::document/test/check | `nix-shell default.nix --run "..."` | All project packages available |
| Run targets pipeline | `nix-shell default.nix --run "Rscript -e 'targets::tar_make()'"` | Needs project packages |
| Git operations | gert/Bash | gert is in dev shell |
| Simple R code | btw tools | Only if packages are in dev shell |

### Example: Running /check

``` bash
cd /path/to/project

# Document
nix-shell default.nix --run "Rscript -e 'devtools::document()'"

# Test
nix-shell default.nix --run "Rscript -e 'devtools::test()'"

# Check
nix-shell default.nix --run "Rscript -e 'devtools::check(args = \"--as-cran\")'"
```

## btw MCP Tool Configuration

**Current subset** (saves ~6k tokens vs all tools):
`btw::btw_tools(c('docs', 'pkg', 'files', 'run', 'env', 'session'))`

| Loaded | Category | Purpose                           |
|--------|----------|-----------------------------------|
| ✓      | docs     | R help pages, vignettes, NEWS     |
| ✓      | pkg      | check, test, document, coverage   |
| ✓      | files    | read, write, list, search         |
| ✓      | run      | execute R code                    |
| ✓      | env      | describe data frames, environment |
| ✓      | session  | platform info, package versions   |

**CRITICAL DELEGATION RULE FOR BTW TOOLS:**

### ⚠️ MANDATORY: No Infinite Waits — Timeouts Required Everywhere

**Blocking indefinitely is STRICTLY FORBIDDEN.** This applies to ALL tools,
agents, and commands — not just btw tools. Any operation that could run
longer than ~30 seconds MUST either:

1. **Use a timeout** (Bash `timeout` parameter, or wrap with `timeout` command)
2. **Run in background** (`run_in_background: true`) and check status non-blocking
3. **Delegate to a subagent** (which has its own `max_turns` limit)

**Common violations (ALL FORBIDDEN):**
- `gh run watch` — blocks until CI finishes (10–30+ min)
- `btw_tool_run_r` with long-running code — has NO built-in timeout
- `btw_tool_pkg_check` / `btw_tool_pkg_test` — can run for minutes
- `nix-build` without timeout — can take 30+ min on cache miss
- Any `Bash` call without explicit `timeout` on commands > 30s
- `shiny::runApp()` or `launch_dashboard()` — blocks forever (waits for browser)
- Any function that waits for user input or network response

**Correct patterns:**
```bash
# ❌ WRONG — blocks for 10+ min
gh run watch 12345 --exit-status

# ✅ CORRECT — non-blocking status check
gh run view 12345 --json status,conclusion

# ❌ WRONG — no timeout on slow build
nix-build default.nix

# ✅ CORRECT — delegate to subagent OR use background
Task(subagent_type="Bash", prompt="nix-build default.nix")

# ❌ WRONG — btw_tool_run_r with devtools::check()
btw_tool_run_r(code = "devtools::check()")

# ✅ CORRECT — delegate to subagent
Task(subagent_type="Bash", model="sonnet", prompt="run devtools::check()")
```

**NEVER call btw_tool_run_r directly for:**
- devtools::test(), check(), build() → Use agent with `model="sonnet"`
- Any gh::gh() API calls that might hang → Use `Bash` with timeout
- Any operation expecting >10 lines output → Use agent with `model="sonnet"`
- Debugging test failures → Use `r-debugger` agent

**NEVER call btw_tool_pkg\_\* directly** → Always use appropriate agent

**Key principle:** Run independent tasks in parallel with appropriate
models (see Agent Usage Rules above)

**Exception:** Simple one-liners (<5s), checking values, quick calculations

| Excluded | Why | Alternative |
|----|----|----|
| git | Use `gert::git_*()` per 9-step workflow | gert R package |
| github | Use [`gh::gh()`](https://gh.r-lib.org/reference/gh.html) per 9-step workflow | gh R package |
| agents | Redundant - Task tool has same agents | Task tool subagents |
| cran | Rarely needed for active dev | WebSearch |
| web | Redundant | WebFetch tool |
| ide | Rarely used | \- |

**Re-enable if needed:** Edit `~/.claude.json` mcpServers args: - Add
`'git'` if gert isn’t working - Add `'github'` if gh::gh() fails - Add
`'cran'` when searching for new packages

## Shinylive/WebR Critical Rules (MUST READ)

### ⚠️ THE MUNSELL PROBLEM - RECURRING ISSUE

**CRITICAL:** The ggplot2/munsell error in Shinylive/WebR is a
**PERSISTENT RECURRING ISSUE** that keeps coming back!

**The Error:**

    preload error: there is no package called 'munsell'
    preload error: Error: package 'ggplot2' could not be loaded

### ❌ INCORRECT Documentation Claims

**FALSE:** “Simple library(ggplot2) works with Shinylive 0.8.0+”
**FALSE:** “Shinylive automatically bundles all dependencies”
**REALITY:** As of Jan 2025, ggplot2 STILL FAILS in WebR due to missing
munsell

### ✅ ACTUAL Working Solutions

#### Option 1: Don’t Use ggplot2 (RECOMMENDED)

``` r
# Use plotly instead - it actually works
library(plotly)
plot_ly(data, x = ~x, y = ~y, type = 'scatter')
```

#### Option 2: Explicitly Install Dependencies (WORKING PATTERN FROM irishbuoys)

``` r
# Install munsell FIRST, then ggplot2 - order matters!
webr::install("munsell", repos = "https://repo.r-wasm.org")
webr::install("ggplot2", repos = "https://repo.r-wasm.org")
library(ggplot2)  # Now works!
```

#### Option 3: Wait for WebR to Fix It (SOMEDAY)

Track issue at: <https://github.com/r-wasm/webr/issues>

### 📋 Shinylive Deployment Checklist

**MANDATORY before EVERY deployment:**

1.  **Build locally**: `quarto render dashboard_shinylive.qmd`
2.  **Check service worker**: Verify `resources: - shinylive-sw.js` in
    YAML
3.  **Open in browser**: Not just curl - ACTUAL browser
4.  **Check F12 console** for:
    - ❌ “munsell” errors
    - ❌ CORS errors
    - ❌ 404 on .wasm files
    - ✅ “Service Worker registered”
5.  **Wait 60 seconds**: Initial load is SLOW
6.  **Test ALL tabs**: Each module must render

### 🚫 Common Shinylive Mistakes to Avoid

1.  **Assuming documentation is correct** - Test everything
2.  **Deploying without browser testing** - Console errors only show in
    browser
3.  **Using GitHub Releases for WASM** - No CORS headers, use GitHub
    Pages
4.  **Complex webr::mount() patterns** - Gets stripped during build
5.  **Trusting “it worked before”** - WebR packages change frequently

### 🔧 When Shinylive Fails

If dashboard shows munsell error after deployment: 1. Remove ggplot2
completely 2. Use plotly for all visualizations 3. Test in browser
before committing 4. Don’t believe documentation about “automatic
bundling”

### 📝 Testing Command

``` bash
# After building, ALWAYS test:
open dashboard_shinylive.html
# Press F12, check Console tab
# Look for "munsell" or "ggplot2" errors
```

## Package Context for LLMs (pkgctx)

Generate compact API documentation for R/Python packages to provide
Claude with function signatures and documentation. **Reduces token usage
by ~67%** while preserving essential API information.

### Quick Usage (No Installation Required)

``` bash
# Generate context for current package
nix run github:b-rodrigues/pkgctx -- r . --compact > package.ctx.yaml

# Generate context for dependencies
nix run github:b-rodrigues/pkgctx -- r dplyr --compact > .claude/context/dplyr.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r targets --compact --hoist-common-args > .claude/context/targets.ctx.yaml
```

### When to Use pkgctx

- **Before asking Claude about package APIs** - Provide context files in
  prompts
- **CI/CD integration** - Auto-update context on push, detect API drift
- **Document dependencies** - Keep `.claude/context/` with key package
  APIs
- **Reduce token usage** - Use `--compact` flag for ~67% reduction

### Integration Pattern

``` bash
# Generate contexts for frequently used packages
mkdir -p .claude/context
for pkg in dplyr tidyr purrr gert gh usethis devtools; do
  nix run github:b-rodrigues/pkgctx -- r "$pkg" --compact > ".claude/context/${pkg}.ctx.yaml"
done
```

**Full details:** See `llm-package-context` skill for CI workflows, API
drift detection, and advanced usage.

## Session End

1.  Commit with `gert` (not bash)
2.  Update `.claude/CURRENT_WORK.md`
3.  Push to remote
4.  If wiki changed: `Rscript R/dev/wiki/sync_wiki.R`

\`\`\`
