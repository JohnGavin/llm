---
paths:
  - "R/**"
  - "tests/**"
---
# Verification Before Completion

## The Iron Law

```
NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE
```

If you haven't run the verification command **in this message**, you cannot claim it passes.

## Verification Gate

1. **IDENTIFY**: What R command proves this claim?
2. **RUN**: Execute the FULL command (fresh, complete)
3. **READ**: Full output, check for errors/warnings/notes
4. **VERIFY**: Does output confirm the claim? If NO: state actual status. If YES: state claim WITH evidence quote.

## R Package Verification Commands

| Claim | Required Command | Not Sufficient |
|-------|------------------|----------------|
| "Tests pass" | `devtools::test()`: 0 failures | Previous run, "should pass" |
| "Check passes" | `devtools::check()`: 0 errors/warnings/notes | Tests alone |
| "Docs updated" | `devtools::document()` then `check()` | Just document() |
| "Package loads" | `devtools::load_all()` succeeds | Assuming it works |
| "Site builds" | `pkgdown::build_site()` completes | Previous build |
| "Targets complete" | `targets::tar_make()` all green | Partial run |
| "Website deployed" | Grep HTML for MISSING EVIDENCE, NULL, Error | "Build succeeded" |
| "Vignettes work" | See `quarto-vignette-validation` rule | "pkgdown built" |

## Before Any Commit

```r
parse("_targets.R")  # VERIFY: no parse errors (ALL PROJECTS)
devtools::document()
devtools::test()   # VERIFY: "[ FAIL 0 | WARN 0 | SKIP 0 | PASS n ]"
devtools::check()  # VERIFY: "0 errors | 0 warnings | 0 notes"
targets::tar_make()  # VERIFY: pipeline runs without errors
```

**Why `parse("_targets.R")`:** A syntax error in `_targets.R` silently breaks the
entire pipeline. `tar_make()` fails but may not be run until later. Parse-checking
catches syntax errors immediately. (Learned 2026-03-24: `plan_pkgdown()` added
without comma broke pipeline for 3 days.)

## Before PR Push

```r
devtools::check()           # In nix-shell
# ../push_to_cachix.sh     # Step 5 of 9-step workflow
usethis::pr_push()          # ONLY after checks pass
```

## Verify Tool Output Counts

Line count ≠ call count. Multi-line matches inflate `wc -l` output.

```bash
# WRONG: reports 349 when answer is 28
ast-grep run -c $CFG -l r -p 'tryCatch(___)' R/ | wc -l  # 349 LINES

# RIGHT: counts actual matches
ast-grep run ... --json=compact | Rscript -e 'cat(nrow(jsonlite::fromJSON(readLines("stdin"))))'  # 28 CALLS
```

Never report tool output without verifying the count method.

## Red Flags — STOP Immediately

You're about to make an unverified claim if you're:
- Using "should", "probably", "seems to" about test status
- Saying "Done!" before verification
- Committing without `devtools::check()`
- Trusting previous run output

## Forbidden vs Correct

```r
# WRONG: "Tests pass"           — Where's the output?
# WRONG: "I ran check() earlier" — Run it NOW
# WRONG: "The fix should work"   — PROVE IT

# RIGHT: Run and quote output
devtools::test()
# Output: "[ FAIL 0 | WARN 0 | SKIP 0 | PASS 47 ]"
# Tests pass.
```

## Integration with 9-Step Workflow

- **Step 4**: Run all checks — VERIFY output before proceeding
- **Step 5**: Push to cachix — VERIFY build succeeded
- **Step 7**: Wait for CI — VERIFY all workflows green
- **Step 8**: Before merge — VERIFY PR checks passed
- **Step 9**: After deploy — VERIFY vignettes render (see `quarto-vignette-validation`)

| Excuse | Why Invalid |
|--------|-------------|
| "Just changed one line" | One line can break everything |
| "Tests passed before" | Before != now |
| "I'll check after commit" | Too late |
| "It's a trivial fix" | Trivial fixes cause non-trivial bugs |
