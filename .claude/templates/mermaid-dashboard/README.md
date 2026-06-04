# Mermaid Dashboard Template

Copy these files when you need a working mermaid diagram in a Quarto
dashboard. Rule: `mermaid-dashboard-pattern`.

## Reference implementations

The template is distilled from two working projects. Look at them first
if you want a working dashboard sooner than you can read this README:

- **JohnGavin/historical**: `docs/causal-diagrams.js` (5 diagrams, 877 lines)
- **JohnGavin/premortem**: `dashboard/premortem-diagrams.js` (2 diagrams, 397 lines)

Both render mermaid diagrams in a Quarto panel-tabset using exactly the
pattern in this template.

## Files

| File | Where it goes | Edit pattern |
|---|---|---|
| `diagrams.js` | `<dashboard>/diagrams.js` (rename to your project) | Replace `dagDefs`, `nodeTooltips`, `edgeMetadata` with your diagrams |
| `diagrams-loader.html` | `<dashboard>/diagrams-loader.html` | Generated from `diagrams.js` via `inline-diagrams.sh` |
| `inline-diagrams.sh` | `<dashboard>/inline-diagrams.sh` | Run after every JS edit; commit both files |
| `mount-div.qmd` | Paste into your `.qmd` where the diagram should appear | Replace `arch-mount` with your mount-div ID |
| `quarto-frontmatter.yaml` | Snippet for your qmd's YAML | Add the `include-after-body` line |

## Minimal workflow (5 minutes from clone to render)

```bash
# 1. Copy the template files into your dashboard
cp -r ~/docs_gh/llm/.claude/templates/mermaid-dashboard/{diagrams.js,diagrams-loader.html,inline-diagrams.sh,mount-div.qmd} dashboard/

# 2. Rename to project-specific names (optional but conventional)
cd dashboard
mv diagrams.js myproject-diagrams.js
mv diagrams-loader.html myproject-diagrams-loader.html
sed -i '' 's/diagrams.js/myproject-diagrams.js/' inline-diagrams.sh

# 3. Edit myproject-diagrams.js — replace dagDefs / nodeTooltips with your diagrams
$EDITOR myproject-diagrams.js

# 4. Inline the JS into the loader (creates the HTML)
bash inline-diagrams.sh

# 5. Wire the loader into the qmd YAML
#    include-after-body:
#      - "myproject-diagrams-loader.html"

# 6. Add a mount div where you want the diagram:
#    <div id="arch-mount" style="min-height:520px;"></div>

# 7. Render
quarto render dashboard/planning.qmd
```

## Why the inlined-module workflow?

Chrome blocks `<script type="module" src="local.js">` from `file://`
origins. Quarto dashboards opened locally (`file://…/dashboard/page.html`)
fall foul of this. Solution: keep the source as a `.js` file (editable,
diff-friendly, git-friendly) but inline it into a `.html` file as
`<script type="module">…content…</script>` before the qmd is rendered.

`inline-diagrams.sh` automates this. Run it after every edit to the `.js`
file. The two files must stay in sync; CI should fail if they diverge.

## Why NOT use Quarto's `{mermaid}` chunks?

See rule `mermaid-dashboard-pattern` section "CRITICAL: Don't Fight Quarto's
Mermaid Loader". Short version: the embedded loader has known issues with
hidden tabs, `<foreignObject>` HTML labels, theme directives, and error
reporting. The external-JS pattern bypasses all of them.

## What to customise per diagram

In `diagrams.js`:

1. **`dagDefs`** — one entry per mount div. Use `graph TD` / `graph LR`,
   quoted subgraph titles AND node labels, per-node `style` directives,
   `linkStyle default stroke:…,stroke-width:4px` for arrows.

2. **`nodeTooltips`** — keyed by node ID. 2-3 sentence descriptions ending
   with `Source: path#L<n>`. The render loop extracts the `Source:` tail
   and turns it into a clickable link in the popup.

3. **`edgeMetadata`** — keyed by `"SRC->DST"`. Each entry has
   `{ tooltip: "...", href: "../path/to/source#L<n>" }`. The render loop
   binds hover + click on each matching path.

4. **Colour palette in `style` lines** — see `mermaid-dashboard-pattern`
   rule's colour table. Yellow with white text was banned 2026-06-03;
   use purple `#a14ef1` for the IHT-equivalent layer.

## Verification checklist (per `mermaid-dashboard-pattern` acceptance)

- [ ] Console shows `[diagrams] rendered <mount-id>` for every diagram
- [ ] No errors in the console
- [ ] Every node has a hover popup with ≥ 2 sentences
- [ ] Every popup body contains `Source:` followed by a path that becomes
      a clickable link
- [ ] Clicking a node opens the source file
- [ ] Tab-switch re-renders work (open Architecture tab → diagram appears
      within 0.5 s)
- [ ] Subgraph backgrounds are dark (not browser default white)
- [ ] Arrow stroke ≥ 2px and visible against the page background
- [ ] Yellow is NOT used as a node fill
