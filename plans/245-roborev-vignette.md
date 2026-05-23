# Plan: #245 roborev architecture vignette

**Status:** MVP delivered (sections 1+2+9+10). Sections 3-8 skeleton.
**PR:** `feat/245-roborev-vignette-mvp`

## Section ownership matrix

| Section | Title | Status | Owner | Blocker |
|---------|-------|--------|-------|---------|
| 1 | Why roborev exists | **DONE** | — | — |
| 2 | Architecture flowchart | **DONE** | — | — |
| 3 | Configuration layers | skeleton stub | follow-up PR | #229 governance |
| 4 | Workflow scenarios | skeleton stub | follow-up PR | sequence diagram authoring |
| 5 | Severity model | skeleton stub | follow-up PR | #160 severity formalisation |
| 6 | Metrics + ROI | skeleton stub | follow-up PR | #226 ETL must land first |
| 7 | Closure-loop philosophy | skeleton stub | follow-up PR | #163 + #241 |
| 8 | Cross-project handoff | skeleton stub | follow-up PR | #149 |
| 9 | Where things live | **DONE** | — | — |
| 10 | Open issues + roadmap | **DONE** | — | — |

## Sections needing `unified.duckdb` data (#226 tables)

| Section | Data needed | Table / query | Blocking? |
|---------|-------------|---------------|-----------|
| 6 — Metrics + ROI | addressed rate, time-to-close, cost per finding | `roborev_findings`, `roborev_agent_runs` | Yes — #226 must land |
| 6 | findings per commit by repo | `roborev_findings JOIN commits` | Yes |
| 5 | severity distribution | `roborev_findings.severity` | Partial — can use static snapshot |
| 10 | live issue count per repo | `roborev_findings WHERE closed=0` | No — using static GH issue links |

## Bidirectional link table

Links in **this vignette** to dashboard panels:

| Vignette section | Anchor in vignette | Dashboard panel URL |
|-----------------|-------------------|---------------------|
| 2 (architecture) | `#architecture` | `roborev-pulse.html#open-findings` |
| 6 (metrics) | `#metrics` | `roborev-pulse.html#addressed-rate` |
| 6 (metrics) | `#metrics` | `roborev-pulse.html#time-to-close` |
| 6 (metrics) | `#metrics` | `roborev-pulse.html#per-repo-volume` |
| 6 (metrics) | `#metrics` | `roborev-pulse.html#cost-roi` |
| 6 (metrics) | `#metrics` | `roborev-pulse.html#severity-distribution` |
| 5 (severity) | `#severity` | `roborev-pulse.html#severity-distribution` |
| 7 (closure) | `#closure` | `roborev-pulse.html#addressed-rate` |
| 8 (handoff) | `#handoff` | `roborev-pulse.html#handoff-log` |
| 10 (roadmap) | `#roadmap` | `roborev-pulse.html#open-findings` |

Links in **llmtelemetry dashboard** back to this vignette (to be added in llmtelemetry#144):

| Dashboard panel | Target in this vignette |
|-----------------|------------------------|
| Page nav "About" | `roborev-architecture.html` |
| Open findings panel header `?` | `roborev-architecture.html#closure` |
| Severity distribution panel header `?` | `roborev-architecture.html#severity` |
| Addressed-rate panel header `?` | `roborev-architecture.html#closure` |
| Per-repo volume panel header `?` | `roborev-architecture.html#architecture` |
| Handoff log panel header `?` | `roborev-architecture.html#handoff` |

## Follow-up PR sweep order

The follow-up PRs should be merged in dependency order:

1. **#226 ETL** — unblocks section 6 data
2. **#229 governance** — unblocks section 3 config reference
3. **Section 3 + 5 PR** — config layers + severity model (can partially fill with static content before #229)
4. **llmtelemetry#144** — dashboard page with reverse links; coordinate merge with section 6 PR
5. **Section 6 PR** — metrics + ROI (needs #226 + llmtelemetry#144)
6. **#149 handoff** — unblocks section 8
7. **Section 4 + 7 + 8 PR** — workflow scenarios, closure loop, cross-project handoff
8. **#246 hover-popup** — add hover popups to Mermaid nodes after that PR merges

## Hover popup / tooltip dependency (#246)

The Mermaid `click` handlers in section 2 currently point to GitHub URLs.
Once #246 (hover-popup standard) merges, each node should also get a CSS
hover tooltip using the `<abbr>`-extended pattern from that PR. Do NOT add
tooltips before #246 merges — the CSS/JS infrastructure does not exist yet.

## Render command

```bash
# From inside the llm nix shell:
timeout 120 quarto render vignettes/articles/roborev-architecture.qmd --to html
```

Mermaid clickable-node verification after render:
```bash
grep -E "click [A-Z]+" /tmp/roborev_arch_render.html | head
```
Expected: ≥ 9 `click` directives matching node names in the flowchart.
