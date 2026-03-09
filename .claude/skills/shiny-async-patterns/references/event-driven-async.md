# Event-Driven Async Patterns

## Event-Driven vs Polling

### Why Event-Driven is Better

```
Polling (future/promises):
- Task completes -> Wait up to 500ms -> Next poll detects completion -> Update
- Latency: milliseconds

Event-Driven (mirai/crew):
- Task completes -> Immediate callback -> Update UI instantly
- Latency: microseconds
```

### mirai Native Promise Support

```r
library(mirai)
library(shiny)

# mirai objects work directly as promises
m <- mirai({
  expensive_computation()
})

# Event-driven resolution (no polling!)
m %...>% function(result) {
  # Fires immediately when mirai completes
}
```

## promises v1.5.0 - Native mirai Integration

**promises v1.5.0** is the engine behind asynchronous Shiny. It now has native mirai integration for event-driven (zero-polling) async.

### Native mirai Support

```r
library(promises)
library(mirai)

# mirai objects work directly as promises (no adapter needed)
m <- mirai({
  expensive_computation()
})

# Event-driven resolution - fires IMMEDIATELY when complete
m %...>% function(result) {
  update_ui(result)
}

# Chain promises
mirai({ step1() }) %...>%
  function(x) mirai({ step2(x) }) %...>%
  function(y) final_result(y)
```

### Why This Matters

```
Before (polling-based):
- Task completes -> Wait up to Xms -> Next poll detects completion -> Callback
- Latency: milliseconds, CPU waste

After (event-driven with mirai):
- Task completes -> Immediate callback
- Zero polling, zero latency
```
