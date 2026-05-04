# /check - Run R Package Checks + Code Sweep

Run the full R package check suite AND ast-grep code sweep.

## Steps

1. Run `devtools::document()` to update NAMESPACE and docs
2. Run `devtools::test()` and report any failures
3. Run `devtools::check()` with `--as-cran` flag
4. Run `r_code_check.sh` (ast-grep + jarl) code sweep for banned patterns and R idiom violations
5. Run `roborev refine --limit 3` to auto-fix unresolved review findings (if roborev daemon is running)
6. Run `parse("_targets.R")` if _targets.R exists
7. Summarize all results and give verdict

## Commands to Execute

```r
devtools::document()
devtools::test()
devtools::check(args = "--as-cran")
```

```bash
# Combined code sweep: ast-grep (structural) + jarl (R idioms)
# Note: jarl is a laptop-local manual install (/usr/local/bin/jarl) and is
# silently skipped when missing — including in GH Actions CI. See llm#99.
~/.claude/scripts/r_code_check.sh R/
```

```r
# Pipeline validation
if (file.exists("_targets.R")) parse("_targets.R")
```

```bash
# Skill spec compliance audit
echo "=== Skill Audit ==="
Rscript ~/docs_gh/llm/.claude/scripts/audit_skills.R 2>/dev/null || echo "(audit_skills.R not available)"
```

```bash
# Structural diff summary (what actually changed semantically)
echo "=== Structural Diff (uncommitted) ==="
git diff --ext-diff --stat 2>/dev/null || echo "(difftastic not configured)"
```

## Optional: Linux Container Check (CI Parity)

If the user says `/check --linux` or if a prior CI failure was Linux-specific, run devtools::check() inside a Linux container via OrbStack:

```bash
# Build a minimal nix-based R container from this project's default.nix
# Then run check inside it — matches CI environment exactly
docker run --rm \
  -v "$(pwd):/pkg:ro" \
  -w /pkg \
  --network=none \
  nixos/nix:latest \
  bash -c 'nix-shell default.nix --run "Rscript -e \"devtools::check()\""'
```

If no Dockerfile/nix container exists yet, report: "No Linux container configured. Run native check only."

This catches: macOS-specific PATH leaks, system lib differences, GNU vs BSD tool divergence, font/locale issues in vignette rendering.

## Output Format

```
## Check Results

- Documentation: [OK/Issues]
- Tests: [X passed, Y failed]
- R CMD check: [X errors, Y warnings, Z notes]

## Code Sweep (ast-grep + jarl)
- ast-grep violations: [N errors, M warnings]
- jarl R idiom violations: [N errors]
- Hardcoded paths: [N]

## Pipeline
- _targets.R parse: [OK/FAIL]

## Verdict
[Ready to push / Needs fixes]
```
