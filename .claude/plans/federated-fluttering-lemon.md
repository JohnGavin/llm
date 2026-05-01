# Plan: Migrate johngavin.github.io from Hugo to Quarto

## Context

The personal site at `johngavin.github.io` uses a 3-year-old Hugo theme
(`hugo-universal-theme`, 24MB, 1,335 files) that's 90% uncustomised template
defaults: placeholder testimonials, fake client logos, lorem ipsum FAQ about
postal rates, demo blog posts about Go templates. The only real content is
`index.md` (6 project listings with beginner links) and `content/projects.md`
(a shorter 3-project list). The site is deployed via Netlify but the baseurl
references `john-gavin.netlify.app` while the actual domain is
`johngavin.github.io` — a configuration mismatch.

Quarto is the right replacement because:
- Already used for every R package vignette and dashboard
- Zero npm dependencies (eliminates future CVEs from vendored themes)
- Native R code execution if blog posts ever need it
- `quarto publish gh-pages` is a one-command deploy
- The site is tiny — 3 real pages plus an index

## What to keep

| Content | Source | Action |
|---|---|---|
| Project index with 6 entries + beginner links | `index.md` | Port verbatim — works as-is in Quarto |
| Projects page (3 entries with vignette links) | `content/projects.md` | Merge into index.md (deduplicate) or keep as separate page |
| WebR files | `webr-worker.js`, `webr-serviceworker.js` | Keep in root for WebR/Shinylive support |

## What to delete

| Content | Why |
|---|---|
| `themes/hugo-universal-theme/` (24MB, 1,335 files) | Unused after migration; source of CVEs |
| `config.toml` | Hugo config; replaced by `_quarto.yml` |
| `_config.yml` | Jekyll fallback; no longer needed |
| `content/faq.md` | 100% lorem ipsum placeholder |
| `content/contact.md` | 100% placeholder ("customer service 24/7") |
| `content/blog/*.md` (5 posts) | Hugo/Go tutorial demos, not real content |
| `static/img/` (28 images) | Theme template images (carousel, testimonials, clients) — not yours |
| `data/` (carousel, clients, testimonials, features YAML) | Template data files |
| `public/` | Hugo build output; Quarto uses `_site/` or `docs/` |
| `resources/` | Hugo cache |
| `.hugo_build.lock` | Hugo lock file |

## New files to create

### `_quarto.yml`

```yaml
project:
  type: website
  output-dir: docs

website:
  title: "John Gavin"
  description: "R developer and data scientist"
  navbar:
    left:
      - text: "Home"
        href: index.qmd
      - text: "Projects"
        href: projects.qmd
    right:
      - icon: github
        href: https://github.com/JohnGavin
  page-footer:
    center: "Built with [Quarto](https://quarto.org)"

format:
  html:
    theme: cosmo
    toc: false
```

### `index.qmd`

Port from current `index.md` — change frontmatter from Jekyll `layout: default`
to Quarto `title:` format.

```yaml
---
title: "John Gavin"
subtitle: "R developer and data scientist"
---
```

**Content changes during migration:**
- Rename `## Projects` to `## Sample projects`
- Reorder: micromort, irishbuoys, randomwalk, **then** historical, footbet,
  millsratio (move historical + footbet after randomwalk)

### `projects.qmd`

Merge `content/projects.md` content into a Quarto page. The TOML frontmatter
(`+++...+++`) becomes YAML (`---...---`). Body markdown is standard and ports
directly.

### `.gitignore` update

Add:
```
_site/
docs/
.quarto/
/_freeze/
```

Remove Hugo-specific ignores (`public/`, `resources/`, etc.).

### `.nojekyll`

Empty file in root — tells GitHub Pages not to process with Jekyll.

## Deployment

**Option A (recommended): `quarto publish gh-pages`**
- Quarto builds the site and pushes to the `gh-pages` branch
- GitHub Pages serves from `gh-pages`
- No GitHub Actions needed
- One command: `quarto publish gh-pages`

**Option B: Build to `docs/` and serve from `main`**
- Set `output-dir: docs` in `_quarto.yml`
- GitHub Pages serves from `main/docs`
- Simpler (no separate branch) but `docs/` is committed to repo

I recommend Option A (`gh-pages` branch) because it keeps the main branch
clean of build artifacts.

## Migration steps

1. **Create a working branch**: `git checkout -b quarto-migration`
2. **Create `_quarto.yml`** with the config above
3. **Create `index.qmd`** from current `index.md` (change frontmatter only)
4. **Create `projects.qmd`** from `content/projects.md` (TOML → YAML frontmatter)
5. **Create `.nojekyll`** empty file
6. **Update `.gitignore`** for Quarto patterns
7. **Test locally**: `quarto preview` — verify all 6 project cards render correctly
8. **Delete Hugo artifacts**: `themes/`, `config.toml`, `_config.yml`,
   `content/`, `data/`, `static/`, `public/`, `resources/`, `.hugo_build.lock`
9. **Keep**: `webr-worker.js`, `webr-serviceworker.js`, `.Rproj`, `.git/`
10. **Commit**: single commit with the full migration
11. **Publish**: `quarto publish gh-pages`
12. **Verify**: https://johngavin.github.io/ shows the new Quarto site
13. **Update baseurl**: if needed, ensure GitHub Pages settings point to
    `johngavin.github.io` not Netlify

## What about existing links?

The project links on the index page (e.g. `https://johngavin.github.io/micromort/`)
point to separate repos' GitHub Pages sites — they are NOT affected by this
migration. Only the index page itself changes rendering engine.

The `content/projects.md` URL (`/projects/`) will become `/projects.html` in
Quarto. If anyone has bookmarked `/projects/` it will 404. Given the site's
traffic level this is acceptable — add a note to the commit message.

## Verification

1. `quarto preview` — site renders locally with all 6 projects visible
2. All external links (GitHub, r-universe, pkgdown sites) are clickable
3. No broken images (we're deleting all theme images — the index has none)
4. `quarto publish gh-pages` deploys successfully
5. https://johngavin.github.io/ loads the new site within 2 minutes
6. No Dependabot alerts (no npm, no vendored theme)

## Critical files

| File | Action |
|---|---|
| `_quarto.yml` | Create |
| `index.qmd` | Create (from `index.md`) |
| `projects.qmd` | Create (from `content/projects.md`) |
| `.nojekyll` | Create (empty) |
| `.gitignore` | Edit |
| `themes/` (24MB) | Delete |
| `config.toml` | Delete |
| `_config.yml` | Delete |
| `content/` | Delete |
| `data/` | Delete |
| `static/` | Delete |
| `public/` | Delete |
| `resources/` | Delete |
| `.hugo_build.lock` | Delete |
