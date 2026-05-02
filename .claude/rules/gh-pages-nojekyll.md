# Rule: `.nojekyll` for GitHub Pages projects with Quarto/static output

## When This Applies

Any project deployed to GitHub Pages that serves a directory containing the output of a static site generator (Quarto, pkgdown, Hugo, Sphinx, mkdocs, etc.). Especially relevant for project repos serving from `main` `/docs`.

## CRITICAL: Add `.nojekyll` to the deployed directory

GitHub Pages runs **Jekyll** by default on every commit. Jekyll's Liquid template parser will choke on:

- `_underscored` directories that Quarto and pkgdown create (`_extensions/`, `_freeze/`, `_quarto/`)
- HTML containing `{{` and `}}` (templates, JSON-LD, mustache-style code in tutorials)
- Files with names Jekyll's defaults misinterpret

When Jekyll fails, the entire Pages build errors and the site stops updating. The error message is a generic "Page build failed" — diagnostic noise, not signal.

**Fix:** an empty file named `.nojekyll` in the deployed root. Tells Pages to skip Jekyll and serve files as-is.

```bash
touch /path/to/repo/docs/.nojekyll  # if serving from main /docs
git -C /path/to/repo add docs/.nojekyll
git -C /path/to/repo commit -m "fix: add .nojekyll to skip Jekyll on Pages"
git -C /path/to/repo push
```

## When to add it

| Trigger | Action |
|---|---|
| New project deploys docs/ via gh-pages | Add `.nojekyll` in the **same commit** that enables Pages |
| Migrating from Hugo / Jekyll to Quarto | Add `.nojekyll` before the first Quarto deploy |
| Existing Pages build starts erroring after adding a Quarto extension | Likely missing `.nojekyll` — add it |
| `gh api /repos/X/Y/pages/builds/latest` returns `"status":"errored"` with a generic message | Check `.nojekyll` first |

## Detection

```bash
ls /path/to/repo/docs/.nojekyll && echo "OK" || echo "MISSING"
```

Or via API once Pages is configured:

```bash
gh api /repos/OWNER/REPO/pages/builds/latest | grep -oE '"status":"[^"]+"'
# "errored" + generic "Page build failed" → suspect .nojekyll
```

## Quarto post-render hook integration

If you use a Quarto post-render hook (e.g. to copy data files to `docs/`), make sure it doesn't accidentally delete `.nojekyll`:

```bash
#!/usr/bin/env bash
# scripts/post-render.sh
set -euo pipefail
# ... your copies ...
# Defensive: ensure .nojekyll persists across full-site renders
touch "${QUARTO_PROJECT_DIR}/docs/.nojekyll"
```

`quarto render` (full-site mode) cleans the output directory before rendering. It preserves `.nojekyll` by default (it's not generated content) but a post-render hook can defensively re-create it.

## Origin

Lesson learned 2026-05-02 in `acd_area_climate_design`: after adding the `closeread` Quarto extension (`_extensions/qmd-lab/closeread/`), Pages started erroring on every push. Two consecutive deploys failed silently before we noticed (validator caught it on the third commit by reporting `status:errored`). Single-character fix once diagnosed: `touch docs/.nojekyll`.

## Related

- `pkgdown-deployment` skill — pkgdown-specific deployment patterns
- `quarto-vignette-validation` rule — post-publish HTML checks (catches the Jekyll failure as `errored` status before users do)
- `website-index-update` rule — for `username.github.io` user-site repos (which have a different rule: serve from default branch, NOT gh-pages branch)
