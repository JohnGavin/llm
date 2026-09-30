#!/usr/bin/env bash
# tests/test_session_init_branch_harvest_cache.sh
#
# Bug: session_init.sh Phase 7g kept ONE global branch-harvest cache file,
# printed it immediately, then refreshed it for the current cwd. A session in
# repo A therefore printed repo B's last audit result (an llm session showed
# statues_named_john's flagged branches).
#
# The fix keys the cache per repo (main-checkout identity, so worktrees of one
# repo share a cache) and labels the printed line with the repo name.
#
# session_init.sh runs at top level, so the Phase 7g cache-read block is
# extracted (marker to marker) and evaluated in isolation with HOME redirected
# to a scratch dir. The same test runs against any hook via HOOK=<path>, which
# is how it was falsified against the unfixed hook (see PR body).
#
# Usage: bash tests/test_session_init_branch_harvest_cache.sh

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "ok     $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL   $*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK:-$REPO_ROOT/.claude/hooks/session_init.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

# Extract from the Phase 7g cache-read start to just before the refresh launch.
# Start marker: the first line mentioning the harvest cache variable's
# definition context. We take everything from the "sinit_repo_key() {" line
# (fixed hook) or the "_bharvest_cache=" line (unfixed hook) through the line
# before "_bharvest_script=".
awk '
  /^sinit_repo_key\(\) \{/ {p=1}
  /^_bharvest_cache=/ {p=1}
  /^_bharvest_script=/ {p=0}
  p {print}
' "$HOOK" > "$TMP/block.sh"

if ! grep -q '_bharvest_cache=' "$TMP/block.sh"; then
  fail "could not extract the Phase 7g cache block from $HOOK"
  echo "---"; echo "passed=$PASS failed=$((FAIL+1))"; exit 1
fi

HOME_T="$TMP/home"
mkdir -p "$HOME_T/.claude/logs"

# Two independent repos plus a real worktree of repo A.
git init -q "$TMP/repoA"; git -C "$TMP/repoA" commit -q --allow-empty -m init
git init -q "$TMP/repoB"; git -C "$TMP/repoB" commit -q --allow-empty -m init
git -C "$TMP/repoA" worktree add -q "$TMP/repoA_wt" -b wt-branch 2>/dev/null

# run_block <dir>: print the banner output of the block in <dir>.
run_block() {
  (cd "$1" && HOME="$HOME_T" bash -c 'source "$1"' _ "$TMP/block.sh" 2>/dev/null)
}
# cache_path <dir>: the cache file the block would use in <dir>.
cache_path() {
  (cd "$1" && HOME="$HOME_T" bash -c 'source "$1"; printf "%s" "$_bharvest_cache"' _ "$TMP/block.sh" 2>/dev/null)
}

# Simulate repo B's background refresh having written its result.
PATH_B="$(cache_path "$TMP/repoB")"
printf 'branch-harvest: 3 unmerged feat branches flagged\n  feat/statues-only-in-B\n' > "$PATH_B"

# 1. Repo A's session must NOT print repo B's cached harvest output.
out_a="$(run_block "$TMP/repoA")"
if printf '%s' "$out_a" | grep -q 'statues-only-in-B'; then
  fail "repo A printed repo B's cached harvest output: $out_a"
else
  ok "repo A does not print repo B's cached harvest output"
fi

# 2. Repo B's own session still prints its cache, labelled with the repo name.
out_b="$(run_block "$TMP/repoB")"
if printf '%s' "$out_b" | grep -q 'statues-only-in-B'; then
  ok "repo B still prints its own cached harvest output"
else
  fail "repo B lost its own cache output: '$out_b'"
fi
if printf '%s' "$out_b" | head -1 | grep -q '^branch-harvest\[repoB\]:'; then
  ok "printed line is labelled with the repo name"
else
  fail "first line not labelled branch-harvest[repoB]: '$(printf '%s' "$out_b" | head -1)'"
fi

# 3. A worktree of repo A shares repo A's cache (main-checkout identity).
if [ "$(cache_path "$TMP/repoA")" = "$(cache_path "$TMP/repoA_wt")" ]; then
  ok "worktree of repo A shares repo A's cache path"
else
  fail "worktree cache path differs from main checkout's"
fi

echo "---"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
