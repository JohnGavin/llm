# Dashboard Components Reference

## Interactive Plots

### Plotly (Python)

```python
import plotly.express as px
fig = px.scatter(df, x='x', y='y', color='category',
                 title="Interactive Scatter Plot")
fig.update_layout(height=400)
fig.show()
```

### Altair (Python)

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

### ggplot2 (R)

```r
library(ggplot2)
ggplot(data, aes(x = x, y = y, color = category)) +
  geom_point() +
  theme_minimal() +
  labs(title = "Scatter Plot")
```

## Tables

### Interactive Tables (Python - itables)

```python
from itables import show
show(df,
     buttons=['copy', 'csv', 'excel'],
     dom='Bfrtip',
     paging=True,
     pageLength=25)
```

### DT Tables (R)

```r
library(DT)
datatable(data,
          filter = 'top',
          options = list(
            pageLength = 25,
            scrollX = TRUE
          ))
```

### Static Tables

```python
# Python
print(df.to_markdown(index=False))
```

```r
# R
knitr::kable(data, format = "html")
```

## Value Boxes

### Static Value Box (Python)

```python
#| content: valuebox
#| title: "Active Users"
dict(
    value = f"{active_users:,}",
    icon = "people-fill",
    color = "primary"
)
```

### Dynamic Value Box - Python Shiny

```python
from shiny import ui
ui.value_box(
    title="Revenue",
    value=ui.output_text("revenue"),
    theme="success",
    showcase=icon_svg("currency-dollar")
)
```

### Dynamic Value Box - R Shiny

```r
bslib::value_box(
  title = "Revenue",
  value = textOutput("revenue"),
  theme = "success",
  showcase = bs_icon("currency-dollar")
)
```

Available `color`/`theme` values: `primary`, `secondary`, `success`, `info`, `warning`, `danger`, `light`, `dark`

## Text Content

### Dynamic Inline Text

```markdown
The total revenue is `{python} f"${revenue:,.0f}"` this quarter.
```

### Content Cards

```markdown
::: {.card title="Analysis Summary"}
## Key Findings

1. Revenue increased by 25%
2. Customer retention improved
3. New markets show promise
:::
```

## Shiny Inputs

### Python

```python
from shiny import ui

# In sidebar or toolbar cell:
ui.input_select("category", "Category:",
                choices=["All", "A", "B", "C"])
ui.input_date_range("dates", "Date Range:")
ui.input_slider("threshold", "Threshold:",
                min=0, max=100, value=50)
```

### R

```r
library(shiny)

# In sidebar or toolbar cell:
selectInput("category", "Category:",
            choices = c("All", "A", "B", "C"))
dateRangeInput("dates", "Date Range:")
sliderInput("threshold", "Threshold:",
            min = 0, max = 100, value = 50)
```
