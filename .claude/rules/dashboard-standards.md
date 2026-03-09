---
paths:
  - "vignettes/**/*.qmd"
  - "R/**/*.R"
---

# Dashboard Standards (Mandatory)

1. Every plot/table card MUST have a `card_footer()` caption
2. Every plotly plot MUST include `config(scrollZoom = TRUE)`
3. Value boxes: `$X,XXX` format (no decimals > $100), `X.XB`/`X.XM` for tokens
4. Every dashboard MUST have a footer with repo link and build date
5. Minimum plot heights: 400px half-width, 500px full-width
6. Table columns with long text must use `white-space: nowrap`
7. Legends above plots (`y = 1.02, yanchor = "bottom"`), never use rangeslider with legend
