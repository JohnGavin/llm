# Tidyverse Verbs Reference

Quick reference for the most commonly used tidyverse verbs across packages.

## Data Manipulation (dplyr)

```r
select()    # Choose columns
filter()    # Choose rows
mutate()    # Create/modify columns
summarise() # Aggregate
arrange()   # Sort rows
group_by()  # Group for operations
join()      # Combine tables (left_join, inner_join, etc.)
```

## Data Reshaping (tidyr)

```r
pivot_longer()   # Wide to long
pivot_wider()    # Long to wide
separate()       # Split column
unite()          # Combine columns
nest()           # Create list-columns
unnest()         # Expand list-columns
```

## String Operations (stringr)

```r
str_detect()     # Pattern matching (returns logical)
str_extract()    # Extract matches
str_replace()    # Replace matches
str_split()      # Split strings
str_c()          # Concatenate (or use glue)
```

## Functional Programming (purrr)

```r
map()            # Apply function, return list
map_chr()        # Apply function, return character
map_dbl()        # Apply function, return double
map2()           # Iterate over two inputs
pmap()           # Iterate over multiple inputs
walk()           # Apply for side effects
```

**For parallel operations, prefer `mirai::mirai_map()` over `furrr::future_map()`.**
