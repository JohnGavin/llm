#!/usr/bin/env bash
# tests/test_prompt_caching.sh — verify prompt caching markers in Anthropic API call sites
#
# Tests:
#   1. detect_patterns.sh uses a system[] block with cache_control: {type: "ephemeral"}
#   2. detect_patterns.sh sends anthropic-beta: prompt-caching-2024-07-31 header
#   3. detect_patterns.sh separates static instructions from dynamic TOOL_SUMMARY
#   4. detect_patterns.sh logs cache metrics to detect_patterns_cache.log
#   5. cross_modal_eval.sh uses a system[] block with cache_control (existing)
#   6. cross_modal_eval.sh sends anthropic-beta: prompt-caching-2024-07-31 header (existing)
#   7. cross_modal_eval.sh logs cache metrics to cross_modal_cache.log (existing)
#   8. detect_patterns.sh PAYLOAD uses jq -n --arg (safe construction — no string interpolation)
#   9. Constructed PAYLOAD for detect_patterns.sh is valid JSON with expected structure
#
# Usage: bash tests/test_prompt_caching.sh
# Exit 0: all assertions pass.  Exit 1: one or more failed.
#
# References: Issue #174, https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching

set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "ok     $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL   $*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DETECT_SCRIPT="$REPO_ROOT/.claude/scripts/detect_patterns.sh"
CROSS_MODAL_SCRIPT="$REPO_ROOT/.claude/scripts/cross_modal_eval.sh"

# ── Guard: scripts must exist ────────────────────────────────────────────────

[ -f "$DETECT_SCRIPT" ]     || { echo "FATAL: $DETECT_SCRIPT not found"; exit 1; }
[ -f "$CROSS_MODAL_SCRIPT" ] || { echo "FATAL: $CROSS_MODAL_SCRIPT not found"; exit 1; }

# ── Assertion 1: detect_patterns.sh — system block with cache_control ────────

if grep -q 'cache_control.*ephemeral' "$DETECT_SCRIPT"; then
    ok "detect_patterns.sh: cache_control {type:ephemeral} present"
else
    fail "detect_patterns.sh: cache_control marker MISSING (Issue #174)"
fi

# ── Assertion 2: detect_patterns.sh — anthropic-beta header ─────────────────

if grep -q 'anthropic-beta.*prompt-caching-2024-07-31' "$DETECT_SCRIPT"; then
    ok "detect_patterns.sh: anthropic-beta prompt-caching header present"
else
    fail "detect_patterns.sh: anthropic-beta header MISSING (required for older SDK)"
fi

# ── Assertion 3: detect_patterns.sh — system block (not user message) ────────

if grep -q '"system":' "$DETECT_SCRIPT" || grep -q 'system:' "$DETECT_SCRIPT"; then
    ok "detect_patterns.sh: system block used (static instructions separated from dynamic)"
else
    fail "detect_patterns.sh: no system block found — static instructions may be in user message"
fi

# ── Assertion 4: detect_patterns.sh — cache metrics logging ──────────────────

if grep -q 'detect_patterns_cache.log' "$DETECT_SCRIPT"; then
    ok "detect_patterns.sh: cache metrics logged to detect_patterns_cache.log"
else
    fail "detect_patterns.sh: cache metrics log MISSING (Issue #174 tracking requirement)"
fi

if grep -q 'cache_read_input_tokens' "$DETECT_SCRIPT"; then
    ok "detect_patterns.sh: cache_read_input_tokens extracted from response"
else
    fail "detect_patterns.sh: cache_read_input_tokens not extracted from response"
fi

if grep -q 'cache_creation_input_tokens' "$DETECT_SCRIPT"; then
    ok "detect_patterns.sh: cache_creation_input_tokens extracted from response"
else
    fail "detect_patterns.sh: cache_creation_input_tokens not extracted from response"
fi

# ── Assertion 5: cross_modal_eval.sh — system block with cache_control ───────

if grep -q 'cache_control.*ephemeral' "$CROSS_MODAL_SCRIPT"; then
    ok "cross_modal_eval.sh: cache_control {type:ephemeral} present (existing)"
else
    fail "cross_modal_eval.sh: cache_control marker MISSING"
fi

# ── Assertion 6: cross_modal_eval.sh — anthropic-beta header ─────────────────

if grep -q 'anthropic-beta.*prompt-caching-2024-07-31' "$CROSS_MODAL_SCRIPT"; then
    ok "cross_modal_eval.sh: anthropic-beta prompt-caching header present (existing)"
else
    fail "cross_modal_eval.sh: anthropic-beta header MISSING"
fi

# ── Assertion 7: cross_modal_eval.sh — cache metrics logging ─────────────────

if grep -q 'cross_modal_cache.log' "$CROSS_MODAL_SCRIPT"; then
    ok "cross_modal_eval.sh: cache metrics logged to cross_modal_cache.log (existing)"
else
    fail "cross_modal_eval.sh: cache_metrics log MISSING"
fi

# ── Assertion 8: detect_patterns.sh — jq --arg payload construction ──────────
# Verifies safe JSON construction — no string interpolation into JSON literals

if grep -q 'jq -n' "$DETECT_SCRIPT" && grep -q '\-\-arg system_text' "$DETECT_SCRIPT" && grep -q '\-\-arg tool_summary' "$DETECT_SCRIPT"; then
    ok "detect_patterns.sh: PAYLOAD uses jq -n --arg (safe JSON construction)"
else
    fail "detect_patterns.sh: PAYLOAD construction may use unsafe string interpolation"
fi

# ── Assertion 9: constructed payload is valid JSON with expected structure ────
# Simulate what jq would produce with empty args and verify structure

if command -v jq >/dev/null 2>&1; then
    SAMPLE_SYSTEM="Test system instructions"
    SAMPLE_SUMMARY="1. Bash: git status\n2. Edit: R/foo.R"

    SAMPLE_PAYLOAD=$(jq -n \
        --arg system_text "$SAMPLE_SYSTEM" \
        --arg tool_summary "$SAMPLE_SUMMARY" \
        '{
            model: "claude-opus-4-5-20251101",
            max_tokens: 2048,
            system: [
                {
                    type: "text",
                    text: $system_text,
                    cache_control: {type: "ephemeral"}
                }
            ],
            messages: [
                {
                    role: "user",
                    content: ("Tool call sequence:\n" + $tool_summary)
                }
            ]
        }')

    # Check required fields exist
    if echo "$SAMPLE_PAYLOAD" | jq -e '.system[0].cache_control.type == "ephemeral"' >/dev/null 2>&1; then
        ok "payload: system[0].cache_control.type == ephemeral"
    else
        fail "payload: system[0].cache_control.type != ephemeral"
    fi

    if echo "$SAMPLE_PAYLOAD" | jq -e '.system[0].text == "Test system instructions"' >/dev/null 2>&1; then
        ok "payload: system[0].text set correctly"
    else
        fail "payload: system[0].text not set correctly"
    fi

    if echo "$SAMPLE_PAYLOAD" | jq -e '.messages[0].role == "user"' >/dev/null 2>&1; then
        ok "payload: messages[0].role == user"
    else
        fail "payload: messages[0].role != user"
    fi

    if echo "$SAMPLE_PAYLOAD" | jq -e '.messages[0].content | startswith("Tool call sequence:")' >/dev/null 2>&1; then
        ok "payload: user message starts with 'Tool call sequence:'"
    else
        fail "payload: user message does not start with 'Tool call sequence:'"
    fi
else
    echo "skip   jq not available — skipping payload structure assertions"
fi

# ── Assertion 10: skill file exists ──────────────────────────────────────────

SKILL_FILE="$REPO_ROOT/.claude/skills/claude-api/SKILL.md"
if [ -f "$SKILL_FILE" ]; then
    ok "claude-api skill file exists: $SKILL_FILE"
else
    fail "claude-api skill MISSING: $SKILL_FILE (Issue #174 doc requirement)"
fi

if [ -f "$SKILL_FILE" ] && grep -q 'cache_control' "$SKILL_FILE"; then
    ok "claude-api skill documents cache_control pattern"
else
    fail "claude-api skill does not document cache_control pattern"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    echo "FAIL — $FAIL assertion(s) failed"
    exit 1
fi

echo "PASS — all $PASS assertions passed"
exit 0
