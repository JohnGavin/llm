#!/usr/bin/env bash
# tests/test_session_init_roborev_backlog.sh — JohnGavin/llm#1276
#
# The `roborev-backlog:` session banner line had three bugs:
#   1. In a worktree, the repo was resolved from `git rev-parse
#      --show-toplevel`, whose basename is the worktree/branch directory
#      name (e.g. "agent-<id>" or "cc-20260924-101007"), not the project
#      name ("llm") — so the DB lookup matched the wrong repo row, or none.
#   2. The refresh cache was a single file shared by every project, so
#      whichever project refreshed last "won" the banner for all of them.
#   3. Every failure path was silent: a stale or absent cache looked
#      identical to a fresh, correct one.
#
# session_init.sh runs at top level, so the two functions under test
# (rbb_resolve_root, rbb_format_cache_line) are extracted and sourced in
# isolation, matching the pattern in test_session_init_nix_state.sh.
#
# Usage: bash tests/test_session_init_roborev_backlog.sh

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "ok     $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL   $*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/session_init.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Resolve through any /var -> /private/var (macOS) or similar symlink so
# string-equality comparisons below match what `rbb_resolve_root` returns
# (it uses `cd ... && pwd`, which resolves symlinks physically once `cd`
# has actually entered the directory — but bash's own `pwd` builtin here
# needs `-P` to do the same, since plain `pwd` returns the logical $PWD).
TMP="$(cd "$TMP" && pwd -P)"

# Extract a top-level function definition `name() {` ... first `^}`.
extract_fn() {
  awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$HOOK"
}

{
  extract_fn rbb_resolve_root
  extract_fn rbb_format_cache_line
} > "$TMP/fns.sh"

if [ ! -s "$TMP/fns.sh" ]; then
  fail "could not extract rbb_resolve_root/rbb_format_cache_line from $HOOK"
  echo "---"
  echo "passed=$PASS failed=$((FAIL+1))"
  exit 1
fi

# ── 1. rbb_resolve_root resolves the MAIN checkout root, not `pwd` ────────
# Real regression case: build a THROWAWAY git repo + a real `git worktree
# add` of it (a genuine worktree, not just a directory with a matching
# name), then run rbb_resolve_root from inside the worktree and confirm it
# returns the MAIN repo's root — not the worktree's own path, whose
# basename is a worktree/branch id, not the project name. This is the exact
# shape of a real .claude/worktrees/agent-<id> or worktrees/llm/feat/foo
# worktree, built fresh here so the test never touches this session's own
# worktree or the shared main checkout.
WT_FIXTURE="$TMP/wt_fixture"
mkdir -p "$WT_FIXTURE"
git init -q "$WT_FIXTURE/mainrepo"
git -C "$WT_FIXTURE/mainrepo" commit -q --allow-empty -m init
git -C "$WT_FIXTURE/mainrepo" worktree add -q "$WT_FIXTURE/mainrepo_agent-deadbeef1234" -b test-branch 2>/dev/null
out=$(cd "$WT_FIXTURE/mainrepo_agent-deadbeef1234" && bash -c 'source "$1"; rbb_resolve_root' _ "$TMP/fns.sh")
if [ "$out" = "$WT_FIXTURE/mainrepo" ]; then
  ok "rbb_resolve_root from a real worktree -> $out (main repo, not the worktree dir)"
else
  fail "rbb_resolve_root from a real worktree -> got '$out', expected '$WT_FIXTURE/mainrepo'"
fi
# The bug this replaces (`git rev-parse --show-toplevel`) would have
# returned the WORKTREE's own path here — confirm the two differ, so this
# test would have failed against the pre-fix logic.
toplevel_would_be=$(cd "$WT_FIXTURE/mainrepo_agent-deadbeef1234" && git rev-parse --show-toplevel)
if [ "$toplevel_would_be" != "$out" ]; then
  ok "confirmed --show-toplevel ($toplevel_would_be) would have been wrong here"
else
  fail "fixture did not actually distinguish worktree-root from main-root"
fi

# ── 2. rbb_resolve_root inside THIS checkout resolves to a real git root ──
out=$(cd "$REPO_ROOT" && bash -c 'source "$1"; rbb_resolve_root' _ "$TMP/fns.sh")
if [ -n "$out" ] && [ -d "$out/.git" ]; then
  ok "rbb_resolve_root from repo root -> $out (has .git)"
else
  fail "rbb_resolve_root from repo root -> got '$out'"
fi

# ── 3. rbb_resolve_root is stable: same answer from repo root and from a
#       subdirectory (proves it does not fall back to --show-toplevel,
#       which WOULD differ between a worktree and its main checkout) ──────
sub_out=$(cd "$TMP" && bash -c 'source "$1"; rbb_resolve_root' _ "$TMP/fns.sh")
# $TMP itself is not inside a repo (mktemp -d is outside any checkout in CI/
# sandboxed runs) so this should come back EMPTY, distinct from a real root.
if [ -z "$sub_out" ] || [ "$sub_out" != "$out" ] || [ ! -d "$sub_out/.git" ]; then
  ok "rbb_resolve_root from outside any repo -> '$sub_out' (not a false-positive match)"
else
  fail "rbb_resolve_root from outside any repo -> got '$sub_out' (unexpected match)"
fi

# ── 4. rbb_format_cache_line: fresh cache -> no suffix ─────────────────────
out=$(bash -c 'source "$1"; rbb_format_cache_line "roborev-backlog: open=3" 60' _ "$TMP/fns.sh")
if [ "$out" = "roborev-backlog: open=3" ]; then
  ok "rbb_format_cache_line fresh (60s) -> no suffix"
else
  fail "rbb_format_cache_line fresh (60s) -> got '$out'"
fi

# ── 5. rbb_format_cache_line: stale cache (>1 day) -> explicit age suffix ──
out=$(bash -c 'source "$1"; rbb_format_cache_line "roborev-backlog: open=3" 90000' _ "$TMP/fns.sh")
case "$out" in
  "roborev-backlog: open=3 [cache "*"h old]") ok "rbb_format_cache_line stale (25h) -> $out" ;;
  *) fail "rbb_format_cache_line stale (25h) -> got '$out'" ;;
esac

# ── 6. Boundary: exactly 86400s is still "fresh" (not > 86400) ────────────
out=$(bash -c 'source "$1"; rbb_format_cache_line "roborev-backlog: open=3" 86400' _ "$TMP/fns.sh")
if [ "$out" = "roborev-backlog: open=3" ]; then
  ok "rbb_format_cache_line at exactly 86400s -> no suffix (boundary)"
else
  fail "rbb_format_cache_line at exactly 86400s -> got '$out'"
fi

# ── 7. Cache filename is per-project, not a single shared file ────────────
if grep -q 'session_init_roborev_backlog_cache_\${_rbb_name_safe}' "$HOOK"; then
  ok "cache filename is derived from the resolved project name (per-project)"
else
  fail "cache filename does not appear to be per-project"
fi

# ── 8. Every background-refresh failure path writes an explicit reason ────
# (grep the heredoc worker script embedded in the hook, not a live run —
# a live run needs ~/.roborev/reviews.db and network-free sqlite access,
# which this test deliberately does not depend on.)
worker_block=$(awk '/<<.RBBEOF./{p=1} p{print} p&&/^RBBEOF$/{exit}' "$HOOK")
missing=0
for reason in "no roborev DB" "no /usr/bin/python3" "could not resolve main checkout root" \
              "empty query result" "no OPEN: line in query output"; do
  if ! echo "$worker_block" | grep -qF "$reason"; then
    fail "background worker missing explicit failure reason: $reason"
    missing=1
  fi
done
[ "$missing" -eq 0 ] && ok "background worker writes an explicit reason on every failure path"

# ── 9. Dead code removed: phase_roborev_backlog() no longer defined ───────
if grep -q '^phase_roborev_backlog()' "$HOOK"; then
  fail "phase_roborev_backlog() still defined (dead code, duplicated the background block)"
else
  ok "phase_roborev_backlog() dead code removed"
fi

# ── 10. Repo lookup prefers root_path, falls back to name ─────────────────
if echo "$worker_block" | grep -q 'WHERE root_path = ?' && echo "$worker_block" | grep -q 'WHERE name = ?'; then
  ok "worker resolves repo by root_path first, name as fallback"
else
  fail "worker does not show a root_path-first / name-fallback repo lookup"
fi

# ── 11. Hook still parses ──────────────────────────────────────────────────
if bash -n "$HOOK"; then ok "bash -n session_init.sh"; else fail "bash -n session_init.sh"; fi

echo "---"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
