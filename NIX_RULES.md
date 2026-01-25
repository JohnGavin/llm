# Critical Nix Environment Rules

## The Golden Rule: NEVER Install Inside Nix

**Why this matters:** Nix environments are designed to be:
- **Immutable**: The `/nix/store` is read-only
- **Reproducible**: Same `default.nix` = exact same environment everywhere
- **Declarative**: All dependencies declared upfront in `default.nix`

## What Happens When You Violate This

When you run `devtools::install()` or `install.packages()` inside Nix:
1. It tries to write to the user library (`~/Library/R/...`)
2. This creates a **hybrid environment** mixing Nix and non-Nix packages
3. **Breaks reproducibility** - next person won't have those packages
4. **Causes version conflicts** - Nix packages vs user packages
5. **Defeats the entire purpose of Nix**

## The Correct Workflow

### To Add a Package

1. **Edit DESCRIPTION** - Add to Imports/Suggests
2. **Run `default.R`** - Regenerates `default.nix` with new packages
3. **Exit and re-enter Nix** - `exit` then `./default.sh`
4. **Package is now available** - Installed from Nix cache

### What's Allowed vs Forbidden

#### ✓ ALLOWED (Read-Only Operations)
```r
devtools::load_all()     # Loads code into memory temporarily
devtools::document()     # Writes to man/ (project directory)
devtools::test()         # Runs tests, no installation
devtools::check()        # Checks package, no installation
library(pkg)             # Load Nix-installed packages
```

#### ✗ FORBIDDEN (Modify R Library)
```r
devtools::install()      # Tries to install to library
install.packages()       # Modifies R library
pak::pkg_install()       # Modifies R library
remotes::install_github() # Modifies R library
BiocManager::install()   # Modifies R library
```

## Quick Test: Am I in Nix?

```bash
echo $IN_NIX_SHELL  # Should be "1" or "impure"
which R              # Should show /nix/store/...
```

## If You Accidentally Installed

1. Exit the Nix shell
2. Clean user library: `rm -rf ~/Library/R/arm64/4.5/library/[package]`
3. Re-enter Nix shell: `./default.sh`
4. Package should now come from Nix only

## Remember

> "If you need a package in Nix, declare it in Nix"

The moment you run `install.packages()` inside Nix, you've broken the contract and created an unreproducible environment.