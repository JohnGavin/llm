# crew Operational Patterns

## Description

Advanced operational patterns for crew including logging, monitoring, auto-scaling configuration, and debugging worker pools. This skill covers production deployment concerns beyond basic usage.

## Purpose

Use this skill when:
- Setting up crew logging and monitoring
- Debugging worker crashes or memory issues
- Optimizing auto-scaling for cost/performance
- Integrating crew with targets pipelines
- Monitoring resource usage in production

## Logging with autometric

### Basic Logging Setup

```r
library(crew)

# Create log directory
log_dir <- tempfile()
dir.create(log_dir)

# Controller with worker logging
controller <- crew_controller_local(
  workers = 4,
  options_local = crew_options_local(
    log_directory = log_dir  # Each worker writes separate log
  )
)

controller$start()
# ... run tasks ...
controller$terminate()

# Read worker logs
list.files(log_dir, full.names = TRUE) |>
  lapply(readLines)
```

### Resource Metrics with autometric

```r
library(crew)
library(autometric)

# Add performance metrics to worker logs
controller <- crew_controller_local(
  workers = 4,
  options_local = crew_options_local(
    log_directory = log_dir
  ),
  options_metrics = crew_options_metrics(
    path = "/dev/stdout",      # Write metrics to log files
    seconds_interval = 1       # Sample every 1 second
  )
)

controller$start()

# Run some tasks
for (i in 1:10) {
  controller$push(
    name = paste0("task_", i),
    command = {
      Sys.sleep(2)
      rnorm(1000000)
    }
  )
}
controller$wait()
controller$terminate()

# Parse and visualize metrics
metrics <- autometric::log_read(log_dir)
autometric::log_plot(metrics)
```

### Metric Data Format

Log entries contain `__AUTOMETRIC__` markers:

```
__AUTOMETRIC__|timestamp|phase|cpu|memory|...
__AUTOMETRIC__|1234567890|task_1|45.2|1024|...
__AUTOMETRIC__|1234567891|__DEFAULT__|2.1|512|...
```

Phases:
- Task names during execution
- `__DEFAULT__` when worker is idle

## Auto-Scaling Configuration

### Key Parameters

```r
controller <- crew_controller_local(
  workers = 8,                    # Maximum concurrent workers

  # --- Auto-scaling (in order of importance) ---
  seconds_idle = 30,              # Kill worker after 30s idle
  tasks_max = 100,                # Recycle worker after 100 tasks
  seconds_wall = 3600,            # Soft limit: 1 hour per worker

  # --- Resilience ---
  crashes_max = 3                 # Max consecutive crashes per task
)
```

### Scaling Strategy Decision

```
                    HIGH LAUNCH OVERHEAD
                    (cloud, HPC clusters)
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
   PERSISTENT         BALANCED           TRANSIENT
   workers = N        seconds_idle=300   seconds_idle=10
   seconds_idle=Inf   tasks_max=1000     tasks_max=50
   tasks_max=Inf      seconds_wall=7200  seconds_wall=600
        │                  │                  │
   Best for:          Best for:          Best for:
   - Continuous       - Batch jobs       - Bursty workloads
   - Low latency      - Cost-aware       - Memory leaks
   - Dedicated        - Mixed load       - Short tasks
```

### Example: Cost-Optimized AWS Batch

```r
# For cloud (high launch cost), favor persistence
controller <- crew_controller_aws_batch(
  workers = 20,
  seconds_idle = 300,    # 5 min idle before shutdown
  tasks_max = 500,       # Recycle after many tasks
  seconds_wall = 14400,  # 4 hour soft limit
  # ... AWS-specific options
)
```

### Example: Memory-Leak Mitigation

```r
# For leaky code, recycle workers frequently
controller <- crew_controller_local(
  workers = 4,
  seconds_idle = 30,
  tasks_max = 10,        # Recycle after just 10 tasks
  seconds_wall = 600     # Hard limit 10 minutes
)
```

## Task Submission Patterns

### Single Task with Promise

```r
# Push single task, get promise back
controller$push(
  name = "my_task",
  command = expensive_computation(data)
) %...>%
  function(result) {
    # Callback fires immediately on completion
    process_result(result)
  }
```

### Batch Submission with walk()

```r
# Submit many tasks at once
controller$walk(
  command = process_item(x),
  iterate = list(x = items_to_process)
)

# Wait for all to complete
controller$wait()

# Collect all results
results <- controller$collect()
```

### Manual Pop Loop

```r
# For fine-grained control
while (!controller$empty()) {
  result <- controller$pop()
  if (!is.null(result)) {
    # Process individual result
    handle_result(result)
  }
  Sys.sleep(0.1)  # Avoid busy-waiting
}
```

## Controller Introspection

### Summary Statistics

```r
controller$summary()
# Returns tibble with:
#   controller: name
#   worker: worker ID
#
#   tasks: completed task count
#   seconds: total runtime
#   errors: error count
#   warnings: warning count
```

### Queue Inspection

```r
# View pending tasks
controller$queue

# Check if tasks remain
controller$empty()      # TRUE if no pending/running tasks
controller$saturated()  # TRUE if all workers busy
controller$resolved()   # Number of completed tasks ready to pop
```

### Worker Status

```r
# Detailed worker info
controller$launcher$summary()
```

## Integration with targets

### Basic Setup

```r
# _targets.R
library(targets)
library(crew)

tar_option_set(
  controller = crew_controller_local(
    workers = 4,
    seconds_idle = 60
  )
)

list(
  tar_target(data, load_data()),
  tar_target(model, fit_model(data))
)
```

### With Logging

```r
# _targets.R
library(targets)
library(crew)
library(autometric)

# Controller with monitoring
ctrl <- crew_controller_local(
  workers = parallel::detectCores() - 1,
  seconds_idle = 120,
  options_local = crew_options_local(
    log_directory = "logs/crew/"
  ),
  options_metrics = crew_options_metrics(
    path = "/dev/stdout",
    seconds_interval = 5
  )
)

tar_option_set(controller = ctrl)

# Start logging for orchestrator process too
if (tar_active()) {
  autometric::log_start(
    path = "logs/orchestrator.log",
    seconds_interval = 5
  )
}

list(
  # ... targets ...
)
```

### Multiple Controllers

```r
# _targets.R
library(targets)
library(crew)

# Different controllers for different resources
ctrl_local <- crew_controller_local(
  name = "local",
  workers = 4
)

ctrl_gpu <- crew_controller_slurm(
  name = "gpu",
  workers = 2,
  slurm_partition = "gpu",
  slurm_gpus_per_node = 1
)

tar_option_set(
  controller = crew_controller_group(ctrl_local, ctrl_gpu)
)

list(
  tar_target(data, load_data()),                             # Uses default
  tar_target(model, fit_gpu_model(data), resources = tar_resources(
    crew = tar_resources_crew(controller = "gpu")            # Uses GPU controller
  ))
)
```

## Debugging Common Issues

### Workers Crashing

```r
# Increase crash tolerance
controller <- crew_controller_local(
  workers = 4,
  crashes_max = 5  # Allow more retries
)

# Check crash logs
controller$launcher$errors
```

### Memory Issues

```r
# Recycle workers frequently to release memory
controller <- crew_controller_local(
  workers = 4,
  tasks_max = 5,       # Recycle after 5 tasks
  seconds_idle = 10    # Quick shutdown when idle
)

# Monitor with autometric
controller <- crew_controller_local(
  workers = 4,
  options_metrics = crew_options_metrics(
    path = "/dev/stdout",
    seconds_interval = 1
  )
)
```

### Tasks Stuck

```r
# Check task status
controller$queue            # Pending tasks
controller$resolved()       # Completed count
controller$launcher$summary()  # Worker status

# Force cleanup
controller$terminate()
```

### Workers Not Starting

```r
# Verify R is accessible
Sys.which("R")

# Check launcher errors
controller$launcher$errors

# Try with verbose output
controller <- crew_controller_local(
  workers = 1,
  options_local = crew_options_local(
    log_directory = tempdir()
  )
)
controller$start()
# Check log files in tempdir()
```

## Performance Tuning

### Optimal Worker Count

```r
# Leave one core for main process
workers <- parallel::detectCores() - 1

# For I/O-bound tasks, can exceed core count
workers <- parallel::detectCores() * 2

# For memory-constrained tasks
total_memory_gb <- 16
memory_per_task_gb <- 2
workers <- floor(total_memory_gb / memory_per_task_gb)
```

### Reducing Overhead

```r
# For many small tasks, batch them
controller$walk(
  command = {
    results <- lapply(chunk, process_item)
    results  # Return batch results
  },
  iterate = list(chunk = split(items, ceiling(seq_along(items) / 100)))
)
```

## Best Practices

1. **Always set `seconds_idle`**: Prevents orphaned workers
2. **Use `tasks_max` for long-running apps**: Mitigates memory leaks
3. **Enable logging in production**: Essential for debugging
4. **Monitor with autometric**: Catch resource issues early
5. **Test locally first**: Before deploying to HPC/cloud
6. **Set reasonable `crashes_max`**: Balance retries vs. giving up

## Resources

- [crew Logging Article](https://wlandau.github.io/crew/articles/logging.html)
- [crew Introduction](https://wlandau.github.io/crew/articles/introduction.html)
- [autometric Package](https://wlandau.github.io/autometric/)
- [targets + crew](https://books.ropensci.org/targets/crew.html)
- [crew.cluster](https://wlandau.github.io/crew.cluster/) (HPC)
- [crew.aws.batch](https://wlandau.github.io/crew.aws.batch/) (AWS)

## Related Skills

- parallel-processing (nanonext/mirai/crew stack)
- shiny-async-patterns (crew + Shiny integration)
- project-telemetry (monitoring approaches)
