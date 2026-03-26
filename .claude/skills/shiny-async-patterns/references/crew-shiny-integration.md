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

## Polling Pattern with `walk()` (Simpler Code, Choppier UX)

Complete runnable app — submit batches with `walk()`, poll for results with `invalidateLater()`. Simpler than promises but UI only updates on the poll interval.

```r
library(shiny)

flip_coin <- function() {
  Sys.sleep(0.1)
  rbinom(n = 1, size = 1, prob = 0.501)
}

ui <- fluidPage(
  div("Is the coin fair?"),
  actionButton("button", "Flip 1000 coins"),
  textOutput("results")
)

server <- function(input, output, session) {
  controller <- crew::crew_controller_local(workers = 10, seconds_idle = 10)
  controller$start()
  onStop(function() controller$terminate())

  flips <- reactiveValues(heads = 0, tails = 0, total = 0)

  # walk() submits a batch inside observeEvent()
  observeEvent(input$button, {
    controller$walk(
      command = flip_coin(),
      iterate = list(index = seq_len(1000)),
      data = list(flip_coin = flip_coin)
    )
  })

  # Poll for finished results every 500ms
  observe({
    invalidateLater(millis = 500)
    results <- controller$collect(error = "stop")
    req(results)
    new_flips <- as.logical(results$result)
    flips$heads <- flips$heads + sum(new_flips)
    flips$tails <- flips$tails + sum(1 - new_flips)
    flips$total <- flips$total + length(new_flips)
  })

  output$results <- renderText({
    invalidateLater(millis = 500)
    sprintf("%s | %s heads, %s tails, %s total",
      format(Sys.time(), "%H:%M:%S"), flips$heads, flips$tails, flips$total)
  })
}

shinyApp(ui = ui, server = server)
```

**When to use polling:** Simpler apps, prototypes, or when you don't need sub-second UI responsiveness. See the promise-based pattern above for snappier UX.

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
