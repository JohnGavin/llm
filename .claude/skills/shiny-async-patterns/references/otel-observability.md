# OpenTelemetry Integration (Shiny 1.12+)

OpenTelemetry (OTel) is an industry standard for collecting telemetry data (traces, logs, metrics) to understand how your code behaves in production. Shiny 1.12 adds native OTel support.

## Installation

```r
pak::pak(c("shiny", "otel", "otelsdk"))
```

## Configuration via Environment Variables

Configure your telemetry backend (Logfire, Jaeger, Zipkin, etc.) in `.Renviron`:

```bash
# .Renviron
OTEL_TRACES_EXPORTER=http
OTEL_LOGS_EXPORTER=http
OTEL_EXPORTER_OTLP_ENDPOINT="https://logfire-us.pydantic.dev"
OTEL_EXPORTER_OTLP_HEADERS="Authorization=<your-write-token>"
```

## Verify Setup

```r
otel::is_tracing_enabled()  # Should return TRUE
```

## What Shiny Automatically Traces

**Traces:**
- Session lifecycle (start/end with HTTP details)
- Reactive cascades triggered by input changes
- Individual reactive expressions
- Debounce/throttle updates
- Extended background tasks (ExtendedTask)

**Logs:**
- Unhandled errors
- `reactiveVal()` assignments
- `reactiveValues()` modifications

All entries include session IDs for filtering specific user sessions.

## Granularity Control

Use the `shiny.otel.collect` option to adjust tracing level:

```r
# Options (from least to most verbose):
options(shiny.otel.collect = "none")            # Disabled
options(shiny.otel.collect = "session")         # Session lifecycle only
options(shiny.otel.collect = "reactive_update") # + Reactive updates
options(shiny.otel.collect = "reactivity")      # + All reactive expressions
options(shiny.otel.collect = "all")             # Complete tracing
```

## Temporary Override

```r
# Override tracing level for specific code blocks
withOtelCollect("all", {
  # Detailed tracing for this section
  expensive_reactive_chain()
})

# Or use localOtelCollect() within functions
my_function <- function() {
  localOtelCollect("reactivity")
  # ... code with detailed tracing ...
}
```

## Supported Packages (2025+)

| Package | Version | What's Traced |
|---------|---------|---------------|
| shiny | 1.12+ | Sessions, reactivity, inputs |
| mirai | 2.5.0+ | Async task execution |
| promises | 1.5.0+ | Promise chains |
| httr2 | 1.2.2+ | HTTP requests |
| ellmer | (coming) | LLM API calls |
| testthat | (coming) | Test execution |

## Why OTel > reactlog

```
reactlog (Development):
- Local debugging only
- Can't run in production (overhead)
- No multi-session analysis

OpenTelemetry (Production):
- Production-scale observability
- Minimal overhead
- Filter by session ID
- Integrate with existing monitoring
```

## Benefits for Production

- **Find bottlenecks**: See which reactive chains are slow
- **Debug async issues**: Trace mirai/crew task execution
- **Monitor HTTP calls**: httr2 traces external API latency
- **Distributed tracing**: Connect Shiny traces with backend services
- **Session debugging**: Filter traces by user session ID
