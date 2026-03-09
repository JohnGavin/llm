# Parallel Processing with nanonext/mirai/crew

## Description

Use the nanonext -> mirai -> crew stack for parallel processing in R. This stack provides async sockets, parallel evaluation, and worker pool management - all designed to work seamlessly with targets pipelines.

## Purpose

Use this skill when:
- Running parallel computations in R
- Integrating parallel workers with targets pipelines
- Building async/concurrent applications
- Replacing future/furrr with more efficient alternatives

## The Stack

```
+---------------------------------------------------------+
|  Level 5: targets + crew                                |
|           Production pipelines with parallel workers    |
|                          ^                              |
|  Level 4: crew                                          |
|           Managed worker pools, auto-scaling            |
|                          ^                              |
|  Level 3: purrr (1.1.0+)                               |
|           Native parallel map via mirai backend         |
|                          ^                              |
|  Level 2: mirai                                         |
|           Async evaluation, simple parallel tasks       |
|                          ^                              |
|  Level 1: nanonext                                      |
|           Low-level NNG sockets, custom protocols       |
+---------------------------------------------------------+
```

## When to Use Each Level

| Need | Use This |
|------|----------|
| Drop-in parallel purrr | `purrr::map(..., .parallel = TRUE)` (1.1.0+) |
| Simple parallel map over list | `mirai::mirai_map()` |
| Async evaluation (fire and forget) | `mirai::mirai()` |
| Managed worker pool | `crew::crew_controller_local()` |
| Parallel targets pipeline | `targets` + `crew` controller |
| Custom network protocols | `nanonext` directly |
| Python <-> R interop | `nanonext` + `pynng` |

## purrr 1.1.0+ Parallel Processing

**purrr 1.1.0** added native parallel processing powered by mirai. This is the SIMPLEST way to parallelize existing purrr code.

```r
library(purrr)
library(mirai)

# Sequential (traditional)
results <- map(items, slow_function)

# Parallel - just add .parallel = TRUE!
results <- map(items, slow_function, .parallel = TRUE)

# Works with all map variants
map_dfr(items, process_item, .parallel = TRUE)
map_chr(items, extract_name, .parallel = TRUE)
map2(x, y, combine_fn, .parallel = TRUE)
pmap(list(a, b, c), multi_fn, .parallel = TRUE)

# Configure workers
map(items, fn, .parallel = list(workers = 4))
map(items, fn, .parallel = TRUE, .progress = TRUE)
```

## Level 2: mirai (Most Common)

mirai evaluates expressions in a **clean environment** on a daemon process. Nothing from the calling environment is available unless explicitly passed. This is the #1 source of mistakes.

**Key rule**: Always pass dependencies via `.args` (recommended) or `...` (for lexical scoping). Use `everywhere()` for persistent shared state.

```r
# Pass dependencies explicitly
m <- mirai(my_func(my_data), .args = list(my_func = my_func, my_data = my_data))

# Parallel map - collect with []
results <- mirai_map(1:10, function(x) x^2)[]

# Always namespace-qualify package functions
m <- mirai(dplyr::filter(df, x > 5), .args = list(df = my_df))

# Block until resolved
result <- m[]
```

See [mirai-internals.md](references/mirai-internals.md) for detailed patterns: dependency passing (`.args` vs `...`), 5 common mistakes, mirai_map options, daemons setup, compute profiles, everywhere(), error handling, debugging (sync mode), remote/distributed computing, RNG, and nanonext advanced usage.

## Level 3: crew (Worker Pools)

```r
library(crew)

controller <- crew_controller_local(
  workers = 4,
  seconds_idle = 10  # Workers shut down after idle
)
controller$start()

controller$push(name = "task1", command = expensive_function(x))
controller$push(name = "task2", command = another_function(y))

controller$wait()
results <- controller$collect()
controller$terminate()
```

## Level 4: targets + crew Integration

```r
# _targets.R
library(targets)
library(tarchetypes)
library(crew)

controller <- crew_controller_local(
  name = "main",
  workers = parallel::detectCores() - 1,
  seconds_idle = 120
)

tar_option_set(
  controller = controller,
  packages = c("dplyr", "duckdb"),
  error = "continue"
)

list(
  tar_target(raw_data, load_from_duckdb()),
  tar_target(
    model_results,
    fit_model(chunk),
    pattern = map(raw_data),
    iteration = "list"
  ),
  tar_target(final_report, combine_results(model_results))
)
```

### Monitoring

```r
controller$summary()
controller$queue

library(autometric)
log_start()
tar_make()
log <- log_read()
log_plot(log)
```

## Decision Matrix

| Scenario | Solution |
|----------|----------|
| `purrr::map()` but parallel | `mirai::mirai_map()` |
| One-off async task | `mirai::mirai()` |
| Reusable worker pool | `crew::crew_controller_local()` |
| targets with parallelism | `tar_option_set(controller = crew_controller_local())` |
| Custom networking | `nanonext::socket()` |

## Migration from future/furrr/parallel

mirai uses event-driven callbacks (microsecond latency) vs future's polling (millisecond latency). This means zero-latency promise integration for Shiny/Plumber and no busy-waiting.

See [conversion-tables.md](references/conversion-tables.md) for detailed conversion tables (future -> mirai, parallel -> mirai), event-driven vs polling architecture, controller lifecycle management, and full comparison examples.

## Profiling & Optimization

**Rule: Profile BEFORE parallelizing.** Most bottlenecks are I/O or algorithmic, not parallelism issues.

See reference files:
- **[references/profiling-workflow.md](references/profiling-workflow.md)** — profvis, bench::mark, when to use each
- **[references/backend-selection.md](references/backend-selection.md)** — dplyr vs duckdb vs data.table vs arrow
- **[references/performance-anti-patterns.md](references/performance-anti-patterns.md)** — growing objects, type instability, premature optimization
- **[references/purrr-modern-patterns.md](references/purrr-modern-patterns.md)** — list_rbind, walk, parallel map (purrr 1.1.0+)

## Best Practices

1. **Start simple**: Use `mirai_map()` first, upgrade to crew if needed
2. **With targets**: Always use crew controller for parallel targets
3. **Worker count**: `parallel::detectCores() - 1` leaves one for main process
4. **Idle timeout**: Set `seconds_idle` to auto-cleanup workers
5. **Error handling**: Use `error = "continue"` in targets to not fail pipeline
6. **Always namespace-qualify**: Use `pkg::fn()` in mirai expressions, or `everywhere(library(pkg))` first
7. **Always terminate**: Use `tryCatch(..., finally = controller$terminate())` or `onStop()` in Shiny

## Resources

- [mirai documentation](https://shikokuchuo.net/mirai/)
- [crew documentation](https://wlandau.github.io/crew/)
- [nanonext documentation](https://shikokuchuo.net/nanonext/)
- [targets + crew](https://books.ropensci.org/targets/crew.html)
- [nanonext 1.7.0 Python interop](https://www.tidyverse.org/blog/2025/09/nanonext-1-7-0/)
