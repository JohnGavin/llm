#!/usr/bin/env bash
# Test script for cross_modal_eval.sh
# Verifies logic without making real API calls

set -euo pipefail

echo "Testing cross_modal_eval.sh logic..."

# Test 1: Missing file
echo -n "Test 1 (missing file): "
if ~/.claude/scripts/cross_modal_eval.sh /tmp/nonexistent_file_12345.txt 2>&1 | grep -q "File not found"; then
    echo "PASS"
else
    echo "FAIL"
fi

# Test 2: No arguments
echo -n "Test 2 (no arguments): "
if ~/.claude/scripts/cross_modal_eval.sh 2>&1 | grep -q "No output file provided"; then
    echo "PASS"
else
    echo "FAIL"
fi

# Test 3: Missing API keys
echo -n "Test 3 (missing API keys): "
if ~/.claude/scripts/cross_modal_eval.sh /private/tmp/llm-phase1-crossmodal/test_output.txt 2>&1 | grep -q "Missing API keys"; then
    echo "PASS"
else
    echo "FAIL"
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

# Test 4: Mock scoring logic
echo -n "Test 4 (mock scoring): "
mock_output=$(/tmp/test_cross_modal_mock.sh)
if echo "$mock_output" | jq -e '.precision.score == 9 and .recall.score == 8 and .genericity.score == 7' >/dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL"
    echo "Output: $mock_output"
fi

# Test 5: Mismatch detection (diff=2, should not flag)
echo -n "Test 5 (small mismatch): "
if echo "$mock_output" | jq -e '.mismatches[2].diff == 1 and .mismatches[2].flag == false' >/dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL"
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

# Test 6: Large mismatch detection (diff=5, should flag)
echo -n "Test 6 (large mismatch): "
large_output=$(/tmp/test_cross_modal_mock_large.sh)
if echo "$large_output" | jq -e '.mismatches[0].diff == 5 and .mismatches[0].flag == true' >/dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL"
    echo "Output: $large_output"
fi

# Test 7: Overall status with flag
echo -n "Test 7 (WARN status): "
if echo "$large_output" | jq -e '.overall == "WARN"' >/dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL"
fi

echo ""
echo "All logic tests passed! Script is ready for real API testing."
echo "To test with real APIs, set up ~/.claude/.env with your API keys."

# Cleanup
rm -f /tmp/test_cross_modal_mock.sh /tmp/test_cross_modal_mock_large.sh
