# Companion: Accessibility Standards — Worked Examples

Worked code examples and consolidation history split out of the
always-loaded [`accessibility`](../accessibility.md) rule to keep it lean.
The normative content (Four Pillars, Color/Contrast/Alt-Text/Table tables,
the 6 Dark Mode clauses, Mandatory Vignette Toolbar table, Forbidden
Patterns) stays in the rule; this file is the verbatim CSS/YAML snippets and
the dated worked example, loaded on demand.

## Rule Consolidation History

Consolidated from: `accessibility-standards`, `dark-mode-completeness`.

## HTML Accessibility — worked YAML snippet

```yaml
format:
  html:
    axe: true  # MANDATORY
```

## Clause 0 — issue 0027 worked example (private-repo tracker)

**5 merged iterations** fixed the wrong layer (mermaid theme override, CSS
catch-all, vendored mermaid 10, per-diagram `%%{init}%%`, http-server
workaround) before the `color-scheme: dark` meta tag was identified as the
root cause.

## Clause 1 — worked CSS snippet

```css
/* RIGHT */
body.dark-mode #element {
  background: #000000 !important;
  color: #ffffff !important;
}
```

## Clause 3 — worked catch-all CSS snippet

```css
body.dark-mode [style*="background:#fff"],
body.dark-mode [style*="background:#f8"]
{ background: #000000 !important; color: #ffffff !important; }
```


## Sections Moved from the Rule Body (2026-09-21 line-limit pass)

Original verbatim text moved out of the rule; the normative summary stays in the rule.

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

Every dark-mode dashboard/vignette MUST include BOTH:

```html
<meta name="color-scheme" content="dark" />
```

```css
:root, html, body { color-scheme: dark; }
```

Without this, **Chrome's "Auto Dark Mode for Web Contents" (default-on since v96, late 2021)** mis-classifies intentionally-dark pages as light and silently inverts the page's lightness — black backgrounds → white, deep palettes → pastels, in plots, tables AND diagrams. Safari/Edge/Brave are unaffected, so the breakage is Chrome-only and easy to miss.

Check this clause FIRST, before any other dark-mode debugging — see the companion doc for the worked example from issue 0027 in a private project's tracker (5 merged iterations fixed the wrong layer before this meta tag was identified as the root cause).

**Dual-mode pages (llm#1003).** The form above pins `dark` and is correct only for pages that are always dark. Chrome's force-dark does not back off because a page *declared a colour scheme* — it backs off only when the page declares that it *supports dark*. A dual-mode page that narrows the declaration to whichever theme is currently active —

```css
/* WRONG on a dual-mode page — light mode is force-darkened */
:root { color-scheme: light; }
:root[data-theme="dark"] { color-scheme: dark; }
```

— re-invites force-dark every time it renders in light mode, while looking, to the person applying the fix, exactly like the fix simply not working. A page supporting both themes MUST declare `color-scheme: light dark` **once, unconditionally**, and MUST NOT narrow it anywhere per theme:

```css
:root, html, body { color-scheme: light dark; }
```

The declaration is not the page's theme; the CSS custom properties are. `check_dashboard_color_scheme.sh` accepts `dark` or `light dark`/`dark light` as satisfying this clause; it still fails a page whose declared value never includes `dark` at all (e.g. a page that only ever says `light`).

Verification: `~/.claude/scripts/check_dashboard_color_scheme.sh <dir>` (greps for both signals in every rendered HTML file that has a same-directory `.qmd`/`.md` source of the same basename; exit 1 on any miss among those. A file with no Quarto source — a shinylive export, a hand-built diagram page, an untracked build artifact — cannot carry a Quarto-injected `<meta>` tag, so it is skipped and reported separately rather than failed; see the script's own header comment for the historical-project case that motivated this scoping). Wire it into the project's Quarto `post-render` alongside `check_dark_contrast.sh`. See llm#584.

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

| Light hex | Dark pair (≥4.5:1 on `#000`) |
|---|---|
| `#198754` (success) | `#69d4a0` |
| `#dc3545` (danger) | `#f08080` |
| `#0dcaf0` (cyan) | `#5edaff` |
| `#0d6efd` (primary) | `#4ea8de` |

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
