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

Force a real yield to the browser by round-tripping through JavaScript.
The pattern has three parts: (1) a JS `addCustomMessageHandler` in the UI
that calls `setTimeout(50ms)` then `setInputValue`, (2) an `observe` that
kicks off the first batch, (3) an `observeEvent(input$next_batch)` that
processes one batch then calls `session$sendCustomMessage("batch_done", ...)`.

The Worker yields on `sendCustomMessage`, the main thread waits 50 ms
(browser renders, handles clicks), then posts back — giving real UI updates
between batches.

See `shinylive-deployment` skill reference: `progress-patterns.md`

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
Standard reactive outputs (renderText, renderPlot, renderUI) update naturally
— no special progress infrastructure needed.

Four proven patterns (full code in reference file):

- **A** — Reactive values + `renderText`: update values at batch end; Shiny flushes within the 50ms window.
- **B** — `reactiveTimer(500)` + `renderText`: fires from the JS main thread; works while the Worker is idle between batches. Use for elapsed time / ETA.
- **C** — `renderUI` for button state: swap text/class/disabled state based on `sim_state()`.
- **D** — `renderPlot` progress placeholder: keep it base-R (not ggplot) to minimise render time. Each call costs ~10% overhead at 500ms intervals; prefer text-only (A/B) for maximum speed.

The randomwalk dashboard combines all four simultaneously.

Alternative (not yet tested): piggyback progress on `batch_done` and update
DOM directly via JS, bypassing Shiny's render cycle. See randomwalk #198.

See `shinylive-deployment` skill reference: `progress-patterns.md`

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
apps embedded in iframes, add custom CSS dark mode: toggle `body.dark-mode`
class via JS, persist to `localStorage`, respect `prefers-color-scheme` on
first load. See `progress-patterns.md` for the snippet.

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
