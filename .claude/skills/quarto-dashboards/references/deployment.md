# Deployment Reference

## Static and Shinylive (No Server Required)

Both static dashboards and Shinylive-powered dashboards deploy without a server:

```bash
# Render to static HTML
quarto render dashboard.qmd

# Publish to various platforms
quarto publish quarto-pub dashboard.qmd
quarto publish gh-pages dashboard.qmd
quarto publish netlify dashboard.qmd
```

For Shinylive: ensure `shinylive-sw.js` is included in the `resources` YAML field.

## Traditional Shiny (Server Required)

### Python Shiny

```bash
# Render dashboard
quarto render dashboard.qmd

# Deploy to shinyapps.io
rsconnect deploy shiny . --name myaccount --title my-dashboard

# Run locally
shiny run app.py
```

### R Shiny

```bash
# Deploy to shinyapps.io
quarto publish shinyapps dashboard.qmd

# Serve locally
quarto serve dashboard.qmd
```

## GitHub Pages with Actions

```yaml
# .github/workflows/publish.yml
name: Publish Dashboard

on:
  push:
    branches: [main]

jobs:
  build-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Set up Quarto
        uses: quarto-dev/quarto-actions/setup@v2

      - name: Render Dashboard
        run: quarto render dashboard.qmd

      - name: Deploy to GitHub Pages
        uses: peaceiris/actions-gh-pages@v3
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./_site
```

## Deployment Model Comparison

| Model | Server Required | Interactivity | Best For |
|-------|----------------|---------------|----------|
| Static | No | Basic (Observable JS) | Simple displays, reports |
| Shinylive | No | Full Shiny (browser WASM) | Educational, demos, simple apps |
| Server Shiny | Yes | Full Shiny + server resources | Complex apps, DB access, large data |
