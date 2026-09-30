# Vendored: tlang Quarto extension

This directory is a **vendored, locally patched** copy of the "T language
blocks" Quarto filter. Read this before updating it from upstream.

## Upstream source

- Origin: the `t` CLI's bundled Quarto extension, installed from the nixpkgs
  `t-lang` package at `share/tlang/quarto/tlang` (vendored in
  [#1293](https://github.com/JohnGavin/llm/pull/1293), commit `e001cd96`).
- Version: the nixpkgs package was `t-lang` 0.51.2; `_extension.yml` still
  reads `version: "0.51.0"`.
- Upstream repository URL and commit pin: **unknown** (not recorded at vendor
  time; the extension was found untracked in a session worktree). Nothing in
  the vendored files names a repository.
- Not committed: `.tlang-store-path` (machine-specific absolute `/nix/store`
  path written by the installer; gitignored, see `portable-build-artifacts`).

## Licence

**Unknown.** Neither vendored file carries a licence header and no licence file
was vendored with them. This has not been established either way; do not
assume one. Resolve before any redistribution outside this repository.

## sha256 of the vendored files BEFORE local patches

As committed in `e001cd96` (identical to the nixpkgs 0.51.2 copy at the time):

```
0b2682c6352ffb4316172e13f86a0137083a49ccd85e8c8af1a5275f80148064  tlang.lua
bee81d114db26e3e23b3c9862af85a16a6975804206dae0334851c484be8355a  _extension.yml
```

`_extension.yml` is unmodified, so its hash is unchanged. `tlang.lua` has
since been patched (below); its current hash differs by design.

## How the filter runs `t`

`tlang.lua` runs `t --mode strict --unsafe run <tempfile>` via `pandoc.pipe`
(argv list, no shell) in a temporary directory. `--unsafe` deliberately
bypasses the CLI's pipeline-only script guard so prose-first documents can
run arbitrary top-level statements. The binary is `t` on PATH, or `TLANG_BIN`
after validation. No network access. The filter does nothing unless a
document enables it.

## Local patches

Source of findings: roborev job 13831 (review 10694). Each change in
`tlang.lua` is tagged `LOCAL PATCH (VENDORED.md #n)`. Re-apply all five after
any upstream update, then run `tests/test_tlang_filter.sh`.

1. **Repeated chunk output (MEDIUM).** Upstream re-runs the accumulated source
   of every earlier chunk for each new chunk, so earlier printing chunks'
   output appeared again in later chunks. `t run` has no persistent
   session/state mode (checked: `t --help`, 0.51.2), so the accumulated re-run
   is kept but a sentinel (`print("@@tlang-chunk-boundary@@")`) is inserted
   between chunks and only the output after the last sentinel is rendered.
   **Remaining limitations:** the re-run is still O(n^2) in the number of
   chunks, and side effects of earlier chunks (file writes, network, timing,
   randomness) still repeat on every later chunk. A chunk that prints the
   sentinel text itself would truncate its own output.
2. **Silent failure with `include: false` (LOW).** A failed chunk now writes
   `[tlang] chunk failed ...` and the error to stderr. State handling is
   unchanged and now documented: a failed chunk is not added to the session,
   so later chunks run as if it did not exist (definitions it would have made
   are absent).
3. **`..` rejection too broad (LOW).** `TLANG_BIN` validation rejected any
   `..` substring (e.g. `t..old`). It now rejects `..` only as a whole path
   segment.
4. **Missing binary mislabelled (LOW).** "Could not run ... TLANG_BIN" was
   chosen by matching `not found` / `No such file` in the message, so a T
   "variable not found" was mislabelled. It is now chosen from how
   `pandoc.pipe` failed: a table with `error_code` means the process ran and
   exited non-zero (reported as an execution failure, with the process's
   stdout appended); anything else means it could not be spawned.
5. **This file (LOW).** Provenance, hashes, licence status and patch list.
