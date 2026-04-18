---
paths: ["**/shinylive/**", "**/*.qmd", "**/dashboard*"]
---

# Rule: Shinylive/WebR Non-Blocking Long Operations (CRITICAL)

## When This Applies

Any Shiny app running in WebR/Shinylive (browser WASM) that performs a
long-running computation (simulation, model fitting, data processing).

## CRITICAL: `invalidateLater()` Does NOT Yield in WebR

In native R Shiny, `invalidateLater(N)` schedules re-invalidation after N ms
and the httpuv event loop processes UI events in between. In WebR/Shinylive,
this does NOT work:

- R runs in a single-threaded Web Worker
- `invalidateLater()` schedules within R's reactive loop but the Worker
  thread never yields to the JS main thread
- The browser event loop (UI clicks, redraws, dropdown interactions) is starved
- The UI appears completely frozen even though reactive values are updating

**Also broken:** `proc.time()[["elapsed"]]` does not advance while R/WASM code
executes. Time-budgeted loops (`repeat until N ms elapsed`) run forever.

## Required Pattern: JS Round-Trip Batching

Force a real yield to the browser by round-tripping through JavaScript:

### 1. Add JS handler in UI

```r
tags$script(HTML("
  $(document).on('shiny:connected', function() {
    Shiny.addCustomMessageHandler('batch_done', function(msg) {
      setTimeout(function() {
        Shiny.setInputValue('next_batch', Math.random());
      }, 50);  // 50ms = browser renders + handles clicks
    });
  });
"))
```

### 2. Kick off first batch when computation starts

```r
observe({
  req(computation_state() == "running")
  session$sendCustomMessage("batch_done", list(kick = TRUE))
})
```

### 3. Process each batch via `observeEvent`

```r
observeEvent(input$next_batch, {
  req(computation_state() == "running")

  # Process a fixed number of steps
  STEPS_PER_BATCH <- 10L
  for (b in seq_len(STEPS_PER_BATCH)) {
    # ... do work ...
  }

  # Update reactive values (progress displays)
  progress_val(new_progress)

  if (done) {
    computation_state("complete")
  } else {
    # Request next batch via JS round-trip
    session$sendCustomMessage("batch_done", list(step = current_step))
  }
}, ignoreInit = TRUE)
```

### Why This Works

```
R (Web Worker)              JS (Main Thread)
─────────────               ────────────────
Process batch
  ↓
sendCustomMessage ─────────→ Receives "batch_done"
  (Worker yields)            setTimeout(50ms)
                             Browser renders, handles clicks
                             ↓
                             setInputValue("next_batch") ───→ observeEvent fires
                                                              Process next batch
```

The `sendCustomMessage` posts a message FROM the Worker TO the main thread.
The Worker then returns to its event loop (idle). The main thread processes
the message, waits 50ms (browser events!), then posts back. The Worker
receives `next_batch` and processes the next batch.

## Tuning

| Parameter | Guideline |
|-----------|-----------|
| `STEPS_PER_BATCH` | Target 50-200ms of R work per batch. Too low = overhead from round-trips. Too high = UI feels sluggish. |
| `setTimeout` delay | 50ms = good default. 20ms = smoother progress, more overhead. 100ms = less overhead, choppier UI. |
| Total overhead | ~2x slower than blocking execution. Acceptable for interactive use. |

With 200 walkers and 10 steps/batch: ~2000 walker-step ops per batch ≈ 70ms
at WebR speeds. With 50ms JS delay → ~120ms per cycle → ~8 UI updates/sec.

## Live Progress Display Patterns (Proven in randomwalk)

The JS round-trip yields control to Shiny's reactive system between batches.
This means standard Shiny reactive outputs (renderText, renderPlot, renderUI)
update naturally — no special progress infrastructure needed.

### Pattern A: Reactive values + renderText (status text)

Update reactive values at the end of each batch. Shiny renders them
during the 50ms JS yield window.

```r
# In batch handler, after processing:
sim_completed(n_done)
sim_black_pixels(sum(grid == 1L))
sim_current_step(step_count)

# In server, standard renderText reads them:
output$status <- renderText({
  if (sim_state() == "running") {
    paste0("Walkers: ", sim_completed(), "/", n_total,
           " | Black: ", sim_black_pixels(),
           " | Step: ", sim_current_step())
  }
})
```

**Why it works:** Between batches, Shiny's flush cycle sees changed reactive
values, re-renders outputs, and sends the HTML to the browser — all within
the 50ms yield window.

### Pattern B: reactiveTimer + renderText (elapsed time)

`reactiveTimer(500)` fires independently of batch processing. Use it for
values that change with wall clock time (elapsed, ETA).

```r
autoInvalidate <- reactiveTimer(500)

output$elapsed <- renderText({
  autoInvalidate()
  if (sim_state() == "running" && !is.null(sim_start_time())) {
    elapsed <- as.numeric(difftime(Sys.time(), sim_start_time(), units = "secs"))
    format_duration(elapsed)
  }
})
```

**Why it works:** `reactiveTimer` fires in the JS main thread. When the
R Worker is idle (between batches), Shiny processes the timer invalidation.

### Pattern C: renderUI for button state changes

Use `renderUI` to swap button appearance (text, class, disabled state)
based on simulation state. Reactive values trigger re-render between batches.

```r
output$run_button_ui <- renderUI({
  if (sim_state() == "running") {
    actionButton("btn_disabled",
                 sprintf("Running... %d/%d", sim_completed(), n_total),
                 class = "btn-warning", disabled = TRUE)
  } else {
    actionButton("run_btn", "Run Simulation", class = "btn-primary")
  }
})
```

### Pattern D: renderPlot for in-progress visualization

Show a lightweight progress plot during simulation. Keep it simple
(base R text, not ggplot) to minimize render time.

```r
output$main_plot <- renderPlot({
  if (sim_state() == "running") {
    autoInvalidate()
    par(bg = "gray70", mar = c(2, 2, 3, 2))
    plot.new()
    text(0.5, 0.6, sprintf("%d%% complete", progress_pct()), cex = 3)
    text(0.5, 0.3, format_duration(elapsed()), cex = 1.5)
    return()
  }
  req(sim_result())
  # ... full plot on completion ...
})
```

**Caution:** Each `renderPlot` call creates a PNG device, transfers it to
the browser. At 500ms intervals this adds ~10% overhead. For maximum speed,
consider showing progress only in text outputs (Patterns A/B) and rendering
the plot only on completion.

### Combining Patterns

The randomwalk dashboard uses all four simultaneously:
- **A** for status block and live progress line
- **B** for elapsed time (updates even between batches)
- **C** for button text showing walker/pixel counts
- **D** for a simple progress message in the plot area

### Alternative: JS-Only Progress (Not Yet Tested)

A potential zero-overhead alternative: piggyback progress data on the
`batch_done` message and update DOM elements directly via JavaScript,
bypassing Shiny's render cycle entirely. This would eliminate all R-side
render overhead but requires JS DOM manipulation. See randomwalk #198
for discussion.

## Anti-Patterns (FORBIDDEN in WebR/Shinylive)

| Pattern | Why It Fails |
|---------|-------------|
| `invalidateLater(N)` for yielding | Worker never yields to JS main thread |
| `proc.time()` time-budgeted loops | Clock doesn't advance during WASM execution |
| `Sys.sleep(N)` between batches | Blocks the Worker thread (same as no sleep) |
| `later::later(callback, N)` | Same as invalidateLater — stays within R event loop |
| Single blocking function call | Entire UI frozen for duration |

## Dark Mode in Shinylive Apps

bslib's `light-switch: true` only works for pkgdown/Quarto pages. For Shinylive
apps embedded in iframes, add custom CSS dark mode:

```r
# CSS: body.dark-mode { background: #1e1e1e; color: #e0e0e0; }
# JS: toggle body.dark-mode class, persist to localStorage
# Respect prefers-color-scheme media query on first load
```

## Service Worker Caching (Testing)

Shinylive service workers (`shinylive-sw.js`) cache aggressively. When testing
local changes:

- **Always use a different port** for each test round
- Or unregister the service worker in DevTools → Application → Service Workers
- The stale service worker serves cached app content even after re-rendering

## Related

- `btw-timeouts` — MCP tool timeout rules (different problem, same theme: R blocking)
- `shiny-async-patterns` — ExtendedTask for native R (not available in WebR)

## References

- randomwalk project: `vignettes/articles/dashboard_comprehensive.qmd` (2026-04-12)
- Shinylive architecture: R in Web Worker, JS on main thread, postMessage communication
