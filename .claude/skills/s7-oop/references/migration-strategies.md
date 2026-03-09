# OOP Migration Strategies

How to migrate between R's OOP systems.

## S3 → S7 (Recommended, ~1-2 hours)

### Before (S3)

```r
new_range <- function(start, end) {
  if (end < start) stop("end must be >= start")
  structure(list(start = start, end = end), class = "range")
}

print.range <- function(x, ...) {
  cat(sprintf("[%s, %s]\n", x$start, x$end))
}

contains.range <- function(x, value) {
  value >= x$start & value <= x$end
}
```

### After (S7)

```r
Range <- new_class("Range",
  properties = list(
    start = class_double,
    end = class_double
  ),
  validator = function(self) {
    if (self@end < self@start) "@end must be >= @start"
  }
)

method(print, Range) <- function(x, ...) {
  cli::cli_text("[{x@start}, {x@end}]")
}

contains <- new_generic("contains", "x")
method(contains, Range) <- function(x, value) {
  value >= x@start & value <= x@end
}
```

### Migration Checklist (S3 → S7)

1. Replace `structure(list(...), class = "foo")` with `new_class("Foo", properties = ...)`
2. Replace `x$field` with `x@property`
3. Move validation from constructor body to `validator` function
4. Replace `method.class <- function(...)` with `method(generic, Class) <- function(...)`
5. Add `.onLoad` with `S7::methods_register()`
6. Add `S7` to DESCRIPTION Imports

## S4 → S7 (~2-4 hours)

### Before (S4)

```r
setClass("Person",
  slots = list(name = "character", age = "numeric"),
  validity = function(object) {
    if (object@age < 0) "age must be non-negative" else TRUE
  }
)
setGeneric("greet", function(x, ...) standardGeneric("greet"))
setMethod("greet", "Person", function(x, ...) {
  paste("Hello, I'm", x@name)
})
```

### After (S7)

```r
Person <- new_class("Person",
  properties = list(name = class_character, age = class_numeric),
  validator = function(self) {
    if (self@age < 0) "@age must be non-negative"
  }
)
greet <- new_generic("greet", "x")
method(greet, Person) <- function(x, ...) {
  paste("Hello, I'm", x@name)
}
```

### Migration Checklist (S4 → S7)

1. Replace `setClass()` with `new_class()`
2. Replace `slots` with `properties` (types use `class_*` not strings)
3. Replace `validity` with `validator` (return `NULL` not `TRUE`)
4. Replace `setGeneric()` with `new_generic()`
5. Replace `setMethod()` with `method(generic, Class) <-`
6. Replace `new("Class", ...)` with `Class(...)`
7. `@` access stays the same (both use `@`)
8. Add `.onLoad` with `S7::methods_register()`

## Base R → vctrs (~2-3 hours)

### Before (Base R)

```r
as_percent <- function(x) {
  structure(x, class = "percent")
}
format.percent <- function(x, ...) paste0(unclass(x) * 100, "%")
c.percent <- function(...) as_percent(c(unlist(lapply(list(...), unclass))))
```

### After (vctrs)

```r
new_percent <- function(x = double()) {
  vec_assert(x, double())
  new_vctr(x, class = "my_percent")
}
format.my_percent <- function(x, ...) paste0(vec_data(x) * 100, "%")
# c() and rbind() handled automatically via vec_ptype2/vec_cast
```

### Migration Checklist (Base → vctrs)

1. Replace `structure(x, class = ...)` with `new_vctr(x, class = ...)`
2. Replace `unclass(x)` with `vec_data(x)`
3. Remove manual `c.class()` — implement `vec_ptype2` + `vec_cast` instead
4. Add `format.class()` method
5. Add pillar methods for tibble display
6. Add vctrs to DESCRIPTION Imports

## R6 → S7: Generally Not Recommended

R6 uses reference semantics (mutable), S7 uses value semantics (copy-on-modify).
Only migrate if you no longer need mutability:

```r
# R6 (mutable)
Counter <- R6::R6Class("Counter",
  public = list(
    count = 0,
    increment = function() self$count <- self$count + 1
  )
)

# S7 equivalent requires returning new objects
Counter <- new_class("Counter",
  properties = list(count = class_integer)
)
increment <- new_generic("increment", "x")
method(increment, Counter) <- function(x, ...) {
  Counter(count = x@count + 1L)  # returns NEW object
}
```
