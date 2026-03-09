# Migration Tables

## Base R → Modern Tidyverse

| Base R | Tidyverse | Notes |
|--------|-----------|-------|
| `subset(df, x > 5)` | `dplyr::filter(df, x > 5)` | |
| `transform(df, y = x*2)` | `dplyr::mutate(df, y = x*2)` | |
| `aggregate(y ~ x, df, mean)` | `dplyr::summarise(df, mean_y = mean(y), .by = x)` | `.by` is modern |
| `merge(a, b, by = "id")` | `dplyr::left_join(a, b, by = "id")` | |
| `sapply(x, f)` | `purrr::map(x, f)` | Type-stable: `map_dbl()` |
| `lapply(x, f)` | `purrr::map(x, f)` | |
| `do.call(rbind, x)` | `purrr::list_rbind(x)` | |
| `Reduce(f, x)` | `purrr::reduce(x, f)` | |
| `grep("pat", x)` | `stringr::str_which(x, "pat")` | |
| `grepl("pat", x)` | `stringr::str_detect(x, "pat")` | |
| `gsub("old", "new", x)` | `stringr::str_replace_all(x, "old", "new")` | |
| `sub("old", "new", x)` | `stringr::str_replace(x, "old", "new")` | |
| `regmatches(x, m)` | `stringr::str_extract(x, pat)` | |
| `substr(x, 1, 3)` | `stringr::str_sub(x, 1, 3)` | |
| `paste0(a, b)` | `stringr::str_c(a, b)` or `glue::glue("{a}{b}")` | |
| `sprintf("%.2f", x)` | `glue::glue("{round(x, 2)}")` | |
| `read.csv("f.csv")` | `readr::read_csv("f.csv")` | Faster, tibble output |
| `reshape(df, ...)` | `tidyr::pivot_longer()` / `pivot_wider()` | |
| `stack(df)` | `tidyr::pivot_longer(df, everything())` | |
| `ifelse(cond, a, b)` | `dplyr::if_else(cond, a, b)` | Type-safe |
| `which.min(x)` | `dplyr::slice_min(df, x, n = 1)` | In data frame context |

## Old Tidyverse → New Tidyverse

| Old Pattern | New Pattern | Since |
|------------|-------------|-------|
| `%>%` | `\|>` | R 4.1+ |
| `function(x) x + 1` | `\(x) x + 1` | R 4.1+ |
| `group_by(x) \|> ... \|> ungroup()` | `summarise(..., .by = x)` | dplyr 1.1.0 |
| `gather(key, value, -id)` | `pivot_longer(cols = -id)` | tidyr 1.0.0 |
| `spread(key, value)` | `pivot_wider(names_from, values_from)` | tidyr 1.0.0 |
| `separate(col, into)` | `separate_wider_delim(col, delim, names)` | tidyr 1.3.0 |
| `unnest(col)` (legacy) | `unnest(col)` (explicit cols required) | tidyr 1.0.0 |
| `map_dfr(x, f)` | `map(x, f) \|> list_rbind()` | purrr 1.0.0 |
| `map_dfc(x, f)` | `map(x, f) \|> list_cbind()` | purrr 1.0.0 |
| `flatten_chr(x)` | `list_c(x)` | purrr 1.0.0 |
| `by = c("a" = "b")` | `by = join_by(a == b)` | dplyr 1.1.0 |
| `top_n(n, wt)` | `slice_max(order_by = wt, n = n)` | dplyr 1.0.0 |
| `sample_n(n)` | `slice_sample(n = n)` | dplyr 1.0.0 |
| `transmute(...)` | `mutate(..., .keep = "none")` | dplyr 1.0.0 |
| `rename_all(tolower)` | `rename_with(tolower)` | dplyr 1.0.0 |
| `summarise_at(vars, fns)` | `summarise(across(cols, fns))` | dplyr 1.0.0 |
| `mutate_if(is.numeric, f)` | `mutate(across(where(is.numeric), f))` | dplyr 1.0.0 |
| `funs(mean, sd)` | `list(mean = mean, sd = sd)` | dplyr 0.8.0 |
| `select_if(is.numeric)` | `select(where(is.numeric))` | tidyselect 1.0.0 |

## Key Version Requirements

| Feature | Minimum Version |
|---------|----------------|
| `.by` argument | dplyr >= 1.1.0 |
| `pick()` | dplyr >= 1.1.0 |
| `reframe()` | dplyr >= 1.1.0 |
| `join_by()` | dplyr >= 1.1.0 |
| `consecutive_id()` | dplyr >= 1.1.0 |
| `across()` | dplyr >= 1.0.0 |
| `list_rbind()` | purrr >= 1.0.0 |
| `.parallel` in map | purrr >= 1.1.0 |
| Base pipe `\|>` | R >= 4.1.0 |
| Lambda `\()` | R >= 4.1.0 |
