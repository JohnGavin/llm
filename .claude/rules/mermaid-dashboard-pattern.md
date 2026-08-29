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

## Dark-mode rendering (mermaid-specific)

Page-level `color-scheme: dark` (see `accessibility.md` Clause 0) is
necessary but not sufficient — mermaid has its own dark-rendering bug
independent of the page setting:

- The `%%{init: {theme:'dark'}}%%` directive is honoured for most
  elements, but mermaid's `<foreignObject>` HTML labels (node/edge text)
  render with the browser's default **white** background regardless of
  the theme directive.
- Fix: set fills explicitly instead of relying on the theme alone —
  either `themeVariables` (`background`, `primaryColor`,
  `primaryTextColor`, `clusterBkg`, `clusterBorder`) in
  `mermaid.initialize()`, or per-node `style ID fill:…,color:…` /
  `classDef` directives in the diagram source itself.
- Subgraph backgrounds default to browser white and must be set dark
  explicitly (e.g. `style SUBGRAPH_ID fill:#000,stroke:#fff`) — a
  diagram isn't done until subgraph backgrounds are dark, not white.

## Enforcement

The `mermaid_dashboard_guard.sh` hook (`PreToolUse:Edit|Write`, wired in
`~/.claude/settings.json`) blocks an edit that would place a
`` ```{mermaid} `` chunk inside a `::: {.panel-tabset}` block in a
`.qmd` file, with a remediation message pointing at this rule.

Escape hatch: `CLAUDE_MERMAID_DASHBOARD_GUARD=0` bypasses for one
command (audited to `~/.claude/logs/mermaid_dashboard_guard_skip.log`).

## Tombstone: `verify_mermaid_dashboard.sh` (removed 2026-07-13)

[#773](https://github.com/JohnGavin/llm/pull/773) deleted
`.claude/scripts/verify_mermaid_dashboard.sh` (plus `audit_mermaid_dashboards.sh`,
`scaffold-mermaid-dashboard.sh`, and the `.claude/templates/mermaid-dashboard/`
scaffold) as unused. It was not unused: a downstream project's Quarto
`post-render.sh` called it by absolute path on every render, and the call site's
`cmd || echo "advisory" >&2` swallow made "script missing" and "script ran clean"
produce the identical exit code — the breakage ran silently for six weeks
([#1067](https://github.com/JohnGavin/llm/issues/1067)).

If your project mounts Mermaid diagrams at runtime via an external JS loader
(the exact pattern this rule documents) and relies on a verifier to catch a
failed mount, that verifier no longer ships from this repo. Options: restore
your own copy of the check locally, or replace it with an
indeterminate-vs-clean-vs-failed three-state check per
[`checks-must-distinguish-unknown`](checks-must-distinguish-unknown.md) so a
missing/renamed tool is never silently read as "passed."

## Related

- `mermaid-click-anchors` — every URL must include `#L<n>`
- `dark-mode-completeness` — diagram background colours
- `checks-must-distinguish-unknown` — the swallow-pattern defect that hid this
  removal's breakage for six weeks ([#1067](https://github.com/JohnGavin/llm/issues/1067))
