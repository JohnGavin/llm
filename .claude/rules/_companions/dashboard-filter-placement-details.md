# Companion: Dashboard Filter Placement — Worked Code Examples

Worked code examples split out of the always-loaded
[`dashboard-filter-placement`](../dashboard-filter-placement.md) rule to keep it
lean. The normative content (CRITICAL statement, Decision Table, Toolbar API
table, Forbidden Patterns, Accessibility) stays in the rule; this file is the
per-function code examples, loaded on demand.

## `align` Parameter — Card Header, Right-Anchored

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
