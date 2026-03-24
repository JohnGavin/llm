---
name: shiny-module-data-sharing
description: Patterns for sharing data between Shiny modules. Use when designing module communication, choosing between reactiveValues/R6/session$userData, or debugging cross-module reactivity.
metadata:
  author: Based on ThinkR patterns (rtask.thinkr.fr)
  version: "1.0"
---
# Shiny Module Data-Sharing Patterns

## Decision Matrix

| App complexity | Pattern | When to use |
|---|---|---|
| Small (2-3 modules) | Pass reactives directly | Simple hierarchy, few shared values |
| Medium (4-10 modules) | Scoped reactiveValues() | Group by domain, pass relevant scope to each module |
| Large/deep hierarchy | R6 + gargoyle triggers | Explicit state management, testable outside Shiny |
| Few shared scalars | session$userData | Session-scoped config, no reactivity needed |
| Multi-session persistence | External storage (DB/storr) | State survives session restart |

## Communication Directions

### Parent to Child (parameter passing)

```r
mod_parent_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    rv_filters <- reactiveValues(country = "UK", year = 2024)

    # Child receives only the state it needs
    mod_chart_server("chart", filters = rv_filters)
    mod_table_server("table", filters = rv_filters)
  })
}

mod_chart_server <- function(id, filters) {
  moduleServer(id, function(input, output, session) {
    # Read shared state
    observe({ plot_data <- get_data(filters$country, filters$year) })
  })
}
```

### Child to Parent (return reactive)

```r
mod_parent_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    # Child returns a reactive — parent decides what to do with it
    selected_row <- mod_table_server("table", data = my_data)

    # Wire child output to another child
    mod_detail_server("detail", selected = selected_row)
  })
}

mod_table_server <- function(id, data) {
  moduleServer(id, function(input, output, session) {
    # ... render table ...
    # Return selection to parent
    reactive(input$table_rows_selected)
  })
}
```

### Sibling to Sibling (via shared parent)

```r
mod_parent_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    # Parent creates shared state
    rv_shared <- reactiveValues(selected_id = NULL)

    # Both siblings read/write the same reactiveValues
    mod_selector_server("selector", shared = rv_shared)
    mod_viewer_server("viewer", shared = rv_shared)
  })
}
```

## Pattern 1: Direct Reactive Passing

Best for: small apps, shallow module trees.

```r
# Parent creates reactive, passes to child
filtered <- reactive({ data |> filter(year == input$year) })
mod_chart_server("chart", data = filtered)

# Child receives and uses it
mod_chart_server <- function(id, data) {
  moduleServer(id, function(input, output, session) {
    output$plot <- renderPlot({ plot(data()) })
  })
}
```

**Limitation**: prop drilling — passing through intermediate modules that don't use the value.

## Pattern 2: Scoped reactiveValues()

Best for: medium apps. Key insight: use **multiple** reactiveValues, one per domain.

```r
mod_app_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    # Domain-scoped shared state
    rv_filters <- reactiveValues(country = NULL, date_range = NULL)
    rv_results <- reactiveValues(model_output = NULL, summary = NULL)

    # Each module gets only the scope it needs
    mod_sidebar_server("sidebar", filters = rv_filters)
    mod_analysis_server("analysis", filters = rv_filters, results = rv_results)
    mod_report_server("report", results = rv_results)
  })
}
```

**Rule**: each reactiveValues() should have <20 entries. If growing, split further.

## Pattern 3: R6 + gargoyle Triggers

Best for: complex apps, testable outside Shiny, explicit reactivity.

```r
AppStore <- R6::R6Class("AppStore",
  private = list(
    .filters = list(country = NULL, year = NULL),
    .results = NULL
  ),
  public = list(
    set_filter = function(key, value) {
      private$.filters[[key]] <- value
      gargoyle::trigger("filters_changed")
    },
    get_filters = function() private$.filters,
    set_results = function(value) {
      private$.results <- value
      gargoyle::trigger("results_updated")
    },
    get_results = function() private$.results
  )
)

# In server
store <- AppStore$new()

mod_sidebar_server("sidebar", store = store)
mod_analysis_server("analysis", store = store)

# In a module
mod_analysis_server <- function(id, store) {
  moduleServer(id, function(input, output, session) {
    gargoyle::init("filters_changed", "results_updated")

    gargoyle::on("filters_changed", {
      result <- run_analysis(store$get_filters())
      store$set_results(result)
    })
  })
}
```

**Advantage**: R6 class is testable with testthat outside Shiny context.

## Pattern 4: session$userData

Best for: few shared scalars (user role, config), not bulk state.

```r
# Set once at app start
session$userData$user_role <- get_user_role(session)
session$userData$app_config <- load_config()

# Access via helper functions (cleaner than direct access)
get_user_role <- function(session = getDefaultReactiveDomain()) {
  session$userData$user_role
}

# In any module — no parameter passing needed
mod_admin_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    if (get_user_role() != "admin") return()
    # ... admin-only logic
  })
}
```

**Warning**: not reactive. Changes to session$userData don't trigger observers. Pair with gargoyle if reactivity needed.

## Pattern 5: External Storage

Best for: state that persives across sessions or is shared between users.

```r
# Use session$token for per-user isolation
storage_key <- paste0("app_state_", session$token)
storr::storr_rds("_state")$set(storage_key, current_state)

# Clean up on session end
session$onSessionEnded(function() {
  storr::storr_rds("_state")$del(storage_key)
})
```

## Anti-Patterns

| Anti-Pattern | Problem | Fix |
|---|---|---|
| Monster reactiveValues (300+ entries) | Untrackable reactive graph | Split by domain, <20 entries each |
| Generic `r` variable name | Unclear scope and contents | Descriptive: `shared_filters`, `analysis_state` |
| Child internal state in parent | Tight coupling, breaks encapsulation | Child owns its state, returns minimal interface |
| Nested reactive chains | Hard to debug, invisible dependencies | Flatten with R6 or explicit trigger signals |
| session$userData for bulk state | No reactivity, hard to track | Use reactiveValues or R6 for reactive state |

## Related Skills
- `shiny-bslib` — UI layout and components
- `shiny-async-patterns` — async/ExtendedTask/crew
- `module-isolation` — layer boundaries (project-specific)

## Reference
- [ThinkR: Sharing Data Across Shiny Modules](https://rtask.thinkr.fr/sharing-data-across-shiny-modules-an-update/)
- [Engineering Production-Grade Shiny Apps, Ch. 15](https://engineering-shiny.org/)
