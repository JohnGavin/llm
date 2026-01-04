# Visualise Search Results

Visualise Search Results

## Usage

``` r
vanda_visualise(
  data,
  x_col = "date",
  y_col = "popularity",
  color_col = "genre"
)
```

## Arguments

- data:

  Data frame from mcp_search.

- x_col:

  Column for X axis (default: "date").

- y_col:

  Column for Y axis (default: "popularity").

- color_col:

  Column for color mapping (default: "genre").

## Value

A ggplot object.
