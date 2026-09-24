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

## Tombstone: `verify_mermaid_dashboard.sh` (removed 2026-07-13, restored 2026-09-24)

[#773](https://github.com/JohnGavin/llm/pull/773) (commit `ab14383f`,
`chore(dashboards): prune unused mermaid loader apparatus`) deleted
`.claude/scripts/verify_mermaid_dashboard.sh` (plus `audit_mermaid_dashboards.sh`,
`scaffold-mermaid-dashboard.sh`, and the `.claude/templates/mermaid-dashboard/`
scaffold) as unused. It was not unused: a downstream project's Quarto
`post-render.sh` called it by absolute path on every render, and the call site's
`cmd || echo "advisory" >&2` swallow made "script missing" and "script ran clean"
produce the identical exit code — the breakage ran silently for six weeks
([#1067](https://github.com/JohnGavin/llm/issues/1067)).

**Restored 2026-09-24** per [#1067](https://github.com/JohnGavin/llm/issues/1067):
`.claude/scripts/verify_mermaid_dashboard.sh` ships again — same F1-F5
findings, same 0/1/2 exit codes plus a new 3 (INDETERMINATE, required
dependency `perl` missing — see `checks-must-distinguish-unknown`). At least
one live consumer still calls it, and the verifier's failure mode is silent
by construction: these dashboards mount Mermaid diagrams into initially-empty
`<div id="*-mount">` elements via an external JS loader at browser runtime,
so a broken mount produces no error anywhere in the static rendered HTML —
without this check, the only way to notice is opening the page in a browser
and looking.

The restore also fixed two false-positive heuristics (F2, F3) that only
covered the CDN-ESM loader pattern (`<script type="module">` importing
mermaid from a URL) and false-fired on a second, equally valid loader
pattern: a vendored mermaid UMD bundle inlined into a classic (non-module)
`<script>` tag, followed by another classic `<script>` that calls
`mermaid.initialize()`/`.run()`/`.render()` — used because Chrome and Brave
block cross-origin ES-module imports from `file://` pages. F2 now recognises
either loader pattern as evidence a mount div's emptiness is expected; F3
now excludes `<script>` body content from its match, so a vendored bundle's
own minified error-message templates (which literally contain "Syntax error
in text" and "mermaid version" as library source, not runtime output) are
no longer mistaken for a real parser failure.

## Related

- `mermaid-click-anchors` — every URL must include `#L<n>`
- `dark-mode-completeness` — diagram background colours
- `checks-must-distinguish-unknown` — the swallow-pattern defect that hid this
  removal's breakage for six weeks ([#1067](https://github.com/JohnGavin/llm/issues/1067))
