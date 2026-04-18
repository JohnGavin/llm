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
