# Shiny Async Patterns

## Description

Modern patterns for non-blocking, asynchronous operations in Shiny applications using ExtendedTask (Shiny 1.8.1+) and crew integration. These patterns keep the UI responsive during long-running computations.

## Purpose

Use this skill when:
- Building Shiny apps with long-running computations
- Integrating crew/mirai workers with Shiny
- Replacing legacy promise-based async patterns
- Creating responsive multi-user Shiny applications
- Debugging async/blocking issues in Shiny

## Key Concepts

### The Problem with Blocking

```
Traditional Shiny (Blocking):
  User clicks -> Server computes (30s) -> ALL users blocked

Async Shiny (Non-Blocking):
  User clicks -> Task spawns in background -> UI responsive
  Other users unaffected -> Result returns when ready
```

## ExtendedTask (Shiny 1.8.1+) - PREFERRED

ExtendedTask is the modern, recommended approach for async in Shiny.

### Core Pattern

1. Declare `ExtendedTask$new(function(params) { future_promise({...}) })` at server level
2. Bind to `input_task_button()` with `bind_task_button()` for auto-disable
3. Invoke from `observeEvent()`, passing reactive values as **parameters**
4. Read results with `task$result()` in render functions

### Critical Rules

- **NEVER** read `input$*` or reactives inside the task function body
- **ALWAYS** pass data as parameters to `ExtendedTask$new(function(param1, param2) {...})`
- Snapshot reactive values at `task$invoke(input$x)` time
- One ExtendedTask = one concurrent execution (queues additional calls)
- For parallel tasks, create multiple ExtendedTask objects or use crew directly

### Task States

```r
task$status()  # "initial", "running", "success", "error"
# task$result() handles all states: NULL while pending, spinner while running,
# value on completion, error message on failure
```

See [extended-task-patterns.md](references/extended-task-patterns.md) for full code examples, crew+ExtendedTask combo, and detailed anti-patterns.

## crew + Shiny Integration

Use crew for managed worker pools with auto-scaling.

### Key Setup Steps

1. Create controller: `crew_controller_local(workers = 4, seconds_idle = 10)`
2. Start in server: `controller$start()`
3. **ALWAYS** cleanup: `onStop(function() controller$terminate())`
4. Push tasks with promise chaining: `controller$push(...) %...>% callback`
5. Call `controller$autoscale()` after pushing batch tasks

### Promise vs Polling

| Approach | Latency | Recommendation |
|----------|---------|----------------|
| Promise-based (`%...>%` callbacks) | Immediate | PREFERRED |
| Polling (`invalidateLater` + `pop()`) | Up to poll interval | AVOID |

See [crew-shiny-integration.md](references/crew-shiny-integration.md) for complete code examples and debugging tips.

## Event-Driven Async (mirai + promises)

mirai objects work directly as promises with zero-polling, event-driven resolution (promises >= 1.5.0).

```r
# mirai as promise - fires IMMEDIATELY when complete
mirai({ expensive_computation() }) %...>% function(result) {
  update_ui(result)
}
```

Key advantage over future/promises: microsecond vs millisecond latency, no CPU waste from polling.

See [event-driven-async.md](references/event-driven-async.md) for full patterns and promise chaining examples.

## Anti-Patterns Summary

| Anti-Pattern | Problem | Fix |
|-------------|---------|-----|
| `input$x` inside task body | Can't read reactives in background | Pass as parameter to `task$invoke()` |
| No `onStop(controller$terminate())` | Memory leak, orphaned workers | Always add cleanup |
| `task$invoke()` twice for parallelism | Queues, doesn't parallelize | Use separate ExtendedTasks or crew |
| `invalidateLater` for completion | Wastes CPU, adds latency | Use promise callbacks |

See [extended-task-patterns.md](references/extended-task-patterns.md) for detailed anti-pattern code examples.

## Decision Matrix

| Scenario | Solution |
|----------|----------|
| Single long computation | `ExtendedTask` + `future_promise()` |
| Multiple parallel tasks | `crew` controller with promises |
| Simple async with immediate callback | `mirai::mirai()` + promise chain |
| Batch job submission | `crew::controller$walk()` |
| Background workers for targets | `crew_controller_local()` in `_targets.R` |

## Version Requirements

| Component | Minimum Version |
|-----------|----------------|
| ExtendedTask | Shiny >= 1.8.1 |
| input_task_button | bslib >= 0.6.0 |
| crew promise integration | crew >= 0.9.0 |
| Native mirai promises (event-driven) | promises >= 1.5.0 |
| OpenTelemetry support | Shiny >= 1.12 |

## OpenTelemetry (Shiny 1.12+)

Production observability for Shiny apps. Traces sessions, reactive cascades, ExtendedTask execution, and HTTP calls. Configured via environment variables, with granularity control from `"none"` to `"all"`.

Key advantages over reactlog: production-scale, minimal overhead, session-ID filtering, integrates with existing monitoring (Logfire, Jaeger, Zipkin).

See [otel-observability.md](references/otel-observability.md) for setup, configuration, and supported packages.

## Debugging Async Issues

```r
# ExtendedTask state
task$status()  # "initial", "running", "success", "error"

# crew controller inspection
controller$summary()  # Worker status, task counts
controller$queue      # Pending tasks

# Enable crew logging
controller <- crew_controller_local(
  workers = 4,
  options_local = crew_options_local(log_directory = "logs/")
)
```

## Resources

- [Shiny Non-Blocking Article](https://shiny.posit.co/r/articles/improve/nonblocking/)
- [crew + Shiny](https://wlandau.github.io/crew/articles/shiny.html)
- [mirai Documentation](https://shikokuchuo.net/mirai/)
- [Will Landau posit::conf(2024)](https://wlandau.github.io/posit2024/)
- [bslib input_task_button](https://rstudio.github.io/bslib/reference/input_task_button.html)

## Related Skills

- parallel-processing (nanonext/mirai/crew stack)
- crew-operations (logging, auto-scaling)
- shinylive-quarto (note: crew doesn't work in WASM)
