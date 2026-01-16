# Shinylive Helper Scripts

Centralized, reusable scripts for fixing common Shinylive issues in R packages.

## Scripts

### `fix_pkgdown_sw_path.R`

**Problem:** pkgdown + Quarto + Shinylive Service Worker path mismatch (Issue #15 pattern)

**Solution:** Copies `shinylive-sw.js` to both locations:
- `/articles/shinylive-sw.js` (from `resources:` in YAML)
- `/shinylive-sw.js` (site root - where meta tag points)

**Usage:**
```r
# After pkgdown::build_site()
source("R/dev/fix_pkgdown_sw_path.R")  # If symlinked
copy_shinylive_sw_to_root()
```

**Setup in new project:**
```bash
# Create symlink
mkdir -p R/dev
ln -s /Users/johngavin/docs_gh/llm/scripts/shinylive/fix_pkgdown_sw_path.R R/dev/

# Or copy if sharing with others
cp /Users/johngavin/docs_gh/llm/scripts/shinylive/fix_pkgdown_sw_path.R R/dev/
```

## Documentation

See: `/Users/johngavin/docs_gh/llm/WIKI_CONTENT/WIKI_SHINYLIVE_LESSONS_LEARNED.md`

## Related Issues

- [Shinylive #133](https://github.com/posit-dev/shinylive/issues/133)
- [pkgdown #2877](https://github.com/r-lib/pkgdown/issues/2877)
