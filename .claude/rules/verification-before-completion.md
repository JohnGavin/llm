# Verification Before Completion

## The Iron Law

**NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE**

If you haven't run the verification command **in this message**, you cannot claim it passes.

### A Check You Have Never Seen Fail Is Not a Check

A green result carries information only if red was reachable. If no input could have produced red, the check is a ritual — it consumes effort, produces reassurance, and transmits nothing.

> **Before recording a check as passed, make it fail once on purpose.**

1. **Name the input that would make this red.** Cannot name one? There is no check yet. 2. **Produce it** — empty the list, break the parser, invent an impossible value. 3. **Confirm red**, for the expected reason and not an unrelated one. 4. **Restore, confirm green, record both.**

Record the falsification beside the result:

```
RESULT: clean — 0 matches across 122 terms
        (falsified: emptying derived_nouns.txt → 4 canaries missing, exit 1)
```

`0 matches` and `the list was empty` are indistinguishable outputs. The parenthesis is what separates them.

#### Five traps

| Type | Shape | Counter |
|---|---|---|
| **A — cannot go red** | Structurally always true: `exit 0` regardless; sentinel supplied by the subject | Run against a value you invented; it must fail |
| **B — wrong object** | Inspects a different artifact than production uses (file vs embedded copy, source vs built) — includes a resting-state screenshot "verifying" `:hover`/`:focus` CSS, and static analysis (`grep`, `jsdom`) "verifying" a client-rendered/SPA page's live layout | Point the check at the **shipped** artifact; diff the two. Force interaction-triggered CSS state in a scratch copy (never the shipped file) and screenshot that (companion doc, 2026-09-05); for SPA/layout claims drive real interaction in a rendering engine that does CSS layout, since `jsdom` never renders CSS (companion doc, 2026-08-31/09-01) |
| **C — wrong property** | Asserts shape/range/count instead of meaning ("all links valid", "parses OK") | Ask what a *correct* result means, not what a *well-formed* one looks like |
| **D — contaminated measurement** | Inherits the state it measures (env vars, caches, stubs) | Isolate: `env -u`, `env -i`, fresh process, cold cache |
| **E — verified by authorship** | "I wrote the fix" substituted for "the fix works" | Observe the effect in the environment that was broken |

Type E is the default failure mode in cross-browser, cross-platform and permissions work, where a diff is routinely correct **and** inert.

#### Stricter bar for safety and privacy gates

Their failure mode is **silence**. A broken test suite eventually goes red because features break; a broken privacy gate keeps saying "clean" forever while data leaks.

- Ship a positive control that runs every time — **and falsify the control**, or you have only moved the problem.
- Target **every artifact that ships**, including files generated from the ones you edit.
- Have the gate **scan itself**. Adding a denylist script to its own target list immediately found real identifiers hardcoded inside it.
- **Refuse to certify a run whose inputs came back thin.** A gate that passes on an empty denylist is worse than none, because it is trusted.

#### Too loud is also broken

A check that cries wolf gets bypassed (a first denylist produced 112 false positives). Aim for **quiet in normal operation, demonstrably loud on a fault you have personally triggered.** Six checks in one session (2026-08-21/22) satisfied the Iron Law while the thing each checked was broken: full incident list in the companion doc. Sibling: `systematic-debugging`'s "Measure the Baseline Before Claiming a Regression".

## Verification Gate

1. **IDENTIFY**: What command proves this claim? 2. **RUN**: Execute FULL command (fresh, complete). 3. **READ**: Check output for errors/warnings/notes. 4. **VERIFY**: Does output confirm claim? Quote evidence.

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

### Error patterns (all must return 0 on every deployed article)

`not available` / `not found in targets` (target missing), `MISSING EVIDENCE` (target never built), `Error in` / `Error:` (R exception), `#&gt;` (raw R output leaked to HTML), `NULL` / `NaN` / bare `NA` (computation error) — except intentional `#>` in code examples. Validation loop over the `_pkgdown.yml` articles (`curl -s` each deployed URL, count the patterns): companion doc.

## One Change Per Verification Run

When verifying fix A, do not fold in change B "while we're here". A single green result then proves them **jointly**, with no way to attribute the outcome.

If a second change is already available and tempting to bundle: **keep** the slower/older run as a control (it isolates what fix A did), **then** apply change B and re-run (the delta is attributable to B).

Worked case (2026-08-01) and the `single-change-experiment` linkage: companion doc.

## Before Any Commit

```r
parse("_targets.R")    # VERIFY: no parse errors
devtools::document()
devtools::test()       # VERIFY: "[ FAIL 0 | WARN 0 | SKIP 0 | PASS n ]"
devtools::check()      # VERIFY: "0 errors | 0 warnings | 0 notes"
```

## Verify Tool Output Counts

Line count ≠ call count: multi-line matches inflate `wc -l`. Count matches from JSON (`ast-grep run ... --json=compact | jq length`), never `| wc -l`.

## Red Flags — STOP

- Using "should", "probably", "seems to" about test status
- Saying "Done!" before verification
- Committing without `devtools::check()`
- Trusting previous run output

## Forbidden vs Correct

- Never "Tests pass" without output: run and quote `[ FAIL 0 | PASS 47 ]`. Never "I ran check() earlier" or "the fix should work": run NOW, show output, PROVE IT.
- Invalid excuses: "just changed one line", "tests passed before", "I'll check after commit".
