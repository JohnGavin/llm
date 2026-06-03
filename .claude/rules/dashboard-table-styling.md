# Rule: Dashboard Table Styling (Mandatory, All Projects)

## When This Applies

Any HTML table emitted by Quarto, Shiny, pkgdown, or any rendered dashboard
or vignette. Applies to inline `<table>` blocks, `DT::datatable()` widgets,
`knitr::kable()`/`kableExtra` output, `gt` tables, `reactable` tables, and
any framework-emitted table.

## Source

JohnGavin/premortem session 30, 2026-06-02. User report: "make all columns
the same width as the text in that column i.e the columns do not have to
span the width of the window, move them to the left and right justify all
columns in all tables."

## CRITICAL: Tables Fit Content, Not the Viewport

A two-column metric/value table stretched to 100% of the viewport puts
unreadable amounts of horizontal whitespace between the metric name and
its value. The reader's eye must traverse blank space to associate label
with value. This is bad for readability and bad for printing.

The default for HTML tables in browsers is `width: auto` (shrink to
content). Bootstrap, Quarto's cosmo theme, DataTables and many other
frameworks override this to `width: 100%`. This rule reverses that
override.

## Required Pattern (CSS)

Every dashboard / vignette stylesheet MUST include these declarations:

```css
/* Tables shrink to content, left-align in container, right-justify cells */
table,
table.dataTable,
.quarto-figure table,
.cell-output table,
.panel-tabset table {
  width: auto !important;          /* shrink to widest column content */
  max-width: 100% !important;       /* but never overflow the container */
  margin-left: 0 !important;        /* left-align the table itself */
  margin-right: auto !important;
  border-collapse: collapse;
  table-layout: auto !important;    /* honour content widths */
}

table th,
table td,
table.dataTable th,
table.dataTable td {
  text-align: right !important;     /* right-justify EVERY cell */
  padding: 0.35rem 0.8rem !important;
  white-space: nowrap;              /* keep cells on one line */
  vertical-align: middle;
}

/* DataTables wrapper inherits the same shrink-to-content behaviour */
.dataTables_wrapper { width: auto !important; display: inline-block; }
.dataTables_filter, .dataTables_info, .dataTables_paginate {
  display: inline-block;
}
```

## Why Right-Justified

- Numbers compare visually when their decimal points align (right-align)
- Currency, percentages, counts and ratios all read better right-aligned
- Mixed numeric / short-text cells (e.g. "£1,234" / "OK") still read
  cleanly right-aligned
- Long-text columns (e.g. multi-paragraph descriptions) should use a
  separate class that overrides to `text-align: left` — these are the
  exception, not the rule

## Allowed Exception: Multi-Paragraph Prose Column

When a column genuinely contains a sentence or paragraph (not a short
label), add a class to that table's `<th>` / `<td>` for that column and
override:

```css
table .prose-column { text-align: left !important; white-space: normal; }
```

Use sparingly. Most "label" columns are short enough that right-align
reads fine.

## Inline `<table>` Blocks in Code-Generated Output

R code that builds HTML tables via `cat()` MUST NOT set `width: 100%`
inline. The CSS above will override it, but inline styles add noise. If
you find inline `<table style="width:100%">` in the codebase, strip the
inline width and let the CSS handle it.

```r
# WRONG: inline width fights the global rule
cat("<table style='width:100%;border-collapse:collapse;'>\n")

# RIGHT: let the CSS handle width; only keep cosmetic styles
cat("<table style='border-collapse:collapse;'>\n")
```

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `table { width: 100% }` in custom CSS | Fights this rule | Use `width: auto !important` |
| `<table style="width:100%">` in code-gen output | Inline override; adds visual noise even with `!important` | Strip inline width |
| `<th style="text-align:left">` on every column | Defeats the right-align default | Remove; let CSS apply right-align; add a prose-column class only where genuinely needed |
| `DT::datatable(..., options=list(autoWidth=FALSE))` with column widths in pixels | Brittle; doesn't shrink to content | Let CSS shrink to content |
| Wrapping a table in a flexbox container that stretches | Same as `width:100%` | Use `display: inline-block` on the wrapper |

## Verification

After applying:
1. Open the rendered HTML in a wide browser window
2. Verify every table is the width of its widest column, not the viewport
3. Verify the table is left-aligned in its container (not centred, not
   right-aligned in a wide blank area)
4. Verify every numeric cell is right-aligned

## Related

- `accessibility` — table contrast, captions
- `uniform-typography` — tables inherit the body font size
- `quarto-vignettes` — table-format rules (DT-only for `vig_*` targets)
- premortem issue 0021 — reference implementation
