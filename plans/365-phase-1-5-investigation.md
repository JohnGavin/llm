# Phase 1.5 Investigation — #365: Wire codex_with_fallback.sh into roborev

**Date:** 2026-05-30
**Branch:** feat/issue-365-phase-1-5-wire-fallback

---

## Step 1 — Binary Classification

**`/usr/local/bin/roborev`** is a **compiled Mach-O ARM64 binary** (Go, ~30 MB).

```
/usr/local/bin/roborev: Mach-O 64-bit arm64 executable
```

`which roborev` returns nothing — roborev is NOT in the Nix shell PATH; it is
only accessible via its absolute path `/usr/local/bin/roborev`.

**`/usr/local/bin/codex`** is a **bash shell script** (thin npx wrapper):

```bash
#!/bin/bash
exec npx -y @openai/codex "$@"
```

---

## Step 2 — How roborev invokes codex

The binary resolves `codex` via `$PATH` at runtime (confirmed by strings: "executable
file not found in $PATH" error message, `PATH` env var referenced). There is NO
environment variable override such as `CODEX_COMMAND=` or `CODEX_BIN=` in the binary.

Relevant strings found:
- `codex version too old for non-interactive execution; upgrade codex or use --agentic`
- `agent to use (codex, claude-code, gemini, copilot, opencode, cursor, kiro, kilo, pi)`
- `executable file not found in $PATH`

Conclusion: roborev resolves `codex` strictly by PATH lookup. No env-var override path exists.

---

## Step 3 — Caller Inventory

### Scripts calling `roborev review`

| File | Line | Call pattern |
|------|------|--------------|
| `.claude/scripts/roborev_poll_merges.sh` | 140 | `"$ROBOREV" review --since "$last_sha"` (subshell `cd "$root_path"`) |
| `.claude/scripts/roborev_verify_closure.sh` | 297 | `"$ROBOREV_BIN" review --sha "$COMMIT_SHA" --wait` |
| `.claude/scripts/roborev_auto_verify.sh` | 516 | `"$ROBOREV_BIN" review --commit "$COMMIT_SHA"` |
| `bin/roborev_install_post_merge_hook.sh` | 69 | `roborev review --since "${1:-ORIG_HEAD}" --quiet` (hook script, calls bare binary name) |

### Scripts calling `roborev refine` with `--agent codex`

| File | Line | Call pattern |
|------|------|--------------|
| `.claude/scripts/session_end_refine.sh` | 129-134 | `"$ROBOREV" refine --since ... --agent codex` |

### ROBOREV variable resolution

| Script | How `$ROBOREV` / `$ROBOREV_BIN` is set |
|--------|----------------------------------------|
| `roborev_poll_merges.sh` | `ROBOREV="${ROBOREV:-/usr/local/bin/roborev}"` |
| `roborev_verify_closure.sh` | `ROBOREV_BIN="${ROBOREV:-$(command -v roborev ... || echo /usr/local/bin/roborev)}"` |
| `roborev_auto_verify.sh` | `ROBOREV_BIN="${ROBOREV:-$(command -v roborev ... || echo /usr/local/bin/roborev)}"` |
| `session_end_refine.sh` | `ROBOREV="/usr/local/bin/roborev"` (hardcoded) |

### Launchd plists calling roborev directly

| Plist | Calls |
|-------|-------|
| `com.claude.roborev-poll-merges.plist` | Calls `roborev_poll_merges.sh` (script wraps roborev) |
| `com.claude.roborev-metrics-etl.plist` | Contains literal `roborev review` call |
| `com.claude.roborev-daily-backlog.plist` | Calls roborev scripts |
| `com.claude.roborev-agent-health.plist` | Calls `roborev_agent_health.sh` |

**PATH in launchd plists:**
`/Users/johngavin/.nvm/versions/node/v24.13.0/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`

---

## Option Analysis

### Option A — PATH override (symlink `~/.local/bin/codex`)

Pros: minimal code changes.
Cons: system-wide blast radius; affects ALL tools that call `codex`, not just roborev.
Requires: `~/.local/bin/` prepended to PATH in every launchd plist (not currently in PATH).
**NOT recommended.** Too broad, hard to audit.

### Option B — `CODEX_COMMAND=` env var

**Not available.** The roborev binary (compiled Go) has no such env var override.
Ruled out by binary inspection.

### Option C — Wrapper around roborev callers (PATH-shim) — RECOMMENDED

Create a codex shim directory `.claude/scripts/codex_shim/` containing a `codex`
script that execs `codex_with_fallback.sh "$@"`. All callers that invoke roborev
(which then calls codex) prepend this shim directory to PATH before invoking
roborev. Because launchd plists include explicit PATH definitions, we can add the
shim directory there too.

**Why Option C:**
- Scoped to roborev invocations only (not system-wide)
- No binary modification needed
- Works with compiled roborev (PATH lookup)
- Auditable — all callers explicitly set PATH
- The shim is a tiny trampoline to our existing wrapper
- Opt-out via env var `CODEX_SHIM_DISABLE=1` in the shim itself

---

## Decision: Option C

Implement `.claude/scripts/codex_shim/codex` + update callers to prepend shim to PATH.
