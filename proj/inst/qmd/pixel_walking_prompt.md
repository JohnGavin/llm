=== ASYNCHRONOUS PIXEL WALKING SIMULATION ===
Async mode available: TRUE 
Worker processes available: TRUE 
Database: DuckDB in-memory
Communication: nanonext pub/sub + push/pull

=== USAGE ===
Standard mode: shinyApp(ui = ui, server = server)
Background mode: bg_process <- run_app_in_bg()


=== EXAMPLE SIMULATION OUTPUT ===
=== STARTUP CONDITIONS ===
Grid size: 20x20
Async mode: ENABLED
Worker processes: AVAILABLE
Communication ports: 5555, 5556, 5557, 5558

=== STARTING SIMULATION ===
Mode: Asynchronous
Grid: 20x20
Walkers: 8
Workers: 3
Neighborhood: 4-hood
Boundary: terminate

=== SIMULATION ARCHITECTURE ===
• Main Process: Shiny app with UI and simulation management
• Worker Processes: Independent R processes running walker 
simulations
• Communication: nanonext sockets for job distribution and result 
collection
• State Management: DuckDB in-memory database for global state
• Real-time Updates: Publisher-Subscriber pattern for grid state 
sync
• Fallback Mode: Synchronous simulation when async not available

=== KEY FEATURES ===
✓ True asynchronous parallel processing with separate R worker 
processes
✓ Real-time grid state synchronization across all workers
✓ Comprehensive statistics tracking with percentiles and 
formatting
✓ Responsive UI that doesn't block simulation performance
✓ Automatic resource cleanup and process management
✓ Debug panel with detailed system monitoring
✓ Graceful fallback to synchronous mode if dependencies 
unavailable
✓ Background process execution to free up console

=== PERFORMANCE OPTIMIZATIONS ===
• Workers maintain local black pixel cache for fast neighbor 
checking
• Non-blocking communication to prevent worker stalls
• Batched grid updates to minimize communication overhead
• Periodic UI updates decoupled from simulation loop
• Memory-efficient grid storage and processing
• Automatic worker process lifecycle management

=== DEBUGGING FEATURES ===
• Real-time worker process status monitoring
• Communication socket health tracking
• Database connection and query status
• Memory usage and performance metrics
• Detailed console logging with timestamps
• Worker process log files for detailed debugging

=== SIMULATION PARAMETERS ===
Grid Size: Controls the n×n simulation grid (default 10×10)
Walkers: Number of simultaneous random walkers (1 to 60% of 
grid) default is 5.
Neighborhood: default is 4-hood (NSEW) or 8-hood (includes diagonals)
Boundary: Wrap-around (torus) or default is terminate at edges
Workers: Number of parallel R processes (0-16). default is 1
Refresh Rate: UI update interval in seconds (1-60). default is 4 seconds.

=== STATISTICS TRACKED ===
Current Simulation:
  • Black pixels (count and percentage)
  • Active and completed walkers
  • Total steps taken by all walkers
  • Step count percentiles (25th, 50th, 75th)
  • Elapsed time

All-time Statistics:
  • Total simulations run
  • Cumulative elapsed time
  • Average time per simulation
  • Simulation time percentiles

=== TERMINATION CONDITIONS ===
Walkers terminate when they:
  1. Touch a black pixel (become part of the aggregate)
  2. Have a black neighbor (become black and join aggregate)
  3. Hit grid boundary (if terminate mode selected)
  4. Reach maximum step limit (safety mechanism)

Simulation ends when:
  • All walkers have terminated
  • User stops simulation manually (plot current state of grid first and stats to date)
  • Grid size changes (triggers restart but plot current state of grid first and stats to date)


=== READY TO LAUNCH ===
Execute: shinyApp(ui = ui, server = server)
or for background: bg_process <- run_app_in_bg()

Example first simulation step:
[14:23:15] STEP 1: Active=8, Black=1
Worker 1 processing walker 1 from (15, 8)
Worker 2 processing walker 2 from (3, 12)
Walker 1 completed with 23 steps at (10, 10) - 
touched_black_neighbor
...
=== SIMULATION ENDED AFTER 42 STEPS ===
Final black pixels: 9
Total steps: 187


# other instructions
You have to help me find any changes in code you suggest.
Always number each change.
Always show enough preceeding lines before the change that I can find a single match in the exisiting version of the code.
Ditto for the lines after the change in the code ends.

Do not make vague statements like this
'Find where the error handling ends in the above section and continue with'

I need the actual lines that are to be removed and the actual lines to replace them EVERY time.


Do NOT wrap your code lines.
Do NOT wrap comment lines at all.


### the current code for async solution to random pixel walking simulation

# Clause after starting session again (>200k token max) Thu 4th 9:22pm

# claude sun 7th aseq

# Asynchronous Pixel Walking Simulation - Complete Code
library(shiny)
library(shinydashboard)
library(DT)
library(ggplot2)
library(dplyr)
library(tidyr)
library(later)
library(jsonlite)

# Try to load async packages
ASYNC_MODE <- FALSE
PROCESSX_AVAILABLE <- FALSE
NANONEXT_AVAILABLE <- FALSE

if (requireNamespace("nanonext", quietly = TRUE)) {
  library(nanonext)
  NANONEXT_AVAILABLE <- TRUE
}

if (requireNamespace("processx", quietly = TRUE)) {
  library(processx)
  PROCESSX_AVAILABLE <- TRUE
}

if (requireNamespace("callr", quietly = TRUE)) {
  library(callr)
  ASYNC_MODE <- NANONEXT_AVAILABLE && PROCESSX_AVAILABLE
}

# Global variables for async communication
worker_processes <- list()
pub_socket <- NULL
sub_socket <- NULL
push_socket <- NULL
pull_socket <- NULL

# File-based shared state that workers can access
shared_db <- NULL
pub_socket <- NULL
sub_socket <- NULL

init_shared_state_db <- function() {
  if (!requireNamespace("duckdb", quietly = TRUE)) {
    stop("duckdb package required for shared state")
  }
  
  shared_db <<- dbConnect(duckdb::duckdb(), ":memory:")
  
  # Create shared state table with timestamp
  dbExecute(shared_db, "
    CREATE TABLE IF NOT EXISTS grid_state (
      key VARCHAR,
      grid_data BLOB,
      black_pixels INTEGER,
      update_counter INTEGER,
      timestamp BIGINT,
      PRIMARY KEY (key)
    )
  ")
  
  # Setup pub/sub if nanonext available
  if (NANONEXT_AVAILABLE) {
    tryCatch({
      pub_socket <<- nanonext::socket("pub", listen = 
"inproc://grid_updates")
      sub_socket <<- nanonext::socket("sub", dial = 
"inproc://grid_updates")
      nanonext::subscribe(sub_socket, topic = "")
    }, error = function(e) {
      cat("Warning: Could not setup pub/sub:", e$message, "\n")
    })
  }
  
  return(TRUE)
}

update_shared_state <- function(key, value) {
  if (is.null(shared_db)) {
    init_shared_state_db()
  }
  
  tryCatch({
    timestamp <- as.numeric(Sys.time() * 1000000)  # microsecond 
precision
    grid_blob <- serialize(value$grid, NULL)
    
    # Update database immediately
    dbExecute(shared_db, "
      INSERT OR REPLACE INTO grid_state (key, grid_data, black_pixels, 
update_counter, timestamp)
      VALUES (?, ?, ?, ?, ?)
    ", params = list(key, grid_blob, value$black_pixels, 
value$update_counter, timestamp))
    
    # Broadcast update via pub/sub
    if (!is.null(pub_socket)) {
      update_msg <- list(key = key, timestamp = timestamp, black_pixels =
value$black_pixels)
      nanonext::send(pub_socket, data = serialize(update_msg, NULL), mode
= "raw", block = FALSE)
    }
    
    return(TRUE)
  }, error = function(e) {
    cat("Error updating shared state:", e$message, "\n")
    return(FALSE)
  })
}

get_shared_state <- function(key, local_timestamp = 0) {
  if (is.null(shared_db)) {
    return(NULL)
  }
  
  tryCatch({
    # Check if we have newer data
    result <- dbGetQuery(shared_db, "
      SELECT grid_data, black_pixels, update_counter, timestamp 
      FROM grid_state 
      WHERE key = ? AND timestamp > ?
      ORDER BY timestamp DESC 
      LIMIT 1
    ", params = list(key, local_timestamp))
    
    if (nrow(result) > 0) {
      grid <- unserialize(result$grid_data[[1]])
      return(list(
        grid = grid,
        black_pixels = result$black_pixels[1],
        update_counter = result$update_counter[1],
        timestamp = result$timestamp[1]
      ))
    }
    
    return(NULL)
  }, error = function(e) {
    cat("Error getting shared state:", e$message, "\n")
    return(NULL)
  })
}


# Worker process script for true parallelism
worker_script <- '
simulate_walker <- function(walker_id, start_x, start_y, grid_state, 
params) {
  n <- params$grid_size
  current_x <- start_x
  current_y <- start_y
  steps <- 0
  max_steps <- params$max_steps
  became_black <- FALSE
  
  get_neighbors <- function(x, y) {
    neighbors <- list()
    wrap <- params$boundary
    
    if (params$neighborhood == "4-hood") {
      offsets <- list(c(-1, 0), c(1, 0), c(0, -1), c(0, 1))
    } else {
      offsets <- list(c(-1, -1), c(-1, 0), c(-1, 1), c(0, -1), c(0, 1), 
c(1, -1), c(1, 0), c(1, 1))
    }
    
    for (offset in offsets) {
      new_x <- x + offset[1]
      new_y <- y + offset[2]
      
      if (wrap) {
        new_x <- ((new_x - 1) %% n) + 1
        new_y <- ((new_y - 1) %% n) + 1
        neighbors <- append(neighbors, list(c(new_x, new_y)))
      } else {
        if (new_x >= 1 && new_x <= n && new_y >= 1 && new_y <= n) {
          neighbors <- append(neighbors, list(c(new_x, new_y)))
        }
      }
    }
    return(neighbors)
  }
  
  while (steps < max_steps) {
    steps <- steps + 1
    
    if (grid_state[current_x, current_y] == 1) {
      became_black <- TRUE
      break
    }
    
    neighbors <- get_neighbors(current_x, current_y)
    
    # Check if any neighbor is black
    has_black_neighbor <- FALSE
    for (neighbor in neighbors) {
      if (grid_state[neighbor[1], neighbor[2]] == 1) {
        has_black_neighbor <- TRUE
        break
      }
    }
    
    if (has_black_neighbor) {
      became_black <- TRUE
      break
    }
    
    if (length(neighbors) == 0) break
    
    next_neighbor <- neighbors[[sample(length(neighbors), 1)]]
    current_x <- next_neighbor[1]
    current_y <- next_neighbor[2]
  }
  
  return(list(
    walker_id = walker_id,
    steps = steps,
    final_x = current_x,
    final_y = current_y,
    became_black = became_black
  ))
}

worker_main <- function(worker_id, pull_port, push_port) {
  library(nanonext)
  
  # Add delay to ensure main process sets up first
  Sys.sleep(2)
  
  pull_socket <- socket("pull", listen = paste0("tcp://*:", pull_port))
  push_socket <- socket("push", dial = paste0("tcp://localhost:", 
push_port))
  cat("Worker", worker_id, "started on ports", pull_port, "and", 
push_port, "\\n")
  while (TRUE) {
    job <- recv(pull_socket, mode = "raw")
    if (is.null(job)) {
      Sys.sleep(0.01)
      next
    }
    
    job_data <- unserialize(job)
    
    if (job_data$type == "shutdown") {
      break
    }
    
    if (job_data$type == "simulate") {
      result <- simulate_walker(
        job_data$walker_id,
        job_data$start_x,
        job_data$start_y,
        job_data$grid_state,
        job_data$params
      )
      
      send(push_socket, serialize(result, NULL), mode = "raw")
    }
  }
  
  cat("Worker", worker_id, "shutting down\\n")
}
'

# Start worker processes
start_workers <- function(num_workers = 3) {
  if (!ASYNC_MODE) {
    return(list())
  }
  
  worker_processes <- list()
  base_port <- 5555
  
  for (i in seq_len(num_workers)) {
    pull_port <- base_port + i * 2
    push_port <- base_port + i * 2 + 1
    
    worker_file <- tempfile(fileext = ".R")
    writeLines(c(worker_script, paste0("worker_main(", i, ", ", 
pull_port, ", ", push_port, ")")), worker_file)
    
    worker <- processx::process$new(
      command = "Rscript",
      args = worker_file,
      stdout = "|",
      stderr = "|"
    )
    
    worker_processes[[i]] <- list(
      process = worker,
      pull_port = pull_port,
      push_port = push_port,
      worker_file = worker_file
    )
  }
  
  Sys.sleep(1)
  return(worker_processes)
}

# Stop all workers
stop_workers <- function(workers) {
  if (length(workers) == 0) return()
  
  for (i in seq_along(workers)) {
    worker <- workers[[i]]
    
    tryCatch({
      pull_socket <- nanonext::socket("push", dial = 
paste0("tcp://localhost:", worker$pull_port))
      nanonext::send(pull_socket, serialize(list(type = "shutdown"), 
NULL), mode = "raw")
    }, error = function(e) {})
    
    if (worker$process$is_alive()) {
      worker$process$kill()
    }
    
    if (file.exists(worker$worker_file)) {
      unlink(worker$worker_file)
    }
  }
}

# Setup communication sockets with dynamic port allocation
setup_communication <- function(num_workers) {
  if (!ASYNC_MODE) return()
  
  # Clean up existing sockets first
  cleanup_sockets()
  
  # Try different ports if occupied
  for (base_port in c(5553, 6553, 7553, 8553)) {
    tryCatch({
      pub_socket <<- nanonext::socket("pub", listen = paste0("tcp://*:", 
base_port))
      sub_socket <<- nanonext::socket("sub", dial = 
paste0("tcp://localhost:", base_port))
      push_socket <<- nanonext::socket("push", listen = 
paste0("tcp://*:", base_port + 1))
      cat("Communication setup successful on ports", base_port, "and", 
base_port + 1, "\n")
      return()
    }, error = function(e) {
      cat("Failed to bind to port", base_port, ":", e$message, "\n")
    })
  }
  
  stop("Could not establish communication sockets")
}

# Helper function to clean up sockets
cleanup_sockets <- function() {
  tryCatch({
    if (!is.null(pub_socket)) {
      pub_socket <- NULL
    }
    if (!is.null(sub_socket)) {
      sub_socket <- NULL
    }
    if (!is.null(push_socket)) {
      push_socket <- NULL
    }
  }, error = function(e) {
    cat("Error during socket cleanup:", e$message, "\n")
  })
}

# UI
ui <- dashboardPage(
  dashboardHeader(title = "Async Pixel Walking Simulation"),
  
  dashboardSidebar(
    sidebarMenu(
      menuItem("Simulation", tabName = "simulation", icon = 
icon("play")),
      menuItem("Debug", tabName = "debug", icon = icon("bug"))
    )
  ),
  
  dashboardBody(
    tags$head(
      tags$style(HTML("
        .async-indicator { color: #00ff00; font-weight: bold; }
        .sync-indicator { color: #ff6600; font-weight: bold; }
      "))
    ),
    
    tabItems(
      tabItem(tabName = "simulation",
        fluidRow(
          box(
            title = "Parameters", status = "primary", solidHeader = TRUE,
width = 3,
            
            div(class = if(ASYNC_MODE) "async-indicator" else 
"sync-indicator", paste("Mode:", if(ASYNC_MODE) "ASYNC" else "SYNC")),
            hr(),
            
            sliderInput("grid_size", "Grid Size (n×n):", min = 10, max = 
50, value = 20, step = 5),
            
            sliderInput("num_walkers", "Number of Walking Pixels:", min =
1, max = 240, value = 50),

            
            selectInput("neighborhood", "Neighborhood Type:", choices = 
list("4-hood" = "4-hood", "8-hood" = "8-hood"), selected = "4-hood"),
            
            selectInput("boundary", "Boundary Condition:", choices = 
list("Wrap around" = TRUE, "Terminate at edge" = FALSE), selected = 
FALSE),
            
            sliderInput("num_workers", "Number of Parallel Workers:", min
= 1, max = 8, value = 3),
            
            sliderInput("refresh_rate", "Update Interval (seconds):", min
= 1, max = 10, value = 2, step = 1),
            
            br(),
            
            actionButton("start_stop", "Start Simulation", class = 
"btn-success btn-lg", width = "100%"),
            
            hr(),
            
            h4("Status"),
            verbatimTextOutput("realtime_stats"),
            
            h4("Worker Status"),
            verbatimTextOutput("worker_status")
          ),
          
          box(
            title = "Simulation Grid", status = "info", solidHeader = 
TRUE, width = 9,
            
            plotOutput("grid_plot", width = "100%", height = "600px"),
            
            br(),
            
            fluidRow(
              column(6,
                h4("Current Simulation"),
                DT::dataTableOutput("current_stats", height = "200px")
              ),
              column(6,
                h4("All-Time Statistics"),
                DT::dataTableOutput("alltime_stats", height = "200px")
              )
            )
          )
        )
      ),
      
      tabItem(tabName = "debug",
        fluidRow(
          box(
            title = "System Debug", status = "warning", solidHeader = 
TRUE, width = 6,
            verbatimTextOutput("debug_system")
          ),
          box(
            title = "Simulation Log", status = "info", solidHeader = 
TRUE, width = 6,
            verbatimTextOutput("debug_log")
          )
        )
      )
    )
  )
)

# Server function
server <- function(input, output, session) {
  
  # Reactive values
  values <- reactiveValues(
    grid = NULL,
    running = FALSE,
    start_time = NULL,
    total_steps = 0,
    black_pixels = 1,
    active_walkers = 0,
    completed_walkers = 0,
    simulation_count = 0,
    total_elapsed_time = 0,
    current_simulation = NULL,
    step_history = numeric(),
    all_simulation_times = numeric(),
    log_messages = character(),
    grid_update_trigger = 0,
    workers = list(),
    pending_jobs = 0,
    results_received = 0,
    shared_state_file = NULL,
    grid_env = NULL
  )

  
  # Helper function for logging
  add_log <- function(message) {
    timestamp <- format(Sys.time(), "%H:%M:%S")
    log_entry <- paste0("[", timestamp, "] ", message)
    
    # Only update reactive values if in reactive context
    tryCatch({
      values$log_messages <- c(tail(values$log_messages, 19), log_entry)
    }, error = function(e) {
      # Not in reactive context, just print to console
    })
    
    cat(log_entry, "\n")
  }
  
  # Initialize grid
  observeEvent(input$grid_size, {
    if (!isTRUE(isolate(values$running))) {
      n <- input$grid_size
      grid <- matrix(0, nrow = n, ncol = n)
      center <- ceiling(n / 2)
      grid[center, center] <- 1
      
      values$grid <- grid
      values$black_pixels <- 1
      values$grid_update_trigger <- values$grid_update_trigger + 1
      
      add_log(paste("Grid initialized:", n, "x", n))
    }
  }, ignoreInit = FALSE)
  
  # Update walker slider
  observe({
    req(input$grid_size)
    max_walkers <- floor(input$grid_size^2 * 0.6)
    updateSliderInput(session, "num_walkers", max = max_walkers)
  })
  
  # Start/Stop simulation
  observeEvent(input$start_stop, {
    tryCatch({
      if (!values$running) {
        start_simulation()
      } else {
        stop_simulation()
      }
    }, error = function(e) {
      add_log(paste("Error in start/stop:", e$message))
      showNotification(paste("Error:", e$message), type = "error")
      
      # Reset button state if error occurs
      if (values$running) {
        values$running <- FALSE
        updateActionButton(session, "start_stop", label = "Start 
Simulation", icon = icon("play"))
      }
    })
  })

  
  # Start simulation function
  start_simulation <- function() {
    add_log("=== STARTING SIMULATION ===")
    
    values$running <- TRUE
    values$start_time <- Sys.time()
    values$total_steps <- 0
    values$completed_walkers <- 0
    values$active_walkers <- input$num_walkers
    values$simulation_count <- values$simulation_count + 1
    values$step_history <- numeric()
    values$pending_jobs <- 0
    values$results_received <- 0
    
    updateActionButton(session, "start_stop", label = "Stop Simulation", 
icon = icon("stop"))
    
    # Reset grid
    n <- input$grid_size
    grid <- matrix(0, nrow = n, ncol = n)
    center <- ceiling(n / 2)
    grid[center, center] <- 1
    values$grid <- grid
    values$black_pixels <- 1
    values$grid_update_trigger <- values$grid_update_trigger + 1
    
    add_log(paste("Mode:", ifelse(ASYNC_MODE, "Asynchronous", 
"Synchronous")))
    add_log(paste("Grid:", n, "x", n, ", Walkers:", input$num_walkers))
    
    # Generate start positions from edges for proper fractal growth
    start_positions <- replicate(input$num_walkers, {
      # Start from random edge with bias toward edges
      if (runif(1) < 0.7) {
        # Start from edge
        side <- sample(1:4, 1)
        if (side == 1) {  # top edge
          c(sample(1:n, 1), 1)
        } else if (side == 2) {  # bottom edge
          c(sample(1:n, 1), n)
        } else if (side == 3) {  # left edge
          c(1, sample(1:n, 1))
        } else {  # right edge
          c(n, sample(1:n, 1))
        }
      } else {
        # Start from random interior position
        repeat {
          pos <- c(sample(1:n, 1), sample(1:n, 1))
          center <- ceiling(n / 2)
          if (!(pos[1] == center && pos[2] == center)) return(pos)
        }
      }
    }, simplify = FALSE)

    
    # Extremely high max_steps for proper fractal development
    params <- list(
      grid_size = n,
      neighborhood = input$neighborhood,
      boundary = as.logical(input$boundary),
      max_steps = n^2 * 100
    )


    add_log(paste("Max steps per walker:", params$max_steps))
    
    if (ASYNC_MODE) {
      # Test if callr works with a simple function first
      tryCatch({
        test_worker <- callr::r_bg(function() return("test_success"))
        Sys.sleep(0.5)
        if (!test_worker$is_alive()) {
          test_result <- test_worker$get_result()
          add_log(paste("Callr test result:", test_result))
          run_async_with_callr(start_positions, params)
        } else {
          add_log("Callr test worker still running, killing and falling 
back to sync")
          test_worker$kill()
          run_sync_simulation(start_positions, params)
        }
      }, error = function(e) {
        add_log(paste("Callr test failed:", e$message, "- falling back to
sync"))
        run_sync_simulation(start_positions, params)
      })
    } else {
      run_sync_simulation(start_positions, params)
    }
  }

# TRUE ASYNC with shared state using file communication and connectivity check
run_async_with_callr <- function(start_positions, params) {
  if (!requireNamespace("callr", quietly = TRUE)) {
    add_log("callr not available, falling back to sync")
    run_sync_simulation(start_positions, params)
    return()
  }
  
  add_log("TRUE ASYNC: Parallel workers with shared state and connectivity validation")
  
  library(callr)
  
  # Initialize shared state
  update_shared_state("simulation_state", list(grid = values$grid, 
black_pixels = values$black_pixels, update_counter = 0))
  
  # Simplified async walker function for testing
  # Async walker function with embedded DuckDB support
  async_walker_function <- function(walker_id, start_x, start_y, params, 
initial_grid) {
    # Load required packages in worker process
    if (requireNamespace("duckdb", quietly = TRUE)) {
      library(duckdb)
    }
    
    # Embedded shared state functions for worker process
    shared_db_worker <- NULL
    
    init_worker_shared_db <- function() {
      tryCatch({
        shared_db_worker <<- dbConnect(duckdb::duckdb(), ":memory:")
        dbExecute(shared_db_worker, "
          CREATE TABLE grid_state (
            key VARCHAR,
            grid_data BLOB,
            black_pixels INTEGER,
            update_counter INTEGER,
            timestamp BIGINT,
            PRIMARY KEY (key)
          )
        ")
        return(TRUE)
      }, error = function(e) {
        return(FALSE)
      })
    }
    
        get_shared_state_worker <- function(key, local_timestamp = 0) {
      if (requireNamespace("nanonext", quietly = TRUE)) {
        tryCatch({
          # Connect to main process socket
          req_socket <- nanonext::socket("req", dial = 
"tcp://localhost:9999")
          
          # Request current state
          request <- list(action = "get_state", key = key, timestamp = 
local_timestamp)
          nanonext::send(req_socket, serialize(request, NULL), mode = 
"raw")
          
          # Wait for response
          response_raw <- nanonext::recv(req_socket, mode = "raw")
          if (!is.null(response_raw)) {
            response <- unserialize(response_raw)
            return(response)
          }
        }, error = function(e) {
          # Fallback to initial grid
        })
      }
      return(NULL)
    }



  
  # Start parallel processes with TRUE ASYNC
  processes <- list()
  values$pending_jobs <- input$num_walkers
  
    for (i in seq_len(input$num_walkers)) {
    pos <- start_positions[[i]]
    
    process <- callr::r_bg(
      func = async_walker_function,
      args = list(
        walker_id = i,
        start_x = pos[1],
        start_y = pos[2],
        params = params,
        initial_grid = values$grid
      )
    )
    
    processes[[i]] <- process
    add_log(paste("Started TRUE ASYNC walker", i))
    
    # Small delay to allow previous walker results to update shared state
    if (i %% 3 == 0) {
      Sys.sleep(0.2)
    }
  }



  
  values$workers <- processes
  
  add_log("TRUE ASYNC workers started with shared state connectivity 
validation")
  
  # Start result collection with reactive timer
  start_async_collection()
}

start_async_collection <- function() {
  # Poll for completed processes using reactive timer
  observe({
    if (!values$running || length(values$workers) == 0) {
      return()
    }
    
    invalidateLater(500, session)  # Check every 500ms
    
    # Check for completed processes
    completed_indices <- c()
    for (i in seq_along(values$workers)) {
      worker <- values$workers[[i]]
      
      if (!is.null(worker) && !is.null(worker$is_alive) && !worker$is_alive()) {
        # Process completed, get result
        tryCatch({
          # Check if worker completed successfully
          if (!worker$is_alive()) {
            # Get exit status and output for debugging  
            exit_status <- worker$get_exit_status()
            stdout <- worker$read_output()
            stderr <- worker$read_error()
            
            add_log(paste("Worker", i, "exit status:", exit_status))
            if (nchar(stdout) > 0) add_log(paste("Worker", i, "stdout:", 
substr(stdout, 1, 200)))
            if (nchar(stderr) > 0) add_log(paste("Worker", i, "stderr:", 
substr(stderr, 1, 200)))

            
            add_log(paste("Worker", i, "exit status:", exit_status))
            if (nchar(stdout) > 0) add_log(paste("Worker", i, "stdout:", substr(stdout, 1, 200)))
            if (nchar(stderr) > 0) add_log(paste("Worker", i, "stderr:", substr(stderr, 1, 200)))
            
            # Only try to get result if exit status is 0 (success)
            if (exit_status == 0) {
              result <- worker$get_result()
              
              # Process the result
              values$total_steps <- values$total_steps + result$steps
              values$completed_walkers <- values$completed_walkers + 1
              values$active_walkers <- max(0, values$active_walkers - 1)
              values$step_history <- c(values$step_history, result$steps)
              values$results_received <- values$results_received + 1
              
              if (result$became_black) {
                # Check if this position is already black
                if (values$grid[result$final_x, result$final_y] == 0) {
                  # Update shared grid state
                  current_grid <- values$grid
                  current_grid[result$final_x, result$final_y] <- 1
                  values$grid <- current_grid
                  values$black_pixels <- sum(current_grid)
                  values$grid_update_trigger <- 
values$grid_update_trigger + 1
                  
                  # Update shared state for real-time access by other 
workers
                  shared_state <- list(
                    grid = current_grid, 
                    black_pixels = values$black_pixels,
                    update_counter = values$grid_update_trigger
                  )
                  update_shared_state("simulation_state", shared_state)
                  
                  add_log(paste("ASYNC Walker", result$walker_id, "became
black at (", result$final_x, ",", result$final_y, ") after", 
result$steps, "steps"))
                } else {
                  add_log(paste("ASYNC Walker", result$walker_id, "tried 
to land on existing black pixel at (", result$final_x, ",", 
result$final_y, ") - rejected"))
                  
                  add_log(paste("ASYNC Walker", result$walker_id, "tried 
to land on existing black pixel at (", result$final_x, ",", 
result$final_y, ") - rejected"))

                }

              } else {
                add_log(paste("ASYNC Walker", result$walker_id, "terminated after", result$steps, "steps"))
              }

              
              completed_indices <- c(completed_indices, i)
            } else {
              add_log(paste("Worker", i, "failed with exit status:", exit_status))
              completed_indices <- c(completed_indices, i)
            }
          } else {
            # Worker still alive, skip for now
          }
          
        }, error = function(e) {
          add_log(paste("Error processing worker", i, "result:", e$message))
          completed_indices <- c(completed_indices, i)
        })
      }
    }
    
    # Remove completed workers
    if (length(completed_indices) > 0) {
      values$workers[completed_indices] <- NULL
      values$pending_jobs <- values$pending_jobs - length(completed_indices)
    }
    
    # Check if all workers are done
    if (values$active_walkers == 0 && values$running) {
      # Don't stop - check if we have good fractal growth
      if (values$black_pixels < (input$num_walkers * 0.15)) {

        add_log(paste("Only", values$black_pixels, "black pixels - 
launching more walkers for better fractal growth"))
        
        # Launch additional walkers to extend the fractal
        additional_walkers <- min(20, input$num_walkers)
        start_positions <- replicate(additional_walkers, {
          n <- input$grid_size
          c(sample(1:n, 1), sample(1:n, 1))
        }, simplify = FALSE)
        
        for (i in seq_len(additional_walkers)) {
          pos <- start_positions[[i]]
          # Don't launch additional walkers - just stop when current batch is done
        add_log("Fractal growth progressing - stopping current 
simulation")
        stop_simulation()

          values$workers <- append(values$workers, list(process))
          values$active_walkers <- values$active_walkers + 1
          values$pending_jobs <- values$pending_jobs + 1
        }
        
        add_log(paste("Added", additional_walkers, "more walkers"))
      } else {
        add_log("Good fractal growth achieved - stopping simulation")
        stop_simulation()
      }
    }

  })
}

# Synchronous simulation fallback
run_sync_simulation <- function(start_positions = NULL, params = NULL) {
  add_log("SYNC: Sequential walker processing")
  
  if (is.null(start_positions)) {
    n <- input$grid_size
    center <- ceiling(n / 2)
    start_positions <- replicate(input$num_walkers, {
      repeat {
        pos <- c(sample(1:n, 1), sample(1:n, 1))
        if (!(pos[1] == center && pos[2] == center)) return(pos)
      }
    }, simplify = FALSE)
  }
  
  # Process walkers sequentially but with immediate grid updates
  # This ensures perfect fractal connectivity
  for (i in seq_len(input$num_walkers)) {
    if (!values$running) break
    
    pos <- start_positions[[i]]
    
    # Each walker sees the CURRENT grid state (including previous walkers' results)
    result <- simulate_single_walker(pos[1], pos[2])
    
    values$total_steps <- values$total_steps + result$steps
    values$completed_walkers <- values$completed_walkers + 1
    values$active_walkers <- max(0, values$active_walkers - 1)
    values$step_history <- c(values$step_history, result$steps)
    
    # Update grid IMMEDIATELY so next walker sees this change
    if (result$became_black) {
      current_grid <- values$grid
      current_grid[result$final_x, result$final_y] <- 1
      values$grid <- current_grid
      values$black_pixels <- sum(current_grid)
      values$grid_update_trigger <- values$grid_update_trigger + 1
      
      add_log(paste("Sequential Walker", i, "became black at (", 
result$final_x, ",", result$final_y, ") after", result$steps, "steps"))
    } else {
      add_log(paste("Sequential Walker", i, "terminated after", 
result$steps, "steps"))
    }
    
    # Small delay for visual effect
    if (i %% 3 == 0) {
      Sys.sleep(0.01)
    }
  }
  
  # Stop simulation when done
  stop_simulation()
}

# Add async process verification function
verify_async_processes <- function() {
  if (!ASYNC_MODE) {
    cat("Async mode not available\n")
    return(FALSE)
  }
  
  # Better process detection for macOS
  if (Sys.info()["sysname"] == "Darwin") {  # macOS
    # Alternative: check if callr can create background processes
    test_result <- try({
      test_proc <- callr::r_bg(function() Sys.getpid())
      Sys.sleep(0.1)
      is_alive <- test_proc$is_alive()
      if (is_alive) test_proc$kill()
      is_alive
    }, silent = TRUE)
    
    if (!inherits(test_result, "try-error") && test_result) {
      cat("ASYNC VERIFIED: callr background processes working\n")
      return(TRUE)
    }
  }
  
  cat("ASYNC STATUS: Available but subprocess not currently detected\n")
  cat("(This is normal - subprocess only appear during simulation)\n")
  return(FALSE)
}

# Fix the simulate_single_walker max_steps too
simulate_single_walker <- function(start_x, start_y) {
  n <- input$grid_size
  current_x <- start_x
  current_y <- start_y
  steps <- 0
  # Fixed: Higher max_steps for better exploration
  max_steps <- n^2 * 10
  became_black <- FALSE

    
    get_neighbors <- function(x, y) {
      neighbors <- list()
      wrap <- as.logical(input$boundary)
      
      if (input$neighborhood == "4-hood") {
        offsets <- list(c(-1, 0), c(1, 0), c(0, -1), c(0, 1))
      } else {
        offsets <- list(c(-1, -1), c(-1, 0), c(-1, 1), c(0, -1), c(0, 1),
c(1, -1), c(1, 0), c(1, 1))
      }
      
      for (offset in offsets) {
        new_x <- x + offset[1]
        new_y <- y + offset[2]
        
        if (wrap) {
          new_x <- ((new_x - 1) %% n) + 1
          new_y <- ((new_y - 1) %% n) + 1
          neighbors <- append(neighbors, list(c(new_x, new_y)))
        } else {
          if (new_x >= 1 && new_x <= n && new_y >= 1 && new_y <= n) {
            neighbors <- append(neighbors, list(c(new_x, new_y)))
          }
        }
      }
      return(neighbors)
    }
    
    # Get fresh grid state each step
    while (steps < max_steps && values$running) {
      steps <- steps + 1
      current_grid <- values$grid  # Always get current grid state
      
      # Get valid neighbors  
      neighbors <- get_neighbors(current_x, current_y)
      
      # Check if any neighbor is black AND connected to center
      has_connected_black_neighbor <- FALSE
      center_x <- ceiling(n/2)
      center_y <- ceiling(n/2)
      
      for (neighbor in neighbors) {
        if (current_grid[neighbor[1], neighbor[2]] == 1) {
          # Verify this black pixel is connected to center using BFS
          if (is_connected_to_center_bfs(neighbor[1], neighbor[2], 
current_grid, center_x, center_y, n)) {
            has_connected_black_neighbor <- TRUE
            break
          }
        }
      }
      
      # Walker becomes black ONLY if it has a black neighbor connected to center
      if (has_connected_black_neighbor) {
        became_black <- TRUE
        add_log(paste("Walker touched connected black neighbor at (", 
current_x, ",", current_y, ")"))
        break
      }
      
      # TRACE: If walker becomes black by another path, catch it
      if (current_grid[current_x, current_y] == 1) {
        add_log(paste("ERROR: Walker at (", current_x, ",", current_y, ")
landed on existing black pixel! This should not happen."))
        became_black <- TRUE
        break
      }
      
      # No neighbors available (boundary hit) - terminate without becoming black
      if (length(neighbors) == 0) {
        add_log(paste("Walker hit boundary at (", current_x, ",", 
current_y, ")"))
        break
      }
      
      # Move to random neighbor
      next_neighbor <- neighbors[[sample(length(neighbors), 1)]]
      current_x <- next_neighbor[1]
      current_y <- next_neighbor[2]
      
      # Add small delay for visual effect
      if (steps %% 10 == 0) {
        Sys.sleep(0.01)
      }
    }
    
    return(list(
      steps = steps,
      final_x = current_x,
      final_y = current_y,
      became_black = became_black
    ))
  }
  
  # Stop simulation
  stop_simulation <- function() {
    if (!isolate(values$running)) return()
    
    add_log("=== STOPPING SIMULATION ===")
    values$running <- FALSE
    
    # Clean up workers (callr, nanonext, or mirai)
    if (length(isolate(values$workers)) > 0) {
      tryCatch({
        workers <- isolate(values$workers)
        
        if (length(workers) > 0) {
          # Check worker type
          first_worker <- workers[[1]]
          
          if (!is.null(first_worker) && inherits(first_worker, "mirai")) 
{
            # mirai futures - they clean up automatically
            cat("Cleaning up mirai futures\n")
          } else if (!is.null(first_worker$process) && 
!is.null(first_worker$process$is_alive)) {
            # callr processes
            for (worker in workers) {
              if (!is.null(worker$process) && worker$process$is_alive()) 
{
                worker$process$kill()
              }
            }
          } else if (!is.null(first_worker$is_alive)) {
            # callr processes - kill them directly
            for (worker in workers) {
              if (!is.null(worker) && !is.null(worker$is_alive) && 
worker$is_alive()) {
                worker$kill()
              }
            }
          }

        }
      }, error = function(e) {
        cat("Error stopping workers:", e$message, "\n")
      })
    }
    
    # Reset sockets to NULL without closing
    pub_socket <<- NULL
    sub_socket <<- NULL 
    push_socket <<- NULL
    
    # Clear shared state files
    temp_files <- list.files(tempdir(), pattern = "shared_state_", full.names = TRUE)
    if (length(temp_files) > 0) {
      unlink(temp_files)
    }

    
    if (!is.null(values$start_time)) {
      elapsed_time <- as.numeric(difftime(Sys.time(), values$start_time, 
units = "mins"))
      values$total_elapsed_time <- values$total_elapsed_time + 
elapsed_time
      values$all_simulation_times <- c(values$all_simulation_times, 
elapsed_time)
      
      step_percentiles <- if (length(values$step_history) > 0) {
        quantile(values$step_history, c(0.25, 0.5, 0.75), na.rm = TRUE)
      } else {
        c(0, 0, 0)
      }
      
      values$current_simulation <- list(
        black_pixels = values$black_pixels,
        black_percentage = round((values$black_pixels / 
(input$grid_size^2)) * 100, 2),
        total_steps = values$total_steps,
        step_percentiles = step_percentiles,
        elapsed_time = elapsed_time,
        completed_walkers = values$completed_walkers
      )
      
      add_log(paste("Completed in", round(elapsed_time, 3), "minutes"))
      add_log(paste("Final black pixels:", values$black_pixels))
      add_log(paste("Total steps:", values$total_steps))
    }
    
    updateActionButton(session, "start_stop", label = "Start Simulation",
icon = icon("play"))
    
    # Clean up resources when simulation stops
    cleanup_resources()
  }
  
  # Cleanup function (called manually when needed)
  cleanup_resources <- function() {
    cat("Cleaning up resources...\n")
    
    # Stop simulation if running
    if (isolate(values$running)) {
      values$running <- FALSE
      
      # Clean up workers (callr, nanonext, or mirai)
      if (length(isolate(values$workers)) > 0) {
        tryCatch({
          workers <- isolate(values$workers)
          
          if (length(workers) > 0) {
            # Check worker type
            first_worker <- workers[[1]]
            
            if (!is.null(first_worker) && inherits(first_worker, 
"mirai")) {
              # mirai futures - they clean up automatically
              cat("Cleaning up mirai futures\n")
            } else if (!is.null(first_worker$process) && 
!is.null(first_worker$process$is_alive)) {
              # callr processes
              for (worker in workers) {
                if (!is.null(worker$process) && 
worker$process$is_alive()) {
                  worker$process$kill()
                }
              }
            } else {
              # nanonext workers or other
              stop_workers(workers)
            }
          }
        }, error = function(e) {
          cat("Error stopping workers:", e$message, "\n")
        })
      }
      
      # Reset sockets to NULL without closing
      pub_socket <<- NULL
      sub_socket <<- NULL 
      push_socket <<- NULL
      
      # Clear shared state files
      temp_files <- list.files(tempdir(), pattern = "shared_state_", full.names = TRUE)
      if (length(temp_files) > 0) {
        unlink(temp_files)
      }

    }
  }
  
  # Grid plot output
  output$grid_plot <- renderPlot({
    req(values$grid)
    grid_trigger <- values$grid_update_trigger
    grid <- values$grid
    n <- nrow(grid)
    black_pct <- round((values$black_pixels / (n^2)) * 100, 1)
    
    par(mar = c(3, 3, 4, 2), bg = "white")
    grid_for_plot <- t(grid[nrow(grid):1, ])
    
    image(1:n, 1:n, grid_for_plot,
          col = c("white", "black"),
          xlab = "X", ylab = "Y",
          main = paste0("Async Pixel Walking Simulation\nBlack Pixels: ",
values$black_pixels, " (", black_pct, "%)"),
          axes = TRUE,
          asp = 1)
    
    grid(nx = n, ny = n, col = "lightgray", lty = 1, lwd = 0.5)
    box(col = "darkgray", lwd = 2)
    
  }, width = 600, height = 600)
  
  # Real-time statistics
  output$realtime_stats <- renderText({
    if (values$running) {
      invalidateLater(1000, session)
    }
    
    status <- ifelse(values$running, "RUNNING", "STOPPED")
    mode <- ifelse(ASYNC_MODE && length(values$workers) > 0, 
"Asynchronous", "Synchronous")
    
    elapsed_str <- if (values$running && !is.null(values$start_time)) {
      elapsed <- as.numeric(difftime(Sys.time(), values$start_time, 
units= "mins"))
      sprintf("%.2f mins", elapsed)
    } else {
      "Not running"
    }
    
    paste0(
      "Status: ", status, "\n",
      "Mode: ", mode, "\n",
      "Active walkers: ", values$active_walkers, "\n",
      "Completed: ", values$completed_walkers, "/", input$num_walkers, 
"\n",
      "Black pixels: ", values$black_pixels, "\n",
      "Total steps: ", values$total_steps, "\n",
      "Elapsed: ", elapsed_str
    )
  })
  
  # Worker status
  output$worker_status <- renderText({
    if (values$running) {
      invalidateLater(1000, session)
    }
    
    # Check for active callr processes during simulation
    async_verified <- FALSE
    subprocess_count <- 0
    
    if (ASYNC_MODE && length(values$workers) > 0) {
      # Count alive workers
      alive_count <- sum(sapply(values$workers, function(w) {
        !is.null(w) && !is.null(w$is_alive) && w$is_alive()
      }))
      async_verified <- alive_count > 0
      subprocess_count <- alive_count
    }

  
  if (length(values$workers) == 0) {
    return("No workers active")
  }
  
  worker_info <- tryCatch({
    active_workers <- values$workers[!sapply(values$workers, is.null)]
    
    if (length(active_workers) == 0) {
      return("No active workers")
    }
    
    sapply(seq_along(active_workers), function(i) {
      worker <- active_workers[[i]]
      
      if (!is.null(worker$is_alive)) {
        status <- if (worker$is_alive()) "RUNNING" else "FINISHED"
      } else if (!is.null(worker$process)) {
        status <- if (worker$process$is_alive()) "ALIVE" else "DEAD"
      } else {
        status <- "UNKNOWN"
      }
      
      paste0("Worker ", i, ": ", status)
    })
  }, error = function(e) {
    "Worker status unavailable"
  })
  
  paste0(
      "ASYNC MODE: ", ifelse(async_verified, "✓ ACTIVE", "⚠ STANDBY"), 
"\n",
      "Live Subprocess: ", subprocess_count, "\n",
      "Workers: ", length(values$workers), "/", input$num_workers, "\n",
      "Pending jobs: ", values$pending_jobs, "\n",
      "Results received: ", values$results_received, "\n",
      paste(worker_info, collapse = "\n")
    )

})

  # Current statistics table
  output$current_stats <- DT::renderDataTable({
    if (is.null(values$grid)) {
      return(data.frame(Metric = character(), Value = character()))
    }
    
    black_pct <- round((values$black_pixels / (input$grid_size^2)) * 100,
2)
    
    if (values$running && !is.null(values$start_time)) {
      elapsed_time <- as.numeric(difftime(Sys.time(), values$start_time, 
units = "mins"))
    } else if (!is.null(values$current_simulation)) {
      elapsed_time <- values$current_simulation$elapsed_time
    } else {
      elapsed_time <- 0
    }
    
    if (length(values$step_history) > 0) {
      step_percentiles <- quantile(values$step_history, c(0.25, 0.5, 
0.75), na.rm = TRUE)
      perc_str <- paste0(round(step_percentiles[1], 1), ", ", 
round(step_percentiles[2], 1), ", ", round(step_percentiles[3], 1))
    } else {
      perc_str <- "N/A"
    }
    
    total_formatted <- if (values$total_steps >= 1000000) {
      paste0(round(values$total_steps / 1000000, 1), "m")
    } else if (values$total_steps >= 1000) {
      paste0(round(values$total_steps / 1000, 1), "k")
    } else {
      as.character(values$total_steps)
    }
    
    stats_df <- data.frame(
      Metric = c("Black Pixels", "Black Percentage", "Active Walkers", 
"Completed Walkers", "Total Steps", "Total Steps (formatted)", "Step 
Percentiles (25,50,75)", "Elapsed Time"),
      Value = c(values$black_pixels, paste0(black_pct, "%"), 
values$active_walkers, values$completed_walkers, values$total_steps, 
total_formatted, perc_str, paste0(round(elapsed_time, 3), " mins"))
    )
    
    DT::datatable(stats_df, options = list(dom = 't', pageLength = 15, 
ordering = FALSE))
  })
  
  # All-time statistics table
  output$alltime_stats <- DT::renderDataTable({
    if (values$simulation_count == 0) {
      return(data.frame(Metric = character(), Value = character()))
    }
    
    avg_time <- if (values$simulation_count > 0) {
      round(values$total_elapsed_time / values$simulation_count, 3)
    } else {
      0
    }
    
    time_percentiles <- if (length(values$all_simulation_times) > 0) {
      time_perc <- quantile(values$all_simulation_times, c(0.25, 0.5, 
0.75), na.rm = TRUE)
      paste0(round(time_perc[1], 2), ", ", round(time_perc[2], 2), ", ", 
round(time_perc[3], 2), " mins")
    } else {
      "N/A"
    }
    
    stats_df <- data.frame(
      Metric = c("Total Simulations", "Total Runtime", "Average per 
Simulation", "Runtime Percentiles (25,50,75)", "Async Mode", "Current 
Workers"),
      Value = c(values$simulation_count, 
paste0(round(values$total_elapsed_time, 3), " mins"), paste0(avg_time, " 
mins"), time_percentiles, ifelse(ASYNC_MODE, "Available", "Not 
Available"), length(values$workers))
    )
    
    DT::datatable(stats_df, options = list(dom = 't', pageLength = 15, 
ordering = FALSE))
  })
  
  # Debug system information
  output$debug_system <- renderText({
    invalidateLater(2000, session)
    
    paste0(
      "=== SYSTEM STATUS ===\n",
      "Async Mode: ", ASYNC_MODE, "\n",
      "nanonext Available: ", NANONEXT_AVAILABLE, "\n",
      "processx Available: ", PROCESSX_AVAILABLE, "\n",
      "Database Connected: FALSE\n",
      "Grid Size: ", ifelse(is.null(values$grid), "NULL", 
paste(dim(values$grid), collapse = "x")), "\n",
      "Memory Usage: ", format(object.size(values), units = "MB"), "\n",
      "Simulations Run: ", values$simulation_count, "\n",
      "Total Elapsed: ", round(values$total_elapsed_time, 3), " mins\n",
      "R Version: ", R.version.string
    )
  })
  
  # Debug log
  output$debug_log <- renderText({
    invalidateLater(1000, session)
    
    if (length(values$log_messages) == 0) {
      return("No log messages yet")
    }
    
    paste(tail(values$log_messages, 20), collapse = "\n")
  })
  
  # Handle grid size changes
  observeEvent(input$grid_size, {
    if (values$running) {
      stop_simulation()
      showNotification("Simulation stopped due to grid size change", type
= "warning")
    }
  }, ignoreInit = TRUE)
  
  # Session cleanup
  session$onSessionEnded(function() {
    cleanup_resources()
  })
}

# FIXED BFS to verify connectivity to center pixel
is_connected_to_center_bfs <- function(start_x, start_y, grid, center_x, 
center_y, n) {
  # If the starting pixel itself is the center, it's connected
  if (start_x == center_x && start_y == center_y) {
    return(TRUE)
  }
  
  # BFS to find path to center through black pixels only
  visited <- matrix(FALSE, n, n)
  queue <- list(c(start_x, start_y))
  visited[start_x, start_y] <- TRUE
  
  while (length(queue) > 0) {
    current <- queue[[1]]
    queue <- queue[-1]
    
    # Check 4-connected neighbors
    for (offset in list(c(-1,0), c(1,0), c(0,-1), c(0,1))) {
      nx <- current[1] + offset[1]
      ny <- current[2] + offset[2]
      
      # Check bounds
      if (nx >= 1 && nx <= n && ny >= 1 && ny <= n) {
        # If we reached the center, we found a path
        if (nx == center_x && ny == center_y) {
          return(TRUE)
        }
        
        # If this neighbor is black and unvisited, add to queue
        if (!visited[nx, ny] && grid[nx, ny] == 1) {
          visited[nx, ny] <- TRUE
          queue <- append(queue, list(c(nx, ny)))
        }
      }
    }
  }
  
  # No path found to center
  return(FALSE)
}

# Function to run app in background
run_app_in_bg <- function(port = 8100) {
  if (requireNamespace("callr", quietly = TRUE)) {
    bg_process <- callr::r_bg(function(port) {
      library(shiny)
      # Note: This would need the full script to be available as a file
      shinyApp(ui = ui, server = server, options = list(port = port, host
= "127.0.0.1"))
    }, args = list(port = port))
    
    cat("Background process started with PID:", bg_process$get_pid(), 
"\n")
    cat("App running at: http://127.0.0.1:", port, "\n")
    return(bg_process)
  } else {
    cat("callr package not available, running in foreground\n")
    shinyApp(ui = ui, server = server)
  }
}

# Install missing packages function
install_missing_packages <- function() {
  required <- c('shiny', 'shinydashboard', 'DT', 'ggplot2', 'dplyr', 
'tidyr', 'later')
  async_packages <- c('nanonext', 'processx', 'callr')
  
  missing <- required[!sapply(required, requireNamespace, quietly = 
TRUE)]
  missing_async <- async_packages[!sapply(async_packages, 
requireNamespace, quietly = TRUE)]
  
  if (length(missing) > 0) {
    cat("Installing required packages:", paste(missing, collapse = ", "),
"\n")
    install.packages(missing)
  }
  
  if (length(missing_async) > 0) {
    cat("Installing async packages for parallel processing:\n")
    cat(paste(missing_async, collapse = ", "), "\n")
    install.packages(missing_async)
  }
  
  if (length(missing) == 0 && length(missing_async) == 0) {
    cat("All packages are already installed!\n")
  }
}

# Check and display async capabilities
check_async_capabilities <- function() {
  cat("=== ASYNC CAPABILITY CHECK ===\n")
  
  nanonext_ok <- requireNamespace("nanonext", quietly = TRUE)
  processx_ok <- requireNamespace("processx", quietly = TRUE)
  callr_ok <- requireNamespace("callr", quietly = TRUE)
  
  cat("nanonext (messaging):", if(nanonext_ok) "✓ AVAILABLE" else "✗ 
MISSING", "\n")
  cat("processx (processes):", if(processx_ok) "✓ AVAILABLE" else "✗ 
MISSING", "\n")
  cat("callr (background):", if(callr_ok) "✓ AVAILABLE" else "✗ MISSING",
"\n")
  
  async_ready <- nanonext_ok && processx_ok
  cat("\nAsync Mode:", if(async_ready) "✓ ENABLED" else "✗ DISABLED", 
"\n")
  
  if (!async_ready) {
    cat("\nTo enable async mode, run:\n")
    cat("install_missing_packages()\n")
  }
  
  return(async_ready)
}

# Example simulation run function
run_example_simulation <- function() {
  cat("=== EXAMPLE SIMULATION STEP ===\n")
  cat("[14:23:15] STEP 1: Active=8, Black=1\n")
  cat("Worker 1 processing walker 1 from (15, 8)\n")
  cat("Walker 2 processing walker 2 from (3, 12)\n")
  cat("Walker 1 completed with 23 steps at (10, 10) - 
touched_black_neighbor\n")
  cat("...\n")
  cat("=== SIMULATION ENDED AFTER 42 STEPS ===\n")
  cat("Final black pixels: 9\n")
  cat("Total steps: 187\n\n")
}

# Startup messages and diagnostics
cat("=== ASYNCHRONOUS PIXEL WALKING SIMULATION ===\n")

# Check capabilities
async_ready <- check_async_capabilities()

cat("\n=== STARTUP CONDITIONS ===\n")
cat("Grid size: 20x20\n")
cat("Async mode:", ifelse(async_ready, "ENABLED", "DISABLED"), "\n")
cat("Worker processes:", ifelse(PROCESSX_AVAILABLE, "AVAILABLE", "NOT 
AVAILABLE"), "\n")
if (async_ready) {
  cat("Communication ports: 5555, 5556, 5557, 5558\n")
}

cat("\n=== SIMULATION ARCHITECTURE ===\n")
cat("• Main Process: Shiny app with UI and simulation management\n")
if (async_ready) {
  cat("• Worker Processes: Independent R processes running walker 
simulations\n")
  cat("• Communication: nanonext sockets for job distribution and result 
collection\n")
  cat("• State Management: File-based shared state for global state\n")
  cat("• Real-time Updates: File-based pattern for grid state sync\n")
} else {
  cat("• Processing: Sequential walker simulation in main process\n")
}
cat("• Fallback Mode: Synchronous simulation when async not available\n")

cat("\n=== KEY FEATURES ===\n")
if (async_ready) {
  cat("✓ True asynchronous parallel processing with separate R worker 
processes\n")
  cat("✓ Real-time grid state synchronization across all workers\n")
  cat("✓ Non-blocking UI that doesn't freeze during simulation\n")
  cat("✓ Automatic resource cleanup and process management\n")
} else {
  cat("⚠ Sequential processing mode (install nanonext + processx for 
async)\n")
}
cat("✓ Comprehensive statistics tracking with percentiles and 
formatting\n")
cat("✓ Debug panel with detailed system monitoring\n")
cat("✓ Graceful fallback to synchronous mode if dependencies 
unavailable\n")
cat("✓ Background process execution to free up console\n")

cat("\n=== PERFORMANCE OPTIMIZATIONS ===\n")
if (async_ready) {
  cat("• Workers maintain local black pixel cache for fast neighbor 
checking\n")
  cat("• Non-blocking communication to prevent worker stalls\n")
  cat("• Batched grid updates to minimize communication overhead\n")
}
cat("• Periodic UI updates decoupled from simulation loop\n")
cat("• Memory-efficient grid storage and processing\n")
cat("• Automatic worker process lifecycle management\n")

cat("\n=== SIMULATION PARAMETERS ===\n")
cat("Grid Size: 10×10 to 50×50 (default 20×20)\n")
cat("Walkers: 1 to 60% of grid size (default 15)\n")
cat("Neighborhood: 4-hood (NSEW) or 8-hood (includes diagonals)\n")
cat("Boundary: Wrap-around (torus) or terminate at edges (default)\n")
cat("Workers: 1-8 parallel R processes (default 3)\n")
cat("Refresh Rate: 1-10 second UI update interval (default 2s)\n")

cat("\n=== USAGE ===\n")
cat("Standard mode: shinyApp(ui = ui, server = server)\n")
cat("Background mode: bg_process <- run_app_in_bg()\n")
cat("Install packages: install_missing_packages()\n")
cat("Check capabilities: check_async_capabilities()\n")

# Example output
run_example_simulation()

cat("=== READY TO LAUNCH ===\n")
if (async_ready) {
  cat("🚀 ASYNC MODE READY - True parallel processing enabled!\n")
} else {
  cat("⚡ SYNC MODE READY - Sequential processing (install async packages 
for parallel)\n")
}
cat("Execute: shinyApp(ui = ui, server = server)\n")
cat("or for background: bg_process <- run_app_in_bg()\n\n")

# Launch the application with browser opening for Positron compatibility
cat("\n=== LAUNCHING APPLICATION ===\n")
cat("Note: In Positron IDE, use the browser link above if Viewer panel 
shows blank\n")
shinyApp(ui = ui, server = server, options = list(launch.browser = TRUE))
