# Companion: Nix Nested Shell Isolation — Background + Worked Examples

Background explanation, worked code, and the full cross-reference list split
out of the always-loaded [`nix-nested-shell-isolation`](../nix-nested-shell-isolation.md)
rule to keep it lean. The normative content (The Problem mechanism, The Fix
shellHook, Fix Options table, What NOT To Do) stays in the rule; this file is
the supplementary background and verbatim commands, loaded on demand.

## What R_LIBS_SITE Is (and Is Not)

`R_LIBS_SITE` is R's **search path for pre-built package libraries** — it lists
`/nix/store/.../library` directories so R can find packages. It is NOT an
installation mechanism. All R packages are pre-built in the Nix store by
`default.nix`; R_LIBS_SITE just tells R where to look.

Nix sets this variable automatically when a shell is entered. The problem arises
only when shells are **nested**.

## Not a date-pin issue

This is NOT a date-pin issue. It happens even when both shells pin the same
date, because `rix::rix()` generates a fresh derivation each time.

## The Symptom — full traceback

```
*** caught segfault ***
address 0x0, cause 'invalid permissions'
Traceback:
 1: dyn.load(file, DLLpath = DLLpath, ...)
 2: library.dynam(lib, package, package.lib)
 3: loadNamespace(package, lib.loc)
```

## T-lang Projects — Required Workflow After Every `t update`

```bash
t update                # regenerates flake.nix -- strips the shellHook patch
bash default.post.sh   # re-applies closure-rebuild (idempotent)
exit
nix develop            # re-enter with patched flake.nix
```

## T-lang Projects — CI Marker Check

Add this to CI (or a pre-commit hook) to catch missing patches:

```bash
grep -q "Closure-rebuild" flake.nix || {
  echo "ERROR: closure-rebuild shellHook missing from flake.nix"
  echo "  Fix: bash default.post.sh"
  exit 1
}
```

## Verification — worked command

```bash
nix-shell default.nix --run 'Rscript -e "library(lme4); cat(\"OK\n\")"'
```

## Full Cross-references

- footbet commit 0002842: first rix implementation of this fix
- rix GitHub: https://github.com/ropensci/rix (does not include this fix as of 2026-04)
- T-lang source: https://github.com/b-rodrigues/tlang --
  `src/package_manager/nix_generator.ml` generates `flake.nix`; closure-rebuild
  NOT in template as of 2026-05-28
- JohnGavin/historical#282 -- first T-lang incident (`t update` stripped shellHook)
- JohnGavin/historical `default.post.sh` -- reference implementation for T-lang workaround
- JohnGavin/llm#303 -- upstream T-lang template fix request
