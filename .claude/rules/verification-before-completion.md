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
| "Website deployed" | curl each deployed URL, grep for all error patterns (see table below) | "Build succeeded", grep of local files, WebFetch (has 15-min cache) |
| "Vignettes work" | See `quarto-vignette-validation` rule | "pkgdown built" |
| "Works on Linux" | `docker run --rm -v .:/pkg:ro nixos/nix bash -c 'nix-shell ...'` | "Passes on my Mac" |

## Post-Deploy Validation (MANDATORY after every push to docs/)

**MUST curl deployed GitHub Pages URLs. Local `grep docs/articles/*.html` does NOT count.**

WebFetch has a 15-min cache and can return stale content. Use `curl -s` directly.

### Error patterns to grep (all must return 0 hits)

| Pattern | Source | Meaning |
|---------|--------|---------|
| `not available` | `show_target()` fallback | Target missing from store AND RDS |
| `not found in targets` | `safe_tar_read()` message | Same as above |
| `MISSING EVIDENCE` | Placeholder text | Target never built |
| `Error in` | R error leaked to output | Unhandled exception |
| `Error:` | R error (alternate form) | Unhandled exception |
| `#&gt;` | knitr `comment = "#>"` | Raw R console output prefix leaked into HTML |
| `NULL` (in `<pre><code>`) | Target returned NULL | Target exists but has no content |
| `NaN` (in table cells) | Division by zero | Computation error in target |
| `NA` (bare, in table cells) | Missing data leaked | Target has incomplete data |
| `class="dataframe"` | Raw tibble HTML | Table not wrapped in DT::datatable() |

### Validation command (run after CI passes)

```bash
for article in $(grep 'href: articles/' _pkgdown.yml | sed 's/.*articles\///' | sed 's/\.html//'); do
  url="https://OWNER.github.io/REPO/articles/${article}.html"
  content=$(curl -s "$url")
  size=$(echo "$content" | wc -c | tr -d ' ')
  nulls=$(echo "$content" | grep -ci 'not available\|not found in targets\|MISSING EVIDENCE')
  errors=$(echo "$content" | grep -ci 'Error in\|Error:')
  hashgt=$(echo "$content" | grep -c '#&gt;')
  printf "| %-25s | %7s | nulls:%d | err:%d | #>:%d |\n" "$article" "${size}B" "$nulls" "$errors" "$hashgt"
done
```

All articles must show 0 for nulls, errors, and #> (except intentional #> in code examples like rest_api).

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

## Verify Only Intended Changes (difftastic)

Before committing, review your changes structurally to confirm only intended modifications are present:

```bash
git diff --ext-diff -- R/ tests/   # structural diff of uncommitted changes
git diff --ext-diff HEAD~1 -- R/   # structural diff of last commit
```

difftastic ignores formatting — if you see a change, it's semantic and you made it.

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
