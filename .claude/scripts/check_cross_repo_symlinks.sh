#!/usr/bin/env bash
# check_cross_repo_symlinks.sh — detect tracked symlinks that escape this git repo.
#
# A "cross-repo symlink" is a file tracked as a git symlink (mode 120000) whose
# real destination — after following the full symlink chain — lives outside this
# repository's working-tree root. Such symlinks create sandbox-escape hazards in
# agent worktrees: an agent that writes through the symlink modifies files in a
# DIFFERENT repository without knowing it (llm#692).
#
# Algorithm:
#   1. List every file tracked as a symlink (git ls-files --stage, mode 120000).
#   2. For RELATIVE symlinks: use realpath -m (no filesystem access) to compute
#      the lexical absolute path and compare with TOPLEVEL.
#   3. For ABSOLUTE symlinks: attempt realpath (follows the full chain, requires
#      the path to exist). If it resolves to outside TOPLEVEL → cross-repo.
#      If realpath fails (broken / CI environment) → WARN and continue.
#   4. Compare each cross-repo finding against the allowlist. Allowlisted entries
#      are WARN-only; non-allowlisted entries set exit code 1.
#
# Usage:
#   check_cross_repo_symlinks.sh                  # uses default allowlist
#   check_cross_repo_symlinks.sh --allowlist FILE # custom allowlist
#   check_cross_repo_symlinks.sh --selftest       # built-in regression test
#
# Allowlist format: one repo-root-relative path per line; # comments; blank lines OK.
#
# Exit codes: 0 = clean (or only allowlisted WARNs); 1 = non-allowlisted cross-repo
#             symlink found; 2 = usage/environment error.
#
# Requires: bash 4+, git, GNU realpath (coreutils).
# llm#692

set -uo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ALLOWLIST="$SCRIPT_DIR/.cross-repo-symlink-allowlist"

usage() {
  echo "Usage: $(basename "$0") [--allowlist FILE] [--selftest]" >&2
  exit 2
}

# Read allowlist file → emit one canonical path per line (strips # comments, blanks)
read_allowlist() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  grep -v '^\s*#' "$file" | grep -v '^\s*$' | sed 's/^\s*//;s/\s*$//'
}

is_allowlisted() {
  local path="$1" allowlist="$2"
  [[ -f "$allowlist" ]] || return 1
  local pattern
  while IFS= read -r pattern; do
    [[ "$path" == "$pattern" ]] && return 0
  done < <(read_allowlist "$allowlist")
  return 1
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

selftest() {
  local tmp fail=0
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  # Create a fake git repo
  git -C "$tmp" init -q
  git -C "$tmp" config user.email "test@test.com"
  git -C "$tmp" config user.name "Test"

  # Relative intra-repo symlink (should pass)
  mkdir -p "$tmp/sub"
  echo "content" > "$tmp/target.txt"
  ln -s "../target.txt" "$tmp/sub/relative-ok.txt"
  git -C "$tmp" add sub/relative-ok.txt
  git -C "$tmp" add target.txt

  # Absolute cross-repo symlink (should fail)
  ln -s "/tmp/some-other-repo/file.txt" "$tmp/cross-repo-trap.sh"
  git -C "$tmp" add cross-repo-trap.sh

  # Allowlist file
  local al="$tmp/allowlist.txt"
  echo "# known trap" > "$al"
  echo "cross-repo-trap.sh" >> "$al"
  git -C "$tmp" add cross-repo-trap.sh

  git -C "$tmp" commit -q -m "selftest setup"

  # --- Test 1: no allowlist → should FAIL (exit 1) because cross-repo-trap.sh
  local out rc
  rc=0
  out=$(
    _run_check "$tmp" "$tmp" "/dev/null"
  ) || rc=$?
  if [[ $rc -eq 1 ]]; then
    echo "selftest PASS 1: exit 1 on non-allowlisted cross-repo symlink"
  else
    echo "selftest FAIL 1: expected exit 1, got $rc"
    fail=1
  fi

  # --- Test 2: with allowlist → should PASS (exit 0, only WARN)
  rc=0
  out=$(
    _run_check "$tmp" "$tmp" "$al"
  ) || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "selftest PASS 2: exit 0 when cross-repo symlink is allowlisted"
  else
    echo "selftest FAIL 2: expected exit 0 with allowlist, got $rc (out=$out)"
    fail=1
  fi

  # --- Test 3: allowlisted trap should emit WARN line
  if echo "$out" | grep -q "WARN"; then
    echo "selftest PASS 3: WARN emitted for allowlisted cross-repo symlink"
  else
    echo "selftest FAIL 3: expected WARN in output, got: $out"
    fail=1
  fi

  return $fail
}

# Core check function, called both by main and selftest
# Arguments: $1 = worktree toplevel, $2 = repo root (main checkout root), $3 = allowlist
_run_check() {
  local toplevel="$1" repo_root="$2" allowlist="$3"
  local errors=0 warns=0 f full target computed rp

  while IFS= read -r f; do
    full="$toplevel/$f"
    [[ -L "$full" ]] || continue   # tracked as symlink but not on disk; skip silently

    target=$(readlink "$full")

    # ---- Relative symlinks: use pure path arithmetic (realpath -m) ----
    if [[ "$target" != /* ]]; then
      computed=$(realpath -m "$(dirname "$full")/$target")
      # OK if within repo root (covers main checkout AND all worktrees)
      if [[ "$computed" != "$repo_root"/* ]] && [[ "$computed" != "$repo_root" ]]; then
        if is_allowlisted "$f" "$allowlist"; then
          echo "  WARN (allowlisted): $f"
          echo "    -> $computed (relative escape outside repo)"
          warns=$((warns + 1))
        else
          echo "  FAIL: $f"
          echo "    -> $computed (relative escape outside repo — not allowlisted)"
          errors=$((errors + 1))
        fi
      fi
      continue
    fi

    # ---- Absolute symlinks: follow full chain with realpath ----
    if rp=$(realpath "$full" 2>/dev/null); then
      # OK if the full resolved chain stays within repo root
      if [[ "$rp" != "$repo_root"/* ]] && [[ "$rp" != "$repo_root" ]]; then
        if is_allowlisted "$f" "$allowlist"; then
          echo "  WARN (allowlisted): $f"
          echo "    -> $rp (cross-repo, pending de-symlink)"
          warns=$((warns + 1))
        else
          echo "  FAIL: $f"
          echo "    -> $rp (cross-repo symlink — not allowlisted)"
          errors=$((errors + 1))
        fi
      fi
    else
      # Can't resolve: broken or path doesn't exist (expected in CI for absolute paths)
      echo "  WARN (unresolvable): $f"
      echo "    -> $target (absolute target not reachable in this environment)"
      warns=$((warns + 1))
    fi

  done < <(git -C "$toplevel" ls-files --stage | awk '$1 == "120000" {print $4}')

  echo ""
  echo "Summary: $errors failure(s), $warns warning(s)"
  if [[ $errors -gt 0 ]]; then
    echo "RESULT: FAIL — $errors non-allowlisted cross-repo symlink(s)"
    return 1
  fi
  echo "RESULT: OK — no non-allowlisted cross-repo symlinks"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

ALLOWLIST="$DEFAULT_ALLOWLIST"
SELFTEST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allowlist)
      shift
      [[ $# -gt 0 ]] || usage
      ALLOWLIST="$1"
      ;;
    --selftest)
      SELFTEST=1
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
  shift
done

if [[ $SELFTEST -eq 1 ]]; then
  selftest
  exit $?
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "check_cross_repo_symlinks: not inside a git repository" >&2
  exit 2
fi

TOPLEVEL=$(git rev-parse --show-toplevel)

# REPO_ROOT is the main checkout root. In a git worktree, --show-toplevel gives
# the worktree directory; --git-common-dir gives the main repo's .git path.
# Using the parent of --git-common-dir as the boundary means symlinks that
# resolve to other worktrees of THE SAME repository are NOT flagged as cross-repo.
# In a plain (non-worktree) checkout, both values resolve to the same directory.
REPO_ROOT=$(realpath "$(git rev-parse --git-common-dir)/..")

echo "check_cross_repo_symlinks: scanning $TOPLEVEL"
echo "repo root (boundary): $REPO_ROOT"
echo "allowlist: $ALLOWLIST"
echo ""

_run_check "$TOPLEVEL" "$REPO_ROOT" "$ALLOWLIST"
