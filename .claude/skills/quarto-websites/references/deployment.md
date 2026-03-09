# Deployment, Theming & Tooling

## Publishing and Deployment

### GitHub Pages with GitHub Actions

```yaml
# .github/workflows/publish.yml
name: Publish Quarto Site

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: Check out repository
        uses: actions/checkout@v4

      - name: Set up Quarto
        uses: quarto-dev/quarto-actions/setup@v2

      - name: Setup R
        uses: r-lib/actions/setup-r@v2

      - name: Setup R Dependencies
        uses: r-lib/actions/setup-renv@v2

      - name: Render and Publish
        uses: quarto-dev/quarto-actions/publish@v2
        with:
          target: gh-pages
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Deployment Strategy: Artifacts vs. Branches

**Crucial Note:** Modern Quarto GitHub Actions (`quarto-dev/quarto-actions/publish@v2`) typically use the GitHub Pages API to deploy from an **artifact**, rather than pushing files to the `gh-pages` branch.

-   **Do not check `git log origin/gh-pages`** to verify deployment. The branch may be stale or empty.
-   **Check `gh run list`** to see the workflow status.
-   **Check the live site** footer or "Last Updated" timestamp to verify changes.

### Local Publishing

```bash
# First time setup (creates _publish.yml)
quarto publish gh-pages

# Subsequent publishes
quarto publish gh-pages --no-prompt

# Or render to docs/ and let GitHub Pages serve it
quarto render
git add docs/
git commit -m "Update site"
git push
```

### Freeze Computations for CI

```yaml
# _quarto.yml
execute:
  freeze: auto  # or true
```

This caches computation results in `_freeze/` directory, avoiding re-execution in CI.

## Theming and Customization

### Built-in Themes

```yaml
format:
  html:
    theme: cosmo  # Bootstrap 5 themes
    # Options: default, cerulean, cosmo, darkly, flatly, journal,
    # litera, lumen, lux, materia, minty, morph, pulse, quartz,
    # sandstone, simplex, sketchy, slate, solar, spacelab,
    # superhero, united, vapor, yeti, zephyr
```

### Custom Theme

Create `custom.scss`:

```scss
/*-- scss:defaults --*/
$primary: #0d6efd;
$secondary: #6c757d;
$font-family-sans-serif: "Inter", system-ui, -apple-system, sans-serif;

/*-- scss:rules --*/
.navbar-brand {
  font-weight: 700;
}

.sidebar nav[role="doc-toc"] {
  font-size: 0.875rem;
}
```

Apply:

```yaml
format:
  html:
    theme: [cosmo, custom.scss]
```

### Dark Mode Support

```yaml
format:
  html:
    theme:
      light: flatly
      dark: darkly
```

## Website Tools

### Development Server

```bash
# Live preview with hot reload
quarto preview

# Preview a specific format
quarto preview --to html

# Preview on a different port
quarto preview --port 4000
```

### Rendering

```bash
# Render entire site
quarto render

# Render specific file
quarto render index.qmd

# Render specific directory
quarto render articles/
```

### Site Management

```yaml
# _quarto.yml
project:
  type: website
  output-dir: _site
  render:
    - "!private/"     # Exclude private directory
    - "!draft-*.qmd"  # Exclude draft files
  resources:
    - "data/*.csv"    # Include data files
    - "images/**"     # Include all images
```

## Integration with R Packages

### Using Quarto from R

```r
library(quarto)

# Render site
quarto_render()

# Render specific file
quarto_render("index.qmd")

# Preview site
quarto_preview()

# Publish to GitHub Pages
quarto_publish_site(
  server = "gh-pages",
  render = TRUE
)
```

### Metadata from DESCRIPTION

```r
# Generate metadata from DESCRIPTION
desc <- desc::desc()

metadata <- list(
  title = desc$get("Package")[[1]],
  subtitle = desc$get("Title")[[1]],
  author = desc$get_authors(),
  version = desc$get_version()
)

# Use in Quarto docs
yaml::write_yaml(metadata, "_metadata.yml")
```
