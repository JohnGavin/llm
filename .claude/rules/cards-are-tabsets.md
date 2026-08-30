---
name: cards-are-tabsets
description: In any dashboard or template page, a set of cards is always a tabset — never a side-by-side grid
paths: ["**/*dashboard*.html", "**/*.qmd", "**/template/**", "**/*artifact*.html", "**/render_*.R"]
---

# Rule: Cards Are Tabsets

## When This Applies

Any page built from the house dashboard template — artifacts, Quarto dashboards,
vignette landing pages — whenever two or more sibling items would be shown as a
row or grid of cards.

## CRITICAL: A set of cards is ALWAYS a tabset. No exceptions.

If there is more than one card, they go in a tabset: one tab per card, first tab
active. There is no threshold, no "only two so a grid is fine", no "these are
short". The grid is never the answer.

| Forbidden | Required |
|---|---|
| `.ag-grid` of item cards | `tabset` — one tab per item |
| `.grid-2` of detail cards | `tabset` — one tab per card |
| A row of KPI/summary cards | `tabset`, or a two-column table |
| "Just these three side by side" | `tabset` |

## Why

A grid puts every card on screen at once, so the page's height grows with its
content and the reader scrolls past nine things to find the one they want. The
density complaint that produces — *"some pages are way way too dense"* — is not
fixed by tightening the CSS; it is fixed by showing one thing at a time and
letting the reader choose which.

Tabs also give the set a visible, scannable index: the tab labels are the
contents list. A grid has no index — you find an item by reading all of them.

## Enforce it in the generator, not in review

A rule that says "prefer tabsets" gets forgotten, and each lapse costs the user
a round trip to point at the same thing again. The durable fix is that **the
renderer has no code path that emits a card grid at all**:

```r
# MANDATORY: a set of cards is ALWAYS a tabset, never a grid.
cards = function(b) tabset(b$id,
  vapply(b$cards, function(c) c$key %||% slug(c$head), character(1)),
  vapply(b$cards, function(c) inline(c$head), character(1)),
  vapply(b$cards, function(c) paste0('<div class="card">', body(c), "</div>"),
         character(1))),
```

Then add a post-render gate, because an author can still paste raw HTML into a
text field:

```r
body_only <- sub("<script>.*", "", sub("^.*</style>", "", html))
if (length(unlist(regmatches(body_only, gregexpr("ag-grid|grid-2", body_only))))) {
  cat("REFUSING TO WRITE -- card grid in the output.\n")
  quit(status = 1)
}
```

Falsify the gate before trusting it: paste `<div class="ag-grid">` into a prose
field and confirm the render refuses and leaves the previous output byte-identical.

## The same discipline applies to long sections

Where a tabset does not fit — a status table, a single long decision card, a
reference list — use a **closed `<details>`** rather than leaving it expanded.
The reader opens what they need. Default to collapsed for anything that is
reference rather than headline.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `.ag-grid` / `.grid-2` in a generated page | The grid is what makes pages dense | `tabset` |
| "Only two cards, a grid is fine" | The rule has no threshold | `tabset` |
| Adding a tabset only where the user complained | Same instruction, unheeded elsewhere | Audit every card set on the page |
| Documenting the rule but leaving the grid code path in place | It will be used again | Delete the code path |

## Related

- [`follow-the-reference-fully`](follow-the-reference-fully.md) — a reference is a
  component library; auditing it up front is how you find the card sets that
  should have been tabsets
- [`dashboard-filter-placement`](dashboard-filter-placement.md) — controls belong
  with the thing they filter, which is the same instinct applied to inputs
- [`accessibility`](accessibility.md) — tab panels need `role="tablist"`,
  `aria-selected`, and arrow-key navigation
- [`verification-before-completion`](verification-before-completion.md) — falsify
  the gate; a check you have never seen fail is not a check

## Origin

User, 2026-08-29, on the Vienna trip artifact: *"move ALL cards to tabs in a
tabset everywhere. no exceptions. make this the mandatory default for all future
templates like this."* The instruction had already been given three times about
individual pages ("why are X and Y not tabs in a tabset? this is my 3rd time
asking"). Each time it was applied only where it was pointed at. Making the
renderer structurally incapable of emitting a grid is what stops the fourth ask.
