# Quarto Dashboards Skill

Build interactive dashboards using Quarto with Python, R, or Observable JS. Supports three deployment models:
- **Static dashboards**: No server required, basic interactivity
- **Shinylive dashboards**: Full Shiny interactivity in browser via WebAssembly, no server required
- **Server-based Shiny**: Traditional Shiny with server backend for complex operations

## Quick Start

### Basic Dashboard Structure

```yaml
---
title: "My Dashboard"
author: "Your Name"
format:
  dashboard:
    logo: images/logo.png
    orientation: rows  # or columns
    nav-buttons: [github, linkedin]
---

## Row {height=70%}

### Chart A

```{python}
#| title: Dynamic Sales Chart
import plotly.express as px
fig = px.line(df, x='date', y='sales')
fig.show()
```

### Chart B

```{python}
import plotly.graph_objects as go
fig = go.Figure(data=[go.Scatter(x=x, y=y)])
fig.show()
```

## Row {height=30%}

### Value Box 1

```{python}
#| content: valuebox
#| title: "Total Revenue"
dict(
    value = f"${revenue:,.0f}",
    icon = "currency-dollar",
    color = "success"
)
```

### Table

```{python}
from itables import show
show(df, buttons=['copy', 'csv', 'excel'])
```
```

## Layout Components

### Navigation Structure

```yaml
format:
  dashboard:
    title: "Multi-Page Dashboard"
    pages:
      - id: overview
        title: "Overview"
      - id: details
        title: "Details"
    nav-buttons:
      - icon: github
        href: https://github.com/yourrepo
      - text: "Help"
        href: help.html
```

### Layout Patterns

#### Row-Based Layout (Default)
```markdown
## Row {height=60%}
Content fills 60% of vertical space

## Row {height=40%}
Content fills 40% of vertical space
```

#### Column-Based Layout
```markdown
---
format:
  dashboard:
    orientation: columns
---

## Column {width=65%}
Content fills 65% of horizontal space

## Column {width=35%}
Content fills 35% of horizontal space
```

#### Tabsets
```markdown
## Row {.tabset}

### Tab 1
Content for tab 1

### Tab 2
Content for tab 2
```

### Cards

#### Auto-Generated Cards
Every code cell automatically becomes a card. Control with cell options:

```python
#| title: My Chart Title
#| padding: 0px
#| expandable: false
#| fill: true
```

#### Manual Cards
```markdown
::: {.card title="Custom Card"}
This is a manually created card with markdown content.
:::
```

## Data Display Components

### Interactive Plots

#### Plotly (Python)
```python
import plotly.express as px
fig = px.scatter(df, x='x', y='y', color='category',
                 title="Interactive Scatter Plot")
fig.update_layout(height=400)
fig.show()
```

#### Altair (Python)
```python
import altair as alt
chart = alt.Chart(df).mark_point().encode(
    x='x:Q',
    y='y:Q',
    color='category:N',
    tooltip=['x', 'y', 'category']
).interactive()
chart
```

#### ggplot2 (R)
```r
library(ggplot2)
ggplot(data, aes(x = x, y = y, color = category)) +
  geom_point() +
  theme_minimal() +
  labs(title = "Scatter Plot")
```

### Tables

#### Interactive Tables (Python)
```python
from itables import show
show(df,
     buttons=['copy', 'csv', 'excel'],
     dom='Bfrtip',
     paging=True,
     pageLength=25)
```

#### DT Tables (R)
```r
library(DT)
datatable(data,
          filter = 'top',
          options = list(
            pageLength = 25,
            scrollX = TRUE
          ))
```

#### Static Tables
```python
# Python
print(df.to_markdown(index=False))

# R
knitr::kable(data, format = "html")
```

### Value Boxes

#### Static Value Box
```python
#| content: valuebox
#| title: "Active Users"
dict(
    value = f"{active_users:,}",
    icon = "people-fill",
    color = "primary"
)
```

#### Dynamic Value Box (Shiny)
```python
# Python Shiny
from shiny import ui
ui.value_box(
    title="Revenue",
    value=ui.output_text("revenue"),
    theme="success",
    showcase=icon_svg("currency-dollar")
)
```

```r
# R Shiny
bslib::value_box(
  title = "Revenue",
  value = textOutput("revenue"),
  theme = "success",
  showcase = bs_icon("currency-dollar")
)
```

### Text Content

#### Dynamic Text
```markdown
The total revenue is `{python} f"${revenue:,.0f}"` this quarter.
```

#### Content Cards
```markdown
::: {.card title="Analysis Summary"}
## Key Findings

1. Revenue increased by 25%
2. Customer retention improved
3. New markets show promise
:::
```

## Input Components

### Sidebars

#### Global Sidebar
```markdown
# {.sidebar}

## Filters

Select date range and categories for analysis.

```{python}
# Input controls here
```
```

#### Inline Sidebar
```markdown
## Row

### Column {.sidebar width="250px"}

Input controls here

### Column

Main content here
```

### Toolbars

#### Global Toolbar
```markdown
# {.toolbar}

Horizontal inputs across top

```{python}
# Controls here
```
```

#### Card Toolbar
```python
#| content: card-toolbar

# Dropdown or control widgets
```

### Shiny Inputs (Python)

```python
from shiny import ui

# In sidebar or toolbar cell:
ui.input_select("category", "Category:",
                choices=["All", "A", "B", "C"])
ui.input_date_range("dates", "Date Range:")
ui.input_slider("threshold", "Threshold:",
                min=0, max=100, value=50)
```

### Shiny Inputs (R)

```r
library(shiny)

# In sidebar or toolbar cell:
selectInput("category", "Category:",
            choices = c("All", "A", "B", "C"))
dateRangeInput("dates", "Date Range:")
sliderInput("threshold", "Threshold:",
            min = 0, max = 100, value = 50)
```

## Interactivity Patterns

### Observable JS (Client-Side)

```javascript
//| echo: false
viewof selectedYear = Inputs.range([2020, 2024],
  {value: 2023, step: 1, label: "Year"})

filteredData = data.filter(d => d.year == selectedYear)

Plot.plot({
  marks: [
    Plot.dot(filteredData, {x: "x", y: "y"})
  ]
})
```

### Shiny for Python (Server-Side)

```python
# Setup in first cell
from shiny import reactive, render
from shiny.express import input, output, ui

# Input cell
ui.input_select("metric", "Select Metric:",
                ["Revenue", "Users", "Growth"])

# Output cell
@render.plot
def trend_chart():
    metric = input.metric()
    return create_plot(df, metric)
```

### Shiny for R (Server-Side)

```r
#| context: setup
library(shiny)

#| context: server
output$trend_chart <- renderPlot({
  filtered_data <- data %>%
    filter(metric == input$metric)

  ggplot(filtered_data, aes(x = date, y = value)) +
    geom_line()
})
```

### Shinylive (Browser-Based, No Server Required)

Shinylive enables full Shiny functionality in the browser using WebAssembly, eliminating the need for a server. Perfect for educational content, simple dashboards, and situations where server deployment is impractical.

#### Setup for R-Shinylive

```bash
# Install R package
install.packages("shinylive")

# Add Quarto extension to your project
quarto add quarto-ext/shinylive
```

#### Basic Shinylive Dashboard

```markdown
---
title: "Interactive Dashboard with Shinylive"
format:
  dashboard:
    orientation: columns
filters:
  - shinylive
resources:
  - shinylive-sw.js
---

# Analysis {orientation="rows"}

## Row

### Interactive App

```{shinylive-r}
#| standalone: true
#| viewerHeight: 600

library(shiny)
library(bslib)
library(ggplot2)

ui <- page_sidebar(
  sidebar = sidebar(
    numericInput("n", "Sample size:", 100, min = 1, max = 1000),
    selectInput("dist", "Distribution:",
                c("Normal" = "norm",
                  "Uniform" = "unif",
                  "Exponential" = "exp")),
    sliderInput("bins", "Number of bins:", 30, min = 10, max = 50)
  ),
  card(
    card_header("Distribution Plot"),
    plotOutput("plot")
  ),
  card(
    card_header("Summary Statistics"),
    verbatimTextOutput("summary")
  )
)

server <- function(input, output, session) {
  data <- reactive({
    switch(input$dist,
           norm = rnorm(input$n),
           unif = runif(input$n),
           exp = rexp(input$n))
  })

  output$plot <- renderPlot({
    ggplot(data.frame(x = data()), aes(x = x)) +
      geom_histogram(bins = input$bins, fill = "steelblue", color = "white") +
      theme_minimal() +
      labs(title = paste("Histogram of", input$dist, "distribution"),
           x = "Value", y = "Frequency")
  })

  output$summary <- renderPrint({
    summary(data())
  })
}

shinyApp(ui = ui, server = server)
```
```

#### Python Shinylive Example

```markdown
```{shinylive-python}
#| standalone: true
#| components: [editor, viewer]

from shiny import App, render, ui
import numpy as np
import matplotlib.pyplot as plt

app_ui = ui.page_fluid(
    ui.input_slider("n", "Number of points:", 10, 100, 50),
    ui.output_plot("plot")
)

def server(input, output, session):
    @render.plot
    def plot():
        np.random.seed(42)
        x = np.random.randn(input.n())
        y = np.random.randn(input.n())
        plt.scatter(x, y)
        plt.xlabel("X axis")
        plt.ylabel("Y axis")
        plt.title(f"Scatter plot with {input.n()} points")

app = App(app_ui, server)
```

#### Key Shinylive Features

1. **Complete Shiny Apps in Browser**
   - Full reactive programming model
   - All standard Shiny inputs and outputs
   - No server infrastructure needed

2. **Limitations**
   - Not all R/Python packages available (must be compiled for WebAssembly)
   - Cannot access server-side resources (databases, APIs)
   - Initial load time can be slower (downloading WebAssembly runtime)
   - Limited to packages available at [webr.r-wasm.org](https://repo.r-wasm.org)

3. **Best Use Cases**
   - Educational tutorials and workshops
   - Simple statistical calculators
   - Data exploration tools with small datasets
   - Proof of concepts and demos
   - Documentation with live examples

4. **Important Configuration**
   - Must include `filters: - shinylive` in YAML
   - Add `resources: - shinylive-sw.js` for proper deployment
   - Use `#| standalone: true` for complete apps
   - Create proper `_quarto.yml` project file

## Theming

### Built-in Themes

```yaml
format:
  dashboard:
    theme: cosmo  # or any of 25 Bootswatch themes
```

Available themes: default, cerulean, cosmo, cyborg, darkly, flatly, journal, litera, lumen, lux, materia, minty, morph, pulse, quartz, sandstone, simplex, sketchy, slate, solar, spacelab, superhero, united, vapor, yeti, zephyr

### Custom Theming

Create `custom.scss`:
```scss
/*-- scss:defaults --*/
$body-bg: #fafafa;
$body-color: #333333;
$navbar-bg: #2c3e50;
$navbar-fg: #ffffff;
$link-color: #3498db;
$font-family-sans-serif: "Open Sans", sans-serif;

/*-- scss:rules --*/
.dashboard-header {
  border-bottom: 2px solid $link-color;
}

.card {
  box-shadow: 0 2px 4px rgba(0,0,0,0.1);
}
```

Apply theme:
```yaml
format:
  dashboard:
    theme:
      - cosmo
      - custom.scss
```

### Value Box Colors

Customize value box appearance:
```scss
$valuebox-bg-primary: #007bff;
$valuebox-bg-success: #28a745;
$valuebox-bg-info: #17a2b8;
$valuebox-bg-warning: #ffc107;
$valuebox-bg-danger: #dc3545;
```

## Deployment

### Three Deployment Models

1. **Static Dashboards** - Basic interactivity, no server
2. **Shinylive Dashboards** - Full Shiny in browser via WebAssembly, no server
3. **Server-Based Shiny** - Traditional Shiny with backend server

### Static & Shinylive Deployment (No Server Required)

Both static dashboards and Shinylive-powered dashboards can be deployed without any server:

```bash
# Render to static HTML (works for both static and Shinylive dashboards)
quarto render dashboard.qmd

# Publish to various platforms
quarto publish quarto-pub dashboard.qmd
quarto publish gh-pages dashboard.qmd
quarto publish netlify dashboard.qmd
```

**Important for Shinylive**: Ensure `shinylive-sw.js` is included in resources for proper functionality.

### Traditional Shiny Deployment (Server Required)

#### Python Shiny
```bash
# Render dashboard
quarto render dashboard.qmd

# Deploy to shinyapps.io
rsconnect deploy shiny . --name myaccount --title my-dashboard

# Or run locally
shiny run app.py
```

#### R Shiny
```bash
# Deploy to shinyapps.io
quarto publish shinyapps dashboard.qmd

# Or serve locally
quarto serve dashboard.qmd
```

### GitHub Pages with Actions

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

## Best Practices

### Performance Optimization

1. **Use Fill Behavior Wisely**
   ```markdown
   ## Row {.fill}
   Content expands to fill space

   ## Row {.flow}
   Content uses natural height
   ```

2. **Optimize Plot Sizing**
   ```python
   # Explicitly set figure sizes for matplotlib
   plt.figure(figsize=(10, 6))

   # Use responsive plots for interactive libraries
   fig.update_layout(height=400, margin=dict(l=0, r=0, t=30, b=0))
   ```

3. **Lazy Load Data**
   ```python
   @reactive.calc
   def filtered_data():
       # Only compute when inputs change
       return expensive_filter(df, input.filters())
   ```

### Mobile Responsiveness

1. **Test Different Screen Sizes**
   ```yaml
   format:
     dashboard:
       scrolling: true  # Enable on mobile
   ```

2. **Use Conditional Layouts**
   ```scss
   @media (max-width: 768px) {
     .card {
       margin-bottom: 1rem;
     }
   }
   ```

### Code Organization

1. **Separate Data Processing**
   ```python
   #| context: setup
   #| include: false
   # Load and preprocess data once
   import pandas as pd
   df = pd.read_csv("data.csv")
   df_processed = process_data(df)
   ```

2. **Modularize Components**
   ```python
   # utils.py
   def create_value_box(value, title, color="primary"):
       return dict(
           value=value,
           title=title,
           color=color,
           icon="graph-up"
       )
   ```

### Error Handling

```python
#| error: true
try:
    fig = create_complex_plot(df)
    fig.show()
except Exception as e:
    print(f"Error creating plot: {e}")
    # Show fallback visualization
    simple_plot(df).show()
```

## Common Patterns

### Dashboard with Filters

```markdown
---
title: "Sales Dashboard"
format: dashboard
---

# {.sidebar}

```{python}
from shiny.express import ui
ui.input_date_range("dates", "Date Range")
ui.input_select("region", "Region",
                ["All", "North", "South", "East", "West"])
```

# Overview

## Row

```{python}
#| title: Sales Trend
@render.plot
def sales_plot():
    filtered = filter_data(input.dates(), input.region())
    return plot_sales_trend(filtered)
```

## Row

```{python}
#| content: valuebox
#| title: Total Sales
@render.express
def total_sales():
    filtered = filter_data(input.dates(), input.region())
    dict(
        value=f"${filtered['sales'].sum():,.0f}",
        icon="currency-dollar",
        color="success"
    )
```
```

### Multi-Page Dashboard

```markdown
---
title: "Analytics Platform"
format:
  dashboard:
    orientation: columns
---

# Overview {orientation="rows"}

## Row
Overview content here

# Details {scrolling="true"}

## Column
Detailed analysis here

# Settings

## Column
Configuration options here
```

## Troubleshooting

### Common Issues

1. **Cards Not Filling Space**
   - Add `#| fill: true` to cell options
   - Check parent container has `.fill` class

2. **Plots Cut Off**
   - Set explicit height: `fig.update_layout(height=400)`
   - Enable scrolling: `{scrolling="true"}`

3. **Shiny Inputs Not Working**
   - Ensure `server: shiny` in YAML header
   - Check reactive contexts are properly set

4. **Tables Too Wide**
   - Use `scrollX: true` in DT options
   - Apply `responsive` class to HTML tables

5. **Value Boxes Not Displaying**
   - Must return dict (Python) or list (R)
   - Include `#| content: valuebox` cell option

## Related Skills

- **quarto-websites**: Build complete documentation sites that can include dashboards
- **shinylive-quarto**: Deep dive into Shinylive WebAssembly deployment for Quarto
- **shinylive-deployment**: GitHub Actions and automation for Shinylive dashboards
- **shiny-async-patterns**: Server-side Shiny patterns (note: async not available in Shinylive)
- **quarto-dynamic-content**: Dynamic tabsets and parameterized reports
- **webr-multi-page-vignettes**: Multi-page vignettes with WebR/Shinylive
- **pkgdown-deployment**: Package documentation sites with dashboards
- **ci-workflows-github-actions**: Automation for dashboard deployment

## Resources

- [Official Docs](https://quarto.org/docs/dashboards/)
- [Example Gallery](https://quarto.org/docs/gallery/#dashboards)
- [Shiny for Python](https://shiny.posit.co/py/)
- [Shiny for R](https://shiny.posit.co/r/)
- [Observable Examples](https://observablehq.com/@observablehq/plot)
- [R-Shinylive Demo](https://github.com/coatless-quarto/r-shinylive-demo)
- [Shinylive Extension](https://github.com/quarto-ext/shinylive)