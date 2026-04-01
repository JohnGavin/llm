# /check - Run R Package Checks + Code Sweep

Run the full R package check suite AND ast-grep code sweep.

## Steps

1. Run `devtools::document()` to update NAMESPACE and docs
2. Run `devtools::test()` and report any failures
3. Run `devtools::check()` with `--as-cran` flag
4. Run ast-grep code sweep for banned patterns
5. Run `parse("_targets.R")` if _targets.R exists
6. Summarize all results and give verdict

## Commands to Execute

```r
devtools::document()
devtools::test()
devtools::check(args = "--as-cran")
```

```bash
# ast-grep code sweep (requires R grammar setup)
CFG=~/.config/ast-grep/sgconfig.yml
if [ -f "$CFG" ]; then
  echo "=== Code Sweep ==="
  for pattern in 'DBI::dbGetQuery(___)' 'stop(___)' 'suppressWarnings(___)'; do
    n=$(ast-grep run -c $CFG -l r -p "$pattern" R/ --json=compact 2>/dev/null | Rscript -e 'cat(nrow(jsonlite::fromJSON(readLines("stdin"))))' 2>/dev/null)
    echo "$pattern: ${n:-0} violations"
  done
fi
```

```r
# Pipeline validation
if (file.exists("_targets.R")) parse("_targets.R")
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

## Code Sweep (ast-grep)
- DBI::dbGetQuery: [N] (must be 0)
- stop(): [N] (should be 0 — use cli::cli_abort)
- suppressWarnings(): [N] (must be 0)

## Pipeline
- _targets.R parse: [OK/FAIL]

## Verdict
[Ready to push / Needs fixes]
```
