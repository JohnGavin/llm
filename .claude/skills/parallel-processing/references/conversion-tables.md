# Conversion & Migration Guide

## purrr: Migration from furrr

```r
# OLD: furrr (heavier, polling-based)
library(furrr)
plan(multisession, workers = 4)
results <- future_map(items, process)

# NEW: purrr + mirai (lighter, event-driven)
library(purrr)
results <- map(items, process, .parallel = TRUE)
```

## Converting from future

| future | mirai |
|--------|-------|
| Auto-detects globals | Must pass all dependencies explicitly |
| `future({expr})` | `mirai({expr}, .args = list(...))` |
| `value(f)` | `m[]` or `call_mirai(m); m$data` |
| `plan(multisession, workers = 4)` | `daemons(4)` |
| `future_lapply(X, FUN)` | `mirai_map(X, FUN)[]` |

## Converting from parallel

| parallel | mirai |
|----------|-------|
| `makeCluster(4)` | `daemons(4)` or `make_cluster(4)` |
| `clusterExport(cl, "x")` | Pass via `.args` / `...`, or `everywhere()` |
| `clusterEvalQ(cl, library(pkg))` | `everywhere(library(pkg))` |
| `parLapply(cl, X, FUN)` | `mirai_map(X, FUN)[]` |
| `mclapply(X, FUN, mc.cores = 4)` | `daemons(4); mirai_map(X, FUN)[]` |

## Event-Driven vs Polling

A critical distinction for Shiny and async applications:

```
Polling (future/promises):
+---------------------------------------------+
| Task completes -> Wait up to Xms ->          |
| Next poll detects completion -> Callback     |
| Latency: milliseconds                       |
+---------------------------------------------+

Event-Driven (mirai/crew):
+---------------------------------------------+
| Task completes -> Immediate callback ->      |
| Zero polling overhead                        |
| Latency: microseconds                       |
+---------------------------------------------+
```

**Why this matters:**
- mirai has "first-class" async support for Shiny/Plumber
- Native promise integration with zero-latency callbacks
- No busy-waiting or polling loops consuming resources
- Better UX in Shiny apps (snappier responses)

```r
# mirai objects ARE promises (event-driven)
library(mirai)
library(promises)

m <- mirai({ expensive_computation() })

# Callback fires IMMEDIATELY when complete
m %...>% function(result) {
  # No polling delay!
  update_ui(result)
}
```

## crew Controller Lifecycle

Always manage controller lifecycle properly:

```r
# In Shiny apps
server <- function(input, output, session) {
  controller <- crew_controller_local(workers = 4)
  controller$start()

  # CRITICAL: Clean up on session end
  onStop(function() {
    controller$terminate()
  })

  # ... use controller ...
}

# In scripts
controller <- crew_controller_local(workers = 4)
controller$start()
tryCatch(
  { # ... use controller ... },
  finally = controller$terminate()
)
```

## Full Comparison: future/furrr vs mirai/crew

```r
# OLD: future/furrr (heavier, polling-based)
library(future)
library(furrr)
plan(multisession, workers = 4)
results <- future_map(items, process)

# NEW: mirai (lighter, event-driven)
library(mirai)
results <- mirai_map(items, process)

# NEW: crew for managed pools
library(crew)
controller <- crew_controller_local(workers = 4)
# ... (see crew section in SKILL.md)
```
