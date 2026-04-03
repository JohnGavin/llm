---
name: quarto-websites
description: >
  Build Quarto websites for R packages and projects. Use when creating
  package documentation sites, converting from pkgdown, setting up
  multi-page Quarto websites, or configuring navigation, search, and
  deployment for Quarto web projects.
---

# Quarto Websites

## Purpose

Guide for building Quarto websites (`type: website`), including R package
documentation, blogs, and multi-page sites. Covers structure, navigation,
deployment, and pkgdown migration.

## When to Use

- Creating a Quarto website (`quarto create project website`)
- Converting pkgdown sites to Quarto
- Adding blog, documentation, or landing pages
- Configuring navbar, sidebar, or search
- Deploying to GitHub Pages or Netlify

## Quick Start

```yaml
# _quarto.yml
project:
  type: website
  output-dir: _site

website:
  title: "My Package"
  navbar:
    left:
      - text: "Home"
        href: index.qmd
      - text: "Reference"
        href: reference.qmd
```

```bash
quarto create project website mysite
quarto preview  # Local dev server
quarto render   # Build to _site/
```

## Site Structure

| Component | File/Dir | Purpose |
|-----------|----------|---------|
| Config | `_quarto.yml` | Project type, navigation, theme |
| Home | `index.qmd` | Landing page |
| Pages | `*.qmd` | Content pages |
| Blog | `posts/` | Blog post directory |
| Output | `_site/` | Rendered output (gitignored) |

See [site-structure.md](references/site-structure.md) for R package website layout,
pkgdown conversion, and blog integration.

## Navigation

| Pattern | Best For | Config |
|---------|----------|--------|
| Navbar only | Simple sites (< 10 pages) | `website: navbar:` |
| Sidebar only | Deep hierarchies | `website: sidebar:` |
| Navbar + sidebar | Large sites | Both in `_quarto.yml` |

See [navigation.md](references/navigation.md) for full YAML examples, search config,
and advanced features (TOC, code annotations, tabsets, callouts).

## pkgdown vs Quarto

| Feature | pkgdown | Quarto |
|---------|---------|--------|
| Auto function docs | Yes | Manual |
| Vignette rendering | Auto | Auto |
| Blog support | No | Yes |
| Custom pages | Limited | Full |
| Theme system | Bootstrap 5 | Bootstrap 5 + SCSS |
| Deployment | GitHub Pages | GitHub Pages, Netlify, etc. |

**Decision:** Use pkgdown for standard R package docs. Use Quarto when you need
blogs, custom layouts, or non-R content. Both can coexist.

## Deployment

| Method | Command/Config | Best For |
|--------|---------------|----------|
| GitHub Pages (Actions) | `.github/workflows/` | Automated CI builds |
| GitHub Pages (local) | `quarto publish gh-pages` | Manual publishing |
| Netlify | `quarto publish netlify` | Preview deploys |

**Key gotcha:** Use `actions/upload-pages-artifact` + `actions/deploy-pages`
(artifacts approach), not direct branch pushing.

See [deployment.md](references/deployment.md) for GitHub Actions YAML, freeze config,
theming, and R integration.

## Best Practices

1. Use `freeze: auto` to avoid re-rendering unchanged pages
2. Set `execute: freeze: auto` per-document for expensive computations
3. Pre-compute data in targets pipeline (zero computation in render)
4. Use `_brand.yml` or `theme:` for consistent styling
5. Add `search: true` for full-text site search
6. Include `404.qmd` for custom error pages
7. Use `quarto preview` for live-reload development
8. Test navigation on mobile viewports

See [troubleshooting.md](references/troubleshooting.md) for common issues.

## Related Skills

- `quarto-dashboards` — Dashboard format
- `quarto-dynamic-content` — Dynamic content generation
- `pkgdown-deployment` — pkgdown site deployment
- `brand-yml` — Brand styling

## Resources

- [Quarto Websites](https://quarto.org/docs/websites/)
- [Quarto Publishing](https://quarto.org/docs/publishing/)
