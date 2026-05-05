---
name: dark-mode-completeness
description: Dark mode means pure black background and white text on every element of every page; verified with check_dark_contrast.sh before every commit
type: rule
---

# Rule: Dark Mode Completeness

## Source

Repeated contrast regressions in `acd_area_climate_design` (2026-05-04 / 05). Six PRs in two days each fixed one element at a time after a user bug report; user explicitly demanded a sweep + automated check, not per-element patches.

## When This Applies

Every project that has a dark-mode toggle or honours `prefers-color-scheme: dark`. Every Quarto vignette, every pkgdown article, every Shiny app, every Shinylive vignette.

## CRITICAL: Black means `#000000`. White means `#ffffff`.

When a user requirement says "black background", use literal `#000000`. Tokens like `var(--card-bg)`, `#16213e`, `#1a1a2e`, `#1e1e3a` are NOT black. They are dark blue. Substituting them for `#000` is a violation of the user's literal requirement.

When a user requirement says "white text", use literal `#ffffff`. `var(--text)`, `#e0e0e0`, `#f0f0f0` are NOT white.

## Mandatory Clauses

### Clause 1 — Inline `style=` requires `!important`

Every dark-mode override of an element that carries inline `style="…"` MUST use `!important` on every property. Inline styles outrank class and id selectors. Without `!important` the override is silently ignored.

```css
/* WRONG — loses to inline style="background:#f8f9fa" */
body.dark-mode #match-summary { background: #000000; color: #ffffff; }

/* RIGHT */
body.dark-mode #match-summary {
  background: #000000 !important;
  color: #ffffff !important;
}
```

### Clause 2 — Audit, don't patch

When a user reports ONE contrast bug:

1. Fetch the rendered HTML for the affected page (or the `docs/` build).
2. Run `scripts/check_dark_contrast.sh <url-or-path>` (write it from the canonical implementation if absent).
3. Fix EVERY uncovered element in the same commit, not just the one reported.

Per-element commits for contrast fixes are a process violation. The sweep IS the fix.

### Clause 3 — Catch-all attribute selector required

Every project's dark-mode CSS MUST include a catch-all attribute selector that traps any future inline light backgrounds:

```css
body.dark-mode [style*="background:#fff"],
body.dark-mode [style*="background:#FFF"],
body.dark-mode [style*="background:#f8"],
body.dark-mode [style*="background:#F8"],
body.dark-mode [style*="background:#fef"],
body.dark-mode [style*="background:#fff8"],
body.dark-mode [style*="background:#fff3"],
body.dark-mode [style*="background:#e7f3"],
body.dark-mode [style*="background:#cff"],
body.dark-mode [style*="background:#f3e8"],
body.dark-mode [style*="background:#dee"]
{ background: #000000 !important; color: #ffffff !important; }
```

This is the safety net. Even if a developer adds a new inline-styled box without naming it, the catch-all forces it dark.

### Clause 4 — Verification gate before commit

No commit touching CSS or `.qmd` may be pushed without `check_dark_contrast.sh` exit 0 against the rendered HTML. The script's exit code is a hard gate, equivalent in severity to `parse(_targets.R)` failing.

### Clause 5 — Script is a project artefact

Every project's `scripts/` directory MUST contain `check_dark_contrast.sh`. There is one canonical implementation, copied across projects. It must be wired to:

- A `post-render.sh` Quarto hook, OR
- A pre-commit hook, OR
- A CI job that fails the build on non-zero exit.

Reference implementation: `acd_area_climate_design/scripts/check_dark_contrast.sh`.

## What the script does

```bash
./scripts/check_dark_contrast.sh https://example.com/page.html
# or
./scripts/check_dark_contrast.sh file:///absolute/path/to/docs/page.html
```

1. Fetches the URL with curl.
2. Strips `<style>...</style>` and `<script>...</script>` blocks (so source code text isn't matched as DOM).
3. Greps every inline `style="...background:#XXXXXX..."` where the hex is genuinely light (each RGB channel ≥ 0xb0).
4. For each match, scans the page's own `<style>` blocks for a dark-mode override (id-level rule or attribute selector matching the hex).
5. Reports a table: `(line, element id/class, inline bg, dark-mode protected? yes/no)`.
6. Exits 0 if all light bgs are covered; 1 otherwise.

## Required dark-mode replacement palette

When an inline span uses a Bootstrap utility colour, the dark-mode override must use the matching readable variant against `#000`:

| Light-mode hex | Role | Dark-mode pair (≥4.5:1 on `#000`) |
|---|---|---|
| `#198754` | success / exact | `#69d4a0` |
| `#dc3545` | danger / unmatched | `#f08080` |
| `#6f42c1` | purple / ambiguous | `#c8a8ff` |
| `#fd7e14` | orange / fuzzy / REST | `#ffb070` |
| `#0dcaf0` | cyan / split-both | `#5edaff` |
| `#6c757d` | secondary / split-partial | `#b8c0c8` |
| `#ffc107` | warning | `#ffd966` |
| `#0d6efd` | primary / link | `#4ea8de` |

Direct use of light-mode utility colours against a dark background is forbidden.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `var(--card-bg)` when user said "black" | `--card-bg` is dark blue, not black | Use `#000000` literally |
| `body.dark-mode #X { background: …; }` without `!important` (when X has inline `style="background:…"`) | Inline style wins specificity | Add `!important` to every property |
| Per-element commit fixing only the reported bug | Leaves N-1 sibling bugs for next session | One sweep PR fixing all uncovered elements |
| No `check_dark_contrast.sh` in `scripts/` | No way to detect future regressions | Copy canonical implementation in |
| Commit without running the script | Verification skipped | Run before every CSS or qmd commit |
| Cyan `#0dcaf0` text on dark bg | 5:1 borderline; user-perceived as invisible | Replace with `#5edaff` per palette |

## Lessons logged

- 2026-05-04/05 acd_area_climate_design: 6 contrast PRs in 2 days, each fixing 1-3 elements, before the user demanded a sweep + script. The script (Clause 5) plus the pre-commit gate (Clause 4) close this loop. The catch-all selector (Clause 3) protects against future per-element regressions.
- The pattern was: developer reads user message as a narrow bug report; fixes only what was named; pushes; user finds the next instance of the same architectural failure; repeat. The cure is to treat every contrast bug report as evidence of a class of bug, run the audit, and fix the class.

## Related

- `accessibility-standards` — WCAG 2.1 AA contrast (4.5:1) and the `axe: true` Quarto integration
- `mandatory-vignette-toolbar` (companion rule) — every vignette must have dark/light + font-size + lang toolbar
- `orchestrator-protocol` — post-render contrast gate
- `quality-gates` — point deductions for contrast violations
- `visualization-standards` — chart-level contrast (replaces inline-token usage)
