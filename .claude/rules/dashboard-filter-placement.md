# Rule: Dashboard Filter Placement

## When This Applies

Every Shiny app, Quarto dashboard, and pkgdown dashboard that contains filter
controls — selectInputs, actionButtons, date pickers, or any interactive element
that modifies a view.

## CRITICAL: Filters live near their data, not floating at the top

Page-top or global-sidebar placement made sense when every input affected every
output. In a multi-card dashboard, a filter sitting three cards away from the
chart it controls imposes a spatial-reasoning tax on the reader: look at the
chart, scan up, find the right input, change it, scan back down.

bslib 0.11.0+ provides `toolbar()` — a compact container family that puts
controls in `card_header()`, `card_footer()`, and inline with input labels.
Use it to co-locate filters with the data they govern.

## Decision Table

| Situation | Use |
|---|---|
| Filter applies to ONE card (chart or table) | `toolbar()` inside `card_header()` or `card_footer()` |
| Filter applies to a single input (preset or reset) | `toolbar()` inline with the input's label |
| Filter applies to MULTIPLE cards or the whole page | `sidebar()` or a page-top toolbar |
| Static KPI (no user input) | Compact two-column table (`dashboard-table-styling` rule) |
| Big standalone metric | NOT `value_box()` — see AGENTS.md Shiny UI ban |

When in doubt: ask "If this input changed, which cards update?" If the answer is
one card, the input belongs in that card's header or footer. If the answer is
every card, it belongs in the sidebar.

## Toolbar API (bslib 0.11.0+)

Seven functions cover all placement scenarios:

| Function | Purpose |
|---|---|
| `toolbar()` | Compact container; accepts `align` and fluid arrangement |
| `toolbar_input_button()` | Action buttons inside toolbars |
| `toolbar_input_select()` | Dropdowns inside toolbars |
| `toolbar_divider()` | Visual separator between toolbar groups |
| `toolbar_spacer()` | Flexible space to push groups apart |
| `update_toolbar_input_button()` | Reactive updates (e.g. icon flip after save) |
| `update_toolbar_input_select()` | Reactive updates for dropdowns |

## Card Header with Embedded Filter

```r
card(
  full_screen = TRUE,
  card_header(
    "Monthly Revenue",
    toolbar(
      toolbar_input_select(
        "rev_region",
        label = NULL,
        choices = c("All regions", "EMEA", "APAC", "Americas"),
        selected = "All regions"
      ),
      toolbar_divider(),
      toolbar_input_button(
        "rev_reset",
        label = bsicons::bs_icon("arrow-counterclockwise", title = "Reset filter")
      )
    )
  ),
  plotOutput("revenue_plot")
)
```

The filter travels with the card: full-screen mode, reordering, and tab
switching all keep the control visible next to its chart.

## Input Label with Inline Preset Buttons

```r
numericInput("threshold", label = toolbar(
  "Threshold",
  toolbar_input_button(
    "preset_low",  label = "Low",  class = "btn-sm btn-outline-secondary"
  ),
  toolbar_input_button(
    "preset_high", label = "High", class = "btn-sm btn-outline-secondary"
  )
), value = 50)
```

## Sidebar for Page-Wide Filters

When a filter genuinely governs all cards (e.g. a date range that affects
every chart), keep it in the sidebar. The sidebar is the right tool for
cross-cutting controls; toolbars are for per-card controls.

```r
page_sidebar(
  sidebar = sidebar(
    dateRangeInput("date_range", "Date range",
      start = Sys.Date() - 90, end = Sys.Date())
  ),
  layout_column_wrap(
    card(card_header("Revenue"), plotOutput("revenue_plot")),
    card(card_header("Costs"),   plotOutput("costs_plot"))
  )
)
```

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `selectInput()` at the top of `page_sidebar()` when it only affects one card | Global placement for a local filter | Move into that card's `card_header()` via `toolbar()` |
| `value_box()` for any metric | Space-wasting; AGENTS.md ban | Compact two-column `<table>` |
| Toolbar without `bslib` version ≥ 0.11.0 in `default.R` / `DESCRIPTION` | Functions not available | Add `bslib (>= 0.11.0)` to Imports |
| `toolbar_input_button()` icon with no `title=` | Inaccessible to screen readers | `bs_icon("x", title = "Clear filter")` |
| Using `toolbar()` for controls that affect multiple cards | Wrong placement level | Use `sidebar()` or page-top row |

## Accessibility

Toolbar buttons that use icon-only labels MUST provide a `title` argument to
`bsicons::bs_icon()` (which sets `a11y = "sem"` automatically). This satisfies
the `accessibility` rule's requirement for screen-reader labels on interactive
elements.

## Related

- `dashboard-table-styling` — how tables look; this rule says where their filters live
- `uniform-typography` — toolbar text must match body font size
- `accessibility` — icon-only buttons require accessible labels
- `shiny-bslib` skill — full bslib component reference including toolbars section
