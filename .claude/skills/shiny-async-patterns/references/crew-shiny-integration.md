# crew + Shiny Integration (Detailed)

For managed worker pools with auto-scaling, use crew with Shiny.

## Promise-Based Pattern (RECOMMENDED)

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

## Polling Pattern (Legacy, Less Responsive)

```r
# AVOID: Polling-based approach (sluggish UX)
observe({
  invalidateLater(500)  # Check every 500ms

  result <- controller$pop()
  if (!is.null(result)) {
    # Process result...
  }
})

# PREFER: Promise-based approach (immediate callbacks)
# See example above
```

## Debugging crew in Shiny

```r
# Inspect crew controller
controller$summary()  # Worker status, task counts
controller$queue      # Pending tasks

# Enable crew logging
controller <- crew_controller_local(
  workers = 4,
  options_local = crew_options_local(log_directory = "logs/")
)
```
