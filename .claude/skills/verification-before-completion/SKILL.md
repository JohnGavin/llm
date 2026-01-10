# Verification Before Completion

## Description

Claiming work is complete without verification is dishonesty, not efficiency. This skill enforces **evidence before claims** for all R package development tasks.

## Purpose

Use this skill when:
- About to claim "tests pass" or "check succeeds"
- Before committing or creating PRs
- Before saying "Done!" or expressing satisfaction
- After any fix, before claiming it works
- Before pushing to cachix or GitHub

## The Iron Law

```
NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE
```

If you haven't run the verification command **in this message**, you cannot claim it passes.

## The R Package Verification Gate

```
BEFORE claiming any status:

1. IDENTIFY: What R command proves this claim?
2. RUN: Execute the FULL command (fresh, complete)
3. READ: Full output, check for errors/warnings/notes
4. VERIFY: Does output confirm the claim?
   - If NO: State actual status with evidence
   - If YES: State claim WITH evidence quote
5. ONLY THEN: Make the claim

Skip any step = lying, not verifying
```

## R Package Verification Commands

| Claim | Required Command | Not Sufficient |
|-------|------------------|----------------|
| "Tests pass" | `devtools::test()` output: 0 failures | Previous run, "should pass" |
| "Check passes" | `devtools::check()` output: 0 errors, 0 warnings, 0 notes | Tests passing alone |
| "Documentation updated" | `devtools::document()` then `check()` | Just running document() |
| "Package loads" | `devtools::load_all()` succeeds | Assuming it works |
| "Site builds" | `pkgdown::build_site()` completes | Previous build |
| "Targets complete" | `targets::tar_make()` all green | Partial run |
| "Nix environment works" | `echo $IN_NIX_SHELL` returns value | Assuming you're in shell |

## Verification Workflow for R Packages

### Before Any Commit
```r
# 1. Document
devtools::document()

# 2. Test (watch output!)
devtools::test()
# VERIFY: "[ FAIL 0 | WARN 0 | SKIP 0 | PASS n ]"

# 3. Check (read full output!)
devtools::check()
# VERIFY: "0 errors ✔ | 0 warnings ✔ | 0 notes ✔"
```

### Before PR Push
```r
# After local checks pass, verify CI will pass
# Run in nix-shell:
devtools::check()

# Push to cachix FIRST (Step 5 of 9-step workflow)
# ../push_to_cachix.sh

# ONLY THEN push to GitHub
usethis::pr_push()
```

### After Claiming "Fixed"
```r
# Re-run the SPECIFIC test that was failing
devtools::test_active_file()
# OR
testthat::test_file("tests/testthat/test-specific.R")

# SHOW the output proving it passes
```

## Red Flags - STOP Immediately

You're about to lie if you're:
- Using "should", "probably", "seems to" about test status
- Saying "Great!", "Perfect!", "Done!" before verification
- About to commit without running `devtools::check()`
- Trusting previous run output
- Thinking "I just ran it, it's fine"
- Tired and wanting to finish

## Forbidden Patterns

```r
# ❌ NEVER claim without evidence
"Tests pass"  # Where's the output?

# ❌ NEVER trust memory
"I ran check() earlier, it passed"  # Run it NOW

# ❌ NEVER assume
"The fix should work"  # PROVE IT

# ❌ NEVER skip the full check
"Tests pass so check will pass"  # CHECK CATCHES MORE
```

## Correct Patterns

```r
# ✅ Run and quote output
devtools::test()
# Output: "[ FAIL 0 | WARN 0 | SKIP 0 | PASS 47 ]"
# Tests pass.

# ✅ Full check with evidence
devtools::check()
# Output: "0 errors ✔ | 0 warnings ✔ | 0 notes ✔"
# R CMD check passes with no issues.

# ✅ Specific verification after fix
testthat::test_file("tests/testthat/test-my-function.R")
# Output: "[ FAIL 0 | WARN 0 | SKIP 0 | PASS 5 ]"
# The specific test now passes.
```

## Integration with 9-Step Workflow

This skill applies at multiple steps:

- **Step 4**: Run all checks - VERIFY output before proceeding
- **Step 5**: Push to cachix - VERIFY build succeeded
- **Step 7**: Wait for GitHub Actions - VERIFY all workflows green
- **Step 8**: Before merge - VERIFY PR checks passed

## Tidyverse Principle Alignment

From [workflow vs script](https://tidyverse.org/blog/2017/12/workflow-vs-script/):
> "Source is real" - your code and its verification output are truth, not your memory

From [tidyverse design](https://design.tidyverse.org/):
> Human-centered means being honest about what actually happened, not what we hope happened

## Common Excuses (All Invalid)

| Excuse | Why Invalid |
|--------|-------------|
| "I just changed one line" | One line can break everything |
| "Tests passed before" | Before ≠ now |
| "I'll check after commit" | Too late, damage done |
| "It's a trivial fix" | Trivial fixes cause non-trivial bugs |
| "CI will catch it" | Wastes CI time, blocks others |
