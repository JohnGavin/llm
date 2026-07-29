# Companion: Quarto Vignette Standards — Worked Code Examples

Worked code examples and consolidation history split out of the always-loaded
[`quarto-vignettes`](../quarto-vignettes.md) rule to keep it lean. The
normative content (the 5 Parts, MANDATORY/FORBIDDEN/CRITICAL statements,
governing tables, Fence Parity pattern table, Pre-Commit Checklist) stays in
the rule; this file is the worked code snippets, loaded on demand.

## Rule Consolidation History

Consolidated from: `quarto-vignette-format`, `quarto-vignette-layout`, `quarto-vignette-data`, `quarto-vignette-evidence`, `quarto-vignette-validation`, `vignette-targets-export`.

## Full-Width — worked CSS snippet

```css
/* pkgdown/extra.css */
body > .container { max-width: 100% !important; width: 100% !important; }
.col-md-9 { flex: 0 0 85% !important; }
```

## Code Folding — worked YAML snippet

```yaml
format:
  html:
    code-fold: true       # MANDATORY
    code-summary: "Show code"
```

## Sub-Bullet Formatting — worked REQUIRED/FORBIDDEN example

```markdown
# REQUIRED:
- **DALY:** Disease burden combining:
    - **YLL:** Premature mortality
    - **YLD:** Morbidity component

# FORBIDDEN:
- **DALY:** Disease burden = YLL + YLD.
```

## CI Pattern: Pre-Computed RDS — worked export loop

```r
vignette_targets <- grep("^vig_", tar_manifest()$name, value = TRUE)
for (name in vignette_targets) {
  saveRDS(tar_read_raw(name), file.path("inst/extdata/vignettes", paste0(name, ".rds")))
}
```

## Error Pattern Check — worked bash loop

```bash
for pattern in "MISSING EVIDENCE" "target not available" "#> NULL"; do
  grep -FHc "$pattern" docs/articles/*.html | grep -v ':0$' && exit 1
done
```

## Build-Info Footer — worked example

```
pkgname 0.1.0 | Git abc1234 | R 4.5.2 | Built 2026-04-13
```

## Fence Parity — manual check + selftest invocation

```bash
# Manual check
~/.claude/scripts/check_qmd_fence_parity.sh vignettes/
~/.claude/scripts/check_qmd_fence_parity.sh --selftest  # 4/4 expected
```

See JohnGavin/llm#465.
