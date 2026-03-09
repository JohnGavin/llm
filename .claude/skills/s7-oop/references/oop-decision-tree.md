# OOP System Decision Tree

Choosing between S3, S7, S4, R6, and vctrs for R classes.

## Quick Decision

```
Is it vector-like (lives in data frame columns)?
├── YES → vctrs (new_vctr)
└── NO → Is it a new project?
    ├── YES → Do you need mutable state?
    │   ├── YES → R6
    │   └── NO → S7
    └── NO → Is it extending existing S3 code?
        ├── YES → S3
        └── NO → S7
```

## Detailed Comparison

| Feature | S3 | S7 | S4 | R6 | vctrs |
|---------|-----|-----|-----|-----|-------|
| **Complexity** | Low | Medium | High | Medium | Medium |
| **Validation** | Manual | Built-in | Built-in | Manual | Built-in |
| **Properties** | Attributes | Typed props | Slots | Fields | Attributes |
| **Dispatch** | Single | Single + Multiple | Multiple | None | Double (cast/ptype) |
| **Mutability** | Copy-on-modify | Copy-on-modify | Copy-on-modify | Reference | Copy-on-modify |
| **Performance** | Fastest | ~3x S3 | ~1.1x S3 | Fastest | Moderate |
| **Inheritance** | Informal | Formal | Formal | Formal | Via coercion |
| **In data frame** | Limited | No | No | No | Yes |
| **Discovery** | Poor | Good | Good | Manual | Via coercion |
| **Migration cost** | N/A | Low (from S3) | High | N/A | Medium |

## When to Use Each

### S3: Simple, Maximum Compatibility
- Quick prototyping
- Internal-only classes
- Extending existing S3 generics (print, summary, format)
- Maximum performance in tight loops

### S7: Modern Default for New Code
- Formal class hierarchies with type-safe properties
- Validated properties (no manual `stopifnot()`)
- Multiple dispatch needs
- Interop with both S3 and S4
- Clear method discovery (`method_explain()`)

### S4: Legacy Formal Systems
- Bioconductor packages (S4 is the standard)
- Extending existing S4 generics
- **Avoid for new projects** — use S7 instead

### R6: Reference Semantics
- Mutable state (database connections, caches, accumulators)
- Encapsulated methods (`self$method()`)
- Python/Java-like OOP
- Shiny modules with shared state

### vctrs: Vector Types for Data Frames
- Custom types in tibble columns (currency, percentage, units)
- Type-safe coercion rules
- Arithmetic operations on custom types
- Integration with dplyr verbs

## Migration Effort

| From → To | Effort | Strategy |
|-----------|--------|----------|
| S3 → S7 | 1-2 hours | Replace `structure()` with `new_class()`, attrs→properties |
| S4 → S7 | 2-4 hours | Replace `setClass()` with `new_class()`, slots→properties |
| Base R → vctrs | 2-3 hours | Replace `structure()` with `new_vctr()`, add cast/ptype2 |
| R6 → S7 | Not recommended | Different paradigm (mutable vs immutable) |
