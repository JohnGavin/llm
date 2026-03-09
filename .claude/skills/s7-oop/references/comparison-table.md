# R OOP Systems Comparison Matrix

Full comparison of all R object-oriented programming systems: S3, S4, R5 (Reference Classes), R6, and S7.

## Quick Decision Guide

| Scenario | Recommended | Rationale |
|----------|-------------|-----------|
| New package, formal classes needed | **S7** | Modern, type-safe, good interop |
| Mutable state required (connections, caches) | **R6** | Reference semantics by design |
| Extending existing S4 ecosystem (Bioconductor) | **S4** | Compatibility with existing classes |
| Simple tag-and-dispatch, no formal structure | **S3** | Minimal overhead, ubiquitous |
| Performance-critical inner loops | **S3** | Fastest dispatch (~1 us) |
| Multiple dispatch needed | **S7** or **S4** | Both support it; S7 is simpler |
| Cross-package method registration | **S7** | `new_external_generic()` is clean |
| Teaching/learning OOP in R | **S7** | Clearest mental model |

## Feature Comparison

| Feature | S3 | S4 | R5 (RefClass) | R6 | S7 |
|---------|----|----|---------------|----|----|
| **Introduced** | 1992 (S) | 1998 (S) | R 2.12 (2010) | 2014 (pkg) | 2024 (pkg) |
| **Status** | Stable, core | Stable, core | Stable, discouraged | Stable, popular | Active development |
| **Where defined** | Base R | methods pkg | methods pkg | R6 pkg | S7 pkg |
| **Formal class def** | No | Yes (`setClass`) | Yes (`setRefClass`) | Yes (`R6Class`) | Yes (`new_class`) |
| **Typed properties/slots** | No | Yes (slots) | Yes (fields) | No | Yes (properties) |
| **Validators** | No | Yes (`validity`) | No | No (manual) | Yes (`validator`) |
| **Dynamic properties** | No | No | No | Active bindings | Yes (`getter`/`setter`) |
| **Default values** | N/A | Yes (`prototype`) | No | Yes | Yes (`default`) |
| **Inheritance** | Implicit (class vector) | Formal (`contains`) | Formal (`contains`) | Formal (`inherit`) | Formal (`parent`) |
| **Multiple inheritance** | Sort of (class vector) | Yes | Yes | No | No |
| **Abstract classes** | No | Yes (VIRTUAL) | No | No | Yes (`abstract = TRUE`) |

## Dispatch Comparison

| Feature | S3 | S4 | R5 (RefClass) | R6 | S7 |
|---------|----|----|---------------|----|----|
| **Dispatch type** | Single | Single + Multiple | Method belongs to object | Method belongs to object | Single + Multiple |
| **Generic definition** | `UseMethod()` | `setGeneric()` | N/A (methods in class) | N/A (methods in class) | `new_generic()` |
| **Method registration** | Naming convention | `setMethod()` | In class definition | In class definition | `method<-` |
| **Dispatch speed** | ~1 us (primitive) | ~1.1 us (primitive) | ~1.5 us | ~0.5 us (env lookup) | ~2.9 us (.Call) |
| **Method lookup** | `class` attribute | Signature matching | `$method()` | `$method()` | `S7_dispatch()` |
| **`super()` / parent call** | `NextMethod()` | `callNextMethod()` | `callSuper()` | `super$method()` | `super(x, to = Parent)` |

## Semantics Comparison

| Feature | S3 | S4 | R5 (RefClass) | R6 | S7 |
|---------|----|----|---------------|----|----|
| **Copy semantics** | Value (copy-on-modify) | Value (copy-on-modify) | **Reference** | **Reference** | Value (copy-on-modify) |
| **Mutability** | Immutable feel | Immutable feel | Mutable | Mutable | Immutable feel |
| **Property access** | `$` or `[[` | `@` | `$field` | `$field` | `@` |
| **Encapsulation** | None | Informal | Public/private possible | Public/private/active | Via getters/setters |
| **`$` behavior** | List access | Error (use `@`) | Field/method access | Field/method access | Not for properties (use `@`) |

## Package Integration

| Feature | S3 | S4 | R5 (RefClass) | R6 | S7 |
|---------|----|----|---------------|----|----|
| **NAMESPACE export** | `export()` | `exportClasses()`, `exportMethods()` | `export()` | `export()` | `export()` constructor |
| **Method registration** | `S3method()` directive | `exportMethods()` | In class def | In class def | `.onLoad` + `methods_register()` |
| **Cross-package methods** | `S3method()` | `setMethod()` in `.onLoad` | N/A | N/A | `new_external_generic()` |
| **R CMD check** | Minimal checks | Strict checks | Minimal checks | Minimal checks | Moderate checks |
| **Dependencies** | None (base R) | None (methods is base) | None (methods is base) | R6 package | S7 package |

## Interoperability

| From / To | S3 | S4 | S7 |
|-----------|----|----|-----|
| **S3 class in S7 generic** | `new_S3_class("foo")` | N/A | Works via `method(gen, new_S3_class("foo"))` |
| **S7 class in S3 generic** | Works automatically | N/A | S7 objects have S3 class attribute |
| **S4 class in S7 generic** | N/A | N/A | Works via `method(gen, s4_class)` |
| **S7 class in S4 generic** | N/A | `S4_register()` first | Then register with `setMethod()` or `method<-` |
| **Extend S3 with S7** | N/A | N/A | `new_class("Foo", parent = new_S3_class("bar"))` |
| **Extend S7 with S3** | N/A | N/A | Possible (S7 objects are S3 objects) |
| **S7 `convert()`** | Replaces `as.foo()` | Replaces `as()` / `setAs()` | Native |

## Memory and Performance

| Aspect | S3 | S4 | R5 (RefClass) | R6 | S7 |
|--------|----|----|---------------|----|----|
| **Object overhead** | ~1 attribute (class) | ~3 attributes | Environment + fields | Environment + bindings | ~2 attributes (class + S7_class) |
| **Construction cost** | Minimal (`structure()`) | Moderate (`new()`) | High (env creation) | Moderate (env creation) | Moderate (`new_object()`) |
| **Property access** | Fast (`$`, `[[`) | Moderate (`@`) | Fast (env `$`) | Fast (env `$`) | Fast (`@`, attribute lookup) |
| **Validation** | None (unless manual) | On construction | None (unless manual) | None (unless manual) | On construction + property set |
| **Deep hierarchy cost** | Linear (class vector) | Cached | N/A | N/A | Linear but fast (~5 us at depth 50) |
| **Garbage collection** | Standard | Standard | Reference counting | Reference counting | Standard |

## When NOT to Use Each System

| System | Avoid When |
|--------|-----------|
| **S3** | You need type safety, formal validation, or multiple dispatch |
| **S4** | You are writing a new package with no Bioconductor/S4 dependencies |
| **R5** | Always -- use R6 instead (R5 is effectively deprecated in practice) |
| **R6** | You need functional/value semantics or multiple dispatch |
| **S7** | You need reference semantics (mutable objects), or are in a performance-critical tight loop |

## Migration Paths

### S3 to S7

```r
# Before (S3)
new_dog <- function(name, breed) {
  structure(list(name = name, breed = breed), class = "dog")
}
print.dog <- function(x, ...) cat(x$name, "\n")

# After (S7)
Dog <- new_class("Dog", properties = list(
  name = class_character,
  breed = class_character
))
method(print, Dog) <- function(x, ...) cat(x@name, "\n")
```

### S4 to S7

```r
# Before (S4)
setClass("Dog", slots = list(name = "character", breed = "character"))
setGeneric("speak", function(x) standardGeneric("speak"))
setMethod("speak", "Dog", function(x) paste(x@name, "barks"))

# After (S7)
Dog <- new_class("Dog", properties = list(
  name = class_character,
  breed = class_character
))
speak <- new_generic("speak", "x")
method(speak, Dog) <- function(x, ...) paste(x@name, "barks")
```

### R6 to S7

R6 and S7 solve different problems. Only migrate if you do not need
reference semantics (mutable state, shared objects):

```r
# Before (R6) - mutable counter
Counter <- R6::R6Class("Counter",
  public = list(
    count = 0,
    increment = function() self$count <- self$count + 1
  )
)

# After (S7) - functional style
Counter <- new_class("Counter", properties = list(
  count = new_property(class_integer, default = 0L)
))
increment <- new_generic("increment", "x")
method(increment, Counter) <- function(x, ...) {
  Counter(count = x@count + 1L)  # returns NEW object
}
```

Note: if you need the counter to be shared/mutable (e.g. tracking state
across callbacks), keep R6.

## Summary Decision Tree

```
Need mutable/shared state?
  YES -> R6
  NO -> Need S4 ecosystem compatibility?
    YES -> S4
    NO -> Need formal types/validation?
      YES -> S7
      NO -> Need it simple and fast?
        YES -> S3
        NO -> S7 (future-proof default)
```
