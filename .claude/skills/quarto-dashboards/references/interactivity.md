# Interactivity Patterns Reference

## Observable JS (Client-Side, No Server)

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

## Shiny for Python (Server-Side)

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

## Shiny for R (Server-Side)

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

## Shinylive (Browser-Based, No Server Required)

Shinylive enables full Shiny functionality in the browser using WebAssembly. No server needed.

### Setup

```bash
# Install R package
install.packages("shinylive")

# Add Quarto extension to your project
quarto add quarto-ext/shinylive
```

### YAML Configuration

```yaml
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
```

### R Shinylive Example

```markdown
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

### Python Shinylive Example

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
```

### Shinylive Limitations and Best Use Cases

**Limitations:**
- Not all R/Python packages available (must be compiled for WebAssembly)
- Cannot access server-side resources (databases, APIs)
- Initial load time can be slower (downloading WebAssembly runtime)
- Limited to packages at [webr.r-wasm.org](https://repo.r-wasm.org)

**Best Use Cases:**
- Educational tutorials and workshops
- Simple statistical calculators
- Data exploration tools with small datasets
- Proof of concepts and demos
- Documentation with live examples

**Important Configuration:**
- Must include `filters: - shinylive` in YAML
- Add `resources: - shinylive-sw.js` for proper deployment
- Use `#| standalone: true` for complete apps
- Create proper `_quarto.yml` project file

## Dashboard with Filters (Full Example)

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
