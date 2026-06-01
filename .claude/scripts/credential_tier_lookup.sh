#!/usr/bin/env bash
# credential_tier_lookup.sh — Look up a credential env-var name in the two-vault tier file.
#
# Usage:
#   credential_tier_lookup.sh <VAR_NAME>
#
# Output:
#   Prints "auto"    (exit 0) if VAR_NAME is in the [auto] tier
#   Prints "ask"     (exit 0) if VAR_NAME is in the [ask] tier
#   Prints "unknown" (exit 1) if VAR_NAME is not found in any tier
#
# Tier file lookup order:
#   1. $CREDENTIAL_TIERS_FILE env var (used in tests to inject a fixture file)
#   2. ~/.claude/credential_tiers.toml
#   3. Falls back to the .example file in the same directory as this script
#      (development / first-run convenience — not a security fallback)
#
# Self-test:
#   CLAUDE_HOOK_SELFTEST=1 bash credential_tier_lookup.sh
#
# See JohnGavin/llm#376.

set -euo pipefail

# ── Locate the tier file ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TIER_FILE="$HOME/.claude/credential_tiers.toml"
EXAMPLE_TIER_FILE="$SCRIPT_DIR/../credential_tiers.toml.example"

if [ -n "${CREDENTIAL_TIERS_FILE:-}" ]; then
  TIER_FILE="$CREDENTIAL_TIERS_FILE"
elif [ -f "$DEFAULT_TIER_FILE" ]; then
  TIER_FILE="$DEFAULT_TIER_FILE"
elif [ -f "$EXAMPLE_TIER_FILE" ]; then
  TIER_FILE="$EXAMPLE_TIER_FILE"
else
  # No tier file found — treat everything as unknown (do not block, let hook decide)
  printf 'unknown\n'
  exit 1
fi

# ── Self-test mode ───────────────────────────────────────────────────────────
# Accept both CREDENTIAL_TIER_LOOKUP_SELFTEST and CLAUDE_HOOK_SELFTEST
_SELFTEST="${CREDENTIAL_TIER_LOOKUP_SELFTEST:-${CLAUDE_HOOK_SELFTEST:-0}}"
if [ "$_SELFTEST" = "1" ]; then
  # Create a temporary fixture toml for self-test
  _fixture=$(mktemp /tmp/cred_tier_fixture_XXXXXX.toml)
  trap 'rm -f "$_fixture"' EXIT

  cat > "$_fixture" << 'TOML_EOF'
[auto]
keys = ["GITHUB_TOKEN_READ", "ROBOREV_DB_PATH"]

[ask]
keys = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GITHUB_TOKEN_WRITE"]
TOML_EOF

  _pass=0
  _fail=0
  SCRIPT_PATH="$(realpath "$0")"

  _run_lookup() {
    local var="$1"
    CREDENTIAL_TIER_LOOKUP_SELFTEST=0 \
    CREDENTIAL_TIERS_FILE="$_fixture" \
    bash "$SCRIPT_PATH" "$var" 2>/dev/null || true
  }

  _check_tier() {
    local desc="$1" var="$2" expected="$3"
    local got exit_code=0
    got=$(CREDENTIAL_TIER_LOOKUP_SELFTEST=0 \
          CREDENTIAL_TIERS_FILE="$_fixture" \
          bash "$SCRIPT_PATH" "$var" 2>/dev/null) || exit_code=$?

    if [ "$got" = "$expected" ]; then
      printf '  PASS  [%s] → %s\n' "$desc" "$got"
      _pass=$((_pass + 1))
    else
      printf '  FAIL  [%s] expected=%s got=%s\n' "$desc" "$expected" "$got"
      _fail=$((_fail + 1))
    fi
  }

  # Also test exit codes
  _check_exit() {
    local desc="$1" var="$2" expected_exit="$3"
    local exit_code=0
    CREDENTIAL_TIER_LOOKUP_SELFTEST=0 \
    CREDENTIAL_TIERS_FILE="$_fixture" \
    bash "$SCRIPT_PATH" "$var" > /dev/null 2>&1 || exit_code=$?
    if [ "$exit_code" = "$expected_exit" ]; then
      printf '  PASS  [%s exit=%s]\n' "$desc" "$exit_code"
      _pass=$((_pass + 1))
    else
      printf '  FAIL  [%s] expected exit=%s got exit=%s\n' "$desc" "$expected_exit" "$exit_code"
      _fail=$((_fail + 1))
    fi
  }

  echo "=== credential_tier_lookup.sh self-test ==="

  _check_tier  "auto key GITHUB_TOKEN_READ"    "GITHUB_TOKEN_READ"  "auto"
  _check_tier  "auto key ROBOREV_DB_PATH"      "ROBOREV_DB_PATH"    "auto"
  _check_tier  "ask key ANTHROPIC_API_KEY"     "ANTHROPIC_API_KEY"  "ask"
  _check_tier  "ask key OPENAI_API_KEY"        "OPENAI_API_KEY"     "ask"
  _check_tier  "ask key GITHUB_TOKEN_WRITE"    "GITHUB_TOKEN_WRITE" "ask"
  _check_tier  "unknown key SOME_OTHER_VAR"    "SOME_OTHER_VAR"     "unknown"

  _check_exit  "auto exits 0"    "GITHUB_TOKEN_READ"  "0"
  _check_exit  "ask exits 0"     "ANTHROPIC_API_KEY"  "0"
  _check_exit  "unknown exits 1" "SOME_OTHER_VAR"      "1"

  echo "=== Results: $_pass passed, $_fail failed (9 total) ==="
  [ "$_fail" -eq 0 ] && exit 0 || exit 1
fi

# ── Main lookup logic ────────────────────────────────────────────────────────
VAR_NAME="${1:-}"
if [ -z "$VAR_NAME" ]; then
  printf 'Usage: %s <VAR_NAME>\n' "$(basename "$0")" >&2
  exit 2
fi

# Parse the TOML file with pure shell.
# The tier file uses a simple format: [section] headers and keys = [...] arrays.
# We do NOT use a TOML parser — we match the exact structure produced by
# credential_tiers.toml.example so the logic stays shell-portable.
#
# Strategy: scan lines for the current section header, then look for VAR_NAME
# inside quoted strings on keys = [...] lines (possibly multi-line arrays).

_current_section=""
_in_array=0
_found_tier=""

while IFS= read -r line; do
  # Strip leading/trailing whitespace
  line="${line#"${line%%[! ]*}"}"
  line="${line%"${line##*[! ]}"}"

  # Skip blank lines and comments
  case "$line" in
    ""|\#*) continue ;;
  esac

  # Section header: [auto] or [ask]
  if printf '%s' "$line" | grep -qE '^\[[a-zA-Z_]+\]$'; then
    _current_section="${line#[}"
    _current_section="${_current_section%]}"
    _in_array=0
    continue
  fi

  # Start of keys array: keys = [...]
  if printf '%s' "$line" | grep -qE '^keys[[:space:]]*='; then
    _in_array=1
  fi

  # Once we are in an array (or on the keys = line itself), scan for VAR_NAME
  if [ "$_in_array" = "1" ]; then
    # Check if VAR_NAME appears as a quoted string on this line
    if printf '%s' "$line" | grep -qE "\"$VAR_NAME\""; then
      _found_tier="$_current_section"
      break
    fi
    # End of array on this line (closing ])
    if printf '%s' "$line" | grep -q ']'; then
      _in_array=0
    fi
  fi
done < "$TIER_FILE"

if [ -n "$_found_tier" ]; then
  printf '%s\n' "$_found_tier"
  exit 0
else
  printf 'unknown\n'
  exit 1
fi
