# debrief pilot — 2026-06-30

## Purpose

Pilot the `r-lib/debrief` package (v0.1.0.9000), which converts profvis profiling
output to text summaries suitable for AI agent consumption. The pilot answers one
specific question before adopting the package in the `r-debugger` performance loop.

## The Key Question

The debrief docs recommend a *persistent* R session (Positron, mcp-repl, etc.).
Our `btw-timeouts` rule forbids persistent R sessions — every R call goes through a
fresh `Rscript` invocation. The pilot's central question:

**Can `pv_*` functions operate on a profvis result that is SAVED to disk in one
Rscript call and RE-LOADED fresh in a later Rscript call?**

## Answer: YES — fully compatible with per-call Rscript workflow

Two separate `Rscript --vanilla` calls, zero shared state:

- Call 1 (`profile_step.R`): runs `profvis::profvis(...)` on a toy slow function,
  saves result with `saveRDS()`.
- Call 2 (`debrief_step.R`): loads with `readRDS()`, calls `pv_debrief()` and
  `pv_print_debrief()` — both succeed on the reloaded object.

The "persistent session" recommendation in the docs refers to source code reference
availability: profvis records file paths, and `pv_source_context()` can show the
actual lines of code if those files still exist at the same paths. When running
Rscript per call the source context is missing (`has_source: FALSE`), but all
timing, memory, and call-path data is fully captured in the serialized object.

Evidence that this is the designed use: `pv_example("default")` (the package's own
built-in example function) uses `readRDS(system.file("extdata/example_profile.rds",
package = "debrief"))` — the package itself ships pre-saved RDS data.

## Build Status

Nix environment built successfully.

- R 4.5.2 (nixpkgs pin 2026-02-02)
- profvis from CRAN (nixpkgs pin)
- debrief v0.1.0.9000 from git (`r-lib/debrief@ce2a45e`)

Build log excerpt:

```
these 3 derivations will be built:
  /nix/store/lixykkmz6sgd1rgr42z3skg35w83fma4-debrief-ce2a45e.drv
  /nix/store/hn1qygpkh6xyd0xg9b2808xdln40jk5j-r-debrief.drv
  /nix/store/v1mjkg2ljni9ia850hrdzs2syxnj8d3d-nix-shell.drv
...
* DONE (debrief)
```

## Sample Text Output from Call 2

```
## PROFILING SUMMARY

Total time: 50 ms (5 samples @ 10 ms interval)
Source references: not available (use devtools::load_all())

### TOP FUNCTIONS BY SELF-TIME
    30 ms ( 60.0%)  slow_cumsum
    20 ms ( 40.0%)  rnorm

### TOP FUNCTIONS BY TOTAL TIME
    30 ms ( 60.0%)  slow_cumsum
    20 ms ( 40.0%)  rnorm

### HOT CALL PATHS

30 ms (60.0%) - 3 samples:
    slow_cumsum

20 ms (40.0%) - 2 samples:
    rnorm

### MEMORY ALLOCATION (by function)
    4.43 MB slow_cumsum
    0.76 MB rnorm

### Next steps
pv_focus(p, "slow_cumsum")
pv_suggestions(p)
pv_help()
```

`pv_suggestions()` output:
```
  priority     category    location                                 action
1        2 hot function slow_cumsum Profile in isolation (60.0% self-time)
      pattern replacement potential_impact
1 slow_cumsum        <NA>    30 ms (60.0%)
```

## Verdict: ADOPT for r-debugger perf loop

debrief is fully compatible with the btw-timeouts / per-call Rscript workflow.

Recommended pattern for `r-debugger` agent:

```r
# In a targets pipeline or agent perf-debug script:

# Step A — profile (call 1):
p <- profvis::profvis({ <slow_code> })
saveRDS(p, "perf_profile.rds")

# Step B — analyze in fresh Rscript (call 2):
p <- readRDS("perf_profile.rds")
d <- debrief::pv_debrief(p)
# d$self_time, d$suggestions, etc. — all available
txt <- capture.output(debrief::pv_print_debrief(p))
cat(txt, sep = "\n")  # paste into agent context
```

The text output from `pv_print_debrief()` is agent-readable: structured, compact,
no HTML, no interactive viewer required. This makes it suitable for dropping into an
agent's context window as profiling evidence.

One limitation to document: `has_source = FALSE` when running via Rscript (profvis
does not capture source file references in non-interactive sessions unless the
source files are loaded via `pkgload::load_all()` first). This means
`pv_source_context()` and `pv_hot_lines()` return NULL. The timing and call-path
data (`pv_self_time`, `pv_total_time`, `pv_hot_paths`, `pv_suggestions`,
`pv_memory`) are all available and sufficient for the agent perf loop.

## Files

| File | Purpose |
|------|---------|
| `default.R` | rix spec — slim nix env with profvis + debrief from git |
| `default.nix` | Generated nix derivation |
| `profile_step.R` | Call 1: profile toy slow function, saveRDS |
| `debrief_step.R` | Call 2: readRDS, run pv_* functions, print text output |
| `output.txt` | Captured output from both calls |

## Related

- Issue: JohnGavin/llm#696
- Rule: `btw-timeouts` (forbids persistent R sessions — this pilot confirms debrief
  does NOT require one)
- Rule: `nix-agent-shell-protocol` (used Form B setwd to generate default.nix)
- Package: https://github.com/r-lib/debrief
