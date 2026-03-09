# mirai Internals & Advanced Patterns

## Core Principle: Explicit Dependency Passing

mirai evaluates expressions in a **clean environment** on a daemon process. Nothing from the calling environment is available unless explicitly passed. This is the #1 source of mistakes.

**`.args` (recommended for most cases)** - objects placed in the local evaluation environment:

```r
my_data <- data.frame(x = 1:10)
my_func <- function(df) sum(df$x)

m <- mirai(my_func(my_data), .args = list(my_func = my_func, my_data = my_data))

# Shortcut: pass entire calling environment
process <- function(x, y) {
  mirai(x + y, .args = environment())
}
```

**`...` (dot-dot-dot)** - objects assigned to daemon's global environment (for lexical scoping):

```r
m <- mirai(run(data), run = my_run_func, data = my_data)

# Shortcut: pass entire environment
df_matrix <- function(x, y) {
  mirai(as.matrix(rbind(x, y)), environment())
}
```

| Scenario | Use |
|----------|-----|
| Data and simple functions | `.args` |
| Helper functions needing lexical scoping | `...` |
| Pass entire local scope to local env | `.args = environment()` |
| Pass entire local scope to global env | `mirai(expr, environment())` |
| Large persistent objects shared across tasks | `everywhere()` first |

## 5 Common Mistakes

```r
# MISTAKE 1: Not passing dependencies
# WRONG:
m <- mirai(my_func(my_data))
# RIGHT:
m <- mirai(my_func(my_data), .args = list(my_func = my_func, my_data = my_data))

# MISTAKE 2: Unqualified package functions
# WRONG:
m <- mirai(filter(df, x > 5), .args = list(df = my_df))
# RIGHT:
m <- mirai(dplyr::filter(df, x > 5), .args = list(df = my_df))
# OR: everywhere(library(dplyr)) first

# MISTAKE 3: Expecting results immediately
# WRONG:
m <- mirai(slow_computation())
result <- m$data  # may be 'unresolved'
# RIGHT:
result <- m[]  # blocks until resolved

# MISTAKE 4: Mismatched .args names
# WRONG:
m <- mirai(process(input), .args = list(fn = process, data = input))
# RIGHT:
m <- mirai(process(input), .args = list(process = process, input = input))

# MISTAKE 5: Unqualified functions in mirai_map callbacks
# WRONG:
results <- mirai_map(data_list, function(x) filter(x, val > 0))[]
# RIGHT:
results <- mirai_map(data_list, function(x) dplyr::filter(x, val > 0))[]
```

## mirai_map: Parallel Map

```r
library(mirai)

# Basic map - collect with []
results <- mirai_map(1:10, function(x) x^2)[]

# With constant arguments via .args
results <- mirai_map(
  1:10,
  function(x, power) x^power,
  .args = list(power = 3)
)[]

# Map over data frame rows (each row becomes function args)
params <- data.frame(mean = 1:5, sd = c(0.1, 0.5, 1, 2, 5))
results <- mirai_map(params, function(mean, sd) rnorm(100, mean, sd))[]

# Options: flatten, progress, early stopping
results <- mirai_map(1:10, sqrt)[.flat]
results <- mirai_map(1:100, slow_task)[.progress]
results <- mirai_map(1:100, risky_task)[.stop]
results <- mirai_map(1:100, task)[.stop, .progress]
```

## Async Evaluation

```r
# Fire and forget
m <- mirai({
  expensive_computation(data)
})

# Do other work while it runs...

# Collect when ready
result <- m[]
```

## Daemons Setup

```r
# Local daemons (persistent pool)
daemons(4)

# Scoped daemons (auto-cleanup)
with(daemons(4), {
  m <- mirai(expensive_task())
  m[]
})

# Compute profiles (multiple independent pools)
daemons(4, .compute = "cpu")
daemons(2, .compute = "gpu")
m1 <- mirai(cpu_work(), .compute = "cpu")
m2 <- mirai(gpu_work(), .compute = "gpu")

# Reset
daemons(0)
```

## everywhere: Pre-load State on All Daemons

```r
daemons(4)
everywhere(library(DBI))
everywhere(con <<- dbConnect(RSQLite::SQLite(), db_path), db_path = tempfile())
everywhere({}, api_key = my_key, config = my_config)
```

## Error Handling

```r
m <- mirai(stop("something went wrong"))
m[]

is_mirai_error(m$data)       # TRUE for execution errors
is_mirai_interrupt(m$data)   # TRUE for cancelled tasks
is_error_value(m$data)       # TRUE for any error/interrupt/timeout

m$data$message               # Error message
m$data$stack.trace           # Full stack trace

# Timeouts (requires dispatcher)
m <- mirai(Sys.sleep(60), .timeout = 5000)  # 5-second timeout

# Cancellation (requires dispatcher)
stop_mirai(m)
```

## Debugging

```r
# Synchronous mode - runs in host process, supports browser()
daemons(sync = TRUE)
m <- mirai({
  browser()
  result <- tricky_function(x)
  result
}, .args = list(tricky_function = tricky_function, x = my_x))
daemons(0)

# Capture daemon stdout/stderr
daemons(4, output = TRUE)
```

## Remote / Distributed Computing

```r
# SSH (direct connection)
daemons(
  url = host_url(tls = TRUE),
  remote = ssh_config(c("ssh://user@node1", "ssh://user@node2"))
)

# HPC cluster (Slurm/SGE/PBS/LSF)
daemons(
  n = 1,
  url = host_url(),
  remote = cluster_config(
    command = "sbatch",
    options = "#SBATCH --job-name=mirai\n#SBATCH --mem=8G\n#SBATCH --array=1-50",
    rscript = file.path(R.home("bin"), "Rscript")
  )
)
```

## Random Number Generation

```r
# Default: L'Ecuyer-CMRG stream per daemon (non-reproducible)
daemons(4)

# Reproducible: L'Ecuyer-CMRG stream per mirai call
daemons(4, seed = 42)
```

## With Progress

```r
library(mirai)
library(cli)

results <- mirai_map(
  items,
  \(x) process(x),
  .progress = TRUE  # Built-in progress bar
)
```

## nanonext: Custom Async Sockets

```r
library(nanonext)

# Create socket pair
s1 <- socket("pair")
s2 <- socket("pair")

# Connect
listen(s1, "ipc:///tmp/test")
dial(s2, "ipc:///tmp/test")

# Async send/receive
send_aio(s1, data = list(x = 1, y = 2))
recv_aio(s2)
```

## nanonext: Python Interop

```r
# R side with nanonext
library(nanonext)
s <- socket("pair")
listen(s, "tcp://127.0.0.1:5555")

# Python side with pynng
# import pynng
# s = pynng.Pair0()
# s.dial("tcp://127.0.0.1:5555")
# s.send(msgpack.packb(data))

# Receive in R
data <- recv(s)
```
