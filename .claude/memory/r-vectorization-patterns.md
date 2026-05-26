---
name: r-vectorization-patterns
description: When R code loops over entities (walkers, patients, instruments), replace with matrix ops for 10-100x speedup. Key patterns: state as matrices not lists, padded grid, batch RNG, cbind indexing.
type: reference
---

R entity loops (simulations, spatial models, portfolio calcs) can be vectorized 10-100x.

**Trigger:** Any `for (i in 1:n) { entity[[i]]$field <- ... }` pattern, especially
when n > 100 and the operation is the same for each entity.

**Key patterns:**
1. State as matrices not lists (`pos_mat[idx,]` vs `walkers[[i]]$pos`)
2. Batch RNG (`sample.int(4, n, replace=TRUE)` — one C call)
3. Vectorized grid lookup (`grid[cbind(rows, cols)]`)
4. Padded grid for boundary-free neighbor checks (zero border, offset indices)
5. Direction lookup tables (`DR[dirs]`) instead of `switch()` per entity

**Full reference:** `~/docs_gh/llm/knowledge/r-performance/wiki/vectorize-entity-loops.md`

**How to apply:** When reviewing or writing R code that loops over entities,
check if the loop body does the same operation on each entity. If so,
suggest the vectorized alternative from the reference. Especially impactful
for WebR/WASM where R is 10-50x slower than native.
