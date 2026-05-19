---
name: nix-agent-shell-protocol
description: Agents must enter project-specific nix shells with absolute paths to access project packages not in the global shell
type: rule
---

# Rule: Nix Agent Shell Protocol

## When This Applies
Every time an agent or subshell needs to run project-specific code (R, Python, or any language with packages defined in a project's `default.nix`).

## CRITICAL: User Shell != Project Shell

The user stays in the **global dev shell** at all times. This shell provides general tools (git, gh, python3, R, etc.) but does NOT have project-specific packages like pdfplumber, lme4, brms, or any package listed in a project's `default.nix`/`default.R`.

**Agents MUST enter the project's nix shell** for any command that requires project-specific packages.

## The Pattern

```bash
# CORRECT: Agent enters project shell with absolute path
nix-shell /absolute/path/to/project/default.nix --run "python3 script.py"
nix-shell /absolute/path/to/project/default.nix --run "Rscript -e 'library(lme4)'"

# WRONG: Assumes project packages are in the outer shell
python3 script.py                    # uses global Python, missing pdfplumber
Rscript -e 'library(lme4)'          # uses global R, missing lme4

# WRONG: Relative path (breaks when cwd != project root)
nix-shell default.nix --run "cmd"

# WRONG: cd && nix-shell (triggers bare-repo guard)
cd /path/to/project && nix-shell default.nix --run "cmd"
```

## When Nix Build Fails (Nixpkgs Regression)

Nix builds can fail due to test suite regressions in transitive dependencies (e.g., Twisted, ibis-framework). When this happens:

1. **Diagnose**: Check the error — is it a test failure in a dependency, not the target package?
2. **Fall back to pip venv** for Python packages:
   ```bash
   /usr/bin/python3 -m venv /tmp/project_venv
   /tmp/project_venv/bin/pip install pdfplumber
   /tmp/project_venv/bin/python3 /path/to/script.py
   ```
3. **File an issue** in the llm project with the regression details
4. **Do NOT** give up and claim the package "doesn't work"

## How to Detect You're in the Wrong Shell

| Signal | Meaning |
|--------|---------|
| `ModuleNotFoundError: No module named 'pdfplumber'` | You're in the global shell, not the project shell |
| Python version mismatch (e.g., 3.13 vs project's 3.12) | Global shell's Python, not project's |
| `which python3` shows `/nix/store/...-python3-3.13.x/` but project uses 3.12 | Wrong shell |
| `which R` shows different store path than project's | Wrong shell |

## Agent Delegation

When delegating to agents that need project-specific packages:

```
Agent(subagent_type="r-debugger",
      prompt="Run tests in the mycare project. Enter the project nix shell first:
              nix-shell /Users/johngavin/.../mycare/default.nix --run 'Rscript -e devtools::test()'")
```

## Regenerating default.nix (NEVER Manual)

When a project's setup changes (new R or Python package needed), the agent
MUST regenerate the nix environment automatically. The sequence is:

```
default.R  →  default.nix  →  nix-shell (via default.sh)
   (rix)       (generated)       (enters shell)
```

1. **Edit `default.R`** — add the new package to `r_pkgs` or `py_pkgs`
2. **Coordinate with DESCRIPTION** — if it's an R package project, the same
   package must be added to `DESCRIPTION` (Imports/Suggests) AND `default.R`
3. **Regenerate `default.nix` using a cwd-safe form** — this runs
   `rix::rix()` inside a shell that has `rix` installed (the llm dev
   shell at `~/docs_gh/llm/`). The bare form `Rscript /path/to/default.R`
   is **WRONG** because it inherits the caller's cwd; `rix::rix()` writes
   `default.nix` relative to cwd and silently overwrites the wrong
   checkout. Always use Form A or Form B (see "Worktree-Isolated rix
   Regenerations" below for the full explanation):
   ```bash
   # Form A — subshell isolates cd (the documented exception in git-no-compound-cd)
   (cd /absolute/path/to/project && \
      nix-shell ~/docs_gh/llm/default.nix --run "Rscript default.R")

   # Form B — explicit setwd() inside Rscript
   nix-shell ~/docs_gh/llm/default.nix --run \
     "Rscript -e 'setwd(\"/absolute/path/to/project\"); source(\"default.R\")'"

   # WRONG — bare path inherits caller cwd, overwrites wrong checkout
   # nix-shell ~/docs_gh/llm/default.nix --run "Rscript /path/to/project/default.R"
   ```
   Verify rix is loadable inside the shell once before relying on it:
   ```bash
   nix-shell ~/docs_gh/llm/default.nix --run \
     "Rscript -e 'cat(\"rix:\", requireNamespace(\"rix\"), packageVersion(\"rix\"))'"
   ```
4. **Verify** — enter the new shell and confirm the package loads:
   ```bash
   nix-shell /absolute/path/to/project/default.nix --run "Rscript -e 'library(newpkg)'"
   ```

**This is ALWAYS done by an agent** (typically `nix-env` agent or the
orchestrator). The user never runs these commands manually. The agent
delegates to an appropriate subagent with the correct skill.

**Multi-language projects:** If the project also has a `pyproject.toml` or
similar, the agent must update BOTH the nix config AND the language-specific
config file, then regenerate the environment. Check for:
- `DESCRIPTION` (R packages)
- `pyproject.toml` / `requirements.txt` (Python)
- `default.R` (nix generation source)

## CRITICAL: Worktree-Isolated rix Regenerations

`default.R` typically calls `rix::rix(..., project_path = ".", overwrite = TRUE)`. The `"."` resolves to the cwd of the Rscript process. **When agents run in worktrees, the orchestrator's cwd may differ from the worktree's cwd**, causing the regenerated `default.nix` to land in the wrong checkout — overwriting the orchestrator's working tree (and any manual patches like the udunits overlay or shellHook) without warning.

### MANDATORY pattern when an agent regenerates a worktree's `default.nix`

Use a subshell (the documented exception in `git-no-compound-cd`) to set cwd correctly:

```bash
# CORRECT: subshell isolates cd, rix sees the worktree's cwd
(cd /private/tmp/<agent-worktree> && \
   nix-shell ~/docs_gh/llm/default.nix --run "Rscript default.R")

# CORRECT: pass cwd explicitly via Rscript -e setwd()
nix-shell ~/docs_gh/llm/default.nix --run \
  "Rscript -e 'setwd(\"/private/tmp/<agent-worktree>\"); source(\"default.R\")'"

# WRONG: cwd inherits from caller, default.nix may land in orchestrator's checkout
nix-shell ~/docs_gh/llm/default.nix --run \
  "Rscript /private/tmp/<agent-worktree>/default.R"
```

### Symptom of the bug

If you see "udunits build failed" or "library(sf) segfault" after a worktree-isolated agent ran, suspect that the orchestrator's `default.nix` was overwritten. Check:

```bash
git -C <main-checkout> diff default.nix    # are the patches still there?
grep -c gnu89 <main-checkout>/default.nix  # 0 means patches were stripped
```

Recovery: `git -C <main-checkout> checkout HEAD -- default.nix`.

### Lesson logged 2026-05-02

In the acd_area_climate_design project, a Stage 2 OSM agent regenerated default.nix in its worktree but the cwd resolved to the orchestrator's main checkout, stripping the udunits + shellHook patches. Detected when the orchestrator's render failed. Restored from HEAD. Filed observation issue and amended this rule.

### Lesson logged 2026-05-08

In the mycare project, regenerating default.nix to add testthat/here/withr stripped a manual `python312Packages.overrideScope` (`twisted.doCheck = false`) overlay needed to bypass the upstream pdfplumber → pandas → ibis → twisted test-failure cascade (JohnGavin/llm#62). The shellHook itself survived (it lives in default.R), but the nixpkgs overlay block — between the `let` keyword and the `pkgs = ...` line — does not, because rix() does not preserve hand-edited overlays.

**Defensive workflow when regenerating default.nix:**

Every step below that runs `Rscript default.R` MUST use one of the
cwd-safe forms documented in the section above (subshell Form A or
explicit `setwd()` Form B). There is no safe exception: even when the
caller appears to be in the right directory, worktree-orchestrator cwd
drift can silently overwrite the wrong checkout. Always use Form A or B.

Preferred — use a `default.post.sh` per project (idempotent shell script
that re-applies the project's overlays):

1. Regenerate (Form A, from agent or orchestrator):
   `(cd /absolute/path/to/project && nix-shell ~/docs_gh/llm/default.nix --run "Rscript default.R")`
2. `(cd /absolute/path/to/project && ./default.post.sh)` —
   re-apply overlays. Script must be idempotent and detect
   "already applied" via a `grep -q "marker" "$NIX_FILE"` guard.
3. Verify by entering the shell and loading affected packages.

Fallback — when no `default.post.sh` exists yet:

1. `cp /absolute/path/to/project/default.nix /absolute/path/to/project/default.nix.pre-regen.bak`
2. `(cd /absolute/path/to/project && nix-shell ~/docs_gh/llm/default.nix --run "Rscript default.R")`
3. `diff /absolute/path/to/project/default.nix.pre-regen.bak /absolute/path/to/project/default.nix` — eyeball stripped sections
4. Re-apply overlays manually
5. Verify
6. `rm /absolute/path/to/project/default.nix.pre-regen.bak`
7. **Capture the manual steps as a `default.post.sh`** so the next regen
   is automatic (and add `default.nix.bak` to `.gitignore`).

Survey for hand-crafted overlays before regen with:
`grep -E "extend|overrideScope|overridePythonAttrs|disabledTestPaths" default.nix`

Known projects with `default.post.sh`:

| Project | Overlay re-applied | Reason |
|---|---|---|
| `mycare` | `python312Packages.twisted.doCheck = false` | pdfplumber→pandas→ibis→twisted build cascade (JohnGavin/llm#62) |

## Why This Architecture

1. **The user never waits** for project-specific nix-shell entry (5-10s overhead)
2. **Each project is isolated** — different R versions, different Python versions, different packages
3. **The global shell is lightweight** — fast to enter, provides shared tools
4. **Agents are ephemeral** — entering/exiting project shells per-command is fine

## Related

- `nix-nested-shell-isolation` — shellHook fix for R_LIBS_SITE contamination
- `nix-rix-r-environment` skill — full nix/rix management guide
- `git-no-compound-cd` — never `cd && nix-shell`
- JohnGavin/llm#62 — tracking nixpkgs regression affecting pdfplumber builds
