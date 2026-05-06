---
paths:
  - "*.qmd"
  - "vignettes/**"
  - ".github/workflows/**"
---
# Quarto Vignette Deployment Validation

Post-publish and pre-deployment checks. See `quarto-vignette-evidence` for content quality rules.

## 12. POST-PUBLISH VALIDATION (MANDATORY)

After EVERY pkgdown deployment, produce a **Validation Table** with these columns:

| Column | Description |
|--------|-------------|
| Article | vignette slug |
| URL | full clickable URL |
| HTTP | status code (must be 200) |
| Size | page size in KB |
| Updated | Last-Modified header or git commit datetime |
| Age | human-readable (e.g. "2 min ago") |
| Errors | count of `#> Error` in HTML |
| NULLs | count of `#> NULL` in HTML |
| NotAvail | count of `not available` or `not found in targets` in HTML |
| Status | OK / WARN / FAIL |

**Agent workflow (manual — no automated enforcement yet):**
1. After any `pkgdown::build_site()` or CI workflow
2. Produce the validation table for every article
3. Report issues before claiming success
4. Print full URLs for user verification

**Lesson learned (2026-03-14):** This validation step is entirely agent-driven — there is no
hook, CI step, or target that enforces it. Agents routinely skip it because nothing blocks
completion without it. The `qa_vignette_compliance` target in `plan_qa_gates.R` partially
addresses this by checking source .qmd files, but does NOT check the deployed HTML output.
Full post-publish validation remains a manual agent responsibility.

Use `httr2::request(url) |> req_perform()` to fetch each article, count error patterns with `gregexpr()`, and report. See `R/dev/validate_pkgdown_deploy.R` for the reference implementation.

**Additional checks:** site structure pages, cross-article `#fragment` links, dark mode toggle.

## 18. [MISSING EVIDENCE] VALIDATION (MANDATORY)

Before any pkgdown deployment, grep for `[MISSING EVIDENCE]` patterns.

See `targets-vignettes` skill reference: `post-publish-checks.md` for bash and CI YAML snippets.

**Common causes:** Forgot `tar_make()`, forgot RDS export, target name typo, target returns NULL.

**Fix:** Run `tar_make(names = starts_with("vig_"))`, export RDS to `inst/extdata/vignettes/`, rebuild site, verify grep returns nothing.

**MANDATORY post-build gate:**
```bash
# MUST return 0 hits for ALL error patterns — fails the build otherwise
for pattern in "MISSING EVIDENCE" "not available" "not found in targets" "Error in" "#> NULL" "Syntax error" "mermaid version"; do
  count=$(grep -c "$pattern" docs/articles/*.html 2>/dev/null | awk -F: '{s+=$2}END{print s+0}')
  if [ "$count" -gt 0 ]; then
    echo "FAIL: $count '$pattern' found in deployed HTML"
    exit 1
  fi
done
```

### Mermaid Diagram Validation (MANDATORY when diagrams present)

`curl` + `grep` cannot catch client-side JS rendering errors. Mermaid errors appear only when the browser runs the JS. Use:

1. **mmdc CLI** (`npx @mermaid-js/mermaid-cli`): validates diagram syntax offline
2. **Chrome headless** (`--dump-dom`): renders page and checks DOM for "Syntax error"

```bash
# Pre-deploy: validate each diagram with mmdc
scripts/qa_mermaid_syntax.sh

# Post-deploy: check deployed URL
scripts/qa_deployed_url.sh
```

See `diagram-generation` rule for the full Quarto 1.8 dashboard workaround pattern.

**Error patterns explained:**

| Pattern | Source | Meaning |
|---------|--------|---------|
| `MISSING EVIDENCE` | Placeholder text | Target never built |
| `not available` | `show_target()` fallback | Target missing from store AND RDS |
| `not found in targets` | `safe_tar_read()` message | Same as above (message output) |
| `Error in` | R error leaked to output | Unhandled exception |
| `#> NULL` | Target returned NULL | Target exists but has no content |

## 19. DARK MODE TOGGLE (MANDATORY)

All pkgdown sites MUST have a dark/light mode toggle defaulting to dark.

See `targets-vignettes` skill reference: `post-publish-checks.md` for `_pkgdown.yml` and `pkgdown/extra.js` snippets.

**Rules:** Dark mode default for first-time visitors. All visualizations readable in both modes. Mermaid uses dark theme (see `diagram-generation.md`).

## 20. BUILD-INFO FOOTER (MANDATORY)

Every vignette and dashboard MUST include a build-info footer with linked metadata.
This provides traceability from rendered HTML back to exact source code, R version,
and build timestamp.

### Required Output Format

```
pkgname 0.1.0 | Git abc1234 | R 4.5.2 | Built 2026-04-13 14:30:00
```

Where each value is a **clickable hyperlink**:

| Element | Links to | URL pattern |
|---------|----------|-------------|
| Version (`0.1.0`) | GitHub release/tag for that version | `https://github.com/{owner}/{repo}/releases/tag/v{version}` |
| Git SHA (`abc1234`) | GitHub commit page | `https://github.com/{owner}/{repo}/commit/{full_sha}` |
| R version (`4.5.2`) | CRAN R release news | `https://cran.r-project.org/doc/manuals/r-release/NEWS.html` |
| Build timestamp | Not linked (informational) | — |

### Required R Code (as a target or inline chunk)

Store as a `vig_build_info` target in `plan_vignette.R`, or use as an inline chunk.
See `targets-vignettes` skill reference: `post-publish-checks.md` for the full R code.

For non-package projects, use the project directory name and omit the version link.

### Fallbacks

| Environment | Behaviour |
|-------------|-----------|
| Local dev (git available) | Full SHA, version from `packageVersion()` |
| CI (GitHub Actions) | SHA from `$GITHUB_SHA`, version from DESCRIPTION |
| WebR/Shinylive (no git) | Hardcoded fallback version, SHA = "N/A" |
| pkgdown articles | Use `Sys.getenv("GITHUB_SHA")` if git unavailable |

### Pre-Computed as Target (Preferred)

Store as `vig_build_info` target; in the vignette use `safe_tar_read("vig_build_info")` with `results: asis`.
See `targets-vignettes` skill reference: `post-publish-checks.md` for the target code.

## Pre-computed outputs for CI

When vignettes use `tar_read()`, CI needs fallback to pre-computed RDS. See `vignette-targets-export` rule for the `safe_tar_read()` pattern and RDS export workflow.

## Checklist

- [ ] Validation table produced after every deployment
- [ ] `grep "[MISSING EVIDENCE]" docs/articles/*.html` returns 0
- [ ] Dark mode toggle present, defaults to dark
- [ ] All content readable in both light and dark modes
- [ ] Ran `tar_make()` before building vignettes
- [ ] Build-info footer present with linked version, SHA, and R version
