# ExtendedTask Patterns (Detailed)

## Basic Pattern

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

## Critical Rules for ExtendedTask

```r
# WRONG: Reading reactives INSIDE task function
task <- ExtendedTask$new(function() {
  future_promise({
    n <- input$n  # ERROR: Can't read reactive inside task!
    sum(rnorm(n))
  })
})

# CORRECT: Pass data as parameters, snapshot at invoke time
task <- ExtendedTask$new(function(n) {
  future_promise({
    sum(rnorm(n))  # n was passed as parameter
  })
})

observeEvent(input$run, {
  task$invoke(input$n)  # Snapshot value here
})
```

## Task States

```r
# task$result() intelligently handles all states:
# - NULL while pending (before first invoke)
# - Shows spinner while running
# - Returns value on completion
# - Shows error message on failure

# Check state programmatically:
task$status()  # "initial", "running", "success", "error"
```

## Task Queueing

```r
# If task is already running, new invoke() calls queue up
# Only ONE task instance runs at a time (per ExtendedTask object)

# Can't run same task concurrently
# Create multiple ExtendedTask objects for concurrent different tasks
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

## Anti-Patterns (Detailed)

### 1. Reading Reactives Inside Tasks

```r
# WRONG
task <- ExtendedTask$new(function() {
  future_promise({
    value <- input$slider  # Can't access reactives!
  })
})

# CORRECT
task <- ExtendedTask$new(function(value) {
  future_promise({
    process(value)  # Use parameter
  })
})
```

### 2. Forgetting Controller Cleanup

```r
# WRONG: Memory leak, orphaned workers
server <- function(input, output, session) {
  controller <- crew_controller_local(workers = 4)
  controller$start()
  # No cleanup!
}

# CORRECT
server <- function(input, output, session) {
  controller <- crew_controller_local(workers = 4)
  controller$start()
  onStop(function() controller$terminate())  # Always cleanup
}
```

### 3. Concurrent Same-Task Invocations

```r
# Can't run same ExtendedTask concurrently
observeEvent(input$run, {
  task$invoke(input$a)
  task$invoke(input$b)  # This queues, doesn't run parallel!
})

# For parallel tasks, use crew directly
observeEvent(input$run, {
  controller$push(command = process(input$a))
  controller$push(command = process(input$b))
  # Both run in parallel on different workers
})
```

### 4. Using invalidateLater for Task Completion

```r
# AVOID: Polling wastes resources, adds latency
observe({
  invalidateLater(500)
  if (task_is_complete()) update_ui()
})

# PREFER: Promise callbacks fire immediately
task$invoke(params) %...>% function(result) {
  update_ui(result)
}
```
