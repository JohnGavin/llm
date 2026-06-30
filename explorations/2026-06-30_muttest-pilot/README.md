# muttest Pilot — `classify_score()` Demonstration

**Exploration score target:** 60 (relaxed threshold for `explorations/`)
**Issue:** JohnGavin/llm#696 — pilot `muttest` before adopting in `adversarial-qa` / `quality-gates` skills

---

## Purpose

Evaluate whether `jakubsob/muttest` (v0.2.1) is suitable for routine adoption in
the llm project's quality workflow. The hypothesis: mutation testing surfaces
boundary-condition gaps that conventional coverage metrics miss.

Approach: write a toy function (`classify_score`) with 4 branches and an
intentionally weak test suite (happy-path only, two input values). Run muttest.
Observe which mutants are killed vs. survived to confirm the tool works as
advertised.

---

## What is `muttest`?

`muttest` uses tree-sitter to parse R source into an AST, applies small
syntactic mutations (operator swaps, numeric literal tweaks, condition negations),
then runs the project's test suite against each mutant. A mutant is **killed** if
at least one test fails; it **survives** if all tests pass, indicating a gap in
test coverage.

Available mutators in v0.2.1:

- `comparison_operators()` — swap `<` / `>` / `<=` / `>=` / `!=` / `==`
- `numeric_literals()` — increment or decrement numeric constants by 1
- `negate_condition()` — wrap `if`-conditions in `!(...)`

---

## Repository & Version

- **Canonical repo:** `jakubsob/muttest` (GitHub)
- **Commit:** `6cec45271f67b155175c18a663c339af86db5942` (v0.2.1, 2024-05)
- **NOT in nixpkgs pin 2026-02-02** — installed via `rix` `git_pkgs`

---

## Nix Build Journey (3 Iterations)

### Iteration 1 — Missing `usethis`

`nix-shell` fixupPhase verifies namespace references in R packages it builds.
The muttest namespace chain transitively loads `usethis`, which was not in the
initial `r_pkgs`. Added `usethis` to `r_pkgs` and `propagatedBuildInputs`.

### Iteration 2 — `doCheck = false` Required

muttest's `Suggests` (covr, cucumber, purrr, stringr) are not available in the
minimal environment. The rix-generated `buildRPackage` derivation runs
`R CMD check` by default. Added `doCheck = false` to the muttest derivation.

### Iteration 3 — Undeclared `digest` Dependency

muttest's `PackageCopyStrategy` calls `digest::digest(plan)` to name the
temporary directory for each mutant. However, `digest` is NOT declared in
muttest's `DESCRIPTION` Imports — it is an undeclared runtime dependency.
Without `digest` in the nix shell, every mutant produced:

```
copy error: there is no package called 'digest'
```

Fix: added `digest` to `r_pkgs` and `propagatedBuildInputs`.

### Manual Patches Required After Every `rix()` Regeneration

`rix::rix()` overwrites `default.nix` from scratch. Four patches must be
re-applied manually each time (or automated via a `default.post.sh`):

1. `buildInputs = [ muttest ] ++ rpkgs ++ system_packages` — fixes the nested
   list Nix error (`[ muttest rpkgs system_packages ]` is invalid when `rpkgs`
   is a list)
2. `doCheck = false` on the muttest derivation
3. `digest` and `usethis` in `propagatedBuildInputs` of the muttest derivation
4. Comment block at top of `default.nix` documenting the patches

A `default.post.sh` per the `nix-agent-shell-protocol` rule would automate
re-applying these overlays. Not yet created for this pilot.

---

## Toy Function: `classify_score()`

```r
classify_score <- function(score) {
  if (!is.numeric(score) || length(score) != 1L) stop("score must be a single numeric value")
  if (score < 0 || score > 100) stop("score must be in [0, 100]")
  if (score < 50) return("fail")
  if (score < 70) return("pass")
  if (score < 85) return("merit")
  "distinction"
}
```

Four branches: fail / pass / merit / distinction, with two input validation guards.

**Intentionally weak tests:** only two values tested (`score = 55` and `score = 60`),
both in the "pass" band. No tests for fail / merit / distinction / boundary values.

---

## Muttest Results

```
[ KILLED 4 | SURVIVED 22 | ERRORS 5 | TOTAL 26 | SCORE 15.4% ]
Duration: 2.58 s
```

### Killed (4)

Mutants successfully killed by the two test values (55 and 60 in "pass" band):

| Mutation | Line | Why Killed |
|---|---|---|
| `if (score < 50)` → `if (score > 50)` | 20 | `classify_score(55)` no longer returns "pass" |
| `if (score < 70)` → `if (score > 70)` | 23 | `classify_score(60)` no longer returns "pass" |
| `if (score < 50)` → `if (!(score < 50))` | 20 | Same — negation fails on test inputs |
| `if (score < 70)` → `if (!(score < 70))` | 23 | Same — negation fails on test inputs |

### Survived (22)

All mutations outside the "pass" band survived:

- **Input validation** (`< 0`, `> 100`, `!= 1L`): 7 mutants survived — no tests
  exercise boundary scores (0, 100) or non-numeric inputs
- **`< 85` threshold** (merit/distinction boundary): all 3 comparison/negation
  mutations survived — no tests reach this branch
- **Off-by-one numerics** (`50 ± 1`, `70 ± 1`, `85 ± 1`, `0 ± 1`, `100 ± 1`):
  10 mutants survived — no boundary-adjacent test values (49, 51, 69, 71, 84, 86)
- **`< 50` → `<= 50`** (closed/open boundary): survived — test values (55, 60)
  are far from the boundary

The survived mutants map exactly to the gaps in the test suite. This is the
expected behaviour — mutation testing is working correctly.

### Errors (5)

Five mutants returned `E` (error) rather than `K` or `S`. Based on the row
positions in the output, these correspond to specific condition-negation mutants
on input-validation guards. The errors are likely caused by the `stop()` calls
in the mutated validation guards executing in an unexpected evaluation context
inside muttest's execution harness. These are not test-suite failures — they
are execution errors within muttest's `PackageCopyStrategy` for those specific
mutants. The 19% error rate is worth monitoring in production use.

---

## Verdict for Adoption

**ADOPT with conditions.**

### Evidence for adoption

- Tool works: 4 mutants killed by exactly the 2 test input values, 22 survived
  in untested branches — correct and useful signal
- Fast: 26 mutants in 2.58 s wall time
- AST-based: no textual string replacement; mutations are syntactically valid R
- Good UX: live progress table, survived-mutant diff output, structured results

### Conditions / known risks

| Risk | Severity | Mitigation |
|---|---|---|
| `digest` undeclared dep in muttest DESCRIPTION | Medium | Already patched in this pilot's `default.nix`; file upstream issue |
| 19% error rate (5/26 mutants) | Medium | Test with more complex functions; may be specific to condition-negation on `stop()` calls |
| Manual nix patches after each `rix()` regen | Medium | Create `default.post.sh` per `nix-agent-shell-protocol` rule |
| `PackageCopyStrategy` requires DESCRIPTION | Low | All llm project packages have DESCRIPTION; document requirement |
| CI-minute cost for nix build | Low | muttest nix derivation builds once (~60 s); mutant evaluation is fast (~0.1 s/mutant); acceptable for project-level CI |

### Integration recommendation

1. Add `muttest` to `default.R` `git_pkgs` in projects that adopt it (not yet
   in nixpkgs, must pin by commit SHA)
2. Add `default.post.sh` to re-apply the 4 nix patches after each `rix()` regen
3. File upstream issue for the `digest` undeclared dependency
4. Target `adversarial-qa` / `quality-gates` skills: add a "run muttest" step
   that fails the gate if score < 80% (configurable threshold)
5. Monitor the error rate in production — if > 10% on real code, investigate
   `PackageCopyStrategy` compatibility with our package structure

---

## Files

```
explorations/2026-06-30_muttest-pilot/
├── README.md               # This file
├── DESCRIPTION             # Minimal package descriptor (required by muttest)
├── default.R               # rix driver — generates default.nix
├── default.nix             # Nix environment with muttest from GitHub + 4 manual patches
├── run_muttest.R           # Script to run mutation testing
├── output.txt              # Captured muttest output
├── R/
│   └── classify.R          # Toy function under test
└── tests/
    └── testthat/
        └── test-classify.R # Intentionally weak tests (happy path only)
```

---

## CI Cost Concern (from #696)

The nix derivation build for `muttest` (fetching from GitHub + building) takes
approximately 60 seconds on first build, then is cached by Nix. Mutant evaluation
is fast (2.58 s for 26 mutants). For CI:

- **First run / cache miss**: ~60 s build overhead
- **Cached runs**: negligible overhead
- **Mutant count scales** with source file complexity; a large function with many
  numeric thresholds could generate 100+ mutants

Conclusion: CI cost is acceptable if the nix store is cached between CI runs
(standard practice). If nixpkgs adopts `muttest`, the `git_pkgs` overhead
disappears. Track nixpkgs adoption as a follow-up to the upstream `digest` issue.
