#!/usr/bin/env bash
# session_init_phase14b_selftest.sh
# Standalone selftest for Phase 14b of session_init.sh (ci-failure issue scan).
#
# Mocks `gh` with a small fixture and confirms:
#   - N=0  → no output
#   - N=3  → exactly one banner line with the exact gh command embedded
#
# Usage: bash session_init_phase14b_selftest.sh
# Exit:  0 on PASS, 1 on any FAIL
#
# Note: Phase 14b uses /usr/bin/git (absolute path) to get the remote URL, so
# we skip the git-URL-parsing path and inject CIFAIL_REPO_OVERRIDE directly.
# This tests the counting + output logic without a network call.
#
# See JohnGavin/llm#387.

set -euo pipefail

PASS=0
FAIL=0

# ── Helpers ─────────────────────────────────────────────────────────────────

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# run_phase14b MOCK_COUNT FAKE_REPO
# Exercises the Phase 14b counting + output logic with a mocked gh binary.
# Injects CIFAIL_REPO_OVERRIDE to bypass the git URL parsing (absolute /usr/bin/git
# cannot be stubbed; the URL parsing is covered by the integration path in prod).
run_phase14b() {
  local mock_count="$1"
  local fake_repo="${2:-JohnGavin/testrepo}"

  # Create a temp dir containing a stub `gh` binary
  local tmpdir
  tmpdir=$(mktemp -d /tmp/p14b_test_XXXXXX)
  trap 'rm -rf "$tmpdir"' RETURN

  # Stub gh: ignores all arguments, outputs the mock count as a bare integer
  # (matching what `--jq 'length'` would return for an array of that length)
  cat > "$tmpdir/gh" <<GHEOF
#!/usr/bin/env bash
echo "${mock_count}"
GHEOF
  chmod +x "$tmpdir/gh"

  # Inject stub at front of PATH; pass repo via env var to skip git URL parse
  local output
  output=$(CIFAIL_REPO_OVERRIDE="$fake_repo" PATH="$tmpdir:$PATH" bash -s <<'INNEREOF'
    # ── Inline reproduction of Phase 14b ────────────────────────────────────
    # When CIFAIL_REPO_OVERRIDE is set, skip the git URL parsing step.
    _cifail_debug_log=/dev/null
    _cifail_repo="${CIFAIL_REPO_OVERRIDE:-}"

    # If override not set, do the normal URL parsing (not exercised by selftest)
    if [ -z "$_cifail_repo" ] && command -v gh >/dev/null 2>&1; then
      _cifail_url=$(/usr/bin/git config --get remote.origin.url 2>/dev/null || true)
      if [ -n "$_cifail_url" ]; then
        _cifail_repo=$(echo "$_cifail_url" | /usr/bin/sed -E 's#^https?://[^/]+/##; s#^git@[^:]+:##; s#\.git$##')
        case "$_cifail_repo" in
          */*) : ;;
          *) _cifail_repo="" ;;
        esac
      fi
    fi

    if [ -n "$_cifail_repo" ]; then
      if command -v timeout >/dev/null 2>&1; then
        _cifail_gh_prefix="timeout 5"
      else
        _cifail_gh_prefix=""
      fi

      _cifail_count=$($_cifail_gh_prefix gh issue list \
          --repo "$_cifail_repo" \
          --label "ci-failure" \
          --state open \
          --json number \
          --jq 'length' \
          2>>"$_cifail_debug_log") || _cifail_count=""

      if [ -n "$_cifail_count" ] && [ "$_cifail_count" -gt 0 ] 2>/dev/null; then
        echo "ci-failures: ${_cifail_count} open  (gh issue list --repo ${_cifail_repo} --label ci-failure --state open)"
      fi
    fi
INNEREOF
  )

  printf '%s' "$output"
}

# ── Test: N=0 produces no output ────────────────────────────────────────────

echo "--- Test 1: N=0 → no output ---"
out0=$(run_phase14b 0 "JohnGavin/testrepo")
if [ -z "$out0" ]; then
  pass "N=0 produces no output"
else
  fail "N=0 produced unexpected output: $out0"
fi

# ── Test: N=3 produces one banner line ───────────────────────────────────────

echo "--- Test 2: N=3 → one banner line ---"
out3=$(run_phase14b 3 "JohnGavin/llmtelemetry")
n_lines=$(printf '%s\n' "$out3" | grep -c . || true)
if [ "$n_lines" -eq 1 ]; then
  pass "N=3 produces exactly 1 line"
else
  fail "N=3 produced $n_lines lines (expected 1): $out3"
fi

# Banner must contain the count
if printf '%s' "$out3" | grep -q "ci-failures: 3 open"; then
  pass "Banner contains 'ci-failures: 3 open'"
else
  fail "Banner missing 'ci-failures: 3 open' — got: $out3"
fi

# Banner must contain the exact gh command the user can copy-paste
expected_cmd="gh issue list --repo JohnGavin/llmtelemetry --label ci-failure --state open"
if printf '%s' "$out3" | grep -qF "$expected_cmd"; then
  pass "Banner embeds exact gh command"
else
  fail "Banner missing exact gh command '$expected_cmd' — got: $out3"
fi

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
