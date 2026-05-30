#!/usr/bin/env bash
# tests/test_roborev_install_all_hooks.sh
#
# Unit tests for bin/roborev_install_all_hooks.sh (Component 8 — llm#356)
#
# Uses:
#   - A synthetic temp git repo fixture
#   - Stub child installers in a temp bin/ directory
#
# Exits 0 if all tests pass, 1 on any failure.
#
# Run:
#   bash tests/test_roborev_install_all_hooks.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/../bin/roborev_install_all_hooks.sh"

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d)"

cleanup() { rm -rf "${TMPDIR_ROOT}"; }
trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────────────────────

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    pass "${desc}"
  else
    fail "${desc} — expected='${expected}' actual='${actual}'"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "${haystack}" | grep -qF "${needle}"; then
    pass "${desc}"
  else
    fail "${desc} — expected to find '${needle}' in output"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "${haystack}" | grep -qF "${needle}"; then
    fail "${desc} — unexpected '${needle}' in output"
  else
    pass "${desc}"
  fi
}

# ── Fixture: create a minimal git repo ────────────────────────────────────────

make_git_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@test"
  git -C "$dir" config user.name "Test"
  touch "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "init"
}

# ── Fixture: create stub bin/ dir with all three child installers ─────────────

make_stub_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"

  for name in \
    roborev_install_post_merge_hook.sh \
    roborev_install_commit_msg_hook.sh \
    roborev_install_post_commit_verifier.sh
  do
    hook_name="${name%.sh}"
    cat > "$bin_dir/$name" <<STUB
#!/usr/bin/env bash
echo "OK: stub ${hook_name} installed in \$1"
exit 0
STUB
    chmod +x "$bin_dir/$name"
  done
}

# ── Sanity check: installer script exists ─────────────────────────────────────

if [ ! -f "$INSTALLER" ]; then
  echo "ERROR: installer not found at $INSTALLER" >&2
  exit 1
fi

# ── Test 1: no arguments → exit 1 ────────────────────────────────────────────

rc=0
SCRIPT_DIR="$TMPDIR_ROOT" bash "$INSTALLER" 2>/dev/null || rc=$?
assert_eq "no args: exit 1" "1" "$rc"

# ── Test 2: non-git directory → exit 1 ───────────────────────────────────────

non_git="$TMPDIR_ROOT/not_a_repo"
mkdir -p "$non_git"
rc=0
SCRIPT_DIR="$TMPDIR_ROOT" bash "$INSTALLER" "$non_git" 2>/dev/null || rc=$?
assert_eq "non-git dir: exit 1" "1" "$rc"

# ── Test 3: all three stubs present → exit 0 + summary line ──────────────────

repo1="$TMPDIR_ROOT/repo1"
bin1="$TMPDIR_ROOT/bin1"
make_git_repo "$repo1"
make_stub_bin "$bin1"

rc=0
output=$(SCRIPT_DIR="$bin1" bash "$INSTALLER" "$repo1" 2>&1) || rc=$?
assert_eq "all stubs: exit 0" "0" "$rc"
assert_contains "all stubs: summary line" "Summary for" "$output"
assert_contains "all stubs: installed count" "installed=3" "$output"

# ── Test 4: missing commit-msg installer → exit 0, skipped=1 ─────────────────

bin2="$TMPDIR_ROOT/bin2"
make_stub_bin "$bin2"
rm -f "$bin2/roborev_install_commit_msg_hook.sh"

rc=0
output=$(SCRIPT_DIR="$bin2" bash "$INSTALLER" "$repo1" 2>&1) || rc=$?
assert_eq "missing commit-msg: exit 0" "0" "$rc"
assert_contains "missing commit-msg: warning" "WARNING:" "$output"
assert_contains "missing commit-msg: skipped=1" "skipped=1" "$output"

# ── Test 5: missing post-commit verifier → exit 0, skipped=1 ─────────────────

bin3="$TMPDIR_ROOT/bin3"
make_stub_bin "$bin3"
rm -f "$bin3/roborev_install_post_commit_verifier.sh"

rc=0
output=$(SCRIPT_DIR="$bin3" bash "$INSTALLER" "$repo1" 2>&1) || rc=$?
assert_eq "missing post-commit: exit 0" "0" "$rc"
assert_contains "missing post-commit: skipped=1" "skipped=1" "$output"

# ── Test 6: all three missing → exit 0, skipped=3 ────────────────────────────

bin4="$TMPDIR_ROOT/bin4"
mkdir -p "$bin4"
# No child installers at all

rc=0
output=$(SCRIPT_DIR="$bin4" bash "$INSTALLER" "$repo1" 2>&1) || rc=$?
assert_eq "all missing: exit 0" "0" "$rc"
assert_contains "all missing: skipped=3" "skipped=3" "$output"

# ── Test 7: failing child installer → exit 1 + failed=1 ──────────────────────

bin5="$TMPDIR_ROOT/bin5"
make_stub_bin "$bin5"
# Replace post-merge stub with a failing one
cat > "$bin5/roborev_install_post_merge_hook.sh" <<'FAIL_STUB'
#!/usr/bin/env bash
echo "ERROR: stub failure" >&2
exit 1
FAIL_STUB
chmod +x "$bin5/roborev_install_post_merge_hook.sh"

rc=0
output=$(SCRIPT_DIR="$bin5" bash "$INSTALLER" "$repo1" 2>&1) || rc=$?
assert_eq "failing installer: exit 1" "1" "$rc"
assert_contains "failing installer: failed=1" "failed=1" "$output"

# ── Test 8: --dry-run flag passes through to child installer ──────────────────

bin6="$TMPDIR_ROOT/bin6"
mkdir -p "$bin6"

# Stubs detect --dry-run flag in any argument position
for name in \
  roborev_install_post_merge_hook.sh \
  roborev_install_commit_msg_hook.sh \
  roborev_install_post_commit_verifier.sh
do
  cat > "$bin6/$name" <<'DRYRUN_STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "--dry-run" ]; then
    echo "OK: stub (dry-run mode)"
    exit 0
  fi
done
echo "OK: stub installed in $1"
exit 0
DRYRUN_STUB
  chmod +x "$bin6/$name"
done

rc=0
output=$(SCRIPT_DIR="$bin6" bash "$INSTALLER" --dry-run "$repo1" 2>&1) || rc=$?
assert_eq "--dry-run: exit 0" "0" "$rc"
assert_contains "--dry-run: appears in header" "dry-run" "$output"

# ── Test 9: --unknown-flag → exit 1 ──────────────────────────────────────────

rc=0
SCRIPT_DIR="$TMPDIR_ROOT" bash "$INSTALLER" --unknown-flag "$repo1" 2>/dev/null || rc=$?
assert_eq "unknown flag: exit 1" "1" "$rc"

# ── Test 10: --help flag exits 0 ─────────────────────────────────────────────

rc=0
bash "$INSTALLER" --help 2>/dev/null || rc=$?
# grep-based help exits 0 in our impl
assert_eq "--help: exit 0" "0" "$rc"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "${PASS}/$((PASS+FAIL)) PASS"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
