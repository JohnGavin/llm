#!/usr/bin/env bash
# file_protection.sh - Block or warn on edits to critical files
# Hook: PreToolUse (Edit, Write)
# Exit 2 = BLOCK (auto-generated files, main-checkout .claude/). Exit 0 = WARN/ALLOW.
#
# Self-test: COMPOUND_GUARD_SELFTEST=1 bash file_protection.sh
#
# Sources: llm#572 (worktree-aware .claude/ protection)
#          llm#601 (orchestrator bounded exceptions + linked-worktree allow)
#          agent-identity-and-task-scopes rule (symlink-trap Pattern 2)

set -euo pipefail

# ─── Self-test harness (CLAUDE_HOOK_SELFTEST=1) ──────────────────────────────
if [ "${CLAUDE_HOOK_SELFTEST:-0}" = "1" ]; then
  PASS=0; FAIL=0; TOTAL=11
  HOOK_PATH="$0"

  # Run the hook in a subprocess with synthetic JSON input.
  # Returns "block" if hook exits 2, "warn" if exits 0 with WARN output,
  # "allow" if exits 0 without WARN output.
  _check_hook() {
    local file_path="$1"
    local tool_name="${2:-Edit}"
    local tmpjson rc out
    tmpjson=$(mktemp /tmp/fp_selftest_XXXXXX.json)
    printf '{"tool_name": "%s", "tool_input": {"file_path": "%s"}}' \
      "$tool_name" "$file_path" > "$tmpjson"
    rc=0
    out=$(CLAUDE_HOOK_SELFTEST=0 bash "$HOOK_PATH" < "$tmpjson" 2>&1) || rc=$?
    rm -f "$tmpjson"
    if [ "$rc" = "2" ]; then
      echo "block"
    elif echo "$out" | grep -q "^WARN:"; then
      echo "warn"
    else
      echo "allow"
    fi
  }

  _ok()   { PASS=$((PASS+1)); printf '  %d/%d PASS  %s\n' "$PASS" "$TOTAL" "$*"; }
  _fail() { FAIL=$((FAIL+1)); printf '  %d/%d FAIL  %s\n' "$((PASS+FAIL))" "$TOTAL" "$*"; }

  # Case 1 — regression: main checkout .claude/ → BLOCK
  r=$(_check_hook "/Users/johngavin/docs_gh/llm/.claude/scripts/foo.sh")
  if [ "$r" = "block" ]; then _ok "main checkout .claude/scripts/ → block"
  else _fail "main checkout .claude/scripts/ expected block, got $r"; fi

  # Case 2 — new: agent worktree own .claude/ (direct path, no symlink) → ALLOW
  r=$(_check_hook "/Users/johngavin/docs_gh/llm/.claude/worktrees/agent-abc123/.claude/scripts/foo.sh")
  if [ "$r" = "allow" ]; then _ok "worktree .claude/scripts/ (real path) → allow"
  else _fail "worktree .claude/scripts/ expected allow, got $r"; fi

  # Case 3 — already worked but now verify: regular worktree R/ file → ALLOW
  # Path goes through repo's .claude/worktrees/agent-* but targets R/ outside
  # the worktree's own .claude/ — must be permitted.
  r=$(_check_hook "/Users/johngavin/docs_gh/llm/.claude/worktrees/agent-abc123/R/foo.R")
  if [ "$r" = "allow" ]; then _ok "worktree R/foo.R (not in .claude/) → allow"
  else _fail "worktree R/ expected allow, got $r"; fi

  # Case 4 — symlink-trap: path that resolves to main checkout .claude/ → BLOCK
  # readlink -f of a symlink <worktree>/.claude/scripts/foo.sh pointing to the
  # main checkout produces the canonical form we test here.
  r=$(_check_hook "/Users/johngavin/docs_gh/llm/.claude/hooks/session_init.sh")
  if [ "$r" = "block" ]; then _ok "symlink-resolved main checkout .claude/hooks/ → block"
  else _fail "symlink-resolved main checkout .claude/hooks/ expected block, got $r"; fi

  # Case 5 — regression: NAMESPACE (auto-generated) → BLOCK
  r=$(_check_hook "/Users/johngavin/docs_gh/llm/NAMESPACE")
  if [ "$r" = "block" ]; then _ok "NAMESPACE → block"
  else _fail "NAMESPACE expected block, got $r"; fi

  # Case 6 — symlink-trap via ~/.claude path:
  # ~/.claude/scripts/ is a symlink to /Users/johngavin/docs_gh/llm/.claude/scripts/.
  # After readlink -f, an edit target of ~/.claude/scripts/foo.sh resolves to the
  # main checkout path. We test the resolved canonical form.
  r=$(_check_hook "/Users/johngavin/docs_gh/llm/.claude/scripts/bar.sh")
  if [ "$r" = "block" ]; then _ok "~/.claude/scripts/ resolved to main checkout → block"
  else _fail "~/.claude/scripts/ expected block, got $r"; fi

  # Cases 7-10 — llm#601: orchestrator bounded exceptions in the MAIN
  # checkout (auto-delegation rule) → ALLOW
  r=$(_check_hook "/Users/johngavin/docs_gh/llm/.claude/CURRENT_WORK.md")
  if [ "$r" = "allow" ]; then _ok "main checkout .claude/CURRENT_WORK.md → allow"
  else _fail "CURRENT_WORK.md expected allow, got $r"; fi

  r=$(_check_hook "/Users/johngavin/docs_gh/llm/.claude/CLAUDE.md")
  if [ "$r" = "allow" ]; then _ok "main checkout .claude/CLAUDE.md → allow"
  else _fail ".claude/CLAUDE.md expected allow, got $r"; fi

  r=$(_check_hook "/Users/johngavin/docs_gh/llm/.claude/rules/some-rule.md")
  if [ "$r" = "allow" ]; then _ok "main checkout .claude/rules/*.md → allow"
  else _fail "rules/*.md expected allow, got $r"; fi

  r=$(_check_hook "/Users/johngavin/docs_gh/llm/.claude/memory/some-note.md")
  if [ "$r" = "allow" ]; then _ok "main checkout .claude/memory/*.md → allow"
  else _fail "memory/*.md expected allow, got $r"; fi

  # Case 11 — llm#601: linked worktree's own .claude/scripts/ (branch copy,
  # ships via PR) → ALLOW. Build a real repo + worktree fixture so the
  # git-dir != git-common-dir detection runs against actual git state.
  _fix=$(mktemp -d /tmp/fp_wtfix_XXXXXX)
  git init -q "$_fix/main"
  git -C "$_fix/main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$_fix/main" worktree add -q -b fp-selftest "$_fix/wt" >/dev/null 2>&1
  mkdir -p "$_fix/wt/.claude/scripts"
  touch "$_fix/wt/.claude/scripts/foo.sh"
  r=$(_check_hook "$_fix/wt/.claude/scripts/foo.sh")
  if [ "$r" = "allow" ]; then _ok "linked worktree .claude/scripts/ → allow"
  else _fail "linked worktree .claude/scripts/ expected allow, got $r"; fi
  git -C "$_fix/main" worktree remove --force "$_fix/wt" >/dev/null 2>&1 || true
  rm -rf "$_fix"

  printf '\nfile_protection selftest: %d/%d PASS\n' "$PASS" "$TOTAL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ─── Main hook logic ─────────────────────────────────────────────────────────

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -z "$FILE_PATH" ] && exit 0

# ─── Resolve symlinks before ANY path check ──────────────────────────────────
# CRITICAL — agent-identity-and-task-scopes rule, symlink-trap Pattern 2 (#517):
# A worktree may contain a path like <worktree>/.claude/scripts/foo.sh that is
# a SYMLINK resolving to ~/docs_gh/llm/.claude/scripts/foo.sh (the main
# checkout). If we only checked the raw path, we would permit the write because
# it appears to be inside the worktree. Resolving symlinks first ensures we
# evaluate the CANONICAL path — where the bytes would actually land.
#
# Implementation: `readlink -f` resolves all symlink components. If the command
# fails (path does not exist yet — legitimate Write to a new file), we fall back
# to the unresolved path; the remaining pattern checks still apply.
RESOLVED_PATH=""
if command -v readlink >/dev/null 2>&1; then
  RESOLVED_PATH=$(readlink -f "$FILE_PATH" 2>/dev/null) || RESOLVED_PATH="$FILE_PATH"
fi
# Use resolved path for all subsequent checks; fall back to raw path if empty.
TARGET_PATH="${RESOLVED_PATH:-$FILE_PATH}"

# ─── Guard: .claude/ in MAIN CHECKOUT — block; in agent worktree — allow ─────
# The hook protects the canonical main-checkout .claude/ from accidental agent
# edits. Agent worktrees have their OWN .claude/ copy — those edits are permitted.
#
# Approach A (llm#572): pattern-match on the RESOLVED path.
#
# Decision logic (applied against TARGET_PATH after symlink resolution):
#
#   *.claude/worktrees/agent-*/*  →  PERMIT
#     The path goes THROUGH the repo's /.claude/worktrees/agent-*/ directory.
#     Everything under that prefix — whether it's the worktree's own .claude/,
#     R/, tests/, etc. — belongs to the agent's isolated sandbox.
#
#   */.claude/*  (not matched above)  →  BLOCK
#     The path is in a .claude/ directory that is NOT inside a worktrees/agent-*/
#     prefix. After symlink resolution, this is the main checkout's .claude/
#     (or a symlink-trapped path that resolves there).
#
# Why this ordering matters:
#   A path like /repo/.claude/worktrees/agent-abc123/R/foo.R contains /.claude/
#   (the repo's own .claude dir is part of the worktrees/ container), but the
#   target file is NOT inside .claude/. The first pattern permits it correctly
#   because the path passes THROUGH the worktrees/agent-* prefix.
#
# Why Approach A over Approach B (git rev-parse subprocess):
#   ~50 ms faster per hook call (no subprocess fork for git). The harness's
#   agent naming convention (`agent-<hex-id>`) is stable (worktree-location
#   rule). If the convention changes, update the pattern below.
#
# Symlink-trap preservation (Pattern 2, agent-identity-and-task-scopes #517):
#   Because we apply this check against TARGET_PATH (the readlink-resolved
#   canonical path), a path like <worktree>/.claude/scripts/foo.sh that is a
#   symlink to the main checkout will resolve to the main-checkout form and be
#   BLOCKED. This is correct — the bytes would land in the main checkout's
#   .claude/, not the worktree.
case "$TARGET_PATH" in
  */.claude/worktrees/agent-*/*)
    # Path goes through a known agent worktree — PERMIT.
    # The bytes land in the agent's isolated sandbox, not in the main checkout.
    ;;
  */.claude/*)
    # Candidate block. Two exemptions apply before blocking (llm#601):
    #
    # (a) Orchestrator bounded exceptions (auto-delegation rule): prose and
    #     session-state files the orchestrator owns and edits directly, even
    #     in the main checkout. Scripts and hooks are NOT in this list —
    #     those must ship via a worktree branch + PR.
    _claude_rel="${TARGET_PATH#*/.claude/}"
    case "$_claude_rel" in
      CURRENT_WORK.md|CLAUDE.md|rules/*.md|memory/*.md)
        exit 0
        ;;
    esac

    # (b) Linked worktree (session sibling, ~/worktrees/<proj>/<branch>/):
    #     its .claude/ is a branch COPY — edits land on that branch and ship
    #     via PR, never directly into the canonical config. A checkout is a
    #     linked worktree iff git-dir != git-common-dir. Only paths already
    #     matching */.claude/* pay this subprocess cost.
    _repo_prefix="${TARGET_PATH%%/.claude/*}"
    if [ -d "$_repo_prefix" ]; then
      _git_dir=$(git -C "$_repo_prefix" rev-parse --git-dir 2>/dev/null || echo "")
      _git_common=$(git -C "$_repo_prefix" rev-parse --git-common-dir 2>/dev/null || echo "")
      if [ -n "$_git_dir" ] && [ "$_git_dir" != "$_git_common" ]; then
        exit 0
      fi
    fi

    # .claude/ in main checkout (or symlink-trapped path) — BLOCK.
    # Message goes to stderr so the harness surfaces it (llm#601 fix 2).
    {
      echo "BLOCKED: $FILE_PATH targets the canonical .claude/ (resolved: $TARGET_PATH)"
      echo "Scripts/hooks changes must go via a worktree branch + PR."
      echo "Orchestrator prose exceptions: CURRENT_WORK.md, CLAUDE.md, rules/*.md, memory/*.md."
      echo "See: agent-identity-and-task-scopes rule, llm#572, llm#601."
    } >&2
    exit 2
    ;;
esac

# ─── Auto-generated files: BLOCK (exit 2) ────────────────────────────────────
# These are overwritten by devtools::document()
BLOCK_PATTERNS=("NAMESPACE" "man/")
for pattern in "${BLOCK_PATTERNS[@]}"; do
  if [[ "$TARGET_PATH" == *"$pattern"* ]]; then
    {
      echo "BLOCKED: $FILE_PATH is auto-generated (matched: $pattern)"
      echo "Run devtools::document() instead of editing directly."
    } >&2
    exit 2
  fi
done

# ─── raw/ folders are append-only: BLOCK edits/overwrites to existing files ──
# New files (Write to non-existent path) are allowed.
# See: raw-folder-readonly rule
if [[ "$TARGET_PATH" == *"/raw/"* ]] && [ -f "$TARGET_PATH" ]; then
  TOOL_NAME=$(echo "$INPUT" | sed -n 's/.*"tool_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write" ]]; then
    {
      echo "BLOCKED: $FILE_PATH is in a raw/ folder (append-only)"
      echo "raw/ files are the source of truth and must not be overwritten."
      echo "See: raw-folder-readonly rule. To redact PHI, save to raw/anonymized/."
    } >&2
    exit 2
  fi
fi

# ─── Config/infrastructure files: WARN (exit 0) — allow but flag ─────────────
WARN_PATTERNS=("inst/extdata/" "default.nix" "_pkgdown.yml" ".github/workflows/")
for pattern in "${WARN_PATTERNS[@]}"; do
  if [[ "$TARGET_PATH" == *"$pattern"* ]]; then
    echo "WARN: Editing protected path: $FILE_PATH (matched: $pattern)"
    exit 0
  fi
done

exit 0
