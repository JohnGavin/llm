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

**CRITICAL:** Do not rely on the native HTML `title` attribute as the sole way to convey explanatory text a user is expected to read (unreliable cursor badge, uncontrolled dwell timing, no keyboard fallback; details in companion doc).

Required: a CSS-driven hover/focus popover: wrapper `position: relative`, child `position: absolute; opacity: 0; visibility: hidden`, revealed via `:hover` and `:focus-within`. Reuse an existing project popover component if one exists.

Verification: a resting-state screenshot does NOT prove hover content renders; force the visible state in a **scratch copy** (never the shipped file) and screenshot that. Full rationale and 2026-09-05 origin: companion doc.

## Part 2: Dark Mode Completeness

### Clause 0: `color-scheme: dark` is mandatory (supersedes all other clauses)

Every dark-mode dashboard/vignette MUST include BOTH `<meta name="color-scheme" content="dark" />` and `:root, html, body { color-scheme: dark; }`.

Without this, Chrome's Auto Dark Mode (default-on since v96) silently inverts intentionally-dark pages (Chrome-only, easy to miss). Check this clause FIRST; worked example (issue 0027) in companion doc.

**Dual-mode pages (llm#1003).** A page supporting both themes MUST declare `color-scheme: light dark` once, unconditionally (`:root, html, body { color-scheme: light dark; }`), and MUST NOT narrow it per theme; narrowing to the active theme re-invites Chrome force-dark in light mode. The theme lives in CSS custom properties, not the declaration.

Verification: `~/.claude/scripts/check_dashboard_color_scheme.sh <dir>` (exit 1 on a miss; wire into Quarto `post-render` alongside `check_dark_contrast.sh`; llm#584). Full explanation and script-scoping detail: companion doc.

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

**CRITICAL:** In dark mode the default/body text token (`--ink`, `--fg`, or equivalent) MUST render white (`#ffffff` or near-white, >= ~95% lightness), never a grey, khaki, or tinted off-white (e.g. `#9BA69C`). Muted text (labels, captions) must stay >= 85% lightness on near-black. **Do not build a separate, dimmer token for secondary/muted text at all:** hierarchy comes from size/weight/letter-spacing, not lowered lightness — default new dashboards to `--muted`/`--faint` == `--ink` (full contrast); any deliberate dimming still MUST clear the >= 85% floor ("dimmer" is permitted, "grey" is not). **Applies beyond Quarto/vignettes — explicitly covers Claude Artifacts and any generated/hosted HTML dashboard**: their `paths:` auto-load never fires for an artifact with no tracked file, which is a gap in automatic reminding, not in scope — check this clause explicitly. A categorical status color used ONLY as text on its own contrasting chip background is judged by chip contrast, but as plain text on the page background Clause 6 applies. This raises, not relaxes, Part 1's 4.5:1 floor. Accent, link and status colours may keep their hue; this clause governs reading-text tokens only. Rationale and origin: companion doc.

**Dark-Mode Replacement Palette:** light-to-dark hex pairs (>= 4.5:1 on `#000`) for success, danger, cyan and primary are in the companion doc.

## Part 3: Mandatory Vignette Toolbar

Every vignette MUST have toolbar with:

| Control | Behavior |
|---------|----------|
| Dark/light toggle | Default dark, persists to localStorage |
| Font A−/A+ | 2px steps, persists |
| Language switch | Only if bilingual |

ONE shared partial per project.

### Font A−/A+ implementation note (CRITICAL)

A control that only updates a CSS custom property (e.g. `--fs-base`) is not enough: `rem` is anchored to the root element's computed `font-size`, so most of the page would not change. Required: `html { font-size: var(--fs-base); }`.

Verification: inspect a `rem`-sized element that does not reference the property directly and confirm its rendered size changed. Full explanation and origin: companion doc.

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
