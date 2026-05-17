#!/usr/bin/env bash
# cross_modal_eval.sh — Multi-model quality evaluation for outputs
# Runs 3 models in parallel to detect errors via precision/recall/genericity checks
#
# Usage:
#   cross_modal_eval.sh <output_file>
#
# Env vars:
#   ANTHROPIC_API_KEY   — Claude Opus 4.5 API key
#   OPENAI_API_KEY      — GPT-4 API key
#   DEEPSEEK_API_KEY    — DeepSeek API key
#   CROSS_MODAL_TIMEOUT — timeout per model call (default: 30s)
#
# Output: JSON with precision/recall/genericity scores and mismatch flags
# Cost: ~$0.05-0.10 per evaluation
#
# Prompt caching: The Anthropic call (call_opus) uses cache_control markers on
# the system block (ephemeral type). Anthropic requires >=1024 tokens to cache;
# PRECISION_PROMPT is ~125 tokens so caching is silently skipped today.
# This is scaffolding: structure is correct, cache-hit logging is active, and
# caching will engage automatically when prompts grow. See Issue #174.
#
# Related: Issue #137 (cross-modal evaluation), Issue #130 (T lang incident),
#          Issue #174 (prompt caching scaffolding)

set -euo pipefail

# Configuration
TIMEOUT="${CROSS_MODAL_TIMEOUT:-30}"
OUTPUT_FILE="${1:-}"
TEMP_DIR="/tmp/cross_modal_eval_$$"
CACHE_DIR="${HOME}/.cache/cross_modal_eval"

# Validation
if [ -z "$OUTPUT_FILE" ]; then
    echo "Error: No output file provided"
    echo "Usage: cross_modal_eval.sh <output_file>"
    exit 1
fi

if [ ! -f "$OUTPUT_FILE" ]; then
    echo "Error: File not found: $OUTPUT_FILE"
    exit 1
fi

# Check API keys
missing_keys=()
[ -z "${ANTHROPIC_API_KEY:-}" ] && missing_keys+=("ANTHROPIC_API_KEY")
[ -z "${OPENAI_API_KEY:-}" ] && missing_keys+=("OPENAI_API_KEY")
[ -z "${DEEPSEEK_API_KEY:-}" ] && missing_keys+=("DEEPSEEK_API_KEY")

if [ ${#missing_keys[@]} -gt 0 ]; then
    echo "Error: Missing API keys: ${missing_keys[*]}"
    echo "See ~/.claude/.env.example for setup instructions"
    exit 1
fi

# Create temp directory
mkdir -p "$TEMP_DIR" "$CACHE_DIR"
trap "rm -rf $TEMP_DIR" EXIT

# Read content
CONTENT=$(cat "$OUTPUT_FILE")
CONTENT_HASH=$(echo "$CONTENT" | shasum -a 256 | cut -d' ' -f1)
CACHE_FILE="$CACHE_DIR/${CONTENT_HASH}.json"

# Check cache (optional enhancement for same content)
if [ -f "$CACHE_FILE" ]; then
    cache_age=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE") ))
    if [ "$cache_age" -lt 3600 ]; then  # 1 hour cache
        echo "Using cached evaluation (age: ${cache_age}s)"
        cat "$CACHE_FILE"
        exit 0
    fi
fi

# Model evaluation prompts (plain strings — never interpolated into JSON literals)
PRECISION_PROMPT="You are a precision checker. Review this text for factual errors, misconceptions, or technically incorrect statements. Focus on: (1) Technical accuracy, (2) Correct terminology, (3) Logical consistency. Rate 1-10 (10=perfect precision) and provide specific feedback on any errors found. Format: {\"score\": N, \"feedback\": \"...\"}"

RECALL_PROMPT="You are a recall checker. Review this text for missing context or incomplete explanations. Focus on: (1) Key concepts omitted, (2) Necessary background missing, (3) Incomplete examples. Rate 1-10 (10=complete coverage) and provide specific feedback on gaps. Format: {\"score\": N, \"feedback\": \"...\"}"

GENERICITY_PROMPT="You are a genericity checker. Review this text for AI slop patterns and generic language. Focus on: (1) Vague phrases like 'it's important to note', (2) Obvious truisms, (3) Non-specific recommendations. Rate 1-10 (10=specific and concrete) and provide specific feedback on generic patterns. Format: {\"score\": N, \"feedback\": \"...\"}"

# Function to call Opus (precision)
# Fix (roborev #779): use jq -n --arg to build the payload — never interpolate
# RAW_CONTENT into a JSON string literal; jq handles all escaping correctly.
#
# Prompt caching scaffolding (Issue #174):
# - The system block carries cache_control: {type: "ephemeral"} so Anthropic will
#   cache it once it exceeds the 1024-token minimum.
# - PRECISION_PROMPT is currently ~125 tokens — below that threshold, so the
#   cache_control marker is silently ignored by the API today.
# - When prompts grow past 1024 tokens (Opus/Sonnet minimum), caching engages
#   automatically without further code changes.
# - Cache hits/creations are logged to ~/.claude/logs/cross_modal_cache.log.
call_opus() {
    local prompt="$1"
    local output="$2"

    local payload
    payload=$(jq -n \
        --arg model "claude-opus-4-5-20251101" \
        --arg system_prompt "$prompt" \
        --arg user_content "$CONTENT" \
        '{
            model: $model,
            max_tokens: 1024,
            system: [
                {
                    type: "text",
                    text: $system_prompt,
                    cache_control: {type: "ephemeral"}
                }
            ],
            messages: [{role: "user", content: $user_content}]
        }')

    local raw_response
    raw_response=$(timeout "$TIMEOUT" curl -s https://api.anthropic.com/v1/messages \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: prompt-caching-2024-07-31" \
        -H "content-type: application/json" \
        -d "$payload" 2>/dev/null) || raw_response='{"error": "API call failed"}'

    # Log cache metrics (cache_read_input_tokens=0 when threshold not yet met)
    local cache_log="${HOME}/.claude/logs/cross_modal_cache.log"
    mkdir -p "$(dirname "$cache_log")"
    local cache_read cache_creation input_tokens output_tokens
    cache_read=$(echo "$raw_response" | jq -r '.usage.cache_read_input_tokens // 0')
    cache_creation=$(echo "$raw_response" | jq -r '.usage.cache_creation_input_tokens // 0')
    input_tokens=$(echo "$raw_response" | jq -r '.usage.input_tokens // 0')
    output_tokens=$(echo "$raw_response" | jq -r '.usage.output_tokens // 0')
    printf '%s hash=%s cache_read=%s cache_creation=%s input=%s output=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S)" \
        "$CONTENT_HASH" \
        "$cache_read" \
        "$cache_creation" \
        "$input_tokens" \
        "$output_tokens" >> "$cache_log"

    echo "$raw_response" > "$output"
}

# Function to call GPT-4 (recall)
# Fix (roborev #779): same jq -n --arg pattern as call_opus.
call_gpt4() {
    local prompt="$1"
    local output="$2"

    local payload
    payload=$(jq -n \
        --arg system_msg "$prompt" \
        --arg user_msg "$CONTENT" \
        '{"model": "gpt-4o-mini", "max_tokens": 1024,
          "messages": [
            {"role": "system", "content": $system_msg},
            {"role": "user",   "content": $user_msg}
          ]}')

    timeout "$TIMEOUT" curl -s https://api.openai.com/v1/chat/completions \
        -H "Authorization: Bearer ${OPENAI_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" > "$output" 2>/dev/null || echo '{"error": "API call failed"}' > "$output"
}

# Function to call DeepSeek (genericity)
# Fix (roborev #779): same jq -n --arg pattern.
call_deepseek() {
    local prompt="$1"
    local output="$2"

    local payload
    payload=$(jq -n \
        --arg system_msg "$prompt" \
        --arg user_msg "$CONTENT" \
        '{"model": "deepseek-chat", "max_tokens": 1024,
          "messages": [
            {"role": "system", "content": $system_msg},
            {"role": "user",   "content": $user_msg}
          ]}')

    timeout "$TIMEOUT" curl -s https://api.deepseek.com/v1/chat/completions \
        -H "Authorization: Bearer ${DEEPSEEK_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" > "$output" 2>/dev/null || echo '{"error": "API call failed"}' > "$output"
}

# Run all models in parallel
echo "Running cross-modal evaluation..." >&2

call_opus "$PRECISION_PROMPT" "$TEMP_DIR/opus.json" &
OPUS_PID=$!

call_gpt4 "$RECALL_PROMPT" "$TEMP_DIR/gpt4.json" &
GPT4_PID=$!

call_deepseek "$GENERICITY_PROMPT" "$TEMP_DIR/deepseek.json" &
DEEPSEEK_PID=$!

# Wait for all to complete
wait "$OPUS_PID" 2>/dev/null || true
wait "$GPT4_PID" 2>/dev/null || true
wait "$DEEPSEEK_PID" 2>/dev/null || true

# Parse responses
parse_opus() {
    if jq -e '.error' "$TEMP_DIR/opus.json" >/dev/null 2>&1; then
        echo '{"score": 0, "feedback": "API call failed", "error": true}'
    else
        # Extract content from Anthropic response format
        local content=$(jq -r '.content[0].text // ""' "$TEMP_DIR/opus.json")
        # Try to extract JSON from content
        echo "$content" | jq -c '{score: .score, feedback: .feedback}' 2>/dev/null || \
            echo '{"score": 0, "feedback": "Failed to parse response", "error": true}'
    fi
}

parse_gpt4() {
    if jq -e '.error' "$TEMP_DIR/gpt4.json" >/dev/null 2>&1; then
        echo '{"score": 0, "feedback": "API call failed", "error": true}'
    else
        # Extract content from OpenAI response format
        local content=$(jq -r '.choices[0].message.content // ""' "$TEMP_DIR/gpt4.json")
        # Try to extract JSON from content
        echo "$content" | jq -c '{score: .score, feedback: .feedback}' 2>/dev/null || \
            echo '{"score": 0, "feedback": "Failed to parse response", "error": true}'
    fi
}

parse_deepseek() {
    if jq -e '.error' "$TEMP_DIR/deepseek.json" >/dev/null 2>&1; then
        echo '{"score": 0, "feedback": "API call failed", "error": true}'
    else
        # Extract content from DeepSeek response format (same as OpenAI)
        local content=$(jq -r '.choices[0].message.content // ""' "$TEMP_DIR/deepseek.json")
        # Try to extract JSON from content
        echo "$content" | jq -c '{score: .score, feedback: .feedback}' 2>/dev/null || \
            echo '{"score": 0, "feedback": "Failed to parse response", "error": true}'
    fi
}

PRECISION_JSON=$(parse_opus)
RECALL_JSON=$(parse_gpt4)
GENERICITY_JSON=$(parse_deepseek)

PRECISION_SCORE=$(echo "$PRECISION_JSON" | jq -r '.score // 0')
RECALL_SCORE=$(echo "$RECALL_JSON" | jq -r '.score // 0')
GENERICITY_SCORE=$(echo "$GENERICITY_JSON" | jq -r '.score // 0')

# Calculate score mismatches
mismatches='[]'

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

mismatches=$(jq -n "[$mismatch1, $mismatch2, $mismatch3]")

# Determine overall status
has_flags=$(echo "$mismatches" | jq '[.[] | select(.flag == true)] | length > 0')
has_errors=$(echo "$PRECISION_JSON$RECALL_JSON$GENERICITY_JSON" | jq -s 'any(.error == true)')
overall="PASS"
[ "$has_flags" = "true" ] && overall="WARN"
[ "$has_errors" = "true" ] && overall="ERROR"

# Build final report
report=$(jq -n \
    --argjson precision "$PRECISION_JSON" \
    --argjson recall "$RECALL_JSON" \
    --argjson genericity "$GENERICITY_JSON" \
    --argjson mismatches "$mismatches" \
    --arg overall "$overall" \
    '{
        precision: ($precision + {model: "opus-4.5"}),
        recall: ($recall + {model: "gpt-4"}),
        genericity: ($genericity + {model: "deepseek"}),
        mismatches: $mismatches,
        overall: $overall
    }')

# Cache result
echo "$report" > "$CACHE_FILE"

# Output report
echo "$report"
