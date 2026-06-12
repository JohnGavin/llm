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
Mermaid diagram. This rule supersedes the "use a `{mermaid}` chunk and let
Quarto handle it" intuition for anything more complex than a single
flat-page diagram with 5 or fewer nodes.

## Source

JohnGavin/premortem session 30-31, 2026-06-02 / 2026-06-03. Seven failed
approaches before adopting JohnGavin/historical's external-JS pattern. Full
failure analysis in `<project>/knowledge_base/lessons_learnt.md` L-10/L-11.

## CRITICAL: Don't Fight Quarto's Mermaid Loader

Quarto ships an embedded mermaid bundle that runs on `window.load`. It has
four documented (here, now) failure modes:

| Failure | Why it happens |
|---|---|
| 0-sized SVG | Quarto loader fires while the tab is `display: none`; mermaid's d3-based text measurement returns 0 in a hidden layout context |
| Silent errors | The Quarto loop has no try/catch around `await mermaid.render()`; one bad diagram aborts the whole loop AND nothing reaches the console |
| Theme inconsistency | `%%{init: {theme:'dark'}}%%` directive is honoured for some elements but `<foreignObject>` HTML labels render with the browser's default white background regardless |
| Loader version coupling | Quarto bundles a SPECIFIC mermaid build; if you need a newer feature or a specific renderer (ELK), you can't easily switch |

Trying to make the embedded loader behave through CSS overrides, theme
directives, `mermaid-tab-fix.html` shims, or `securityLevel` flags is a
losing game. **Bypass it entirely.**

## The Six-Step Pattern

### Step 0 — Page-level `color-scheme: dark` (check FIRST)

The most common failure mode for Chrome dashboard diagrams is NOT mermaid
theme inversion or CSS catch-all gaps; it's **Chrome's Auto Dark Mode for
Web Contents** (default-on since v96) auto-inverting the whole page —
black subgraphs render white, the palette goes pastel, and only in Chrome.
Before spending ANY time on mermaid theme overrides or vendored bundles,
verify the page declares:

```html
<meta name="color-scheme" content="dark" />
```

plus `:root, html, body { color-scheme: dark; }` in CSS. See
`accessibility` rule Part 2 Clause 0 (origin: premortem issue 0027 — five
merged iterations on the wrong layer). Automated check:
`~/.claude/scripts/check_dashboard_color_scheme.sh <output-dir>` (llm#584).

### Step 1 — Use the external-module approach

Create `<dashboard>/<your-diagrams>.js` modelled on the reference template
at `~/docs_gh/llm/.claude/templates/mermaid-dashboard/diagrams.js`. Key
ingredients:

```javascript
import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";

mermaid.initialize({
  startOnLoad: false,           // CRITICAL — we control the loop
  securityLevel: "loose",       // CRITICAL — required for click directives
  theme: "dark",
  themeVariables: { background: "#000", primaryColor: "#000",
                    primaryTextColor: "#fff", lineColor: "#CC0000",
                    clusterBkg: "#000", clusterBorder: "#fff" }
});
```

### Step 2 — Inline the module (file:// requires it)

Chrome blocks `<script type="module" src="local.js">` from `file://`
origins (CORS-like restriction on module loading from local files). But
inline modules — `<script type="module">…content…</script>` — DO work,
AND they can cross-origin import from CDN URLs.

The reference workflow is:

1. Edit `<dashboard>/<your-diagrams>.js` (the source of truth)
2. Inline it into `<dashboard>/<your-diagrams>-loader.html` via:
   ```bash
   printf '<script type="module">\n' > loader.html
   cat your-diagrams.js >> loader.html
   printf '\n</script>\n' >> loader.html
   ```
   Or commit a shell script `inline-diagrams.sh` in the dashboard dir.
3. Reference the loader from the qmd YAML:
   ```yaml
   format:
     html:
       include-after-body:
         - "your-diagrams-loader.html"
   ```

### Step 3 — Mount divs in the qmd (not `{mermaid}` chunks)

In the qmd, the diagrams are placeholders:

```markdown
## Architecture

<div id="arch-mount" style="min-height:520px;"></div>

<p class="figure-caption">Figure 1: …</p>
```

NOT `{mermaid}` chunks. The JS populates the mount div at runtime.

### Step 4 — Diagram source in the JS file's `dagDefs` object

```javascript
var dagDefs = {
  "arch-mount":
    "graph TD\n" +
    "  subgraph IO_LAYER[\"IO layer\"]\n" +
    "    IO[\"initial_state_from_yaml\"]\n" +
    "    LOAD_SCEN[\"load_scenarios\"]\n" +
    "  end\n" +
    "  …",
  "assump-mount": "graph LR\n  …"
};
```

The mount-div ID is the dictionary key. Use `graph TD`/`graph LR` (not
`flowchart TB`) — older syntax, more lenient parser. Quote subgraph
titles AND node labels. Use per-node `style ID fill:…,stroke:…,color:…`
directives for theming, NOT CSS.

### Step 5 — Per-diagram render with try/catch

```javascript
async function renderAll() {
  for (var mountId in dagDefs) {
    var mount = document.getElementById(mountId);
    if (!mount) continue;
    if (mount.querySelector('svg')) continue;       // already rendered
    if (mount.offsetParent === null) continue;       // hidden tab — wait
    try {
      var out = await mermaid.render('mmd-' + mountId, dagDefs[mountId]);
      mount.innerHTML = out.svg;
      // … hover-popup attachment …
    } catch (e) {
      console.error('[diagrams] render failed for ' + mountId + ':', e);
      mount.innerHTML = '<pre style="color:#ff5050">' + e.message + '</pre>';
    }
  }
}

document.addEventListener('DOMContentLoaded',
  function() { setTimeout(renderAll, 500); });
document.addEventListener('shown.bs.tab',
  function() { setTimeout(renderAll, 300); });
```

Per-diagram try/catch means one bad diagram doesn't break others. The
`shown.bs.tab` listener handles hidden-tab re-rendering.

### Step 6 — Rich hover popups with embedded source links

Native browser tooltips (`<abbr title="…">`) are too short and too small.
Build a custom floating popup div:

```javascript
var nodeTooltips = {
  "IO": "initial_state_from_yaml() — reads estate.yaml …. Source: model/R/io.R#L44",
  // … 2-3 sentence detailed body for every node …
};

// Inject popup styles ONCE; use 1.05rem font (larger than body default
// because hover content needs to be readable without leaning in)
var popupCSS = `
.pm-popup {
  position: fixed; visibility: hidden;
  background: #0d1421; color: #ffffff;
  border: 1px solid #ff5050; border-radius: 6px;
  padding: 12px 16px; max-width: 480px;
  font-size: 1.05rem; line-height: 1.5;
  z-index: 9999; box-shadow: 0 4px 16px rgba(0,0,0,0.5);
}
.pm-popup a { color: #69d4a0; text-decoration: underline; font-weight: 600; }
`;
```

Same pattern for edge tooltips via `edgeMetadata` keyed by `"SRC->DST"`.

## Reference Template Files (Mandatory Starting Point)

`~/docs_gh/llm/.claude/templates/mermaid-dashboard/`:

| File | Purpose |
|---|---|
| `diagrams.js` | The source module — `dagDefs`, `nodeTooltips`, `edgeMetadata`, render loop, popup logic. Adapted from JohnGavin/historical/docs/causal-diagrams.js with the project-specific bits stripped. |
| `diagrams-loader.html` | Inlined-module wrapper. Generated from `diagrams.js` via the shell snippet in Step 2. |
| `mount-div.qmd` | The markdown pattern for the qmd: a mount div with a colour-key figure caption. |
| `README.md` | "Copy these 3 files; do the 3 replacements named in the README; you have working diagrams." |

The reference implementation that proves it works:

- **JohnGavin/historical**: `docs/causal-diagrams.js` (877 lines, fully
  documented) renders 5 diagrams in a panel-tabset with edge popups and
  click-to-zoom.
- **JohnGavin/premortem**: `dashboard/premortem-diagrams.js` (397 lines)
  renders the architecture + assumptions diagrams in a Quarto panel-tabset.

## Colour Palette (proven readable)

| Layer | Fill | Stroke | Text |
|---|---|---|---|
| IO / inputs | `#4e9af1` (blue) | `#CC0000` (red) | `#000` (black) |
| Engine / compute | `#f17c4e` (orange) | `#CC0000` | `#000` |
| IHT / regulation | `#a14ef1` (purple) | `#CC0000` | `#fff` (white) — NOT yellow with dark text |
| Output / sink | `#4ef18a` (green) | `#CC0000` | `#000` |
| Edges | n/a | `#CC0000` 4px | n/a |
| Subgraph backgrounds | `#000` (black) | `#fff` 2px | n/a |
| Popup background | `#0d1421` (dark navy) | `#ff5050` 1px | `#fff` |
| Popup link | `#69d4a0` (mint) underline | n/a | n/a |

Yellow `#f1c84e` was rejected on 2026-06-03 (poor contrast with white
text). Use purple `#a14ef1` instead.

## Anti-Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `` ```{mermaid} … ``` `` chunks in a panel-tabset dashboard | Quarto's loader fires on `window.load` when hidden tabs are `display: none`; SVGs come back 0-sized | Use mount divs + external JS module (this rule) |
| Generating the mermaid block via R `cat()` with `results: asis` | Adds an indirection layer that swallows the actual mermaid error | Define the diagram source as a JS string in `dagDefs` |
| Single-node subgraphs | ELK renderer throws TypeError | Merge into multi-node subgraphs OR remove the subgraph wrapping |
| Trying to fix theme via CSS only | mermaid's `<foreignObject>` HTML labels render with browser-default white bg | Use per-node `style ID fill:…,color:…` directives in the diagram source |
| Yellow node fill with white text | Contrast WCAG fails | Purple `#a14ef1` with white text |
| `<script type="module" src="local.js">` from a `file://` HTML | Chrome blocks module-load from file:// | Inline the script: `<script type="module">…content…</script>` |
| `<abbr title="short">` for hover popups | Browser default tooltip is tiny and supports only plain text | Custom floating div with HTML body + embedded `<a href>` source links |
| One-sentence tooltips | Reader needs to know WHERE the node lives in source | 2-3 sentence body + `Source: path#L<n>` trailer |

## Acceptance Criteria

A dashboard mermaid diagram is "shipped" only when:

1. The diagram renders in the browser within 1 second of clicking its tab
2. Console shows `[diagrams] rendered <mount-id>` (no errors)
3. Every node has a hover popup with ≥ 2 sentences + a `Source:` link
4. Every edge with semantic meaning has a hover popup
5. Clicking a node opens the source file in a new tab
6. Subgraph backgrounds are dark (not browser-default white)
7. Arrow strokes are thick enough to read (≥ 2px; this project uses 4px)
8. Node colours work with the chosen text colour (WCAG AA contrast)

## Enforcement (4 Layers)

This rule is enforced — not advisory. Four independent layers catch the
failure modes from L-10/L-11. Each has its own selftest battery.

| Layer | Type | Fires when | Path | Selftest |
|---|---|---|---|---|
| **L1** | PreToolUse:Edit\|Write hook | Agent edits a `.qmd` and the diff puts a `` ```{mermaid} `` chunk inside `::: {.panel-tabset}` | `~/.claude/hooks/mermaid_dashboard_guard.sh` | `CLAUDE_HOOK_SELFTEST=1 bash …mermaid_dashboard_guard.sh` (7/7) |
| **L2** | Post-render verifier | After `quarto render`, scans rendered `.html` for runtime failure signatures | `~/.claude/scripts/verify_mermaid_dashboard.sh` | `…verify_mermaid_dashboard.sh --selftest` (15/15) |
| **L3** | Scaffold helper | When starting a new dashboard, drops the 4 reference template files in place with name substitution | `~/.claude/scripts/scaffold-mermaid-dashboard.sh` | `…scaffold-mermaid-dashboard.sh --selftest` (13/13) |
| **L4** | Repo-wide audit | Sweeps every `.qmd` in a project tree for pre-existing violations; safe to wire into `/check` and CI | `~/.claude/scripts/audit_mermaid_dashboards.sh` | `…audit_mermaid_dashboards.sh --selftest` (7/7) |

### L1 — PreToolUse hook (blocks at edit time)

Registered in `~/.claude/settings.json` under `PreToolUse.matcher=Edit|Write`.
Returns exit code 2 with a remediation message when an edit would put a
`` ```{mermaid} `` chunk inside a `::: {.panel-tabset}` block of a `.qmd`
file. The block message lists the rule path, template path, and lessons
learnt path so the agent can self-correct without a round-trip.

Escape hatches:

| Env var | Effect |
|---|---|
| `CLAUDE_MERMAID_DASHBOARD_GUARD=0` | Bypass for one command (audited to `~/.claude/logs/mermaid_dashboard_guard_skip.log`) |
| `mermaid-dashboard-guard: off` line in `.claude/CLAUDE.md` | Per-project exemption (not yet wired — manual env-var bypass for now) |

### L2 — Post-render verifier (catches runtime failures)

Scans rendered `.html` for five known failure signatures:

| ID | Signal | Failure mode |
|---|---|---|
| F1 | `<pre class="mermaid mermaid-js">` inside `class="tab-pane"` | The dashboard fail mode — diagram never renders in hidden tab |
| F2 | Empty `<div id="*-mount">` AND no inline `<script type="module">` on page | Template adopted but loader never reached the page |
| F3 | Literal `"Syntax error in text"` near `"mermaid version"` | Parser threw — diagram silently failed |
| F4 | `fill:#f1c84e` (banned yellow) | Poor contrast with white text (WCAG fail) |
| F5 | `<script type="module" src="local.js">` from file:// (Chrome blocks) | Will never load |

F4 and F5 strip `<!-- … -->` and `<pre>` / `<code>` blocks before scanning
so documentation snippets showing the banned patterns don't trigger.

Add to `_quarto.yml`:

```yaml
project:
  post-render:
    - bash /Users/johngavin/.claude/scripts/verify_mermaid_dashboard.sh docs
```

### L3 — Scaffold helper (starts a new dashboard correctly)

```bash
scaffold-mermaid-dashboard.sh <target-dashboard-dir> <project-name>
```

Copies the 4 reference template files into the target directory with
`PROJECT_NAME` substitution, and prints the mount-div + YAML fragments to
paste into the target `.qmd`. Idempotent — refuses to overwrite without
`--force`.

### L4 — Repo audit (catches pre-existing violations)

```bash
audit_mermaid_dashboards.sh [path]
```

Walks `*.qmd` (excluding `.git/`, `_freeze/`, `_targets/`, `node_modules/`,
`.claude/templates/`) and reports each `{mermaid}` chunk found inside a
`::: {.panel-tabset}` block. Exits non-zero on any violation. Safe to wire
into `~/.claude/scripts/r_code_check.sh` or a project's CI workflow.

### Recommended chain

1. **Starting a new dashboard:** `scaffold-mermaid-dashboard.sh` (L3)
2. **While editing:** L1 catches accidents at tool-call time
3. **Before pushing:** `quarto render` then `verify_mermaid_dashboard.sh docs/` (L2)
4. **Repo-wide check:** `audit_mermaid_dashboards.sh .` (L4) — wire into `/check`

## Related

- `~/docs_gh/llm/.claude/templates/mermaid-dashboard/` — reference template
- `mermaid-click-anchors` — every URL must include `#L<n>` (still applies
  to the click directives in the JS `dagDefs` strings)
- `visualization-detailed` — broader chart guidance; see the mermaid section
- `uniform-typography` — popup font choice (≥ body size, NOT smaller)
- `dark-mode-completeness` — popup + diagram background colours
- premortem `knowledge_base/lessons_learnt.md` L-10/L-11 — origin failure
- JohnGavin/historical `docs/causal-diagrams.js` — canonical working
  implementation
