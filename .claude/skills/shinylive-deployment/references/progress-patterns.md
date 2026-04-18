# Shinylive/WebR Progress Patterns — Code Reference

Extracted from `shinylive-webr-nonblocking` rule. Apply these patterns when
implementing the JS round-trip batching technique for non-blocking WebR apps.

## JS Round-Trip Batching — Full Implementation

### 1. JS handler in UI

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

### How the round-trip works

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

---

## Live Progress Display Patterns

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

Between batches, Shiny's flush cycle sees changed reactive values,
re-renders outputs, and sends the HTML to the browser — all within
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

`reactiveTimer` fires in the JS main thread. When the R Worker is idle
(between batches), Shiny processes the timer invalidation.

### Pattern C: renderUI for button state changes

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

Keep it base-R (not ggplot) to minimize render time. At 500ms intervals,
each `renderPlot` call adds ~10% overhead; prefer text-only (A/B) for
maximum throughput.

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

---

## Dark Mode CSS/JS Snippet

```r
# In UI, add custom CSS + JS for dark mode in Shinylive iframes
# (bslib light-switch: true does not work inside iframes)
tags$style(HTML("
  body.dark-mode { background: #1e1e1e; color: #e0e0e0; }
  body.dark-mode .well, body.dark-mode .panel { background: #2d2d2d; border-color: #444; }
")),
tags$script(HTML("
  // Respect system preference on first load
  if (window.matchMedia('(prefers-color-scheme: dark)').matches) {
    document.body.classList.add('dark-mode');
  }
  // Restore user preference from localStorage
  if (localStorage.getItem('darkMode') === 'true') {
    document.body.classList.add('dark-mode');
  }
  // Toggle function called by a button
  function toggleDarkMode() {
    document.body.classList.toggle('dark-mode');
    localStorage.setItem('darkMode', document.body.classList.contains('dark-mode'));
  }
"))
```

---

## Sources

- randomwalk project: `vignettes/articles/dashboard_comprehensive.qmd` (2026-04-12)
- Extracted from `~/.claude/rules/shinylive-webr-nonblocking.md` (2026-04-18)
