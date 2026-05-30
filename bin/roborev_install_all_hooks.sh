#!/usr/bin/env bash
# roborev_install_all_hooks.sh <repo-path>
#
# Unified per-repo hook installer.  Installs ALL three roborev hooks for one
# repository in a single idempotent command:
#
#   1. post-merge hook   (bin/roborev_install_post_merge_hook.sh)   — llm#217
#   2. commit-msg hook   (bin/roborev_install_commit_msg_hook.sh)   — llm#352
#   3. post-commit hook  (bin/roborev_install_post_commit_verifier.sh) — llm#353
#
# If an individual installer is absent (sibling PR not yet merged), the
# unified installer emits a WARNING and continues — it never hard-fails on a
# missing child installer.  This makes Component 8 independently deployable.
#
# Idempotent: re-running on a repo that already has all hooks is safe.
#
# Safety: inherits each child installer's own safety checks (unrecognised
# existing hook detection, DB migration validation, etc.).
#
# Usage:
#   bin/roborev_install_all_hooks.sh /path/to/repo
#   bin/roborev_install_all_hooks.sh --dry-run /path/to/repo
#
# Options:
#   --dry-run   Pass --dry-run through to each child installer (no files written)
#   --help      Show this message
#
# Self-test:
#   ROBOREV_INSTALL_ALL_SELFTEST=1 bash bin/roborev_install_all_hooks.sh
#
# Part of: llm#356 Component 8
# Tracked in llm#163 automation loop

set -uo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# SCRIPT_DIR may be overridden by tests (via env var) or defaults to this
# script's own directory.  The env-var override lets tests supply stub child
# installers without modifying the real bin/ directory.
if [ -z "${SCRIPT_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//' | head -30
  exit 0
}

# ── Self-test ─────────────────────────────────────────────────────────────────

_selftest() {
  local pass=0 fail=0
  _t() {
    local label="$1" expected="$2" got="$3"
    if [ "$got" = "$expected" ]; then
      pass=$((pass+1))
      echo "  PASS [$label]"
    else
      fail=$((fail+1))
      echo "  FAIL [$label]: expected='$expected' got='$got'"
    fi
  }

  # Create a minimal git repo with stub child installers
  local tmpdir
  tmpdir=$(mktemp -d)
  local repo="$tmpdir/test_repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@test"
  git -C "$repo" config user.name "Test"
  touch "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "init"

  local stub_dir="$tmpdir/bin"
  mkdir -p "$stub_dir"

  # Stub installer: post-merge (succeeds, writes marker)
  cat > "$stub_dir/roborev_install_post_merge_hook.sh" <<'STUB'
#!/usr/bin/env bash
# Stub: records invocation
echo "OK: stub post-merge hook installed in $1"
exit 0
STUB
  chmod +x "$stub_dir/roborev_install_post_merge_hook.sh"

  # Stub installer: commit-msg (succeeds)
  cat > "$stub_dir/roborev_install_commit_msg_hook.sh" <<'STUB'
#!/usr/bin/env bash
echo "OK: stub commit-msg hook installed in $1"
exit 0
STUB
  chmod +x "$stub_dir/roborev_install_commit_msg_hook.sh"

  # Stub installer: post-commit verifier (succeeds)
  cat > "$stub_dir/roborev_install_post_commit_verifier.sh" <<'STUB'
#!/usr/bin/env bash
echo "OK: stub post-commit hook installed in $1"
exit 0
STUB
  chmod +x "$stub_dir/roborev_install_post_commit_verifier.sh"

  # Test 1: all three stubs present — installer exits 0
  local rc=0
  SCRIPT_DIR="$stub_dir" bash "$0" "$repo" 2>/dev/null || rc=$?
  _t "all stubs present: exit 0" "0" "$rc"

  # Test 2: missing commit-msg installer — exits 0 (skip with warning)
  rm -f "$stub_dir/roborev_install_commit_msg_hook.sh"
  rc=0
  SCRIPT_DIR="$stub_dir" bash "$0" "$repo" 2>/dev/null || rc=$?
  _t "missing commit-msg: exit 0 (skip)" "0" "$rc"
  # Restore
  cat > "$stub_dir/roborev_install_commit_msg_hook.sh" <<'STUB'
#!/usr/bin/env bash
echo "OK: stub commit-msg hook installed in $1"
exit 0
STUB
  chmod +x "$stub_dir/roborev_install_commit_msg_hook.sh"

  # Test 3: missing post-commit verifier — exits 0 (skip)
  rm -f "$stub_dir/roborev_install_post_commit_verifier.sh"
  rc=0
  SCRIPT_DIR="$stub_dir" bash "$0" "$repo" 2>/dev/null || rc=$?
  _t "missing post-commit: exit 0 (skip)" "0" "$rc"

  # Test 4: non-git directory — exits 1
  rc=0
  SCRIPT_DIR="$stub_dir" bash "$0" "$tmpdir" 2>/dev/null || rc=$?
  _t "non-git dir: exit 1" "1" "$rc"

  # Test 5: missing repo path argument — exits 1
  rc=0
  SCRIPT_DIR="$stub_dir" bash "$0" 2>/dev/null || rc=$?
  _t "no args: exit 1" "1" "$rc"

  rm -rf "$tmpdir"
  echo ""
  echo "${pass}/$((pass+fail)) PASS"
  [ "$fail" -eq 0 ] && return 0 || return 1
}

if [ "${ROBOREV_INSTALL_ALL_SELFTEST:-0}" = "1" ]; then
  _selftest
  exit $?
fi

# ── Argument parsing ──────────────────────────────────────────────────────────

DRY_RUN_FLAG=""
REPO_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN_FLAG="--dry-run" ; shift ;;
    -h|--help)  usage ;;
    -*)         echo "ERROR: unknown option: $1" >&2; exit 1 ;;
    *)
      if [ -z "$REPO_PATH" ]; then
        REPO_PATH="$1"
      else
        echo "ERROR: unexpected argument '$1' (repo path already set to '$REPO_PATH')" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "$REPO_PATH" ]; then
  echo "ERROR: repo path argument required" >&2
  echo "Usage: $0 [--dry-run] <repo-path>" >&2
  exit 1
fi

if [ ! -d "$REPO_PATH/.git" ]; then
  echo "ERROR: not a git repository (no .git/ directory): $REPO_PATH" >&2
  exit 1
fi

# ── Helper: call child installer, skip gracefully if missing ─────────────────

# Counters
installed=0
skipped=0
failed=0

_call_installer() {
  local installer_name="$1"
  local installer_path="$SCRIPT_DIR/$installer_name"

  if [ ! -f "$installer_path" ]; then
    echo "WARNING: $installer_name not found at $installer_path — skipping (PR not yet merged?)" >&2
    skipped=$((skipped+1))
    return 0
  fi

  if [ ! -x "$installer_path" ]; then
    chmod +x "$installer_path" 2>/dev/null || true
  fi

  local output rc
  rc=0
  # shellcheck disable=SC2086
  output=$("$installer_path" $DRY_RUN_FLAG "$REPO_PATH" 2>&1) || rc=$?

  if [ "$rc" -ne 0 ]; then
    echo "FAILED: $installer_name in $REPO_PATH (exit $rc)" >&2
    echo "$output" >&2
    failed=$((failed+1))
  elif echo "$output" | grep -q "^SKIP:"; then
    echo "$output"
    skipped=$((skipped+1))
  else
    echo "$output"
    installed=$((installed+1))
  fi
}

# ── Install all three hooks ───────────────────────────────────────────────────

echo "roborev_install_all_hooks: installing into $REPO_PATH${DRY_RUN_FLAG:+ (dry-run)}"
echo ""

_call_installer "roborev_install_post_merge_hook.sh"
_call_installer "roborev_install_commit_msg_hook.sh"
_call_installer "roborev_install_post_commit_verifier.sh"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Summary for $REPO_PATH: installed=$installed skipped=$skipped failed=$failed"

if [ "$failed" -gt 0 ]; then
  exit 1
fi

exit 0
