# Destructive Scripts Audit

**Date:** 2026-05-05
**Scope (v1):** `~/.claude/hooks/` (canonical: `~/docs_gh/llm/.claude/hooks/`), `~/docs_gh/llm/.claude/scripts/`, `~/docs_gh/llm/bin/`
**Patterns searched:** `git reset --hard`, `git push --force`, `git clean -fd`, `git branch -D`, `rm -rf`, `rm -fr`, overwrite redirects to `.json`/`.sql` files, `dbExecute.*(DROP|TRUNCATE)`, `duckdb.*(DROP|TRUNCATE)`, `aws.*delete`, `gh api.*-X (DELETE|PATCH|PUT)`

## Inventory

| # | File | Line | Operation | Classification | Recovery mechanism | Action |
|---|------|------|-----------|---------------|-------------------|--------|
| 1 | `bin/refresh_and_preserve.sh` | 97 | `git reset --hard` | **Recovery trail present** | `git stash create` + `git stash store` (lines 94-96) stores exact ref before reset; unconditional `git stash apply $STASH_REF` at exit (line 390); JSON archived to timestamped `inst/extdata/archive/` (lines 118-120) | No action needed — this script is the model implementation from #100 |
| 2 | `bin/refresh_and_preserve.sh` | 408 | `rm -rf "$LLM_REPO/inst/extdata/archive/$dir"` | **Reproducible** | Removes old archive directories beyond the last 10; each archive was itself created as a dated backup of JSON files that are also stored in DuckDB; the DuckDB records are permanent. Archive cleanup is intentional rotation, not irreversible data loss | No action needed |
| 3 | `bin/refresh_and_preserve.sh` | 278, 281 | `> inst/extdata/ccusage_session_all.json` and `> inst/extdata/ccusage_blocks_all.json` | **Reproducible** | Both files are re-fetched from `npx ccusage` on every run; the underlying source of truth is the ccusage CLI + cloud data, not the JSON file. JSON files are committed to git, so `git checkout HEAD -- inst/extdata/*.json` recovers the previous version | No action needed |
| 4 | `.claude/scripts/setup_ast_grep_r.sh` | 40 | `rm -rf "$TMPDIR"` | **Reproducible** | `$TMPDIR` is created by `mktemp -d` at line 32 and contains only a shallow clone of `r-lib/tree-sitter-r` fetched from GitHub. The compiled grammar is written to `~/.config/ast-grep/r.dylib` before cleanup. Re-running the script regenerates everything from the public GitHub repo | No action needed |
| 5 | `.claude/scripts/signal_braindump_handler.sh` | 78, 110 | `rm -rf "$txt_dir"` | **Reproducible** | `$txt_dir` is created by `mktemp -d` at line 72 and contains only Whisper's intermediate `.txt` output for a single audio file. The transcribed text is written to `$DUMP_DIR` (braindumps directory) AND inserted into DuckDB before cleanup. Audio source file is never touched | No action needed |
| 6 | `.claude/scripts/signal_notes_sync.sh` | 69 | `rm -rf "$_txt_dir"` | **Reproducible** | Same pattern as #5: `mktemp -d` at line 45 holds only Whisper intermediate output; text written to `$DUMP_DIR` and DuckDB before cleanup | No action needed |
| 7 | `.claude/hooks/destructive_api_guard.sh` | 79, 82, 92, 96, 116 | References to `gh api -X DELETE`, `aws delete`, `duckdb DROP/TRUNCATE` | **Recovery trail present** | These are pattern-match strings in the guard itself — the hook *intercepts* these patterns to prompt the user. Not destructive ops; preventive infrastructure | No action needed |

## Summary Counts

**7 total destructive ops (or references to destructive patterns)**
- **2 with recovery trail** (ops #1, #7)
- **5 reproducible** (ops #2, #3, #4, #5, #6)
- **0 MISSING** (no destructive op found without either a recovery trail or a reproducibility justification)

## Notes

- The `destructive_api_guard.sh` hook (item #7) was itself created to intercept destructive patterns in Claude's tool calls. Its presence shows the hooks directory is already guarded.
- All `rm -rf` occurrences in scripts operate on `mktemp`-created temporary directories whose contents have already been flushed to durable storage (DuckDB or a named output file). None operate on user data directories.
- `refresh_and_preserve.sh` (item #1) is the reference implementation of the stash-create+store pattern. Future scripts requiring `git reset --hard` should copy lines 87-102 and 385-403 verbatim.
- The `bin/` directory contains one `.plist` file (`com.johngavin.ccusage-refresh.plist`) — this is a launchd manifest that schedules `refresh_and_preserve.sh`; it does not itself contain destructive ops. Launchd plist auditing across `~/Library/LaunchAgents/` is out of scope for v1 (tracked as follow-up below).

## Out-of-Scope (v1 follow-ups)

- Per-project `bin/` audits across `~/docs_gh/*` (beyond `llm/bin/`)
- launchd plists in `~/Library/LaunchAgents/`
- CI/precommit lint enforcement (grep hook that verifies recovery-trail comments near destructive patterns)
