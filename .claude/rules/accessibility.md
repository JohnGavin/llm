---
description: WCAG 2.1 AA accessibility + dark mode completeness for all public-facing outputs
paths:
  - "**/*.qmd"
  - "vignettes/**"
  - "dashboard/**"
  - "docs/**"
  - "**/*.css"
  - "**/*.scss"
  - "**/*.css.html"
---

# Rule: Accessibility Standards

Source: DSTT Ch5 (Turner). WCAG 2.2, Section 508.

## Part 1: WCAG 2.1 AA Requirements

### Four Pillars (POUR)

All outputs must be Perceivable, Operable, Understandable, and Robust.

### Color and Contrast

| Requirement | Standard |
|-------------|----------|
| Text contrast ratio | 4.5:1 minimum (normal), 3:1 (large: 18pt or 14pt bold) |
| Color as sole differentiator | FORBIDDEN — combine with shape, line type, or labels |
| Mandatory palettes | Viridis or ColorBrewer (`"Dark2"`, `"Set2"`) |

### Alt Text

| Context | Requirement |
|---------|-------------|
| Quarto figures | `fig-alt` on EVERY figure (separate from `fig-cap`) |
| Content | Describe data: "Peak at 2,400 in week 5" NOT "Bar chart showing cases" |

### Accessible Tables

- Every table has caption
- No merged cells (screen reader issue)
- Use `gt` or `DT::datatable()`

### HTML Accessibility

Every Quarto `format: html:` block MUST set `axe: true`. A worked YAML
snippet is in the companion doc.

### Shiny Apps

- Keyboard navigation via Tab/Enter
- ARIA labels on dynamic content
- Visible focus rings
- Labels on all inputs

### Tooltips: prefer a CSS hover/focus popover over native `title=`

**CRITICAL:** Do not rely on the native HTML `title` attribute as the sole
way to convey explanatory text a user is expected to actually read (e.g.
an icon-only button's purpose). It is unreliable in practice, not just
inelegant:

- Browsers commonly render a `cursor: help` "?" badge cursor on
  `[title]`-bearing elements — easily mistaken for "the tooltip," masking
  the fact that no readable text ever appeared.
- Dwell-timing is outside CSS/JS control and browser-dependent; a mouse
  that moves at all can reset the delay indefinitely, so the tooltip may
  never fire in practice even though the markup is correct.
- No usable fallback for keyboard users beyond whatever `:focus` behavior
  the browser itself happens to implement for `title`.

Required: a CSS-driven hover/focus popover instead — wrapper with
`position: relative`, a child holding the explanatory text with
`position: absolute; opacity: 0; visibility: hidden`, revealed via
`:hover` and `:focus-within` on the wrapper. This is fully within project
control: always renders, predictable position, normal text
wrapping/selection, identical behavior for mouse and keyboard. Reuse an
existing project popover component if one already exists rather than
inventing a second one.

Verification: a plain screenshot of a page's resting state does NOT prove
hover-triggered content renders — force the popover's visible state in a
**scratch copy** of the rendered file (never the file being shipped) and
screenshot that. See `verification-before-completion`'s companion doc for
the worked incident this note comes from.

Origin: 2026-09-05, an icon-only toggle button's native `title=` tooltip
showed nothing at all on hover — even after fixing an earlier `cursor:
help` masking bug on the same element. The cursor bug was real but was not
the actual cause; native title-tooltip unreliability was.

## Part 2: Dark Mode Completeness

### Clause 0: `color-scheme: dark` is mandatory (supersedes all other clauses)

Every dark-mode dashboard/vignette MUST include BOTH:

```html
<meta name="color-scheme" content="dark" />
```

```css
:root, html, body { color-scheme: dark; }
```

Without this, **Chrome's "Auto Dark Mode for Web Contents" (default-on since v96, late 2021)** mis-classifies intentionally-dark pages as light and silently inverts the page's lightness — black backgrounds → white, deep palettes → pastels, in plots, tables AND diagrams. Safari/Edge/Brave are unaffected, so the breakage is Chrome-only and easy to miss.

Check this clause FIRST, before any other dark-mode debugging — see the companion doc for the worked example from issue 0027 in a private project's tracker (5 merged iterations fixed the wrong layer before this meta tag was identified as the root cause).

Verification: `~/.claude/scripts/check_dashboard_color_scheme.sh <dir>` (greps for both signals in every rendered HTML file that has a same-directory `.qmd`/`.md` source of the same basename; exit 1 on any miss among those. A file with no Quarto source — a shinylive export, a hand-built diagram page, an untracked build artifact — cannot carry a Quarto-injected `<meta>` tag, so it is skipped and reported separately rather than failed; see the script's own header comment for the historical-project case that motivated this scoping). Wire it into the project's Quarto `post-render` alongside `check_dark_contrast.sh`. See llm#584.

### CRITICAL: Black = `#000000`. White = `#ffffff`.

`var(--card-bg)`, `#16213e`, `#1a1a2e` are NOT black. They are dark blue.

### Clause 1: Inline `style=` requires `!important`

A worked `body.dark-mode #element { ... !important; }` CSS snippet is in the companion doc.

### Clause 2: Audit, don't patch

When ONE contrast bug is reported:
1. Run `check_dark_contrast.sh`
2. Fix ALL uncovered elements in same commit

Per-element commits are a process violation.

### Clause 3: Catch-all selector required

A worked `body.dark-mode [style*="background:#fff"] { ... }` catch-all CSS
snippet is in the companion doc.

### Clause 4: Verification gate

No CSS/qmd commit without `check_dark_contrast.sh` exit 0.

### Clause 5: Single global script

Script at `~/docs_gh/llm/.claude/scripts/check_dark_contrast.sh`. Projects reference by absolute path — NEVER copy per-project.

### Clause 6: Default text color must be white in dark mode, not a tinted grey

**CRITICAL:** In dark mode, the default/body text color token (`--ink`, `--fg`,
or equivalent) MUST render as white (`#ffffff` or a near-white ≥ ~95%
lightness) — never a mid-tone grey, khaki, or a thematically-tinted off-white
(e.g. a light-mode brand palette's dark ink carried into dark mode unchanged
in hue, only lightened — `#9BA69C`, `#78827A`). Secondary/muted text tones
(labels, captions, footnotes) MUST stay light enough to still read as "white,
dimmed" rather than "grey" — target ≥ 85% lightness on a near-black
background, not a distinct grey hue.

This is a stricter bar than Part 1's Color and Contrast table (4.5:1
minimum) — Clause 6 does not relax that floor, it raises it for the
*default* body-text token specifically. Grey-on-black is measurably harder
to read than white-on-black even when it nominally clears 4.5:1: thin
sans-serif text at typical body sizes loses definition against a near-black
background well before the WCAG AA floor.

A dark-mode ink family may keep its light-mode counterpart's hue for accents
(`--accent`, badges, links, semantic status colors) — Clause 6 governs
reading-text tokens only, not the whole palette.

Origin: user instruction 2026-09-05, after reporting that a generated
trip-dashboard's default text (grey-green `--ink-soft`/`--ink-faint` tones
against a near-black `--paper`) was too hard to read; escalated from a
one-off fix to a global rule so it applies to every project's dark mode, not
just the one that prompted it.

### Dark-Mode Replacement Palette

| Light hex | Dark pair (≥4.5:1 on `#000`) |
|---|---|
| `#198754` (success) | `#69d4a0` |
| `#dc3545` (danger) | `#f08080` |
| `#0dcaf0` (cyan) | `#5edaff` |
| `#0d6efd` (primary) | `#4ea8de` |

## Part 3: Mandatory Vignette Toolbar

Every vignette MUST have toolbar with:

| Control | Behavior |
|---------|----------|
| Dark/light toggle | Default dark, persists to localStorage |
| Font A−/A+ | 2px steps, persists |
| Language switch | Only if bilingual |

ONE shared partial per project.

### Font A−/A+ implementation note (CRITICAL)

A text-size control that only updates a CSS custom property (e.g.
`--fs-base`) via JS is not sufficient on its own. `rem` units are anchored
to the **root element's computed `font-size` property**, not to any custom
property. A typical stylesheet uses `rem` for most rules and references
the custom property directly in only a handful — so the control silently
does nothing for the majority of the page's text, even though the property
itself is genuinely changing value on every click.

Required:

```css
html { font-size: var(--fs-base); }
```

This makes the root's actual `font-size` track the property, so every
`rem`-sized rule scales along with it — not just the rules that reference
`var(--fs-base)` explicitly.

Verification: after using the control, inspect a `rem`-sized element that
does NOT reference the custom property directly (a nav link, a table cell)
and confirm its rendered size changed — not just an element that was
already wired to the property.

Origin: 2026-09-05, a trip-dashboard's A+/A− control moved `--fs-base` but
almost nothing on the page visibly changed size, because nearly every rule
used `rem`, and `html`'s own `font-size` — never wired to the property —
is what actually governs what `rem` resolves to.

## Forbidden Patterns

| Pattern | Fix |
|---------|-----|
| `scale_fill_manual(c("red", "green"))` | Use viridis |
| Figure without `fig-alt` | Add descriptive alt text |
| `var(--card-bg)` when user said "black" | Use `#000000` |
| Per-element contrast fix | Sweep PR with full audit |
| Vignette missing dark toggle | Include shared toolbar |
| Dark-mode default text using a tinted grey/khaki hue | Default text white/near-white; see Clause 6 |
| Native `title=` as the only way to explain an icon-only control | CSS hover/focus popover instead |
| Text-size control updates a custom property but never `html`'s `font-size` | `html { font-size: var(--fs-base) }` |

## Related

- [`_companions/accessibility-details.md`](_companions/accessibility-details.md) — worked code examples split out of this rule
- `visualization` — chart contrast, captions
- `quarto-vignettes` — vignette structure
