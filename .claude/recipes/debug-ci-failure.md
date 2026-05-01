# Recipe: Debug a CI Failure

## Steps

### 1. Read the log
```bash
gh run view <run-id> --log-failed
```
Find the FIRST error — not the cascade of failures after it.

### 2. Classify the failure

| Error type | Action |
|-----------|--------|
| Missing package | Add to DESCRIPTION + default.R, regenerate default.nix |
| Test failure | Read test, reproduce locally, fix |
| R CMD check NOTE/WARNING | See `r-cmd-check-fixes` skill |
| Nix build failure | Check nixpkgs regression, fall back to pip venv |
| YAML syntax error | Validate with `python3 -c "import yaml; yaml.safe_load(open('file'))"` |
| Timeout | Increase timeout, check for infinite loops |

### 3. Reproduce locally
```bash
nix-shell /path/to/project/default.nix --run "Rscript -e 'devtools::check()'"
```

### 4. Fix and push
Fix the issue, commit, push. Do NOT use `--no-verify`.

### 5. Watch CI
```bash
gh run watch <new-run-id> --exit-status
```

### 6. If it fails again
After FIRST fix attempt, delegate to `fixer` or `r-debugger` agent — don't burn opus on iterative CI fixes.
