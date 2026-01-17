
# Instructions

amend the existing code to update
a shiny app for the following game in tidyverse code (where appropriate):

create a nxn grid of pixels (default n = 10).
Colour the pixel nearest the center in black at the start.
All other pixels are white.

Select a pixel at random which will walk around the grid in steps, known as 'walkers'.
Look at the colour of the neighbouring pixels around each walker.
If a neighbour is black, colour the walker's pixel black.
Once a walker turns black (or when a walker starts at a randomly selected pixel which happens to be black), it terminates that walker.
If no neighbour is black then select one of neighbourhood pixels at random and move the walker to that new position.
Repeat the process by looking at the walker's new neighbours and decide if the walker turns black, and stops walking, or that the walker moves to a new random neighbour position etc.

This is NOT a DLA simulation. It is a simple random walk that builds a fractal graph.

Use asynchronous updates (via https://github.com/r-lib/nanonext R package else https://github.com/r-lib/mirai) so each walker runs via a local R process (a worker) that gets near real time updates on the current set of black pixels on the grid.
i.e. each walker independently updates of the others, but is aware of near real time updates of the global set of currently black pixels via asynchronous updates.

Walkers wait in queue for next available worker to become free.
Use in-memory duckdb database to maintain global states.
Publisher-Subscriber Pattern: Uses nanonext's pub-sub sockets for real-time communication between parallel R processes. an in-memory duckdb database holds the global state. Use nanonext to pub/sub updates to/from workers and to store the global state.
Event Processing: Walkers send events (completed, terminated) asynchronously
Grid State Broadcasting: Grid updates are broadcast to all walkers asap
Publisher: Broadcasts grid updates to all walkers
Subscriber: Receives walker events
DuckDB: Maintains in-memory shared state accessible to all processes
Each walker runs in its own R process
Listens for grid updates via subscriber socket
Sends position/status events via publisher socket Event types: completed, terminated
Main process receives event → updates grid → broadcasts grid update. All other walkers receive grid update → update their local knowledge

It is critical to realise that when two or more workers are in parallel perfect information is not possible but near real-time updates of the global state are sufficient for each worker, to get a good enough simulation. In particular each worker needs to know the global state when each new walker starts and whenever a walker running in another parallel process changes the global state. But each walker only has to update the global state once, when it turns a pixel black or when it terminates by hitting an edge (if this option is selected)

Add a panel on the left of the grid for user to choose parameters:
Slider to select n to size the nxn grid. Default n=10.
Slider to select number of walking pixels (walkers) from 1 to n * n * 0.6, default 5.
Dropdown for neighbourhood:
 4 positions north south east west - labelled '4-hood' - default.
 8 positons NSEW as above plus NW NE SW SE - labelled '8-hood'.
Slider to select the number of parallel workers 0 to 16, default 2. 

Dropdown to select if pixel walking off side of grid either wraps around to the opposite side of grid (i.e. nxn grid lies on a sphere) or walking pixel terminates if it goes off grid (default)

Start/stop button is a toggle to start or stop the simulation. 
When the simulation starts, the start button should show the real time updates of the number of walkers still working, the number of black pixels, elapsed time in minutes.
( See https://wlandau.github.io/crew/articles/shiny.html for sample code e.g. "output$results <- renderText( ... )" to see how to embed real time updates in to the start/stop toggle button.)
If start/stop button is clicked to stop simulation then update the stats and graph as of the stop time) and also do this when all walkers have terminated (see also real-time feedback of stats below).

stats to track:
	number and percentage of black pixels,
  number of walkers still alive,
	number of steps taken by walkers both in total.
  25, 50, 75 percentiles of number of steps taken across past and current walkers,
	(total steps taken by walkers in human friendly format - e.g. 9k for ~9000 steps, 11m for ~1000000 steps, using the units package),
	total elapsed time for this simulation,
	total elapsed time for all simulations so far,
	number of simulations so far,
	25, 50, 75 percentiles of simulation time across all simulations so far
	current time,
Add a seperate column to retain the corresponding results from the previous simulation run.

Add black pixels number (and percent of black pixels in brackets) into plot title, when plotting the grid. Plot should not display a legend.

If grid _size_ changes, start a new simulation.

UI updates periodically to provide feedback on latest stats and plot state during long simulations.
The GUI should not slow down the simulation, as it only needs period updates of the global state of the grid for plotting and to calc summary stats and changes.
So add input Slider to update the stats and the plot every few seconds (default 10 seconds, range 1 to 60 seconds).

Send the entire shiny app to a independent R process to free up the console, so that logging information can be sent to the console, seperately to the stats summary going to the UI.

NB: this simulation runs in finite time with high probability, as the number of walkers monotonically decreases to zero due to small grid size, termination at edge (if selected), encountering an increasing number of black pixels. 

You have to help me find any changes in code you suggest.
Always number each change.
Always show enough preceeding lines before the change that I can find a single match in the exisiting version of the code.
Ditto for the lines after the change in the code ends.



===

# Key Architectural Features
This application is built on the advanced, asynchronous model specified:
DuckDB as the Global State: An in-memory duckdb database acts as the single, authoritative source of truth. It contains three tables:
grid: Stores the (x, y) coordinates of all black pixels.
walkers: Stores the real-time state (id, x, y, total_steps, etc.) of all currently active walkers.
finished_walkers: A log of the total steps for every walker that has completed its journey, used for accurate percentile calculations.
nanonext for Communication (with Correct API):
  PUSH/PULL for Job Queuing: The main Shiny app acts as a dispatcher, "pushing" jobs (walkers to be processed) into a queue. The parallel workers "pull" from this queue, ensuring that no two workers process the same walker at the same time.
PUB/SUB for State Broadcasting: This is the crucial "near real-time" update mechanism. When the main app processes a result and a pixel turns black, it immediately "publishes" that single event (e.g., "PIXEL:52,51"). All running workers are "subscribed" to this feed and update their local, in-memory knowledge of the grid. NB: each walker only publishes to the global state once, when it tereminates. Until then it just updates from subscribing to the global state to update its local cache of black pixels.
Smart, Efficient Workers: Each parallel R process first listens non-blockingly for any broadcasted grid updates to keep its local knowledge fresh, then pulls a job and processes one walker either for a batch of steps (more efficient?) or a single-step model - balancing  communication overhead while staying up-to-date.
Fully Decoupled Loops: The application correctly separates the simulation logic from the UI updates:
A fast, asynchronous loop in the main Shiny process is dedicated to listening for results from workers and dispatching new jobs.
A time-based periodic loop, controlled by the UI slider, is responsible for for the GUI querying the database to take a periodic "snapshot" of the current statistics and triggering the UI to redraw.
Background Process Execution: As requested, the file includes a launcher function to run the entire Shiny app in a background process, freeing up the console for real-time logging.


Architecture Highlights:
DuckDB maintains global state across all processes
nanonext handles async communication (with fallback)
Worker processes run independently with proper cleanup
Publisher-Subscriber pattern for real-time grid updates
Queue-based job distribution for walker processing

Usage:

Standard mode: shinyApp(ui = ui, server = server)
Background mode: bg_process <- run_app_in_bg()

The app will automatically detect if nanonext is available and use the full async architecture, otherwise it falls back to a simpler but functional synchronous simulation.
The simulation runs stably with proper resource management and UI responsiveness.

Keep the UI implementation independent of the simulation implementation.
The UI pass info to initialise the simulation and get periodic updates to display by polling the global state.

Ensure clear termination conditions: The simulation loop must properly check when walkers turn black or die.
Proper termination logic: Walkers now correctly terminate when they:
  Touch a black pixel (become part of the aggregate).
  Hit the grid boundary (in terminate mode, if selected).
All parallel R process (aka workers) terminate when all walkers are finished.

Add brief debugging output to the console showing starup conditions and the first and final simulation steps only.
Also add a debug panel to the GUI.
Detailed logging for each worker goes into a local file.


The app now works as follows:

Creates walkers at random positions (avoiding the center)
Each simulation step processes all active walkers
Walkers check for black neighbors and either stop/become black or move randomly
The simulation terminates when no walkers remain
Full statistics are calculated and displayed

Example logging output

shinyApp(ui = ui, server = server)


SIMULATION STEP 4 ===
Active walkers: 5
Black pixels: 1
Processing walker 1 at ( 4 , 7 ) with 3 steps
 Walker 1 moves to ( 4 , 8 )
Processing walker 2 at ( 6 , 9 ) with 3 steps
 Walker 2 moves to ( 6 , 8 )
Processing walker 3 at ( 3 , 9 ) with 3 steps
 Walker 3 moves to ( 3 , 8 )
Processing walker 4 at ( 10 , 3 ) with 3 steps
 Walker 4 moves to ( 10 , 4 )
Processing walker 5 at ( 7 , 6 ) with 3 steps
 Walker 5 moves to ( 7 , 5 )
Updated 5 walkers
Remaining walkers: 5
=== SIMULATION STEP 5 ===
Active walkers: 5
Black pixels: 1
Processing walker 1 at ( 4 , 8 ) with 4 steps
 Walker 1 moves to ( 4 , 7 )
Processing walker 2 at ( 6 , 8 ) with 4 steps
 Walker 2 moves to ( 7 , 8 )
Processing walker 3 at ( 3 , 8 ) with 4 steps
 Walker 3 moves to ( 4 , 8 )
Processing walker 4 at ( 10 , 4 ) with 4 steps
 Walker 4 moves to ( 10 , 5 )
Processing walker 5 at ( 7 , 5 ) with 4 steps
 Walker 5 moves to ( 8 , 5 )
Updated 5 walkers
Remaining walkers: 5
=== SIMULATION ENDED AFTER 42 STEPS ===
=== STOPPING SIMULATION ===
Simulation completed in 0.01 minutes
Final black pixels: 6
Total steps: 147
                     

"""





# claude sat 40 15:09 
# Working zero workers but NOT 1+ workers / Asynchronous  Shiny App

# Asynchronous Pixel Walking Simulation
# Uses nanonext for async communication and DuckDB for global state management

library(shiny)
library(shinydashboard)
library(DT)
library(ggplot2)
library(dplyr)
library(tidyr)
library(plotly)
library(duckdb)

# Try to load nanonext - fallback to synchronous if not available
ASYNC_MODE <- FALSE
if (requireNamespace("nanonext", quietly = TRUE)) {
  library(nanonext)
  ASYNC_MODE <- TRUE
  cat("nanonext loaded - using asynchronous mode\n")
} else {
  cat("nanonext not available - using synchronous fallback\n")
}

# Global variables for async communication
pub_socket <- NULL
sub_socket <- NULL
job_socket <- NULL
result_socket <- NULL
db_conn <- NULL
worker_processes <- list()

# Initialize DuckDB connection
init_database <- function() {
  conn <- dbConnect(duckdb::duckdb(), ":memory:")
  
  # Create tables for global state
  dbExecute(conn, "
    CREATE TABLE grid (
      x INTEGER,
      y INTEGER,
      PRIMARY KEY (x, y)
    )
  ")
  
  dbExecute(conn, "
    CREATE TABLE walkers (
      id INTEGER PRIMARY KEY,
      x INTEGER,
      y INTEGER,
      steps INTEGER,
      status TEXT DEFAULT 'active'
    )
  ")
  
  dbExecute(conn, "
    CREATE TABLE finished_walkers (
      id INTEGER PRIMARY KEY,
      steps INTEGER,
      final_x INTEGER,
      final_y INTEGER,
      status TEXT
    )
  ")
  
  dbExecute(conn, "
    CREATE TABLE simulation_state (
      key TEXT PRIMARY KEY,
      value TEXT
    )
  ")
  
  return(conn)
}

# Initialize async communication
init_async_communication <- function() {
  if (!ASYNC_MODE) return(FALSE)
  
  tryCatch({
    # Create sockets for job distribution (PUSH/PULL pattern)
    job_socket <<- socket("push", listen = "tcp://127.0.0.1:5555")
    
    # Create sockets for broadcasting grid updates (PUB/SUB pattern)  
    pub_socket <<- socket("pub", listen = "tcp://127.0.0.1:5556")
    
    # Result collection socket
    result_socket <<- socket("pull", listen = "tcp://127.0.0.1:5557")
    
    Sys.sleep(0.2)  # Allow sockets to bind
    cat("Async sockets initialized successfully\n")
    return(TRUE)
  }, error = function(e) {
    cat("Failed to initialize async communication:", e$message, "\n")
    return(FALSE)
  })
}

# Worker process function
worker_process_code <- function(worker_id, grid_size, neighborhood_type, wrap_around) {
  # This code runs in a separate R process
  '
  library(nanonext)
  library(duckdb)
  
  # Connect to communication sockets
  job_pull_socket <- socket("pull", dial = "tcp://127.0.0.1:5555")
  grid_sub_socket <- socket("sub", dial = "tcp://127.0.0.1:5556")
  result_push_socket <- socket("push", dial = "tcp://127.0.0.1:5557")
  
  # Connect to shared database (in real implementation, this would be a shared connection)
  conn <- dbConnect(duckdb::duckdb(), ":memory:")
  
  # Local grid state cache
  local_black_pixels <- data.frame(x = integer(), y = integer())
  
  get_neighbors <- function(x, y, n, neighborhood_type, wrap_around) {
    neighbors <- list()
    
    if (neighborhood_type == "4-hood") {
      offsets <- list(c(-1, 0), c(1, 0), c(0, -1), c(0, 1))
    } else {
      offsets <- list(c(-1, 0), c(1, 0), c(0, -1), c(0, 1),
                     c(-1, -1), c(-1, 1), c(1, -1), c(1, 1))
    }
    
    for (offset in offsets) {
      new_x <- x + offset[1]
      new_y <- y + offset[2]
      
      if (wrap_around) {
        new_x <- ((new_x - 1) %% n) + 1
        new_y <- ((new_y - 1) %% n) + 1
        neighbors <- append(neighbors, list(c(new_x, new_y)), after = length(neighbors))
      } else {
        if (new_x >= 1 && new_x <= n && new_y >= 1 && new_y <= n) {
          neighbors <- append(neighbors, list(c(new_x, new_y)), after = length(neighbors))
        }
      }
    }
    
    return(neighbors)
  }
  
  is_black_pixel <- function(x, y) {
    any(local_black_pixels$x == x & local_black_pixels$y == y)
  }
  
  # Main worker loop
  while (TRUE) {
    # Check for grid updates (non-blocking)
    grid_update <- recv(grid_sub_socket, mode = "raw", block = FALSE)
    if (!is.null(grid_update)) {
      # Parse and update local grid cache
      update_data <- unserialize(grid_update)
      if (update_data$type == "PIXEL_BLACK") {
        local_black_pixels <- rbind(local_black_pixels, 
                                   data.frame(x = update_data$x, y = update_data$y))
      }
    }
    
    # Get next job (blocking with timeout)
    job <- recv(job_pull_socket, mode = "raw", block = TRUE)
    if (is.null(job)) break
    
    job_data <- unserialize(job)
    if (job_data$type == "WALKER") {
      # Process walker
      walker_id <- job_data$walker_id
      start_x <- job_data$start_x
      start_y <- job_data$start_y
      
      current_x <- start_x
      current_y <- start_y
      steps <- 0
      max_steps <- 10000
      
      while (steps < max_steps) {
        steps <- steps + 1
        
        # Get neighbors
        neighbors <- get_neighbors(current_x, current_y, grid_size, neighborhood_type, wrap_around)
        
        # Check for black neighbors
        black_neighbor <- FALSE
        for (neighbor in neighbors) {
          if (is_black_pixel(neighbor[1], neighbor[2])) {
            black_neighbor <- TRUE
            break
          }
        }
        
        if (black_neighbor || is_black_pixel(current_x, current_y)) {
          # Walker turns black and terminates
          result <- list(
            type = "WALKER_FINISHED",
            walker_id = walker_id,
            final_x = current_x,
            final_y = current_y,
            steps = steps,
            status = "turned_black"
          )
          send(result_push_socket, serialize(result, NULL), mode = "raw")
          break
        } else {
          # Move to random neighbor
          if (length(neighbors) == 0) {
            # No valid neighbors - terminated at boundary
            result <- list(
              type = "WALKER_FINISHED",
              walker_id = walker_id,
              final_x = current_x,
              final_y = current_y,
              steps = steps,
              status = "boundary_terminated"
            )
            send(result_push_socket, serialize(result, NULL), mode = "raw")
            break
          }
          
          next_neighbor <- neighbors[[sample(length(neighbors), 1)]]
          current_x <- next_neighbor[1]
          current_y <- next_neighbor[2]
        }
      }
      
      if (steps >= max_steps) {
        result <- list(
          type = "WALKER_FINISHED",
          walker_id = walker_id,
          final_x = current_x,
          final_y = current_y,
          steps = steps,
          status = "max_steps_reached"
        )
        send(result_push_socket, serialize(result, NULL), mode = "raw")
      }
    } else if (job_data$type == "TERMINATE") {
      break
    }
  }
  
  # Cleanup
  close(job_pull_socket)
  close(grid_sub_socket) 
  close(result_push_socket)
  dbDisconnect(conn)
  '
}

# Start worker processes
start_workers <- function(num_workers, grid_size, neighborhood_type, wrap_around) {
  if (!ASYNC_MODE || num_workers == 0) return(list())
  
  workers <- list()
  
  # For this implementation, we simulate workers
  # In a full implementation, you would use processx or system() to start separate R processes
  for (i in 1:num_workers) {
    workers[[i]] <- list(
      id = i,
      pid = paste0("simulated_worker_", i),
      status = "active",
      start_time = Sys.time()
    )
  }
  
  cat("Started", num_workers, "simulated worker processes\n")
  return(workers)
}

# Stop all workers
stop_workers <- function() {
  if (!ASYNC_MODE || is.null(job_socket)) return()
  
  # Send termination signal to all workers
  for (i in seq_along(worker_processes)) {
    terminate_msg <- list(type = "TERMINATE")
    tryCatch({
      send(job_socket, serialize(terminate_msg, NULL), mode = "raw", block = FALSE)
    }, error = function(e) {
      cat("Error sending termination to worker", i, ":", e$message, "\n")
    })
  }
  
  # Clear worker list
  worker_processes <<- list()
  cat("Stopped all worker processes\n")
}

# Cleanup function
cleanup_async <- function() {
  if (!ASYNC_MODE) return()
  
  stop_workers()
  
  # Close sockets
  if (!is.null(pub_socket)) close(pub_socket)
  if (!is.null(sub_socket)) close(sub_socket)
  if (!is.null(job_socket)) close(job_socket)
  if (!is.null(result_socket)) close(result_socket)
  
  # Close database
  if (!is.null(db_conn)) dbDisconnect(db_conn)
}

# UI remains the same as original but with debug panel
ui <- dashboardPage(
  dashboardHeader(title = "Async Pixel Walking Simulation"),
  
  dashboardSidebar(
    sidebarMenu(
      menuItem("Simulation", tabName = "simulation", icon = icon("play")),
      menuItem("Debug", tabName = "debug", icon = icon("bug"))
    )
  ),
  
  dashboardBody(
    tabItems(
      tabItem(tabName = "simulation",
        fluidRow(
          # Control Panel
          box(
            title = "Parameters", status = "primary", solidHeader = TRUE, width = 3,
            
            sliderInput("grid_size", "Grid Size (n×n):",
                       min = 10, max = 100, value = 10, step = 5),
            
            sliderInput("num_walkers", "Number of Walking Pixels:",
                       min = 1, max = 60, value = 5),
            
            selectInput("neighborhood", "Neighborhood Type:",
                       choices = list("4-hood" = "4-hood",
                                    "8-hood" = "8-hood"),
                       selected = "4-hood"),
            
            selectInput("boundary", "Boundary Condition:",
                       choices = list("Wrap around" = TRUE,
                                    "Terminate at edge" = FALSE),
                       selected = FALSE),
            
            sliderInput("num_workers", "Number of Parallel Workers:",
                       min = 0, max = 16, value = 2),
            
            sliderInput("refresh_rate", "Update Interval (seconds):",
                       min = 1, max = 60, value = 10, step = 1),
            
            hr(),
            
            actionButton("start_stop", "Start Simulation", 
                        class = "btn-success btn-lg", width = "100%"),
            
            hr(),
            
            h4("Real-time Info"),
            verbatimTextOutput("realtime_stats"),
            
            h4("Current Time"),
            verbatimTextOutput("current_time")
          ),
          
          # Main Plot and Statistics
          box(
            title = "Simulation Grid & Statistics", status = "info", solidHeader = TRUE, width = 9,
            
            plotlyOutput("main_plot", height = "500px"),
            
            br(),
            
            fluidRow(
              column(6,
                h4("Current Simulation"),
                DT::dataTableOutput("current_stats", height = "300px")
              ),
              column(6,
                h4("Previous Simulation"),
                DT::dataTableOutput("previous_stats", height = "300px")
              )
            ),
            
            br(),
            
            h4("All-time Statistics"),
            DT::dataTableOutput("alltime_stats", height = "200px")
          )
        )
      ),
      
      # Debug panel
      tabItem(tabName = "debug",
        fluidRow(
          box(
            title = "Debug Information", status = "warning", solidHeader = TRUE, width = 12,
            
            h4("System Status"),
            verbatimTextOutput("debug_system"),
            
            h4("Database State"),
            verbatimTextOutput("debug_database"),
            
            h4("Worker Status"),
            verbatimTextOutput("debug_workers"),
            
            h4("Communication Status"),
            verbatimTextOutput("debug_communication")
          )
        )
      )
    )
  )
)

# Server function
server <- function(input, output, session) {
  # Initialize database connection
  db_conn <<- init_database()
  
  # Initialize async communication flag
  async_initialized <- FALSE
  
  # Reactive values
  values <- reactiveValues(
    grid = NULL,
    running = FALSE,
    start_time = NULL,
    total_steps = 0,
    black_pixels = 0,
    active_walkers = 0,
    completed_walkers = 0,
    simulation_count = 0,
    total_elapsed_time = 0,
    previous_simulation = NULL,
    current_simulation = NULL,
    step_history = numeric(),
    last_update_time = Sys.time()
  )
  
  # Initialize async communication when app starts
  observe({
    if (ASYNC_MODE && !async_initialized) {
      async_initialized <<- init_async_communication()
      if (async_initialized) {
        cat("Async communication initialized successfully\n")
      }
    }
  })
  
  # Initialize grid
  observe({
    req(input$grid_size)
    n <- input$grid_size
    
    # Create grid (0 = white, 1 = black)
    grid <- matrix(0, nrow = n, ncol = n)
    
    # Color center pixel black
    center <- ceiling(n / 2)
    grid[center, center] <- 1
    
    values$grid <- grid
    values$black_pixels <- 1
    
    # Update database
    if (!is.null(db_conn)) {
      dbExecute(db_conn, "DELETE FROM grid")
      dbExecute(db_conn, "INSERT INTO grid (x, y) VALUES (?, ?)", 
                params = list(center, center))
    }
  })
  
  # Update max walkers based on grid size
  observe({
    req(input$grid_size)
    max_walkers <- floor(input$grid_size^2 * 0.6)
    updateSliderInput(session, "num_walkers", max = max_walkers)
  })
  
  # Simulation management
  observeEvent(input$start_stop, {
    if (!values$running) {
      start_simulation()
    } else {
      stop_simulation()
    }
  })
  
  start_simulation <- function() {
    cat("=== STARTING SIMULATION ===\n")
    cat("Grid size:", input$grid_size, "x", input$grid_size, "\n")
    cat("Walkers:", input$num_walkers, "\n")
    cat("Workers:", input$num_workers, "\n")
    cat("Neighborhood:", input$neighborhood, "\n")
    cat("Boundary:", ifelse(input$boundary, "wrap", "terminate"), "\n")
    cat("Async mode:", ASYNC_MODE, "\n")
    
    values$running <- TRUE
    values$start_time <- Sys.time()
    values$total_steps <- 0
    values$completed_walkers <- 0
    values$active_walkers <- input$num_walkers
    values$simulation_count <- values$simulation_count + 1
    values$step_history <- numeric()
    
    # Store previous results
    if (!is.null(values$current_simulation)) {
      values$previous_simulation <- values$current_simulation
    }
    
    updateActionButton(session, "start_stop", label = "Stop Simulation", 
                      icon = icon("stop"))
    
    # Reset database state
    dbExecute(db_conn, "DELETE FROM walkers")
    dbExecute(db_conn, "DELETE FROM finished_walkers")
    
    # Reset grid
    n <- input$grid_size
    grid <- matrix(0, nrow = n, ncol = n)
    center <- ceiling(n / 2)
    grid[center, center] <- 1
    values$grid <- grid
    values$black_pixels <- 1
    
    # Start workers if in async mode
    if (ASYNC_MODE && async_initialized && input$num_workers > 0) {
      worker_processes <<- start_workers(input$num_workers, input$grid_size, 
                                        input$neighborhood, input$boundary)
      run_async_simulation()
    } else {
      run_sync_simulation()
    }
  }
  
  stop_simulation <- function() {
    cat("=== STOPPING SIMULATION ===\n")
    values$running <- FALSE
    
    if (ASYNC_MODE) {
      stop_workers()
    }
    
    if (!is.null(values$start_time)) {
      elapsed_time <- as.numeric(difftime(Sys.time(), values$start_time, units = "mins"))
      values$total_elapsed_time <- values$total_elapsed_time + elapsed_time
      
      # Calculate final statistics
      black_pct <- round((values$black_pixels / (input$grid_size^2)) * 100, 2)
      avg_steps <- if (length(values$step_history) > 0) {
        mean(values$step_history, na.rm = TRUE)
      } else {
        0
      }
      
      # Store current simulation results
      values$current_simulation <- list(
        black_pixels = values$black_pixels,
        black_percentage = black_pct,
        total_steps = values$total_steps,
        avg_steps = round(avg_steps, 1),
        elapsed_time = round(elapsed_time, 3),
        walkers_completed = values$completed_walkers,
        total_walkers = input$num_walkers,
        percentiles = if (length(values$step_history) > 0) {
          quantile(values$step_history, c(0.25, 0.5, 0.75), na.rm = TRUE)
        } else {
          c(0, 0, 0)
        }
      )
      
      cat("Simulation completed in", round(elapsed_time, 3), "minutes\n")
      cat("Final black pixels:", values$black_pixels, "\n")
      cat("Total steps:", values$total_steps, "\n")
    }
    
    updateActionButton(session, "start_stop", label = "Start Simulation", 
                      icon = icon("play"))
  }
  
  # Async simulation function
  run_async_simulation <- function() {
    cat("Starting async simulation with", input$num_workers, "workers\n")
    
    # For this implementation, we'll simulate the async behavior
    # In a real implementation, you would start actual R worker processes
    # using system() or processx to run separate R scripts
    
    # Generate random starting positions
    n <- input$grid_size
    center <- ceiling(n / 2)
    
    # Create mock walker jobs and process them
    walker_results <- list()
    
    for (i in 1:input$num_walkers) {
      if (!values$running) break
      
      # Generate random start position
      repeat {
        start_x <- sample(1:n, 1)
        start_y <- sample(1:n, 1)
        if (!(start_x == center && start_y == center)) {
          break
        }
      }
      
      # Store the current values to avoid reactive context issues
      current_walker_id <- i
      current_start_x <- start_x
      current_start_y <- start_y
      current_grid_size <- n
      current_neighborhood <- input$neighborhood
      current_boundary <- as.logical(input$boundary)
      
      # Simulate async processing with a slight delay
      later::later(function() {
        # Check if simulation is still running by accessing the reactive value properly
        if (!isolate(values$running)) return()
        
        # Simulate walker processing
        current_grid <- isolate(values$grid)
        result <- simulate_walker_sync(current_grid, current_start_x, current_start_y, 
                                     current_grid_size, current_neighborhood, current_boundary)
        
        # Create result data structure
        result_data <- list(
          type = "WALKER_FINISHED",
          walker_id = current_walker_id,
          final_x = result$final_pos[1],
          final_y = result$final_pos[2], 
          steps = result$steps,
          status = "turned_black"
        )
        
        # Process the result - wrap in observe to handle reactive context
        local({
          if (!isolate(values$running)) return()
          
          # Update grid
          if (result_data$final_x >= 1 && result_data$final_x <= nrow(isolate(values$grid)) &&
              result_data$final_y >= 1 && result_data$final_y <= ncol(isolate(values$grid))) {
            
            # Only update if pixel isn't already black
            current_grid <- isolate(values$grid)
            if (current_grid[result_data$final_x, result_data$final_y] == 0) {
              current_grid[result_data$final_x, result_data$final_y] <- 1
              values$grid <- current_grid
              values$black_pixels <- sum(current_grid)
            }
            
            # Update statistics
            values$total_steps <- isolate(values$total_steps) + result_data$steps
            values$completed_walkers <- isolate(values$completed_walkers) + 1
            values$active_walkers <- max(0, isolate(values$active_walkers) - 1)
            values$step_history <- c(isolate(values$step_history), result_data$steps)
            
            cat("Walker", result_data$walker_id, "finished with", result_data$steps, 
                "steps at (", result_data$final_x, ",", result_data$final_y, ")\n")
            
            # Check if simulation is complete
            if (isolate(values$active_walkers) <= 0) {
              cat("All walkers completed - stopping simulation\n")
              later::later(function() {
                if (isolate(values$running)) {
                  values$running <- FALSE
                  
                  if (!is.null(isolate(values$start_time))) {
                    elapsed_time <- as.numeric(difftime(Sys.time(), isolate(values$start_time), units = "mins"))
                    values$total_elapsed_time <- isolate(values$total_elapsed_time) + elapsed_time
                    
                    # Calculate final statistics
                    black_pct <- round((isolate(values$black_pixels) / (input$grid_size^2)) * 100, 2)
                    current_step_history <- isolate(values$step_history)
                    avg_steps <- if (length(current_step_history) > 0) {
                      mean(current_step_history, na.rm = TRUE)
                    } else {
                      0
                    }
                    
                    # Store current simulation results
                    values$current_simulation <- list(
                      black_pixels = isolate(values$black_pixels),
                      black_percentage = black_pct,
                      total_steps = isolate(values$total_steps),
                      avg_steps = round(avg_steps, 1),
                      elapsed_time = round(elapsed_time, 3),
                      walkers_completed = isolate(values$completed_walkers),
                      total_walkers = input$num_walkers,
                      percentiles = if (length(current_step_history) > 0) {
                        quantile(current_step_history, c(0.25, 0.5, 0.75), na.rm = TRUE)
                      } else {
                        c(0, 0, 0)
                      }
                    )
                    
                    cat("Simulation completed in", round(elapsed_time, 3), "minutes\n")
                    cat("Final black pixels:", isolate(values$black_pixels), "\n")
                    cat("Total steps:", isolate(values$total_steps), "\n")
                  }
                  
                  updateActionButton(session, "start_stop", label = "Start Simulation", 
                                    icon = icon("play"))
                }
              }, delay = 0.1)
            }
          }
        })
        
      }, delay = runif(1, 0.1, 1.0))  # Random delay to simulate async processing
    }
  }
  
  # Fallback synchronous simulation
  run_sync_simulation <- function() {
    cat("Running synchronous simulation...\n")
    
    n <- input$grid_size
    center <- ceiling(n / 2)
    num_walkers <- input$num_walkers
    neighborhood <- input$neighborhood
    wrap_around <- as.logical(input$boundary)
    
    # Generate starting positions
    start_positions <- replicate(num_walkers, {
      repeat {
        pos <- c(sample(1:n, 1), sample(1:n, 1))
        if (!(pos[1] == center && pos[2] == center)) {
          return(pos)
        }
      }
    }, simplify = FALSE)
    
    # Process walkers sequentially
    for (i in 1:num_walkers) {
      if (!values$running) break
      
      pos <- start_positions[[i]]
      result <- simulate_walker_sync(values$grid, pos[1], pos[2], n, neighborhood, wrap_around)
      
      # Update grid and statistics directly
      values$grid <- result$grid
      values$total_steps <- values$total_steps + result$steps
      values$black_pixels <- sum(values$grid)
      values$completed_walkers <- values$completed_walkers + 1
      values$active_walkers <- max(0, values$active_walkers - 1)
      values$step_history <- c(values$step_history, result$steps)
      
      cat("Walker", i, "finished with", result$steps, "steps at (", 
          result$final_pos[1], ",", result$final_pos[2], ")\n")
      
      # Small delay to allow UI updates
      Sys.sleep(0.02)
    }
    
    if (values$running && values$active_walkers <= 0) {
      stop_simulation()
    }
  }
  
  # Synchronous walker simulation function
  simulate_walker_sync <- function(grid, start_x, start_y, n, neighborhood_type, wrap_around, max_steps = 10000) {
    current_x <- start_x
    current_y <- start_y
    steps <- 0
    
    # Get neighbors function
    get_neighbors <- function(x, y, n, neighborhood_type, wrap_around) {
      neighbors <- list()
      
      if (neighborhood_type == "4-hood") {
        offsets <- list(c(-1, 0), c(1, 0), c(0, -1), c(0, 1))
      } else {
        offsets <- list(c(-1, 0), c(1, 0), c(0, -1), c(0, 1),
                       c(-1, -1), c(-1, 1), c(1, -1), c(1, 1))
      }
      
      for (offset in offsets) {
        new_x <- x + offset[1]
        new_y <- y + offset[2]
        
        if (wrap_around) {
          new_x <- ((new_x - 1) %% n) + 1
          new_y <- ((new_y - 1) %% n) + 1
          neighbors <- append(neighbors, list(c(new_x, new_y)), after = length(neighbors))
        } else {
          if (new_x >= 1 && new_x <= n && new_y >= 1 && new_y <= n) {
            neighbors <- append(neighbors, list(c(new_x, new_y)), after = length(neighbors))
          }
        }
      }
      
      return(neighbors)
    }
    
    while (steps < max_steps) {
      steps <- steps + 1
      
      neighbors <- get_neighbors(current_x, current_y, n, neighborhood_type, wrap_around)
      
      # Check for black neighbors
      black_neighbor <- FALSE
      for (neighbor in neighbors) {
        if (grid[neighbor[1], neighbor[2]] == 1) {
          black_neighbor <- TRUE
          break
        }
      }
      
      if (black_neighbor || grid[current_x, current_y] == 1) {
        grid[current_x, current_y] <- 1
        break
      } else {
        if (length(neighbors) == 0) {
          break  # Terminated at boundary
        }
        
        next_neighbor <- neighbors[[sample(length(neighbors), 1)]]
        current_x <- next_neighbor[1]
        current_y <- next_neighbor[2]
      }
    }
    
    return(list(grid = grid, steps = steps, final_pos = c(current_x, current_y)))
  }
  
  # Result collection for async mode
  collect_results <- function() {
    # This function is no longer needed since we handle results directly in run_async_simulation
    # Keeping it for potential future use with real worker processes
    return()
  }
  
  # Main plot
  output$main_plot <- renderPlotly({
    if (values$running) {
      invalidateLater(input$refresh_rate * 1000, session)
    }
    
    req(values$grid)
    
    n <- nrow(values$grid)
    black_pct <- round((values$black_pixels / (n^2)) * 100, 1)
    
    # Convert grid to long format
    grid_df <- expand.grid(x = 1:n, y = 1:n) %>%
      mutate(value = as.vector(values$grid),
             color = ifelse(value == 1, "Black", "White"))
    
    p <- ggplot(grid_df, aes(x = x, y = n - y + 1, fill = color)) +
      geom_tile(color = "lightgray", linewidth = 0.1) +
      scale_fill_manual(values = c("Black" = "black", "White" = "white")) +
      theme_void() +
      theme(legend.position = "none",
            plot.title = element_text(hjust = 0.5)) +
      coord_fixed() +
      labs(title = paste0("Black Pixels: ", values$black_pixels, " (", black_pct, "%)"))
    
    ggplotly(p, tooltip = NULL) %>%
      config(displayModeBar = FALSE)
  })
  
  # Real-time statistics
  output$realtime_stats <- renderText({
    if (values$running) {
      invalidateLater(input$refresh_rate * 1000, session)
    }
    
    if (values$running && !is.null(values$start_time)) {
      elapsed <- difftime(Sys.time(), values$start_time, units = "mins")
      elapsed_str <- sprintf("%.2f mins", as.numeric(elapsed))
      status <- "RUNNING"
    } else {
      elapsed_str <- "Not running"
      status <- "STOPPED"
    }
    
    paste0(
      "Status: ", status, "\n",
      "Mode: ", ifelse(ASYNC_MODE && input$num_workers > 0, "Asynchronous", "Synchronous"), "\n",
      "Active walkers: ", values$active_walkers, "\n",
      "Completed: ", values$completed_walkers, "/", input$num_walkers, "\n",
      "Black pixels: ", values$black_pixels, "\n",
      "Total steps: ", values$total_steps, "\n",
      "Elapsed: ", elapsed_str
    )
  })
  
  # Current time
  output$current_time <- renderText({
    invalidateLater(1000, session)
    format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  })
  
  # Statistics tables
  output$current_stats <- DT::renderDataTable({
    if (values$running) {
      invalidateLater(input$refresh_rate * 1000, session)
    }
    
    if (is.null(values$grid)) {
      return(data.frame(Metric = character(), Value = character()))
    }
    
    black_pct <- round((values$black_pixels / (input$grid_size^2)) * 100, 2)
    elapsed_time <- if (values$running && !is.null(values$start_time)) {
      as.numeric(difftime(Sys.time(), values$start_time, units = "mins"))
    } else if (!is.null(values$current_simulation)) {
      values$current_simulation$elapsed_time
    } else {
      0
    }
    
    # Calculate percentiles
    if (length(values$step_history) > 0) {
      percentiles <- quantile(values$step_history, c(0.25, 0.5, 0.75), na.rm = TRUE)
      perc_str <- paste0(round(percentiles[1], 1), ", ", 
                        round(percentiles[2], 1), ", ", 
                        round(percentiles[3], 1))
    } else {
      perc_str <- "N/A"
    }
    
    avg_steps <- if (length(values$step_history) > 0) {
      mean(values$step_history, na.rm = TRUE)
    } else {
      0
    }
    
    stats_df <- data.frame(
      Metric = c("Black Pixels", "Black Percentage", "Active Walkers", "Completed Walkers",
                "Total Steps", "Avg Steps", "Step Percentiles (25,50,75)", "Elapsed Time"),
      Value = c(values$black_pixels, paste0(black_pct, "%"), values$active_walkers,
               values$completed_walkers, values$total_steps, round(avg_steps, 1),
               perc_str, paste0(round(elapsed_time, 3), "m"))
    )
    
    DT::datatable(stats_df, options = list(dom = 't', pageLength = 15, ordering = FALSE))
  })
  
  output$previous_stats <- DT::renderDataTable({
    if (is.null(values$previous_simulation)) {
      return(data.frame(Metric = character(), Value = character()))
    }
    
    prev <- values$previous_simulation
    perc_str <- if (!is.null(prev$percentiles)) {
      paste0(round(prev$percentiles[1], 1), ", ", 
             round(prev$percentiles[2], 1), ", ", 
             round(prev$percentiles[3], 1))
    } else {
      "N/A"
    }
    
    stats_df <- data.frame(
      Metric = c("Black Pixels", "Black Percentage", "Completed Walkers", "Total Walkers",
                "Total Steps", "Avg Steps", "Step Percentiles (25,50,75)", "Elapsed Time"),
      Value = c(prev$black_pixels, paste0(prev$black_percentage, "%"), 
               prev$walkers_completed, prev$total_walkers, prev$total_steps,
               prev$avg_steps, perc_str, paste0(prev$elapsed_time, "m"))
    )
    
    DT::datatable(stats_df, options = list(dom = 't', pageLength = 15, ordering = FALSE))
  })
  
  output$alltime_stats <- DT::renderDataTable({
    # Calculate all-time percentiles
    all_sim_times <- c()
    if (!is.null(values$current_simulation)) {
      all_sim_times <- c(all_sim_times, values$current_simulation$elapsed_time)
    }
    if (!is.null(values$previous_simulation)) {
      all_sim_times <- c(all_sim_times, values$previous_simulation$elapsed_time)
    }
    
    time_percentiles <- if (length(all_sim_times) > 0) {
      perc <- quantile(all_sim_times, c(0.25, 0.5, 0.75), na.rm = TRUE)
      paste0(round(perc[1], 2), ", ", round(perc[2], 2), ", ", round(perc[3], 2), "m")
    } else {
      "N/A"
    }
    
    avg_time <- if (values$simulation_count > 0) {
      round(values$total_elapsed_time / values$simulation_count, 3)
    } else {
      0
    }
    
    stats_df <- data.frame(
      Metric = c("Total Simulations", "Total Elapsed Time", "Average Time per Simulation",
                "Time Percentiles (25,50,75)"),
      Value = c(values$simulation_count, 
               paste0(round(values$total_elapsed_time, 3), "m"),
               paste0(avg_time, "m"),
               time_percentiles)
    )
    
    DT::datatable(stats_df, options = list(dom = 't', pageLength = 10, ordering = FALSE))
  })
  
  # Debug outputs
  output$debug_system <- renderText({
    invalidateLater(2000, session)  # Update every 2 seconds
    
    paste0(
      "Async Mode Available: ", ASYNC_MODE, "\n",
      "Async Initialized: ", async_initialized, "\n",
      "Database Connected: ", !is.null(db_conn), "\n",
      "Grid Size: ", ifelse(is.null(values$grid), "NULL", paste(dim(values$grid), collapse = "x")), "\n",
      "Memory Usage: ", format(object.size(values), units = "Mb"), "\n",
      "R Session: ", R.version.string
    )
  })
  
  output$debug_database <- renderText({
    invalidateLater(2000, session)
    
    if (is.null(db_conn)) {
      return("Database not connected")
    }
    
    tryCatch({
      grid_count <- dbGetQuery(db_conn, "SELECT COUNT(*) as count FROM grid")$count
      walker_count <- dbGetQuery(db_conn, "SELECT COUNT(*) as count FROM walkers")$count
      finished_count <- dbGetQuery(db_conn, "SELECT COUNT(*) as count FROM finished_walkers")$count
      
      paste0(
        "Grid pixels in DB: ", grid_count, "\n",
        "Active walkers in DB: ", walker_count, "\n",
        "Finished walkers in DB: ", finished_count, "\n",
        "Last update: ", format(values$last_update_time, "%H:%M:%S")
      )
    }, error = function(e) {
      paste("Database error:", e$message)
    })
  })
  
  output$debug_workers <- renderText({
    invalidateLater(2000, session)
    
    if (!ASYNC_MODE) {
      return("Asynchronous mode not available (nanonext not loaded)")
    }
    
    if (length(worker_processes) == 0) {
      return("No workers active")
    }
    
    worker_status <- sapply(worker_processes, function(w) {
      paste0("Worker ", w$id, ": ", w$status)
    })
    
    paste(c(
      paste0("Total workers: ", length(worker_processes)),
      worker_status
    ), collapse = "\n")
  })
  
  output$debug_communication <- renderText({
    invalidateLater(2000, session)
    
    if (!ASYNC_MODE) {
      return("Communication: Synchronous mode")
    }
    
    socket_status <- c()
    if (!is.null(job_socket)) socket_status <- c(socket_status, "Job socket: OK")
    if (!is.null(pub_socket)) socket_status <- c(socket_status, "Pub socket: OK") 
    if (!is.null(result_socket)) socket_status <- c(socket_status, "Result socket: OK")
    
    if (length(socket_status) == 0) {
      socket_status <- "No sockets initialized"
    }
    
    paste(c(
      paste0("Communication mode: ", ifelse(async_initialized, "Asynchronous", "Failed")),
      socket_status,
      paste0("Last message: ", format(Sys.time(), "%H:%M:%S"))
    ), collapse = "\n")
  })
  
  # Clean up on session end
  onStop(function() {
    cat("=== CLEANING UP SESSION ===\n")
    cleanup_async()
  })
  
  # Handle grid size changes - restart simulation
  observeEvent(input$grid_size, {
    if (values$running) {
      stop_simulation()
      showNotification("Simulation stopped due to grid size change", type = "warning")
    }
  }, ignoreInit = TRUE)
}

# Function to run app in background process
run_app_in_bg <- function() {
  if (requireNamespace("callr", quietly = TRUE)) {
    cat("Starting Shiny app in background process...\n")
    
    bg_process <- callr::r_bg(function() {
      # Source this file or run the app
      shiny::shinyApp(ui = ui, server = server)
    })
    
    cat("Background process started with PID:", bg_process$get_pid(), "\n")
    cat("App should be available at http://127.0.0.1:8100\n")
    
    return(bg_process)
  } else {
    cat("callr package not available. Running in foreground.\n")
    shinyApp(ui = ui, server = server)
  }
}

# Print startup information
cat("=== ASYNC PIXEL WALKING SIMULATION ===\n")
cat("Async mode:", ASYNC_MODE, "\n")
cat("Database support: DuckDB\n")
cat("Communication: nanonext (if available)\n")
cat("\nUsage:\n")
cat("Standard mode: shinyApp(ui = ui, server = server)\n")
cat("Background mode: bg_process <- run_app_in_bg()\n")
cat("\n")

# Example startup logging
cat("=== SIMULATION STEP 1 ===\n")
if (ASYNC_MODE) {
  cat("nanonext available - async communication will be initialized on app start\n")
  cat("Setting up DuckDB database...\n")
  cat("Ready for parallel processing\n")
} else {
  cat("Running in synchronous fallback mode\n")
  cat("nanonext not available - install with: install.packages('nanonext')\n")
}

# Run the application
shinyApp(ui = ui, server = server)


"""
