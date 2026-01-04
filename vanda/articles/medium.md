# Medium: Data Extraction

``` r
library(vanda)
library(dplyr)
#> 
#> Attaching package: 'dplyr'
#> The following objects are masked from 'package:stats':
#> 
#>     filter, lag
#> The following objects are masked from 'package:base':
#> 
#>     intersect, setdiff, setequal, union
library(tibble)
library(knitr)
```

## Data Extraction

This vignette shows how to extract detailed information for specific
objects found in a search and perform multi-criteria tabulation.

``` r
client <- mcp_connect()
results <- mcp_search(client, "Textile")
#> Could not connect to V&A MCP server or search failed. Returning mock data.
```

## Extracting Details

Let’s extract details for the top 3 most popular items.

``` r
top_items <- results |>
  arrange(desc(popularity)) |>
  head(3)

details_list <- lapply(top_items$id, function(id) {
  mcp_extract(client, id)
})
#> Extracting data for object: O19
#> Extracting data for object: O9
#> Extracting data for object: O14

# Convert list to data frame for display
details_df <- bind_rows(details_list)
kable(details_df, caption = "Top 3 Popular Items Details")
```

| id  | title      | description                                     | dimensions | material    | acquisition_year |
|:----|:-----------|:------------------------------------------------|:-----------|:------------|-----------------:|
| O19 | Object O19 | A detailed description of this museum artifact. | Variable   | Mixed Media |             2015 |
| O9  | Object O9  | A detailed description of this museum artifact. | Variable   | Mixed Media |             1958 |
| O14 | Object O14 | A detailed description of this museum artifact. | Variable   | Mixed Media |             1874 |

Top 3 Popular Items Details

## Advanced Tabulation

We can tabulate the results by multiple categories such as **Period**,
**Genre**, and **Popularity** ranges.

### Tabulate by Period and Genre

``` r
summary_table <- results |>
  group_by(period, genre) |>
  summarise(
    count = n(),
    avg_pop = mean(popularity),
    .groups = "drop"
  ) |>
  arrange(desc(avg_pop))

kable(summary_table, caption = "Summary by Period and Genre")
```

| period      | genre     | count | avg_pop |
|:------------|:----------|------:|--------:|
| Renaissance | Textile   |     1 |      71 |
| Victorian   | Textile   |     2 |      71 |
| Victorian   | Painting  |     1 |      64 |
| Baroque     | Sculpture |     1 |      60 |
| Victorian   | Furniture |     2 |      53 |
| Modern      | Sculpture |     1 |      40 |
| Baroque     | Painting  |     2 |      28 |
| Modern      | Textile   |     2 |      27 |
| Baroque     | Furniture |     1 |      26 |
| Renaissance | Sculpture |     1 |      22 |
| Modern      | Painting  |     3 |      17 |
| Modern      | Furniture |     1 |      14 |
| Renaissance | Painting  |     2 |      12 |

Summary by Period and Genre

### Tabulate by Popularity Deciles

``` r
pop_table <- results |>
  mutate(pop_bracket = cut(popularity, breaks = seq(0, 100, by = 25))) |>
  group_by(pop_bracket) |>
  summarise(
    item_count = n(),
    genres = paste(unique(genre), collapse = ", ")
  )

kable(pop_table, caption = "Items grouped by Popularity Bracket")
```

| pop_bracket | item_count | genres                                  |
|:------------|-----------:|:----------------------------------------|
| (0,25\]     |          8 | Painting, Sculpture, Textile, Furniture |
| (25,50\]    |          5 | Sculpture, Painting, Furniture, Textile |
| (50,75\]    |          6 | Painting, Furniture, Textile, Sculpture |
| (75,100\]   |          1 | Textile                                 |

Items grouped by Popularity Bracket

## Session Info

``` r
sessionInfo()
#> R version 4.5.2 (2025-10-31)
#> Platform: x86_64-pc-linux-gnu
#> Running under: Ubuntu 24.04.3 LTS
#> 
#> Matrix products: default
#> BLAS:   /usr/lib/x86_64-linux-gnu/openblas-pthread/libblas.so.3 
#> LAPACK: /usr/lib/x86_64-linux-gnu/openblas-pthread/libopenblasp-r0.3.26.so;  LAPACK version 3.12.0
#> 
#> locale:
#>  [1] LC_CTYPE=C.UTF-8       LC_NUMERIC=C           LC_TIME=C.UTF-8       
#>  [4] LC_COLLATE=C.UTF-8     LC_MONETARY=C.UTF-8    LC_MESSAGES=C.UTF-8   
#>  [7] LC_PAPER=C.UTF-8       LC_NAME=C              LC_ADDRESS=C          
#> [10] LC_TELEPHONE=C         LC_MEASUREMENT=C.UTF-8 LC_IDENTIFICATION=C   
#> 
#> time zone: UTC
#> tzcode source: system (glibc)
#> 
#> attached base packages:
#> [1] stats     graphics  grDevices utils     datasets  methods   base     
#> 
#> other attached packages:
#> [1] knitr_1.51   tibble_3.3.0 dplyr_1.1.4  vanda_0.1.0 
#> 
#> loaded via a namespace (and not attached):
#>  [1] vctrs_0.6.5       cli_3.6.5         rlang_1.1.6       xfun_0.55        
#>  [5] generics_0.1.4    textshaping_1.0.4 jsonlite_2.0.0    glue_1.8.0       
#>  [9] htmltools_0.5.9   ragg_1.5.0        sass_0.4.10       rappdirs_0.3.3   
#> [13] rmarkdown_2.30    evaluate_1.0.5    jquerylib_0.1.4   fastmap_1.2.0    
#> [17] yaml_2.3.12       lifecycle_1.0.4   httr2_1.2.2       compiler_4.5.2   
#> [21] fs_1.6.6          pkgconfig_2.0.3   systemfonts_1.3.1 digest_0.6.39    
#> [25] R6_2.6.1          tidyselect_1.2.1  curl_7.0.0        pillar_1.11.1    
#> [29] magrittr_2.0.4    bslib_0.9.0       tools_4.5.2       pkgdown_2.2.0    
#> [33] cachem_1.1.0      desc_1.4.3
```
