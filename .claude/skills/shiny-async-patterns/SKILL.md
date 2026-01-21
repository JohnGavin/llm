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
┌─────────────────────────────────────────┐
│ User clicks → Server computes (30s) →   │
│ ALL users blocked during computation    │
└─────────────────────────────────────────┘

Async Shiny (Non-Blocking):
┌─────────────────────────────────────────┐
│ User clicks → Task spawns in background │
│ UI remains responsive → Result returns  │
│ Other users unaffected                  │
└─────────────────────────────────────────┘
```

## ExtendedTask (Shiny 1.8.1+) - PREFERRED

ExtendedTask is the modern, recommended approach for async operations in Shiny.

### Basic Pattern

```r
library(shiny)
library(bslib)
library(future)
library(promises)

# Enable multiprocess futures
plan(multisession)

ui <- page_sidebar(
  sidebar = sidebar(
    numericInput("n", "Iterations:", 1000000),
    input_task_button("run", "Run Simulation")  # bslib button
  ),
  card(
    card_header("Results"),
    verbatimTextOutput("result")
  )
)

server <- function(input, output, session) {

  # Declare ExtendedTask ONCE at server level
  task <- ExtendedTask$new(function(n) {
    future_promise({
      # Long-running code runs in separate R process
      Sys.sleep(5)  # Simulate work
      sum(rnorm(n))
    })
  }) |> bind_task_button("run")  # Bind to button for auto-disable

  # Trigger task from observer
  observeEvent(input$run, {
    task$invoke(input$n)  # Pass reactive values as PARAMETERS
  })

  # Render results
  output$result <- renderPrint({
    task$result()  # Handles pending/complete/error states

  })
}

shinyApp(ui, server)
```

### Critical Rules for ExtendedTask

```r
# ❌ WRONG: Reading reactives INSIDE task function
task <- ExtendedTask$new(function() {
  future_promise({
    n <- input$n  # ERROR: Can't read reactive inside task!
    sum(rnorm(n))
  })
})

# ✅ CORRECT: Pass data as parameters, snapshot at invoke time
task <- ExtendedTask$new(function(n) {
  future_promise({
    sum(rnorm(n))  # n was passed as parameter
  })
})

observeEvent(input$run, {
  task$invoke(input$n)  # Snapshot value here
})
```

### Task States

```r
# task$result() intelligently handles all states:
# - NULL while pending (before first invoke)
# - Shows spinner while running
# - Returns value on completion
# - Shows error message on failure

# Check state programmatically:
task$status()  # "initial", "running", "success", "error"
```

### Task Queueing

```r
# If task is already running, new invoke() calls queue up
# Only ONE task instance runs at a time (per ExtendedTask object)

# ❌ Can't run same task concurrently
# ✅ Create multiple ExtendedTask objects for concurrent different tasks
```

## crew + Shiny Integration

For managed worker pools with auto-scaling, use crew with Shiny.

### Promise-Based Pattern (RECOMMENDED)

```r
library(shiny)
library(crew)
library(promises)

ui <- fluidPage(
  titlePanel("crew + Shiny"),
  sidebarLayout(
    sidebarPanel(
      numericInput("n", "Tasks:", 10, min = 1, max = 100),
      actionButton("submit", "Submit Tasks")
    ),
    mainPanel(
      verbatimTextOutput("status"),
      tableOutput("results")
    )
  )
)

server <- function(input, output, session) {

  # Initialize controller with auto-scaling workers
  controller <- crew_controller_local(
    workers = 4,
    seconds_idle = 10  # Workers shut down after 10s idle
  )
  controller$start()

  # CRITICAL: Clean up on session end
  onStop(function() {
    controller$terminate()
  })

  # Store results reactively
  results <- reactiveVal(data.frame())

  # Submit tasks with promise chaining
  observeEvent(input$submit, {

    for (i in seq_len(input$n)) {
      # Push task and chain promise for immediate callback
      controller$push(
        name = paste0("task_", i),
        command = {
          Sys.sleep(runif(1, 0.5, 2))  # Simulate work
          list(id = .task_name, value = rnorm(1))
        }
      ) %...>%
        (function(result) {
          # This callback fires immediately when task completes
          # NOT on a polling schedule
          current <- results()
          results(rbind(current, as.data.frame(result)))
        })
    }

    # Trigger auto-scaling
    controller$autoscale()
  })

  output$status <- renderPrint({
    invalidateLater(1000)  # Update status display
    controller$summary()
  })

  output$results <- renderTable({
    results()
  })
}

shinyApp(ui, server)
```

### Polling Pattern (Legacy, Less Responsive)

```r
# ❌ AVOID: Polling-based approach (sluggish UX)
observe({
  invalidateLater(500)  # Check every 500ms

  result <- controller$pop()
  if (!is.null(result)) {
    # Process result...
  }
})

# ✅ PREFER: Promise-based approach (immediate callbacks)
# See example above
```

## Event-Driven vs Polling

### Why Event-Driven is Better

```
Polling (future/promises):
┌─────────────────────────────────────────┐
│ Task completes → Wait up to 500ms →     │
│ Next poll detects completion → Update   │
│ Latency: milliseconds                   │
└─────────────────────────────────────────┘

Event-Driven (mirai/crew):
┌─────────────────────────────────────────┐
│ Task completes → Immediate callback →   │
│ Update UI instantly                     │
│ Latency: microseconds                   │
└─────────────────────────────────────────┘
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

## Complete Example: crew + ExtendedTask

```r
library(shiny)
library(bslib)
library(crew)

ui <- page_sidebar(
  sidebar = sidebar(
    numericInput("iterations", "Iterations:", 100),
    input_task_button("run", "Run Analysis")
  ),
  card(
    card_header("Analysis Results"),
    plotOutput("plot"),
    verbatimTextOutput("summary")
  )
)

server <- function(input, output, session) {

  # Shared crew controller
  controller <- crew_controller_local(
    workers = 2,
    seconds_idle = 30
  )
  controller$start()
  onStop(function() controller$terminate())

  # ExtendedTask using crew for execution
  analysis_task <- ExtendedTask$new(function(n, ctrl) {
    # Push to crew and return promise
    ctrl$push(
      command = {
        # Heavy computation on crew worker
        Sys.sleep(3)
        data.frame(
          x = seq_len(n),
          y = cumsum(rnorm(n))
        )
      }
    )

    # Return promise that resolves when task completes
    ctrl$promise()
  }) |> bind_task_button("run")

  observeEvent(input$run, {
    analysis_task$invoke(input$iterations, controller)
  })

  output$plot <- renderPlot({
    req(analysis_task$result())
    plot(analysis_task$result(), type = "l",
         main = "Random Walk", col = "steelblue")
  })

  output$summary <- renderPrint({
    req(analysis_task$result())
    summary(analysis_task$result()$y)
  })
}

shinyApp(ui, server)
```

## Anti-Patterns to Avoid

### 1. Reading Reactives Inside Tasks

```r
# ❌ WRONG
task <- ExtendedTask$new(function() {
  future_promise({
    value <- input$slider  # Can't access reactives!
  })
})

# ✅ CORRECT
task <- ExtendedTask$new(function(value) {
  future_promise({
    process(value)  # Use parameter
  })
})
```

### 2. Forgetting Controller Cleanup

```r
# ❌ WRONG: Memory leak, orphaned workers
server <- function(input, output, session) {
  controller <- crew_controller_local(workers = 4)
  controller$start()
  # No cleanup!
}

# ✅ CORRECT
server <- function(input, output, session) {
  controller <- crew_controller_local(workers = 4)
  controller$start()
  onStop(function() controller$terminate())  # Always cleanup
}
```

### 3. Concurrent Same-Task Invocations

```r
# ❌ Can't run same ExtendedTask concurrently
observeEvent(input$run, {
  task$invoke(input$a)
  task$invoke(input$b)  # This queues, doesn't run parallel!
})

# ✅ For parallel tasks, use crew directly
observeEvent(input$run, {
  controller$push(command = process(input$a))
  controller$push(command = process(input$b))
  # Both run in parallel on different workers
})
```

### 4. Using invalidateLater for Task Completion

```r
# ❌ AVOID: Polling wastes resources, adds latency
observe({
  invalidateLater(500)
  if (task_is_complete()) update_ui()
})

# ✅ PREFER: Promise callbacks fire immediately
task$invoke(params) %...>% function(result) {
  update_ui(result)
}
```

## Decision Matrix

| Scenario | Solution |
|----------|----------|
| Single long computation | `ExtendedTask` + `future_promise()` |
| Multiple parallel tasks | `crew` controller with promises |
| Simple async with immediate callback | `mirai::mirai()` + promise chain |
| Batch job submission | `crew::controller$walk()` |
| Background workers for targets | `crew_controller_local()` in `_targets.R` |

## Version Requirements

- **ExtendedTask**: Requires Shiny >= 1.8.1
- **input_task_button**: Requires bslib >= 0.6.0
- **crew promise integration**: Requires crew >= 0.9.0
- **promises v1.5.0**: Native mirai integration (event-driven)
- **Shiny 1.12+**: OpenTelemetry support for observability

## OpenTelemetry Integration (Shiny 1.12+)

OpenTelemetry (OTel) is an industry standard for collecting telemetry data (traces, logs, metrics) to understand how your code behaves in production. Shiny 1.12 adds native OTel support.

### Installation

```r
pak::pak(c("shiny", "otel", "otelsdk"))
```

### Configuration via Environment Variables

Configure your telemetry backend (Logfire, Jaeger, Zipkin, etc.) in `.Renviron`:

```bash
# .Renviron
OTEL_TRACES_EXPORTER=http
OTEL_LOGS_EXPORTER=http
OTEL_EXPORTER_OTLP_ENDPOINT="https://logfire-us.pydantic.dev"
OTEL_EXPORTER_OTLP_HEADERS="Authorization=<your-write-token>"
```

### Verify Setup

```r
otel::is_tracing_enabled()  # Should return TRUE
```

### What Shiny Automatically Traces

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

### Granularity Control

Use the `shiny.otel.collect` option to adjust tracing level:

```r
# Options (from least to most verbose):
options(shiny.otel.collect = "none")            # Disabled
options(shiny.otel.collect = "session")         # Session lifecycle only
options(shiny.otel.collect = "reactive_update") # + Reactive updates
options(shiny.otel.collect = "reactivity")      # + All reactive expressions
options(shiny.otel.collect = "all")             # Complete tracing
```

### Temporary Override

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

### Supported Packages (2025+)

| Package | Version | What's Traced |
|---------|---------|---------------|
| shiny | 1.12+ | Sessions, reactivity, inputs |
| mirai | 2.5.0+ | Async task execution |
| promises | 1.5.0+ | Promise chains |
| httr2 | 1.2.2+ | HTTP requests |
| ellmer | (coming) | LLM API calls |
| testthat | (coming) | Test execution |

### Why OTel > reactlog

```
reactlog (Development):
┌─────────────────────────────────────────┐
│ Local debugging only                    │
│ Can't run in production (overhead)      │
│ No multi-session analysis               │
└─────────────────────────────────────────┘

OpenTelemetry (Production):
┌─────────────────────────────────────────┐
│ Production-scale observability          │
│ Minimal overhead                        │
│ Filter by session ID                    │
│ Integrate with existing monitoring      │
└─────────────────────────────────────────┘
```

### Benefits for Production

- **Find bottlenecks**: See which reactive chains are slow
- **Debug async issues**: Trace mirai/crew task execution
- **Monitor HTTP calls**: httr2 traces external API latency
- **Distributed tracing**: Connect Shiny traces with backend services
- **Session debugging**: Filter traces by user session ID

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
┌─────────────────────────────────────────┐
│ Task completes → Wait up to Xms →       │
│ Next poll detects completion → Callback │
│ Latency: milliseconds, CPU waste        │
└─────────────────────────────────────────┘

After (event-driven with mirai):
┌─────────────────────────────────────────┐
│ Task completes → Immediate callback →   │
│ Zero polling, zero latency              │
└─────────────────────────────────────────┘
```

## Debugging Async Issues

```r
# Check if ExtendedTask is running
task$status()  # "initial", "running", "success", "error"

# Inspect crew controller
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
