#!/usr/bin/env bash
# codex_with_fallback.sh — invoke codex; auto-fall back to gemini on 429.
#
# Phase 1 of JohnGavin/llm#150 (codex↔gemini auto-fallback wrapper).
#
# Behaviour:
#   1. Invoke $CODEX_BIN (default: codex) with all supplied args.
#   2. Classify the result: success | rate_limit_429 | auth_failed |
#      provider_error | other.
#   3. On rate_limit_429: retry once with $GEMINI_BIN (default: gemini).
#   4. On auth_failed: fail immediately (do NOT fall back silently).
#   5. On any other non-zero: fail immediately, log the error.
#   6. Emit one JSON line per invocation to
#        ~/.claude/logs/codex_fallback/YYYY-MM-DD.jsonl
#
# Environment overrides (for testing):
#   CODEX_BIN         Path to primary binary     (default: codex)
#   GEMINI_BIN        Path to fallback binary    (default: gemini)
#   FALLBACK_LOG_DIR  Parent of YYYY-MM-DD.jsonl (default: ~/.claude/logs/codex_fallback)
#
# Exit codes match the final provider's exit code.
#
# Constraints:
#   - No compound && commands (single command per line; subshell exception OK).
#   - Passes bash -n.
#   - Handles gemini absent from PATH with a clear error.
#
# Tracked: JohnGavin/llm#150

# NOTE: do NOT use set -e here — we capture exit codes manually and must not
# exit on non-zero from the provider binaries.
set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

CODEX_BIN="${CODEX_BIN:-codex}"
GEMINI_BIN="${GEMINI_BIN:-gemini}"
FALLBACK_LOG_DIR="${FALLBACK_LOG_DIR:-$HOME/.claude/logs/codex_fallback}"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Generate a UUID-like token without external deps or pipelines from /dev/urandom
_uuid() {
  local hex=""
  # Read 16 bytes as hex using xxd if available, else od with safe head
  if command -v xxd >/dev/null 2>&1; then
    hex=$(xxd -l 16 -p /dev/urandom 2>/dev/null)
  else
    # od approach: read exactly 16 bytes, output hex, first token only
    hex=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
  fi
  # If both fail, use time+pid
  if [ -z "$hex" ] || [ "${#hex}" -lt 32 ]; then
    hex=$(printf '%x%x' "$(date +%s)" "$$")
    # pad to 32 chars
    while [ "${#hex}" -lt 32 ]; do
      hex="${hex}0"
    done
  fi
  # Format as xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  printf '%s-%s-%s-%s-%s' \
    "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

# Redact secrets from the args array, returning a JSON array string
_redact_args() {
  local out="["
  local first=1
  local val
  for arg in "$@"; do
    val="$arg"
    # Case-insensitive check for sensitive keywords
    local upper
    upper=$(printf '%s' "$arg" | tr '[:lower:]' '[:upper:]')
    case "$upper" in
      *KEY*|*TOKEN*|*SECRET*|*PASSWORD*|*PASS*)
        val="<redacted>"
        ;;
    esac
    # Escape backslash and double-quote in val
    val=$(printf '%s' "$val" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if [ "$first" -eq 1 ]; then
      out="${out}\"${val}\""
      first=0
    else
      out="${out},\"${val}\""
    fi
  done
  out="${out}]"
  printf '%s' "$out"
}

# Classify a provider invocation result.
# Uses grep (not case) to handle multi-line combined output reliably.
# Outputs one of: success rate_limit_429 auth_failed provider_error other
_classify() {
  local exit_code="$1"
  local combined="$2"

  if [ "$exit_code" -eq 0 ]; then
    printf 'success'
    return
  fi

  # Rate-limit signals (case-insensitive grep)
  if printf '%s' "$combined" | grep -qiE '429|rate_limit_exceeded|rate.limit|quota exceeded|RateLimitError'; then
    printf 'rate_limit_429'
    return
  fi

  # Auth failure signals
  if printf '%s' "$combined" | grep -qiE '^.*(401|unauthori[sz]ed|invalid.api.key|authentication error|AuthenticationError).*$'; then
    printf 'auth_failed'
    return
  fi
  # Extra plain-word auth check
  if printf '%s' "$combined" | grep -qiE '401|unauthorized|invalid.api.key|AuthenticationError'; then
    printf 'auth_failed'
    return
  fi

  # Distinguish provider error vs truly unknown
  if printf '%s' "$combined" | grep -qiE 'error|fail'; then
    printf 'provider_error'
    return
  fi

  printf 'other'
}

# Estimate byte sizes from temp files for token-count approximation.
# Neither codex nor gemini CLI exposes structured token counts at the CLI
# layer.  We capture response_bytes (stdout size) and prompt_bytes (args string
# size) as proxies.  The ETL converts these to approximate tokens and cost:
#   tokens ≈ bytes / 4  (conservative 4-char-per-token estimate for code/prose)
# A follow-up issue will replace this with actual API usage data (#380).
_file_bytes() {
  local f="$1"
  if [ -f "$f" ]; then
    wc -c < "$f" 2>/dev/null | tr -d ' ' || echo "0"
  else
    echo "0"
  fi
}

# Emit one JSONL record to the daily log file.
# Arguments (positional):
#   1  invocation_id
#   2  primary_exit
#   3  primary_classification
#   4  fallback_used        (true|false)
#   5  fallback_provider    (gemini|"")
#   6  fallback_exit        (int or "")
#   7  final_provider       (codex|gemini)
#   8  duration_sec
#   9  response_bytes       (stdout byte count — used for token approximation)
#  10  prompt_bytes         (args string byte count — proxy for prompt size)
#  11  model                (model name or "" when unknown)
#  12+ original args (redacted)
_emit_jsonl() {
  local inv_id="$1"
  local prim_exit="$2"
  local prim_class="$3"
  local fb_used="$4"
  local fb_provider="$5"
  local fb_exit="$6"
  local final_prov="$7"
  local dur="$8"
  local resp_bytes="$9"
  local prompt_bytes="${10}"
  local model_id="${11}"
  shift 11

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local date_part
  date_part=$(date -u +%Y-%m-%d)

  mkdir -p "$FALLBACK_LOG_DIR"
  local logfile="${FALLBACK_LOG_DIR}/${date_part}.jsonl"

  local args_json
  args_json=$(_redact_args "$@")

  local fb_provider_json='null'
  if [ -n "$fb_provider" ]; then
    fb_provider_json="\"${fb_provider}\""
  fi

  local fb_exit_json='null'
  if [ -n "$fb_exit" ]; then
    fb_exit_json="${fb_exit}"
  fi

  local model_json='"unknown"'
  if [ -n "$model_id" ]; then
    model_json="\"${model_id}\""
  fi

  # resp_bytes and prompt_bytes default to 0 when missing
  resp_bytes="${resp_bytes:-0}"
  prompt_bytes="${prompt_bytes:-0}"

  printf '{"ts":"%s","invocation_id":"%s","primary_provider":"codex","primary_exit":%s,"primary_classification":"%s","fallback_used":%s,"fallback_provider":%s,"fallback_exit":%s,"final_provider":"%s","duration_sec":%s,"response_bytes":%s,"prompt_bytes":%s,"model":%s,"args_redacted":%s}\n' \
    "$ts" "$inv_id" "$prim_exit" "$prim_class" "$fb_used" \
    "$fb_provider_json" "$fb_exit_json" "$final_prov" "$dur" \
    "$resp_bytes" "$prompt_bytes" "$model_json" "$args_json" \
    >> "$logfile"
}

# ── Main ──────────────────────────────────────────────────────────────────────

INV_ID=$(_uuid)
T_START=$(date +%s)

# ── Step 1: invoke primary (codex) ───────────────────────────────────────────

if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
  echo "codex_with_fallback: ERROR — primary '$CODEX_BIN' not found on PATH" >&2
  _emit_jsonl "$INV_ID" 127 "other" false "" "" "codex" 0 0 0 "" "$@"
  exit 127
fi

PRIMARY_STDOUT=$(mktemp /tmp/codex_fallback_stdout_XXXXXX)
PRIMARY_STDERR=$(mktemp /tmp/codex_fallback_stderr_XXXXXX)

# Cleanup tempfiles on exit
cleanup() {
  rm -f "${PRIMARY_STDOUT:-}" "${PRIMARY_STDERR:-}" \
        "${FB_STDOUT:-}" "${FB_STDERR:-}" 2>/dev/null
}
trap cleanup EXIT

PRIMARY_EXIT=0
"$CODEX_BIN" "$@" >"$PRIMARY_STDOUT" 2>"$PRIMARY_STDERR" || PRIMARY_EXIT=$?

T_END=$(date +%s)
DURATION=$(( T_END - T_START ))

# Capture byte counts for token-count approximation.
# Neither codex nor gemini exposes token counts at the CLI layer.
# response_bytes = stdout size (proxy for completion tokens: bytes/4 ≈ tokens).
# prompt_bytes   = args string length (proxy for prompt tokens).
# The ETL computes: prompt_tokens ≈ prompt_bytes/4, completion_tokens ≈ response_bytes/4.
# Tracked: JohnGavin/llm#380. Follow-up will wire actual API usage data.
PRIMARY_RESP_BYTES=$(_file_bytes "$PRIMARY_STDOUT")
PROMPT_BYTES=$(printf '%s' "$*" | wc -c | tr -d ' ')

# Detect codex model from environment (CODEX_MODEL env var, or default codex model).
# roborev sets ROBOREV_MODEL when invoking the wrapper; fall back to detection.
DETECTED_MODEL="${ROBOREV_MODEL:-${CODEX_MODEL:-gpt-5.4}}"

# Combine stdout+stderr for classification
PRIMARY_COMBINED=""
PRIMARY_COMBINED=$(cat "$PRIMARY_STDOUT" "$PRIMARY_STDERR" 2>/dev/null) || true
PRIMARY_CLASS=$(_classify "$PRIMARY_EXIT" "$PRIMARY_COMBINED")

# ── Step 2: handle classification ────────────────────────────────────────────

case "$PRIMARY_CLASS" in
  success)
    _emit_jsonl "$INV_ID" "$PRIMARY_EXIT" "success" false "" "" "codex" \
      "$DURATION" "$PRIMARY_RESP_BYTES" "$PROMPT_BYTES" "$DETECTED_MODEL" "$@"
    cat "$PRIMARY_STDOUT"
    exit 0
    ;;

  rate_limit_429)
    echo "codex_with_fallback: codex 429 — falling back to gemini" >&2

    if ! command -v "$GEMINI_BIN" >/dev/null 2>&1; then
      echo "codex_with_fallback: ERROR — fallback '$GEMINI_BIN' not found on PATH" >&2
      echo "  Install hint: npm install -g @google/gemini-cli" >&2
      _emit_jsonl "$INV_ID" "$PRIMARY_EXIT" "rate_limit_429" false "" "" "codex" \
        "$DURATION" "$PRIMARY_RESP_BYTES" "$PROMPT_BYTES" "$DETECTED_MODEL" "$@"
      cat "$PRIMARY_STDERR" >&2
      exit "$PRIMARY_EXIT"
    fi

    FB_STDOUT=$(mktemp /tmp/codex_fallback_fb_stdout_XXXXXX)
    FB_STDERR=$(mktemp /tmp/codex_fallback_fb_stderr_XXXXXX)

    FB_EXIT=0
    "$GEMINI_BIN" "$@" >"$FB_STDOUT" 2>"$FB_STDERR" || FB_EXIT=$?
    T_FB_END=$(date +%s)
    TOTAL_DURATION=$(( T_FB_END - T_START ))

    FB_RESP_BYTES=$(_file_bytes "$FB_STDOUT")
    FB_MODEL="${GEMINI_MODEL:-gemini-2.5-pro}"

    _emit_jsonl "$INV_ID" "$PRIMARY_EXIT" "rate_limit_429" true "gemini" "$FB_EXIT" "gemini" \
      "$TOTAL_DURATION" "$FB_RESP_BYTES" "$PROMPT_BYTES" "$FB_MODEL" "$@"

    if [ "$FB_EXIT" -ne 0 ]; then
      echo "codex_with_fallback: gemini fallback also failed (exit $FB_EXIT)" >&2
      cat "$FB_STDERR" >&2
      exit "$FB_EXIT"
    fi

    cat "$FB_STDOUT"
    exit 0
    ;;

  auth_failed)
    echo "codex_with_fallback: authentication failure — not falling back (check API key)" >&2
    _emit_jsonl "$INV_ID" "$PRIMARY_EXIT" "auth_failed" false "" "" "codex" \
      "$DURATION" "$PRIMARY_RESP_BYTES" "$PROMPT_BYTES" "$DETECTED_MODEL" "$@"
    cat "$PRIMARY_STDERR" >&2
    exit "$PRIMARY_EXIT"
    ;;

  provider_error|other)
    echo "codex_with_fallback: provider error (exit $PRIMARY_EXIT, class $PRIMARY_CLASS) — not falling back" >&2
    _emit_jsonl "$INV_ID" "$PRIMARY_EXIT" "$PRIMARY_CLASS" false "" "" "codex" \
      "$DURATION" "$PRIMARY_RESP_BYTES" "$PROMPT_BYTES" "$DETECTED_MODEL" "$@"
    cat "$PRIMARY_STDERR" >&2
    exit "$PRIMARY_EXIT"
    ;;
esac
