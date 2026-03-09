---
name: s7-oop
description: >
  Guidance for using S7, the modern object-oriented programming system for R.
  Use when: (1) Defining classes with new_class() and properties, (2) Creating
  generics and methods with new_generic()/method(), (3) Setting up inheritance
  hierarchies, (4) Integrating S7 with existing S3/S4 code, (5) Using S7 in
  R packages with proper registration and NAMESPACE, (6) Choosing between S7,
  R6, S4, or S3 for a given problem, (7) Writing property validators, or
  (8) Understanding dispatch order and performance characteristics.
metadata:
  author: johngavin
  version: "1.0"
  source: S7 package docs (RConsortium/S7)
  github-issue: 43
---

# S7: Modern OOP for R

S7 unifies S3 and S4 into a single coherent system. It is developed by the
R Consortium and is the recommended OOP system for new R packages.

## When to Use S7

- New packages needing formal class hierarchies with typed properties
- Replacing informal S3 classes with type-safe, validated properties
- Single or multiple dispatch with clean syntax
- Interop with existing S3/S4 generics
- Computed/dynamic properties

For full S7 vs R6 vs S4 vs S3 guidance, see
[references/comparison-table.md](references/comparison-table.md).

## Defining Classes

```r
Dog <- new_class("Dog",
  properties = list(
    name = class_character,
    age = class_numeric,
    breed = class_character
  )
)

rex <- Dog(name = "Rex", age = 5, breed = "Labrador")
rex@name       # get property
rex@age <- 6   # set property
```

| `new_class()` arg | Purpose |
|--------------------|---------|
| `name` | Class name (must match variable: `Foo <- new_class("Foo")`) |
| `parent` | Parent class (default: `S7_object`) |
| `properties` | Named list of types or `new_property()` specs |
| `abstract` | If `TRUE`, cannot be instantiated |
| `constructor` | Custom constructor (must call `new_object()`) |
| `validator` | Function(self) returning `NULL` or character vector of problems |

## Properties

### Type specifications

```r
# Base types: class_logical, class_integer, class_double, class_character,
#   class_numeric, class_list, class_function, class_environment
# S3 types: class_factor, class_Date, class_POSIXct, class_data.frame
# Unconstrained: class_any
```

### Defaults and custom validators

```r
Pizza <- new_class("Pizza",
  properties = list(
    slices = new_property(class_integer, default = 8L),
    toppings = new_property(class_character, default = "cheese")
  )
)

# Property-level validator: checks individual values
Percentage <- new_class("Percentage",
  properties = list(
    value = new_property(
      class = class_double,
      validator = function(value) {
        if (length(value) != 1) return("must be length 1")
        if (value < 0 || value > 100) return("must be between 0 and 100")
        NULL
      }
    )
  )
)
```

### Class-level validator (checks property combinations)

```r
Range <- new_class("Range",
  properties = list(start = class_numeric, end = class_numeric),
  validator = function(self) {
    if (length(self@start) != 1) return("@start must be length 1")
    if (length(self@end) != 1) return("@end must be length 1")
    if (self@end < self@start) return("@end must be >= @start")
    NULL
  }
)
```

### Dynamic (computed) properties

```r
Circle <- new_class("Circle",
  properties = list(
    radius = class_double,
    area = new_property(class_double,
      getter = function(self) pi * self@radius^2
    ),
    diameter = new_property(class_double,
      getter = function(self) 2 * self@radius,
      setter = function(self, value) { self@radius <- value / 2; self }
    )
  )
)
# getter-only = read-only; dynamic props excluded from constructor args
```

## Generics and Methods

```r
# Define a generic
describe <- new_generic("describe", dispatch_args = "x")

# Register a method
method(describe, Dog) <- function(x, ...) {
  cli::cli_text("{x@name} is a {x@age}-year-old {x@breed}")
}

# Generic with extra required args
format_value <- new_generic("format_value", "x", function(x, ..., digits = 2) {
  S7_dispatch()
})
method(format_value, class_numeric) <- function(x, ..., digits = 2) {
  round(x, digits)
}

# Multiple dispatch
collide <- new_generic("collide", dispatch_args = c("x", "y"))
method(collide, list(Asteroid, Spaceship)) <- function(x, y, ...) "boom!"

# Debug dispatch
method_explain(describe, Dog())
```

## Inheritance

```r
Animal <- new_class("Animal",
  properties = list(name = class_character, sound = class_character)
)
Cat <- new_class("Cat", parent = Animal,
  properties = list(indoor = class_logical)
)
whiskers <- Cat(name = "Whiskers", sound = "meow", indoor = TRUE)
```

### Abstract classes

```r
Shape <- new_class("Shape", abstract = TRUE,
  properties = list(color = new_property(class_character, default = "black"))
)
# try(Shape())  # Error: Can't construct from abstract class
Rectangle <- new_class("Rectangle", parent = Shape,
  properties = list(width = class_double, height = class_double)
)
```

### Dispatch order

1. Exact class match -> 2. Parent -> 3. Grandparent -> ... -> `S7_object` -> `class_any`

For multiple dispatch, combinations checked most-specific-first (similar to S4).

### Calling parent methods

```r
speak <- new_generic("speak", "x")
method(speak, Animal) <- function(x, ...) paste(x@name, "says", x@sound)
method(speak, Cat) <- function(x, ...) {
  base_msg <- speak(super(x, to = Animal), ...)
  if (x@indoor) paste(base_msg, "(from inside)") else base_msg
}
```

### Class unions and base type inheritance

```r
# Union: register one method for multiple types
NumberOrChar <- new_union(class_numeric, class_character)
method(flexible, NumberOrChar) <- function(x, ...) paste("Got:", x)

# Inherit from base types
Sentence <- new_class("Sentence", parent = class_character,
  properties = list(language = new_property(class_character, default = "en"))
)
s <- Sentence("Hello world", language = "en")
nchar(s)    # base ops work
S7_data(s)  # access underlying data
```

## Integration with S3 and S4

```r
# S7 method for S3 generic (S7 objects are S3 objects)
method(print, Dog) <- function(x, ...) {
  cli::cli_text("<Dog> {x@name} ({x@breed}, age {x@age})")
}

# S7 method for an S3 class
s3_tbl <- new_S3_class("tbl_df")
method(row_count, s3_tbl) <- function(x, ...) nrow(x)

# Register S7 class with S4 (for S4 generic dispatch)
S4_register(Dog)

# Type conversion (replaces as.foo() / setAs())
method(convert, list(Dog, class_character)) <- function(from, to) {
  paste(from@name, "the", from@breed)
}
convert(rex, to = class_character)
# Downcasting (child->parent) and upcasting (parent->child) have defaults
```

## Using S7 in Packages

### DESCRIPTION and .onLoad (REQUIRED)

```
Imports:
    S7
```

```r
# R/zzz.R -- ALWAYS include this
.onLoad <- function(libname, pkgname) {
  S7::methods_register()
}
```

### NAMESPACE

```r
#' @import S7
# Or selectively:
#' @importFrom S7 new_class new_generic method method<- new_property S7_object
```

For R < 4.3.0 compatibility (`@` only works with S4 in older R):

```r
#' @rawNamespace if (getRversion() < "4.3.0") importFrom("S7", "@")
NULL
```

### Exporting classes and generics

```r
#' A Dog
#' @param name Character. The dog's name.
#' @param age Numeric. The dog's age.
#' @param breed Character. The dog's breed.
#' @export
Dog <- new_class("Dog", properties = list(
  name = class_character, age = class_numeric, breed = class_character
))
```

### External generics (soft dependency)

```r
other_generic <- new_external_generic("otherpkg", "generic_name", "x")
method(other_generic, MyClass) <- function(x, ...) { ... }
```

## Performance

| Dispatch | S7 | S3 | S4 |
|----------|-----|-----|-----|
| Single | ~2.9 us | ~1.0 us | ~1.1 us |
| Double | ~5.3 us | N/A | ~2.9 us |

S7 is slightly slower (package `.Call` vs primitive) but overhead is small and
constant -- negligible for typical OOP usage. Property access via `@` is fast
(attribute lookup). Hierarchy depth has minimal impact (< 10 levels).

**Batch property updates** to avoid repeated validation:

```r
valid_eventually(my_obj, function(obj) {
  obj@prop1 <- new_val1
  obj@prop2 <- new_val2
  obj  # validation runs once, not twice
})
```

For tight inner loops called millions of times, prefer S3 or direct functions.

## Common Patterns

```r
# Immutable value objects: return new objects
method(translate, Point) <- function(point, ..., dx = 0, dy = 0) {
  Point(x = point@x + dx, y = point@y + dy)
}

# Factory with custom constructor
Connection <- new_class("Connection",
  properties = list(host = class_character, port = class_integer),
  constructor = function(url) {
    parsed <- parse_url(url)
    new_object(S7_object(), host = parsed$host, port = as.integer(parsed$port))
  }
)

# Enum-like class
Color <- new_class("Color", parent = class_character,
  validator = function(self) {
    valid <- c("red", "green", "blue", "yellow")
    if (!all(S7_data(self) %in% valid))
      paste0("must be one of: ", paste(valid, collapse = ", "))
  }
)
```

## Anti-Patterns

```r
# WRONG: use $ for properties    | RIGHT: use @
dog$name                          # dog@name

# WRONG: skip .onLoad            | RIGHT: always register
# (external methods silently fail)
.onLoad <- function(libname, pkgname) { S7::methods_register() }

# WRONG: bypass S7 validation    | RIGHT: use constructor
structure(list(), class = "Foo")  # Foo()
```

## Review Checklist

- [ ] Class name matches variable name (`Foo <- new_class("Foo")`)
- [ ] Properties have explicit type constraints (not `class_any` unless needed)
- [ ] Validator returns `NULL` or character vector (never `TRUE`/`FALSE`)
- [ ] `.onLoad` calls `S7::methods_register()`
- [ ] `@` used for property access (not `$`)
- [ ] Custom constructors call `new_object()`
- [ ] `S7` in DESCRIPTION `Imports`; exported classes documented with `@export`
- [ ] `super()` used instead of direct parent method calls
- [ ] `valid_eventually()` used when setting multiple properties

## Related Skills

- **lifecycle-management** - Deprecating S7 class properties or methods
- **tidyverse-style** - Integration with tidy evaluation
- **testthat-patterns** - Testing S7 classes and methods

## Resources

- [S7 documentation](https://rconsortium.github.io/S7/)
- [S7 GitHub](https://github.com/RConsortium/S7)
- [vignette("classes-objects")](https://rconsortium.github.io/S7/articles/classes-objects.html)
- [vignette("generics-methods")](https://rconsortium.github.io/S7/articles/generics-methods.html)
- [vignette("packages")](https://rconsortium.github.io/S7/articles/packages.html)

See [references/comparison-table.md](references/comparison-table.md) for the full S3/S4/R5/R6/S7 comparison.
