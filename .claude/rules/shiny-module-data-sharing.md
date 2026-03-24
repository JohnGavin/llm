---
paths:
  - "R/**"
  - "shiny/**"
  - "inst/shiny/**"
  - "app.R"
---
# Shiny Module Data-Sharing Pitfalls

## 1. Monster reactiveValues()

```r
# BAD: single object with everything
r <- reactiveValues(
  filter_country = NULL, filter_year = NULL, selected_id = NULL,
  plot_data = NULL, table_data = NULL, sidebar_open = TRUE,
  # ... 50+ more entries
)

# GOOD: scoped by domain
rv_filters <- reactiveValues(country = NULL, year = NULL)
rv_results <- reactiveValues(plot_data = NULL, table_data = NULL)
```

Keep each reactiveValues() under ~20 entries. If it grows beyond that, split by domain.

## 2. Generic variable names

```r
# BAD: what does r contain? Everything.
mod_chart_server("chart", r = r)

# GOOD: explicit about what's shared
mod_chart_server("chart", shared_filters = rv_filters)
```

Never name shared state `r`, `rv`, or `vals`. Use descriptive names: `shared_filters`, `analysis_state`, `global_config`.

## 3. Parent storing child-internal state

```r
# BAD: parent creates state for child's private UI
r$chart_zoom_level <- 1
r$chart_selected_series <- "all"
mod_chart_server("chart", r = r)

# GOOD: child owns its internal state, returns only what parent needs
chart_selection <- mod_chart_server("chart", data = filtered_data)
# chart_selection is a reactive() returning the user's selection
```

## 4. Implicit sibling communication

```r
# BAD: sibling reads another module's internal reactive
mod_table_server <- function(id, chart_module_internals) {
  # Tight coupling to chart module's implementation
}

# GOOD: parent mediates via shared reactiveValues or explicit wiring
mod_parent_server <- function(id) {
  rv_shared <- reactiveValues(selected_row = NULL)
  mod_chart_server("chart", shared = rv_shared)
  mod_table_server("table", shared = rv_shared)
}
```

## 5. Missing reactivity with R6/session$userData

```r
# BAD: R6 field changed but no reactive invalidation
store$set_filter("2024")
# Downstream observers never fire

# GOOD: pair R6 with gargoyle trigger
store$set_filter("2024")
gargoyle::trigger("filter_changed")

# In consuming module:
gargoyle::on("filter_changed", { ... })
```

## Code Review Checklist

- [ ] No single reactiveValues() with >20 entries
- [ ] All shared reactive objects have descriptive names (not `r`, `rv`, `vals`)
- [ ] Each module returns only what callers need (minimal interface)
- [ ] Parent-to-child: passed as server function parameter
- [ ] Child-to-parent: returned as reactive from module server
- [ ] Sibling communication goes through parent or shared store
- [ ] No module reads another module's internal state directly
- [ ] R6 stores (if used) have explicit gargoyle/trigger signals for reactivity
- [ ] session$userData used sparingly (few shared scalars, not bulk state)
