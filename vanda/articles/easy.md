# Easy: Basic Search

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
```

## Introduction

This vignette demonstrates how to connect to the V&A MCP server and
perform a basic search.

## Connecting

First, establish a connection to the server.

``` r
client <- mcp_connect()
print(client)
#> $url
#> [1] "https://mcp.vam.ac.uk/mcp/"
#> 
#> $session_start
#> [1] "2026-01-04 22:25:02 UTC"
#> 
#> attr(,"class")
#> [1] "vanda_client"
```

## Searching

Now, let’s search for items related to “Morris”.

``` r
results <- mcp_search(client, "Morris")
#> Could not connect to V&A MCP server or search failed. Returning mock data.
head(results)
#> # A tibble: 6 × 7
#>   id    title                       date period      artist     popularity genre
#>   <chr> <chr>                      <int> <chr>       <chr>           <int> <chr>
#> 1 O1    Object related to Morris 1  1762 Modern      John Cons…          6 Pain…
#> 2 O2    Object related to Morris 2  1746 Renaissance J.M.W. Tu…         22 Scul…
#> 3 O3    Object related to Morris 3  1900 Renaissance William M…         19 Pain…
#> 4 O4    Object related to Morris 4  1896 Baroque     William M…          2 Pain…
#> 5 O5    Object related to Morris 5  1704 Victorian   John Cons…         64 Pain…
#> 6 O6    Object related to Morris 6  1954 Modern      Philip We…         40 Scul…
```

The results include the object ID, title, date, artist, and other
metadata.

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
#> [1] dplyr_1.1.4      vanda_0.0.0.9000
#> 
#> loaded via a namespace (and not attached):
#>  [1] vctrs_0.6.5       cli_3.6.5         knitr_1.51        rlang_1.1.6      
#>  [5] xfun_0.55         generics_0.1.4    textshaping_1.0.4 jsonlite_2.0.0   
#>  [9] glue_1.8.0        htmltools_0.5.9   ragg_1.5.0        sass_0.4.10      
#> [13] rappdirs_0.3.3    rmarkdown_2.30    tibble_3.3.0      evaluate_1.0.5   
#> [17] jquerylib_0.1.4   fastmap_1.2.0     yaml_2.3.12       lifecycle_1.0.4  
#> [21] httr2_1.2.2       compiler_4.5.2    fs_1.6.6          pkgconfig_2.0.3  
#> [25] systemfonts_1.3.1 digest_0.6.39     R6_2.6.1          utf8_1.2.6       
#> [29] tidyselect_1.2.1  curl_7.0.0        pillar_1.11.1     magrittr_2.0.4   
#> [33] bslib_0.9.0       tools_4.5.2       pkgdown_2.2.0     cachem_1.1.0     
#> [37] desc_1.4.3
```
