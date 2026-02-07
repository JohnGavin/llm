# Nix Environment Troubleshooting

## Environment Not Activating

**Problem:** Packages not found after entering nix shell

**Solution:**
```bash
# Exit shell
exit

# Clean nix store cache (if needed)
nix-collect-garbage

# Rebuild from scratch
nix-shell default.nix
```

## Version Conflicts

**Problem:** Different package versions locally vs CI

**Solution:**
```r
# Check r_ver date in both default.R files
# Ensure they match

# Local: /path/to/project/default.R
# CI: Uses same default.nix from repo

# Re-source to sync:
source("default.R")
```

## Package Not Available

**Problem:** Package won't load in nix shell

**Solution:**
```r
# 1. Check if package in default.R
# 2. Check if package exists for that r_ver date
# 3. Try different r_ver date
# 4. Or add as git_pkg from GitHub

# Update default.R
rix(
  r_ver = "2024-12-01",  # Try newer date
  r_pkgs = c("newpackage"),
  # ...
)
source("default.R")
```

## Shell Too Slow to Start

**Problem:** `nix-shell` takes minutes to start

**Solution: Use Cachix Binary Cache**

```bash
# Enable rstats-on-nix cache for pre-built R packages
nix-shell -p cachix --run "cachix use rstats-on-nix"

# Now nix-shell downloads pre-built packages instead of compiling!
nix-shell default.nix  # Much faster
```

**If still slow with Cachix:**
```bash
# Add to ~/.config/nix/nix.conf:
experimental-features = nix-command flakes
```

## Environment Degradation During Long Sessions

**Problem:** Commands like `git`, `gh`, `R` start failing with "command not found" or "No such file or directory" during a multi-hour session

**Root Cause:** Nix garbage collection removed store paths that were in `$PATH` at session start

**Warning Signs:**
- Commands that worked earlier now fail
- Error: `/nix/store/xxx-package/bin/command: No such file or directory`
- R packages that loaded before won't load
- Git operations failing unexpectedly

**Immediate Recovery:**
```bash
# Option 1: Exit and re-enter (fastest)
exit
nix-shell default.nix

# Option 2: If you have unsaved R session state
# Find working binaries and use full paths temporarily
find /nix/store -name "git" -type f 2>/dev/null | head -1
```

**Prevention Strategies:**

**Strategy 1: Periodic Shell Restart (Simplest)**
```bash
# Every 2-3 hours during long sessions:
exit
nix-shell default.nix
# Takes seconds, prevents degradation
```

**Strategy 2: Use Safer Garbage Collection**
```bash
# NEVER use this:
nix-collect-garbage -d  # ❌ Too aggressive

# Instead use:
nix-collect-garbage --delete-older-than 30d  # ✅ Safer
nix-collect-garbage  # ✅ Remove orphaned only
```

**Strategy 3: Create GC Roots (Advanced)**
```bash
# Prevent GC from removing active environment
nix-build default.nix -o ~/.nix-gc-roots/project-name

# Remove when done:
rm ~/.nix-gc-roots/project-name
```

**For Detailed Troubleshooting:** See `NIX_TROUBLESHOOTING.md` in project root.
