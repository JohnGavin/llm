# Explorations Folder

Scratch area for experimental code, prototypes, and research experiments. Relaxed quality requirements apply here — the bar is "does it run?" not "is it production-ready?"

## Quality Threshold

| Stage | Score | Meaning |
|-------|-------|---------|
| Here (explorations/) | >= 60 | Works, readable, no data leaks |
| Graduate to R/ or vignettes/ | >= 80 | Bronze quality gate |
| Merge to main | >= 95 | Gold quality gate |

## File Naming

```
explorations/
  YYYY-MM-DD_topic-slug.R        # Single-file explorations
  YYYY-MM-DD_topic-slug/         # Multi-file explorations
    README.md                    # One-paragraph purpose + outcome
    *.R
```

## What Belongs Here

- Proof-of-concept code for ideas not yet committed to
- Benchmarking / performance experiments
- Data sketches (no PHI, no >1MB raw data files)
- Failed approaches (keep with brief explanation — see Archiving below)

## What Does NOT Belong Here

- PHI or confidential data (never, anywhere)
- Files >5MB (add to .gitignore or use pins)
- Production-bound code (graduate it, don't leave it here)

## Archiving Abandoned Explorations

When an exploration is abandoned, add a `ABANDONED.md` in its directory (or a comment header in the .R file) with:

```r
# ABANDONED: 2026-04-19
# Reason: duckdb window functions are non-deterministic in parallel mode.
# See: JohnGavin/llm rule duckdb-non-determinism
# Alternative tried: dplyr::slice_max() — works but slower (see explorations/2026-04-20_slice-max-bench.R)
```

This preserves institutional memory and prevents rediscovering known dead ends.

## Graduating to Production

When a prototype reaches Bronze (>=80 quality score):

1. Move files to `R/`, `vignettes/`, or appropriate location
2. Add tests in `tests/testthat/`
3. Add roxygen docs
4. Delete or archive the exploration with a note pointing to the new location
5. Run `devtools::document()` and quality gate checks
