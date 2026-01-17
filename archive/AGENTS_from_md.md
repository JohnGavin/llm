# AGENTS.md - Agent Guidelines for this Project

## 1. Vignette Standards

### Pre-built Vignettes Strategy (CRITICAL)
*   **CI/CD Strategy**: To avoid incompatibilities between Nix, Quarto, and bslib in CI, and to speed up builds, vignettes are rendered **locally via targets** and committed to git.
*   **Workflow**:
    1.  Edit `.qmd` source.
    2.  Run `targets::tar_make()` locally (in Nix shell).
    3.  Commit the generated `inst/doc/*.html` files.
    4.  Push to GitHub.
*   **CI Behavior**: The CI workflow (`pkgdown.yml`) uses these pre-built HTML files and DOES NOT run Quarto or targets.

### File Format
*   **ALWAYS** use Quarto (`.qmd`) files for vignettes in preference to RMarkdown (`.Rmd`).
*   Ensure the YAML header output format is appropriate (e.g., `rmarkdown::html_vignette` or `quarto::html_document` depending on package setup).

### Content & Reproducibility
*   **Minimize R Code in Vignettes**: Vignettes should contain minimal R code.
*   **Use `targets`**: All data processing, analysis, and visualization generation must be done within the `targets` pipeline.
*   **Loading Results**: Vignettes should primarily consist of text and calls to `targets::tar_read()` or `targets::tar_load()` to display pre-computed objects (tables, plots, values).
*   **Rationale**: This ensures reproducibility and keeps the documentation clean and focused on the narrative.

## 2. Project Structure

### Targets Pipelines
*   **Location**: Store all `targets` pipeline plans in `R/tar_plans/`.
*   **Organization**: Each distinct analysis or vignette should have its own plan file (e.g., `R/tar_plans/plan_memorial_analysis.R`).
*   **Main `_targets.R`**: The root `_targets.R` file should source these plan files and combine them.

## 3. CI/CD & Caching

### Optimization Strategy
*   **Cachix (Preferred)**: This project uses `cachix/install-nix-action` and `cachix-action` to pull binaries from `rstats-on-nix` and `johngavin`. This has proven faster (3-4 mins) than `magic-nix-cache` (26+ mins due to upload overhead) for this specific R environment.
*   **Magic Nix Cache (Avoid)**: Do not use `magic-nix-cache-action` unless the cache upload time is acceptable or the binary cache is insufficient.
*   **Hybrid Workflow**:
    *   **R-CMD-check**: Run in **Nix** (`nix-shell`) to guarantee reproducibility and consistent system dependencies.
    *   **pkgdown**: Run in **Native R** (`r-lib/actions`) to bypass Nix read-only limitations with Quarto/bslib. Use `remotes::install_local` to handle local packages robustly.

### Cachix Configuration
*   **Prioritization**: To ensure the fastest binary cache search, `rstats-on-nix` MUST be prioritized over the project-specific cache (`johngavin`).
*   **Configuration Rule**: Set `name: rstats-on-nix` and `extraPullNames: johngavin` (or other project cache) in `cachix-action`.
*   **Example YAML**:
    ```yaml
    - name: Setup Cachix
      uses: cachix/cachix-action@v15
      with:
        name: rstats-on-nix          # Primary cache (checked first)
        extraPullNames: johngavin    # Secondary cache (checked next)
        authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'
    ```

## 4. Documentation Management

When tidying up towards the end of each session, 
consider reducing the number of '*.md' files in ./R/setup/ 
by merging files and merging duplicated topics to produce fewer more detailed md files. 
Summarise the themes, topics and contents by similarity, and 
suggest which parts  might be better migrated to a 
wiki page on that topic or theme on the GH repo or to a FAQs wiki page and raise a GH issue for any outstanding issues/todo/features.
*   **Wiki FAQs**: Create and maintain a "FAQs" page on the GitHub Wiki documenting tasks logged in `./R/setup/`. Each entry should summarize the task and provide a direct link to the corresponding R script in the repository (e.g., link `R/setup/task_name.R` for `task_name`).
*   **README Maintenance**: The top-level `README.md` should be generated from `inst/qmd/README.qmd`. Any content updates should be made in the `.qmd` file and then rendered to `README.md` using Quarto (e.g., `quarto render inst/qmd/README.qmd --to gfm --output README.md`).

## 5. Version Control & GitHub Workflow

*   **R Packages over CLI**: ALWAYS prefer using R packages (`gert`, `gh`, `usethis`) for Git and GitHub operations instead of command-line tools (`git`, `gh`).
    *   Use `gert` for git operations (commit, push, branch, etc.).
    *   Use `gh` for GitHub API interactions (issues, PRs, releases).
    *   Use `usethis` for project setup and workflow automation (PR helpers).
*   **Log Operations**: All Git/GitHub operations performed via these R packages MUST be logged into reproducible R scripts within the `R/setup/` directory (e.g., `R/setup/create_pr_feature_x.R`). This ensures that the workflow is documented and can be audited or reproduced.

## 6. Website Verification

*   **Post-Merge Check**: After merging a PR, monitor the `pkgdown` workflow on the main branch.
*   **Verification Loop**: Check the website URL (e.g., `https://username.github.io/repo/`) every minute (timeout 5 mins) to confirm the update has been deployed successfully.

## 7. Package Dependency Verification

*   **Upon DESCRIPTION Update**: Whenever the `DESCRIPTION` file is updated (e.g., adding new `Imports` or `Suggests`), you MUST immediately verify that all listed packages are available in the current Nix shell environment.
*   **Verification Command**: Run the following command to attempt loading all dependencies:
    ```bash
    Rscript -e 'd <- read.dcf("DESCRIPTION"); pkgs <- unique(trimws(unlist(strsplit(c(if("Imports" %in% colnames(d)) d[,"Imports"] else NULL, if("Suggests" %in% colnames(d)) d[,"Suggests"] else NULL, if("Depends" %in% colnames(d)) d[,"Depends"] else NULL), ","))); pkgs <- gsub("\s*\(.*
", "", pkgs); pkgs <- pkgs[pkgs != "R"]; missing <- pkgs[!sapply(pkgs, function(p) requireNamespace(p, quietly = TRUE))]; if(length(missing) > 0) { cat("Missing packages:", paste(missing, collapse = ", "), "\n"); quit(status = 1) } else { cat("All dependencies available.\n") }'
    ```
*   **Action on Failure**: If the verification fails (packages missing), do NOT proceed with implementation. Instead, **ask the user for advice** on how to update the Nix environment (e.g., updating `default.R` and regenerating `default.nix`).

## 8. Nix Environment Standards

*   **Fixed Versions**: When defining the Nix environment (e.g., in `default.R` via `rix`), **NEVER** use dynamic version specifiers like `"latest-upstream"`. Always use a fixed date (e.g., `"2025-11-25"`) or a specific commit hash. This ensures the environment remains identical over time, preventing future breakages due to package updates.

## 9. Reproducible R Session Management: Persistent Nix Shell Requirement

**Effective Date:** 2025-11-11

The primary objective for all R development workflows within Nix/rix environments is **true reproducibility**. This is achieved by enforcing the use of a **single persistent nix-shell** for executing all R commands across all projects.

### 9.1 Starting and Using the Persistent Nix Shell

*   **Check Environment**: First, check if you are already in a nix shell (e.g., check for `NIX_CC` environment variable or `which R` pointing to `/nix/store`).
*   **Already Inside?**: If you are already inside a nix-shell, **DO NOT** nest another `nix-shell` command (e.g., `nix-shell --run ...` or `nix-shell default.nix`). Just run the command directly (e.g., `Rscript ...`).
*   **Package Updates**: If you modify `DESCRIPTION` or `default.nix` to add new packages, you **CANNOT** load them in the current running shell. You must **ask the user to restart** the nix-shell environment to pick up the changes.
*   **Execute All Commands Within**: ALL subsequent R commands and related operations for that project must be executed within this single shell instance. This includes:
    *   Running R scripts (`Rscript`).
    *   Interactive R sessions (`R`).
    *   Package development commands (`devtools::check()`, `devtools::test()`, `devtools::document()`).
    *   Website building (`pkgdown::build_site()`).
    *   Git/GitHub operations using R packages (`gert`, `gh`, `usethis`).
    *   `targets` pipeline execution.
    *   Any other R-related operations.

### 9.2 Why This Is Critical

Adhering to this principle ensures:
*   **Consistent Package Versions**: All operations benefit from a single, consistent set of package versions defined by the Nix environment.
*   **Shared R Session State**: Enables continuity of work and shared objects/data within the R session.
*   **Faster Execution**: Avoids repeated, time-consuming initialization of new Nix environments for individual commands.
*   **True Reproducibility**: Guarantees that the environment remains identical throughout the session, which is fundamental for reproducible research and development.
*   **Avoids Pitfalls**: New shell instances break reproducibility, as each may have a different state or slightly different package configurations.

### 9.3 Examples

*   **❌ WRONG Approach (Do NOT Do This)**: Launching new `nix-shell` instances for individual commands breaks reproducibility.
    ```bash
    # Creates new environment each time - breaks reproducibility
    nix-shell --run "Rscript script1.R"
    nix-shell --run "Rscript script2.R"
    nix-shell --run "Rscript script3.R"
    ```
*   **✅ CORRECT Approach (Always Do This)**: Execute all commands within the single persistent shell.
    ```bash
    # Then execute all commands in that shell:
    Rscript script1.R
    Rscript script2.R
    Rscript script3.R
    ```

## 10. R/setup/ Organization

*   **Purpose**: The `R/setup/` directory is for storing R scripts that manage the project's development workflow, including session logs, CI scripts, development utilities, and test data.
*   **Structure**: To maintain clarity and ease of navigation, all scripts within `R/setup/` MUST be organized into logical subfolders based on their topic or function. 
    *   **Example Subfolders**: `archive/`, `ci_scripts/`, `dev_scripts/`, `session_logs/`, `test_data/`, `docs/`, `plans/`.
*   **Naming Convention**: Subfolders should clearly indicate their purpose.
*   **Reference**: See `https://github.com/JohnGavin/statues_named_john/tree/main/R/setup` for a concrete example of this organization.

## 11. Documentation Maintenance & Cleanup

*   **Session Tidy-up**: When tidying up towards the end of each session:
    *   Consider reducing the number of `*.md` files in `./R/setup/` by merging files and merging duplicated topics to produce fewer, more detailed markdown files.
    *   Summarise the themes, topics, and contents by similarity.
    *   Suggest which parts might be better migrated to a wiki page on that topic or theme on the GitHub repository or to a FAQs wiki page.
    *   Raise GitHub issues for any outstanding issues, todos, or features identified during cleanup.

## 12. Session Start Protocol

*   **Initial Review**: At the start of each session:
    *   Review all `./*.md` files for next steps, todos, issues, bugs, and new features.
    *   Review open GitHub issues.
    *   Group the issues/items by similarity.
    *   Order them by difficulty, placing the easiest first within each group and between groups.

## 13. Vignette Requirements

*   **Session Info**: Always include `sessionInfo()` at the bottom of each vignette (`.qmd` file) to aid in reproducibility and debugging.
    ```r
    ## Session Info

    ```{r session-info}
    sessionInfo()
    ```
    ```