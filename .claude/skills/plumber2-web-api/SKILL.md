# Web APIs with plumber2

## Description

plumber2 v0.1.0 is a complete reimagining of the plumber web API framework for R, featuring native support for promises and mirai for high-concurrency web services.

## Purpose

Use this skill when:
- Building REST APIs in R
- Creating high-concurrency web services
- Integrating async operations with web endpoints
- Replacing legacy plumber code with modern patterns

## Key Features in plumber2

### Native Async Support

plumber2 has first-class support for:
- **promises**: Native async handlers
- **mirai**: Event-driven parallel processing
- **crew**: Managed worker pools for API requests

### The Stack

```
┌─────────────────────────────────────────────────────────────┐
│  plumber2   - Web API framework (routes, middleware)        │
│  mirai      - Async task execution (event-driven)           │
│  crew       - Worker pool management (auto-scaling)         │
│  promises   - Async promise chains                          │
└─────────────────────────────────────────────────────────────┘
```

## Basic Usage

### Simple API

```r
library(plumber2)

#* @get /hello
function() {
  list(message = "Hello, World!")
}

#* @get /data/<id>
function(id) {
  fetch_data(id)
}

#* @post /process
function(req) {
  body <- req$body
  process_data(body)
}
```

### Async Endpoints with mirai

```r
library(plumber2)
library(mirai)
library(promises)

#* @get /slow-query
function() {
  # Returns immediately, client gets response when mirai completes

  mirai({
    Sys.sleep(5)  # Simulate slow query
    fetch_large_dataset()
  })
}

#* @post /analyze
function(req) {
  data <- req$body

  # Non-blocking analysis
  mirai({
    run_expensive_analysis(data)
  }) %...>% function(result) {
    list(status = "complete", result = result)
  }
}
```

### With crew Worker Pool

```r
library(plumber2)
library(crew)

# Initialize controller at startup
controller <- crew_controller_local(
  workers = 4,
  seconds_idle = 60
)
controller$start()

#* @get /parallel-task
function() {
  controller$push(
    command = {
      expensive_computation()
    }
  )
  controller$promise()  # Returns promise for auto response
}

# Cleanup on shutdown
onStop(function() {
  controller$terminate()
})
```

## High-Concurrency Patterns

### Request Queue with Auto-scaling

```r
library(plumber2)
library(crew)

# Auto-scaling worker pool
controller <- crew_controller_local(
  workers = 2,          # Start with 2 workers
  workers_max = 8,      # Scale up to 8 under load
  seconds_idle = 30     # Scale down when idle
)
controller$start()

#* @post /batch-process
function(req) {
  items <- req$body$items

  # Submit all items to worker pool
  for (item in items) {
    controller$push(
      command = process_item(item),
      data = list(item = item)
    )
  }

  # Auto-scale based on queue depth
  controller$autoscale()

  # Return promise that resolves when all complete
  controller$promise()
}
```

### Rate Limiting with Middleware

```r
library(plumber2)

#* @filter rate-limit
function(req, res) {
  # Check rate limit
  if (is_rate_limited(req$client_ip)) {
    res$status <- 429
    return(list(error = "Rate limit exceeded"))
  }
  plumber::forward()
}
```

## OpenTelemetry Integration

plumber2 supports OpenTelemetry for production observability:

```r
library(plumber2)
library(otel)

# Initialize OpenTelemetry
otel::otel_init(
  service_name = "my_api",
  exporter = "otlp",
  endpoint = "http://localhost:4317"
)

#* @get /traced-endpoint
function() {
  otel::with_span("database_query", {
    fetch_from_database()
  })
}
```

## Migration from plumber v1

### Before (plumber v1)

```r
# Blocking endpoint
#* @get /slow
function() {
  Sys.sleep(10)  # Blocks ALL requests!
  result()
}
```

### After (plumber2)

```r
# Non-blocking endpoint
#* @get /slow
function() {
  mirai({
    Sys.sleep(10)
    result()
  })  # Other requests continue processing
}
```

## Best Practices

1. **Always use async for slow operations**: Any operation > 100ms should be async
2. **Use crew for CPU-bound tasks**: Offload to worker pool, not main process
3. **Set idle timeouts**: Workers should auto-terminate when not needed
4. **Add OpenTelemetry**: Essential for debugging production issues
5. **Handle errors gracefully**: Use promise error handlers

```r
#* @get /safe-endpoint
function() {
  mirai({
    risky_operation()
  }) %...!% function(error) {
    # Handle errors gracefully
    list(status = "error", message = error$message)
  }
}
```

## Decision Matrix

| Scenario | Pattern |
|----------|---------|
| Simple CRUD | Direct return (sync) |
| Database queries | `mirai()` async |
| CPU-intensive | `crew` worker pool |
| Multiple parallel tasks | `crew` + promises |
| Long-running job | `crew` + job ID + polling endpoint |

## Resources

- [plumber2 Documentation](https://www.rplumber.io/)
- [mirai Documentation](https://shikokuchuo.net/mirai/)
- [crew Documentation](https://wlandau.github.io/crew/)
- [Shiny 1.12 Blog (OpenTelemetry)](https://shiny.posit.co/blog/posts/shiny-r-1.12/)

## Related Skills

- parallel-processing (nanonext/mirai/crew stack)
- shiny-async-patterns (promises, ExtendedTask)
- project-telemetry (OpenTelemetry setup)
