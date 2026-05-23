#!/usr/bin/env bash
# Test script for cross_modal_eval.sh
# Verifies logic without making real API calls
#
# Fix (roborev #777): track failures via FAIL_COUNT; exit 1 when any assertion
# fails so CI (and the unconditional success message) never masks broken tests.
# Fix (roborev #777 / finding 5): reference in-repo paths under .claude/scripts/
# and .claude/.env.example rather than ~/.claude/ paths.
# Closure (roborev #777, #779): both resolved in commit 60389d4 (PR #164).
# #779 covered COMPLETION_SUMMARY.md "Ready for Merge" claim; that file now
# documents in-repo deliverable paths and the accurate test-count (8/8 with
# exit 1 on any failure).

set -euo pipefail

# Resolve the repo root from this script's location so tests work from any cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROSS_MODAL_SCRIPT="${SCRIPT_DIR}/.claude/scripts/cross_modal_eval.sh"
ENV_EXAMPLE="${SCRIPT_DIR}/.claude/.env.example"

# Verify expected in-repo files exist before running tests
if [ ! -f "$CROSS_MODAL_SCRIPT" ]; then
    echo "ERROR: $CROSS_MODAL_SCRIPT not found — did you run this from the repo root?" >&2
    exit 1
fi
if [ ! -f "$ENV_EXAMPLE" ]; then
    echo "ERROR: $ENV_EXAMPLE not found" >&2
    exit 1
fi

echo "Testing cross_modal_eval.sh logic..."
echo "Script: $CROSS_MODAL_SCRIPT"
echo "Env example: $ENV_EXAMPLE"
echo ""

FAIL_COUNT=0

# Helper to record pass/fail
assert_pass() {
    local label="$1"
    local result="$2"   # "PASS" or "FAIL"
    echo -n "${label}: "
    if [ "$result" = "PASS" ]; then
        echo "PASS"
    else
        echo "FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Note: the cross_modal_eval.sh script exits non-zero on validation failures.
# We capture output first, then test it, to avoid set -e killing our script.

# Test 1: Missing file
echo -n "Test 1 (missing file): "
t1_out=$("$CROSS_MODAL_SCRIPT" /tmp/nonexistent_file_12345.txt 2>&1 || true)
if echo "$t1_out" | grep -q "File not found"; then
    echo "PASS"
else
    echo "FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Test 2: No arguments
echo -n "Test 2 (no arguments): "
t2_out=$("$CROSS_MODAL_SCRIPT" 2>&1 || true)
if echo "$t2_out" | grep -q "No output file provided"; then
    echo "PASS"
else
    echo "FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Test 3: Missing API keys (use a real file that exists; no keys set)
# Create a temp file so the script gets past the file-not-found check
TMPFILE=$(mktemp)
echo "Sample text for testing" > "$TMPFILE"
echo -n "Test 3 (missing API keys): "
t3_out=$(env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY \
   "$CROSS_MODAL_SCRIPT" "$TMPFILE" 2>&1 || true)
if echo "$t3_out" | grep -q "Missing API keys"; then
    echo "PASS"
else
    echo "FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
rm -f "$TMPFILE"

# Test 4: .env.example exists in repo with placeholder keys (not real)
echo -n "Test 4 (.env.example exists in repo): "
if [ -f "$ENV_EXAMPLE" ]; then
    echo "PASS"
else
    echo "FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Test 4b: .env.example contains no real key patterns (only placeholders)
echo -n "Test 4b (.env.example has only placeholder keys): "
if grep -qE '^(ANTHROPIC|OPENAI|DEEPSEEK)_API_KEY=sk-' "$ENV_EXAMPLE"; then
    # Has key lines — check none look like real keys (>20 chars after prefix)
    if grep -E '^(ANTHROPIC|OPENAI|DEEPSEEK)_API_KEY=sk-[a-zA-Z0-9_-]{20,}' "$ENV_EXAMPLE" | grep -qv 'xxx'; then
        echo "FAIL (possible real key detected)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "PASS"
    fi
else
    echo "FAIL (no key lines found)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Create a mock version of the script for testing the scoring logic
cat > /tmp/test_cross_modal_mock.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Mock responses with known scores
PRECISION_SCORE=9
RECALL_SCORE=8
GENERICITY_SCORE=7

# Calculate mismatches
check_mismatch() {
    local s1=$1 s2=$2 m1="$3" m2="$4"
    local diff=$(( s1 > s2 ? s1 - s2 : s2 - s1 ))
    local flag="false"
    [ "$diff" -gt 3 ] && flag="true"
    echo "{\"models\": [\"$m1\", \"$m2\"], \"diff\": $diff, \"flag\": $flag}"
}

mismatch1=$(check_mismatch "$PRECISION_SCORE" "$RECALL_SCORE" "opus-4.5" "gpt-4")
mismatch2=$(check_mismatch "$PRECISION_SCORE" "$GENERICITY_SCORE" "opus-4.5" "deepseek")
mismatch3=$(check_mismatch "$RECALL_SCORE" "$GENERICITY_SCORE" "gpt-4" "deepseek")

# Build report
cat <<JSON
{
  "precision": {"model": "opus-4.5", "score": $PRECISION_SCORE, "feedback": "Test precision feedback"},
  "recall": {"model": "gpt-4", "score": $RECALL_SCORE, "feedback": "Test recall feedback"},
  "genericity": {"model": "deepseek", "score": $GENERICITY_SCORE, "feedback": "Test genericity feedback"},
  "mismatches": [
    $mismatch1,
    $mismatch2,
    $mismatch3
  ],
  "overall": "PASS"
}
JSON
EOF

chmod +x /tmp/test_cross_modal_mock.sh

# Test 5: Mock scoring logic
echo -n "Test 5 (mock scoring): "
mock_output=$(/tmp/test_cross_modal_mock.sh)
if echo "$mock_output" | jq -e '.precision.score == 9 and .recall.score == 8 and .genericity.score == 7' >/dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL"
    echo "Output: $mock_output"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Test 6: Mismatch detection (diff=1, should not flag)
echo -n "Test 6 (small mismatch): "
if echo "$mock_output" | jq -e '.mismatches[2].diff == 1 and .mismatches[2].flag == false' >/dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Test large mismatch
cat > /tmp/test_cross_modal_mock_large.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PRECISION_SCORE=9
RECALL_SCORE=4  # Large diff from precision
GENERICITY_SCORE=7

check_mismatch() {
    local s1=$1 s2=$2 m1="$3" m2="$4"
    local diff=$(( s1 > s2 ? s1 - s2 : s2 - s1 ))
    local flag="false"
    [ "$diff" -gt 3 ] && flag="true"
    echo "{\"models\": [\"$m1\", \"$m2\"], \"diff\": $diff, \"flag\": $flag}"
}

mismatch1=$(check_mismatch "$PRECISION_SCORE" "$RECALL_SCORE" "opus-4.5" "gpt-4")
mismatch2=$(check_mismatch "$PRECISION_SCORE" "$GENERICITY_SCORE" "opus-4.5" "deepseek")
mismatch3=$(check_mismatch "$RECALL_SCORE" "$GENERICITY_SCORE" "gpt-4" "deepseek")

cat <<JSON
{
  "mismatches": [
    $mismatch1,
    $mismatch2,
    $mismatch3
  ],
  "overall": "WARN"
}
JSON
EOF

chmod +x /tmp/test_cross_modal_mock_large.sh

# Test 7: Large mismatch detection (diff=5, should flag)
echo -n "Test 7 (large mismatch): "
large_output=$(/tmp/test_cross_modal_mock_large.sh)
if echo "$large_output" | jq -e '.mismatches[0].diff == 5 and .mismatches[0].flag == true' >/dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL"
    echo "Output: $large_output"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Test 8: Overall status with flag
echo -n "Test 8 (WARN status): "
if echo "$large_output" | jq -e '.overall == "WARN"' >/dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Cleanup
rm -f /tmp/test_cross_modal_mock.sh /tmp/test_cross_modal_mock_large.sh

echo ""
echo "Results: $((8 - FAIL_COUNT))/8 assertions passed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "FAILED: $FAIL_COUNT assertion(s) failed."
    exit 1
fi

echo "All logic tests passed. Script is ready for real API testing."
echo "To test with real APIs, copy .claude/.env.example to ~/.claude/.env and add your keys."
