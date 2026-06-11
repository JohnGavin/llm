---
description: Filters live near their data — bslib toolbar() in card headers/footers; sidebar only for page-wide filters
---

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
| Spacer to push controls to opposing ends of a toolbar | `toolbar_spacer()` between the groups |
| Filter applies to MULTIPLE cards or the whole page | `sidebar()` or a page-top toolbar |
| Cross-cutting filter + resizable sidebar | `sidebar(resizable = TRUE)` — per-card filters still go in card toolbars because the sidebar can shrink and occlude them |
| Static KPI (no user input) | Compact two-column table (`dashboard-table-styling` rule) |
| Big standalone metric | NOT `value_box()` — see AGENTS.md Shiny UI ban |

When in doubt: ask "If this input changed, which cards update?" If the answer is
one card, the input belongs in that card's header or footer. If the answer is
every card, it belongs in the sidebar.

## Toolbar API (bslib 0.11.0+)

Nine functions cover all placement scenarios:

| Function | Purpose |
|---|---|
| `toolbar()` | Compact container; accepts `align = "left"` (default) or `align = "right"` to anchor controls |
| `toolbar_input_button()` | Action buttons inside toolbars |
| `toolbar_input_select()` | Dropdowns inside toolbars |
| `toolbar_divider()` | Visual separator between toolbar groups |
| `toolbar_spacer()` | Flexible space to push groups apart (e.g. label left, buttons right) |
| `update_toolbar_input_button()` | Reactive updates (e.g. icon flip after save, disabled toggle) |
| `update_toolbar_input_select()` | Reactive updates for dropdowns (choices, label, selected) |
| `input_submit_textarea()` | Message-composer textarea with attachment / priority / clear toolbar embedded in the label |

### `align` parameter

`toolbar(align = "right")` anchors the entire toolbar to the trailing edge of its
container. Use `align = "left"` (the default) for most card-header filters; use
`align = "right"` when the controls are secondary to a title that occupies the
left side:

```r
card_header(
  "Monthly Revenue",
  toolbar(
    align = "right",
    toolbar_input_select("rev_region", label = NULL,
      choices = c("All regions", "EMEA", "APAC", "Americas"))
  )
)
```

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

## `toolbar_spacer()` — Full-Width Controls Inside a Label

`toolbar_spacer()` inserts flexible space that expands to push sibling elements
apart. Use it when you want label text on the left and action buttons flush right
within the same toolbar:

```r
numericInput("budget", label = toolbar(
  "Budget cap",
  toolbar_spacer(),          # pushes the buttons to the right edge
  toolbar_input_button("budget_reset",
    label = bsicons::bs_icon("arrow-counterclockwise", title = "Reset to default")),
  toolbar_input_button("budget_help",
    label = bsicons::bs_icon("question-circle", title = "Show help"))
), value = 10000)
```

## Message-Composer Textarea (`input_submit_textarea()`)

`input_submit_textarea()` ships a textarea whose label is itself a toolbar. Use it
for AI chat / LLM-output panels where the user attaches context, sets a priority,
or clears the input from within the input control itself:

```r
input_submit_textarea(
  "user_prompt",
  label = toolbar(
    toolbar_input_select(
      "prompt_priority",
      label = NULL,
      choices = c("Normal", "High", "Critical")
    ),
    toolbar_spacer(),
    toolbar_input_button(
      "attach_file",
      label = bsicons::bs_icon("paperclip", title = "Attach file")
    ),
    toolbar_input_button(
      "clear_prompt",
      label = bsicons::bs_icon("x-circle", title = "Clear message")
    )
  ),
  placeholder = "Ask the model…",
  submit_button = bsicons::bs_icon("send", title = "Send")
)
```

The submit button is keyboard-accessible (Enter sends; Shift+Enter inserts a
newline) and fires `input$user_prompt` like a standard `actionButton`.

## Reactive Updates

### `update_toolbar_input_button()` — Icon flip after save

Use this server-side to reflect state changes without re-rendering the card.
Common pattern: toggle a save button between "unsaved" and "saved" state:

```r
# UI
toolbar_input_button(
  "save_btn",
  label = bsicons::bs_icon("floppy", title = "Save changes")
)

# Server
observeEvent(input$save_btn, {
  save_data()
  update_toolbar_input_button(
    session, "save_btn",
    label    = bsicons::bs_icon("check-circle", title = "Saved"),
    disabled = TRUE
  )
  # Re-enable after 2 seconds
  later::later(function() {
    update_toolbar_input_button(
      session, "save_btn",
      label    = bsicons::bs_icon("floppy", title = "Save changes"),
      disabled = FALSE
    )
  }, delay = 2)
})
```

### `update_toolbar_input_select()` — Dynamic choices from server

Use this to narrow dropdown choices reactively (e.g. filter available regions
based on a dataset loaded after app startup):

```r
# UI
toolbar_input_select("rev_region", label = NULL,
  choices = c("Loading..."), selected = "Loading...")

# Server
observe({
  regions <- get_available_regions()  # computed reactively
  update_toolbar_input_select(
    session, "rev_region",
    choices  = c("All regions", regions),
    selected = "All regions"
  )
})
```

## Tooltips on Icon-Only Toolbar Buttons

Icon-only buttons MUST supply a `title` to `bs_icon()`. bslib wires this to
`aria-label` automatically. The same `title` text also renders as a browser
tooltip on hover, giving sighted users a visible affordance:

```r
toolbar_input_button(
  "export_csv",
  label = bsicons::bs_icon("download", title = "Export as CSV")
  # title= gives aria-label for screen readers AND a hover tooltip for sighted users
)
```

Do NOT add a separate `tooltip()` wrapper around an icon-only button — the
`title=` on `bs_icon()` already handles both the accessibility and tooltip
requirements.

## Sidebar for Page-Wide Filters

When a filter genuinely governs all cards (e.g. a date range that affects
every chart), keep it in the sidebar. The sidebar is the right tool for
cross-cutting controls; toolbars are for per-card controls.

`sidebar(resizable = TRUE)` (bslib 0.11.0+) lets users narrow the sidebar.
Because a narrow sidebar can occlude wide controls, keep per-card filters in
card-header toolbars — do not move them to the sidebar just because the sidebar
is present.

```r
page_sidebar(
  sidebar = sidebar(
    resizable = TRUE,
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
| Page-level `selectInput()` for a filter that only affects one card | Global placement for a local filter; forces reader to scan back to the top | Move into that card's `card_header()` via `toolbar()` |
| `selectInput()` at the top of `page_sidebar()` when it only affects one card | Same as above — page-sidebar context does not change the rule | Move into that card's toolbar |
| `value_box()` for any metric | Space-wasting; AGENTS.md ban | Compact two-column `<table>` |
| Toolbar without `bslib` version >= 0.11.0 in `default.R` / `DESCRIPTION` | Functions not available | Add `bslib (>= 0.11.0)` to Imports |
| `toolbar_input_button()` icon with no `title=` | Inaccessible to screen readers; no hover tooltip | `bs_icon("x", title = "Clear filter")` |
| Using `toolbar()` for controls that affect multiple cards | Wrong placement level | Use `sidebar()` or page-top row |
| Extra `tooltip()` wrapper around an icon-only toolbar button | Redundant — `bs_icon(title=)` already handles both a11y and hover | Remove the `tooltip()` wrapper |
| Moving per-card filters into the sidebar because `resizable = TRUE` is used | Sidebar can shrink and occlude controls | Keep per-card filters in `card_header()` toolbars |

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
