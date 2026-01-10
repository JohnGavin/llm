# Parallel Processing with nanonext/mirai/crew

## Description

Use the nanonext → mirai → crew stack for parallel processing in R. This stack provides async sockets, parallel evaluation, and worker pool management - all designed to work seamlessly with targets pipelines.

## Purpose

Use this skill when:
- Running parallel computations in R
- Integrating parallel workers with targets pipelines
- Building async/concurrent applications
- Replacing future/furrr with more efficient alternatives

## The Stack

```
┌─────────────────────────────────────────────────────────────┐
│  Level 4: targets + crew                                    │
│           Production pipelines with parallel workers        │
│                          ↑                                  │
│  Level 3: crew                                              │
│           Managed worker pools, auto-scaling                │
│                          ↑                                  │
│  Level 2: mirai                                             │
│           Async evaluation, simple parallel tasks           │
│                          ↑                                  │
│  Level 1: nanonext                                          │
│           Low-level NNG sockets, custom protocols           │
└─────────────────────────────────────────────────────────────┘
```

## When to Use Each Level

| Need | Use This |
|------|----------|
| Simple parallel map over list | `mirai::mirai_map()` |
| Async evaluation (fire and forget) | `mirai::mirai()` |
| Managed worker pool | `crew::crew_controller_local()` |
| Parallel targets pipeline | `targets` + `crew` controller |
| Custom network protocols | `nanonext` directly |
| Python ↔ R interop | `nanonext` + `pynng` |

## Level 2: mirai (Most Common)

### Simple Parallel Map

```r
library(mirai)

# Parallel map (like purrr::map but parallel)
results <- mirai_map(
  1:10,
  \(x) {
    Sys.sleep(1)  # Simulate work
    x^2
  }
)

# Results collected automatically
unlist(results)
```

### Async Evaluation

```r
# Fire and forget
m <- mirai({
  expensive_computation(data)
})

# Do other work while it runs...

# Collect when ready
result <- m[]
```

### With Progress

```r
library(mirai)
library(cli)

results <- mirai_map(
  items,
  \(x) process(x),
  .progress = TRUE  # Built-in progress bar
)
```

## Level 3: crew (Worker Pools)

### Basic Worker Pool

```r
library(crew)

# Create controller with 4 workers
controller <- crew_controller_local(
  workers = 4,
  seconds_idle = 10  # Workers shut down after idle
)

# Start workers
controller$start()

# Push tasks
controller$push(name = "task1", command = expensive_function(x))
controller$push(name = "task2", command = another_function(y))

# Wait and collect
controller$wait()
results <- controller$collect()

# Cleanup
controller$terminate()
```

### With targets

```r
# _targets.R
library(targets)
library(crew)

# Configure crew controller
tar_option_set(
  controller = crew_controller_local(
    workers = 4,
    seconds_idle = 60
  )
)

list(
  tar_target(data, load_data()),
  tar_target(
    processed,
    process_chunk(data),
    pattern = map(data)  # Parallel over chunks
  )
)
```

## Level 4: targets + crew Integration

### Production Pipeline

```r
# _targets.R
library(targets)
library(tarchetypes)
library(crew)

# Persistent workers
controller <- crew_controller_local(
  name = "main",
  workers = parallel::detectCores() - 1,
  seconds_idle = 120
)

tar_option_set(
  controller = controller,
  packages = c("dplyr", "duckdb"),
  error = "continue"  # Don't fail entire pipeline
)

list(
  # Data loading (single worker)
  tar_target(raw_data, load_from_duckdb()),

  # Parallel processing (uses crew workers)
  tar_target(
    model_results,
    fit_model(chunk),
    pattern = map(raw_data),
    iteration = "list"
  ),

  # Combine results
  tar_target(
    final_report,
    combine_results(model_results)
  )
)
```

### Monitoring

```r
# Check worker status
controller$summary()

# View active tasks
controller$queue

# Autometric for resource monitoring
library(autometric)
log_start()
tar_make()
log <- log_read()
log_plot(log)
```

## Level 1: nanonext (Advanced)

### Custom Async Sockets

```r
library(nanonext)

# Create socket pair
s1 <- socket("pair")
s2 <- socket("pair")

# Connect
listen(s1, "ipc:///tmp/test")
dial(s2, "ipc:///tmp/test")

# Async send/receive
send_aio(s1, data = list(x = 1, y = 2))
recv_aio(s2)
```

### Python ↔ R Interop

```r
# R side with nanonext
library(nanonext)
s <- socket("pair")
listen(s, "tcp://127.0.0.1:5555")

# Python side with pynng
# import pynng
# s = pynng.Pair0()
# s.dial("tcp://127.0.0.1:5555")
# s.send(msgpack.packb(data))

# Receive in R
data <- recv(s)
```

## Decision Matrix

| Scenario | Solution |
|----------|----------|
| `purrr::map()` but parallel | `mirai::mirai_map()` |
| One-off async task | `mirai::mirai()` |
| Reusable worker pool | `crew::crew_controller_local()` |
| targets with parallelism | `tar_option_set(controller = crew_controller_local())` |
| Custom networking | `nanonext::socket()` |

## Comparison with future/furrr

```r
# ❌ OLD: future/furrr (heavier, more overhead)
library(future)
library(furrr)
plan(multisession, workers = 4)
results <- future_map(items, process)

# ✅ NEW: mirai (lighter, faster startup)
library(mirai)
results <- mirai_map(items, process)

# ✅ NEW: crew for managed pools
library(crew)
controller <- crew_controller_local(workers = 4)
# ... (see above)
```

## Best Practices

1. **Start simple**: Use `mirai_map()` first, upgrade to crew if needed
2. **With targets**: Always use crew controller for parallel targets
3. **Worker count**: `parallel::detectCores() - 1` leaves one for main process
4. **Idle timeout**: Set `seconds_idle` to auto-cleanup workers
5. **Error handling**: Use `error = "continue"` in targets to not fail pipeline

## Resources

- [mirai documentation](https://shikokuchuo.net/mirai/)
- [crew documentation](https://wlandau.github.io/crew/)
- [nanonext documentation](https://shikokuchuo.net/nanonext/)
- [targets + crew](https://books.ropensci.org/targets/crew.html)
- [nanonext 1.7.0 Python interop](https://www.tidyverse.org/blog/2025/09/nanonext-1-7-0/)
