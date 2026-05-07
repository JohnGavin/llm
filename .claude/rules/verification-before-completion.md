---
paths:
  - "R/**"
  - "tests/**"
---
# Verification Before Completion

## The Iron Law

**NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE**

If you haven't run the verification command **in this message**, you cannot claim it passes.

## Verification Gate

1. **IDENTIFY**: What command proves this claim?
2. **RUN**: Execute FULL command (fresh, complete)
3. **READ**: Check output for errors/warnings/notes
4. **VERIFY**: Does output confirm claim? Quote evidence.

## Required Commands

| Claim | Required Command | Not Sufficient |
|-------|------------------|----------------|
| "Tests pass" | `devtools::test()`: 0 failures | Previous run |
| "Check passes" | `devtools::check()`: 0 errors/warnings/notes | Tests alone |
| "Docs updated" | `devtools::document()` then `check()` | Just document() |
| "Package loads" | `devtools::load_all()` succeeds | Assuming it works |
| "Site builds" | `pkgdown::build_site()` completes | Previous build |
| "Targets complete" | `targets::tar_make()` all green | Partial run |
| "Website deployed" | curl deployed URLs, grep error patterns | Local grep, WebFetch (cached) |
| "Works on Linux" | docker run with nix-shell | "Passes on Mac" |

## Post-Deploy Validation (MANDATORY)

Curl deployed URLs. WebFetch has 15-min cache — use `curl -s` directly.

### Error patterns (all must return 0)

| Pattern | Meaning |
|---------|---------|
| `not available`, `not found in targets` | Target missing |
| `MISSING EVIDENCE` | Target never built |
| `Error in`, `Error:` | R exception |
| `#&gt;` | Raw R output leaked to HTML |
| `NULL`, `NaN`, bare `NA` | Computation error |

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

All articles must show 0 for nulls, errors, #> (except intentional #> in code examples).

## Before Any Commit

```r
parse("_targets.R")    # VERIFY: no parse errors
devtools::document()
devtools::test()       # VERIFY: "[ FAIL 0 | WARN 0 | SKIP 0 | PASS n ]"
devtools::check()      # VERIFY: "0 errors | 0 warnings | 0 notes"
```

## Verify Tool Output Counts

Line count ≠ call count. Multi-line matches inflate `wc -l`.

```bash
# WRONG: wc -l reports 349 (lines), actual matches = 28
ast-grep run ... | wc -l

# RIGHT: parse JSON for actual count
ast-grep run ... --json=compact | jq length
```

## Red Flags — STOP

- Using "should", "probably", "seems to" about test status
- Saying "Done!" before verification
- Committing without `devtools::check()`
- Trusting previous run output

## Forbidden vs Correct

| Wrong | Right |
|-------|-------|
| "Tests pass" (no output) | Run, quote: `"[ FAIL 0 | PASS 47 ]"` |
| "I ran check() earlier" | Run NOW, show output |
| "The fix should work" | PROVE IT |

| Excuse | Why Invalid |
|--------|-------------|
| "Just changed one line" | One line can break everything |
| "Tests passed before" | Before != now |
| "I'll check after commit" | Too late |
