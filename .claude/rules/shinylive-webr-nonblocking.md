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
