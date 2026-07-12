---
description: Mermaid in dashboards bypasses Quarto's loader — external JS module + mount divs, never mermaid chunks in tabsets
paths:
  - "**/*.qmd"
  - "dashboard/**"
  - "docs/**"
  - "**/*.js"
---

# Rule: Mermaid Diagrams in Dashboards (Mandatory, All Projects)

## When This Applies

Every time a Quarto dashboard, vignette, or panel-tabset page needs a
Mermaid diagram.

## CRITICAL: Never Put a `{mermaid}` Chunk Inside a panel-tabset

Quarto's embedded mermaid loader fires on `window.load` while a hidden
tab is `display: none`. Mermaid's d3-based text measurement returns 0 in
that hidden layout context, so the diagram renders as a 0-sized SVG —
silently, with no console error.

**Fix:** put the diagram on a flat page instead of inside a
`::: {.panel-tabset}` block. This is what every live vignette in this
repo already does — a plain ```` ```{mermaid} ```` chunk on a normal
page renders correctly.

## Enforcement

The `mermaid_dashboard_guard.sh` hook (`PreToolUse:Edit|Write`, wired in
`~/.claude/settings.json`) blocks an edit that would place a
`` ```{mermaid} `` chunk inside a `::: {.panel-tabset}` block in a
`.qmd` file, with a remediation message pointing at this rule.

Escape hatch: `CLAUDE_MERMAID_DASHBOARD_GUARD=0` bypasses for one
command (audited to `~/.claude/logs/mermaid_dashboard_guard_skip.log`).

## Related

- `mermaid-click-anchors` — every URL must include `#L<n>`
- `dark-mode-completeness` — diagram background colours
