# Nix Operations & Troubleshooting

## NEVER Install Packages Inside Nix

```r
# FORBIDDEN - Breaks Nix immutability
install.packages()       # NO!
devtools::install()      # NO!
pak::pkg_install()       # NO!

# ALLOWED - Safe operations
devtools::load_all()     # YES
devtools::document()     # YES
devtools::test()         # YES
```

**To add packages:** Edit DESCRIPTION -> Run `default.R` -> Exit Nix -> Re-enter

## Nix Segfaults - R Version Mismatch

**The Error:**
```
*** caught segfault ***
address 0x0, cause 'invalid permissions'
Traceback: dyn.load -> library.dynam -> loadNamespace
```

**Root Cause:** Binary incompatibility between R version in default.nix date and cachix binaries.
Example: Date 2025-10-27 = R 4.5.1, but cachix has R 4.5.2 binaries -> SEGFAULT

### Fix Pattern

1. Use `rix::available_dates()` to find compatible dates
2. Select date matching cachix R version (currently ~4.5.2)
3. Regenerate: `Rscript default.R`
4. Test: `nix-shell default.nix --run "Rscript -e 'library(ggplot2); library(dplyr)'"`

### Rollback Strategy

If newest date doesn't work:
1. List dates: `rix::available_dates()`
2. Try progressively older dates
3. Verify ALL DESCRIPTION packages load in temp nix shell

### Common Mistakes
- Blaming macOS/OS issues (Nix is OS-independent)
- Using arbitrary rix dates without checking R version
- Not testing package loading before committing
- Assuming newest date always works

## Nix Segfaults - Nested Shell R_LIBS_SITE Contamination

**The Error:**
```
*** caught segfault ***
address 0x0, cause 'invalid permissions'
Traceback: dyn.load -> library.dynam -> loadNamespace
```

**Root Cause:** Impure nix-shells inherit `R_LIBS_SITE` from outer shell. Both shells may use R 4.5.2 but from different nixpkgs commits, causing ABI mismatch at `dyn.load()`.

**Diagnostic:**
```bash
echo $R_LIBS_SITE | tr ':' '\n' | wc -l
# Clean: ~218 paths. Contaminated: >500 paths.
```

**Fix:**
1. `default.nix` shellHook: use `pkgs.lib.closePropagation` to compute correct `R_LIBS_SITE`
2. `.Rprofile`: warn if >300 `R_LIBS_SITE` paths
3. Always enter via `./default.sh` (pure shell entry point)

**Key insight:** Never clear `R_LIBS_SITE = ""` — Nix uses it to provide packages. Override with the correct paths for the current derivation.

**Reference:** NixOS/nixpkgs#293777, rix::rix_init() gap

## Cachix Push Rule

`default.nix` (mkShell, dev env) != `package.nix` (buildRPackage, installable)

**KEY PRINCIPLE: NEVER push standard R packages to johngavin.**

Standard R packages belong on rstats-on-nix cache. johngavin.cachix is ONLY for:
- The project's own R package (e.g., `r-footbet`)
- Packages built from GitHub that aren't on CRAN/rstats-on-nix (e.g., `r-goalmodel`)
- Packages needing nixpkgs overrides (e.g., `r-engsoccerdata` with `broken = false`)

Note: The `r-` prefix is a nix store naming convention, not part of the R package name.

- CORRECT: Run `./push_to_cachix.sh` (has safety pre-check)
- CORRECT: `echo $RESULT | cachix push johngavin` (1 path, this package only)
- WRONG: `cachix push johngavin $RESULT` (pushes entire closure)
- WRONG: `nix-store -qR $RESULT | cachix push johngavin` (pushes all deps)

**CRITICAL: `echo $RESULT | cachix push` ALSO pushes the entire closure!**
Cachix resolves the full closure from the single path and uploads any paths
not already in the *target* cache (johngavin), even if they exist in
rstats-on-nix. Always use `push_to_cachix.sh` which pre-checks this.

### For expensive packages (e.g., xgboost with cmake)

If adding a package that needs long compilation:
1. Build locally first: `nix-build package.nix --no-out-link`
2. Push only the custom package via `push_to_cachix.sh`
3. Script pre-check verifies standard R deps are in rstats-on-nix
4. CI pulls from all 3 caches (cache.nixos.org, rstats-on-nix, johngavin)

### package.nix Date Sync (Lesson Learned 2026-03-14)

**`package.nix` date pin MUST match `default.nix` date pin.**

If they differ, `nix-build package.nix` will compile ALL R dependencies from
source because the rstats-on-nix cache only has binaries for specific dates.

**Diagnostic:** `nix-build` should report exactly 1 derivation to build
(your package). If it reports multiple, the date is wrong:

```bash
grep "rstats-on-nix/nixpkgs/archive" default.nix package.nix
# Dates MUST match. If not, sync package.nix to default.nix date.
```

**Also sync Imports:** When DESCRIPTION `Imports:` changes, update
`package.nix` `propagatedBuildInputs` to match.

### cachix PATH in Nix Shells

`cachix` lives at `~/.nix-profile/bin/cachix` but is NOT on PATH inside
project nix-shells (it's a user-level tool, not a project dependency).
`push_to_cachix.sh` should fall back to `$HOME/.nix-profile/bin/cachix`.

## Gitignore: Nix Build Artifacts

The `result` symlink (nix-build output pointing to `/nix/store/...`) must NEVER be committed.

**Global `~/.gitignore`** includes `result` so it's ignored in all projects.

**Per-project `.gitignore`** should also include `result` as a safety net.

When setting up a new project, verify `result` is in `.gitignore` before first commit.
Also watch for accidental "* symlink N" files (e.g. "AGENTS.md symlink 1") created
by macOS Finder copy operations — add these to `.gitignore` when spotted.

## GC-Rooted drv for Network-Free nix-shell (launchd crons, llm#596)

Unhashed `fetchTarball` in `default.nix` re-downloads once the tarball TTL
lapses — and launchd contexts can't resolve github.com, so cron `nix-shell
default.nix` calls die. Fix: instantiate once where network exists, then run
from the drv (zero evaluation, zero network):

- `nix-instantiate default.nix -A shell --indirect --add-root ~/.claude/nix-gcroots/<proj>-shell.drv`
- `nix-store --realise <drv-root> --indirect --add-root ~/.claude/nix-gcroots/<proj>-shell-out` (outputs survive GC without keep-outputs)
- `nix-shell <drv-root> --run 'cmd'`

Maintained by `.claude/scripts/nix_gcroot_refresh.sh`. **Gotcha:** store
paths have mtime=1970, so `-nt` freshness tests against the drv symlink
always read stale — compare against the `.stamp` file the refresh script
touches instead.
