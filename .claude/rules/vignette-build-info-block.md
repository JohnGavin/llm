---
name: vignette-build-info-block
description: Mandatory build-info block at the end of every vignette, dashboard, and pkgdown article.
type: rule
---

# Rule: Vignette Build-Info Block (Mandatory)

## When This Applies

Every `.qmd` under `vignettes/`, `vignettes/articles/`, `dashboard/`, or any
rendered Quarto page in any project. Applies to pkgdown articles, Quarto
dashboards, and standalone vignettes in equal measure.

## CRITICAL: Every Published Vignette MUST End with a Build-Info Block

Readers who return to a vignette months after first reading it need to know
whether the data, code, and analysis they see are current. The build-info block
answers three questions the methodology block does not:

1. When was this page first published?
2. When was it last run?
3. What version of R, packages, and the Nix environment produced it?

## Required Fields

| Field | Source | Example |
|---|---|---|
| **Posted on** | YAML `date:` | `2026-06-03` |
| **Last rebuilt** | `format(Sys.time(), "%Y-%m-%dT%H:%M:%S UTC")` at render | `2026-06-03T14:30:00 UTC` |
| **Length** | Computed: `N words · ceil(N/230) min read` | `2054 words · 10 min read` |
| **Categories** | YAML `categories:` | `nlmixr2, time-to-event` |
| **Tags** | YAML `tags:` | `tte, survival, tutorial` |
| **See also** | YAML `see-also:` (list of `[title](path)` links) | linked list |
| **Source** | Git short SHA + permalink to `.qmd` on main | `[3d5ef8f](https://github.com/…)` |
| **Render env** | R version + key package versions + Nix pin date | `R 4.5.1 · nix-pin 2026-05-30` |

Fields 1–6 are author-supplied (YAML front-matter). Fields 7–8 are computed at
render time and MUST be inline R expressions — never hardcoded strings.

## Placement

The block goes at the END of every vignette body in this exact order:

```markdown
## Methodology
<...methodology subsections...>

{{< include /_includes/build-info.qmd >}}

{{< include /_includes/qr-footer.qmd >}}
```

The build-info block is AFTER `## Methodology` (per `narrative-evidence-block`
rule) and BEFORE any QR/footer include. Placing it after the footer include
excludes it from the rendered page — that is a defect.

## Two Valid Placements

| Option | When to use |
|---|---|
| **Footer** (default) | Single-page vignettes — include at end of body |
| **Build info tab** | Dashboards with `panel-tabset` — add one tab named "Build info" containing the include |

Projects choose one placement and stay consistent throughout. Both go AFTER
`## Methodology` and BEFORE any QR/footer include.

## How to Add the Block

1. Add `{{< include /_includes/build-info.qmd >}}` at the correct position.
2. Add `date:` to the YAML front-matter if absent.
3. Optionally add `categories:`, `tags:`, `see-also:` to YAML.
4. The partial sources `.claude/scripts/vignette_build_info.R` automatically;
   no additional sourcing needed in the vignette.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Block missing from the vignette | Fails QA gate (`check_build_info_blocks()`) | Add the include |
| `{{< include >}}` placed AFTER QR-footer include | Block excluded from rendered output | Move before QR include |
| `Last rebuilt: 2026-06-03` (hardcoded literal) | Violates `dynamic-prose-values` — stale immediately | Must be inline R from `build_info_render_env()` |
| Source SHA hardcoded as `3d5ef8f` | Stale on next commit | Must be `build_info_source_link()` at render time |
| Block placed before `## Methodology` | Wrong document order | Methodology first, then build-info |

## Related

- `narrative-evidence-block` — methodology block; build-info is the sibling beneath it
- `dynamic-prose-values` — every computed field obeys this; never hardcode dates/SHAs
- `hover-popup-standard` — model for how shared `_includes/*.qmd` partials work
- `mermaid-click-anchors` — `#L<n>` permalink discipline for the Source field
- `uniform-typography` — block renders at body font size, not smaller
- `accessibility` — all text meets contrast minima; not a place for small grey text
- `cross-cutting-rename` — audit-grep is the acceptance test, not diff count
- Issue #455 — origin specification
