# Quality Gates: Basic Check Example

Run from any R package project directory:

```bash
Rscript ~/.claude/skills/quality-gates/examples/basic-check/run.R
```

## What It Does

1. Runs `devtools::test()` — checks for test failures
2. Counts NAMESPACE exports vs man pages — documentation coverage
3. Greps for `DBI::dbGetQuery` — code style violations

Produces a weighted score: Bronze (>=80), Silver (>=90), Gold (>=95).

## Expected Output

`output/gate_result.json` — compare your result against this:

```json
{
  "total_score": 94.3,
  "grade": "Silver",
  "components": { "check": 98, "documentation": 85, "code_style": 100 }
}
```

If your score differs significantly, check which component is low and fix accordingly.
