#!/usr/bin/env bash
# external_content_quarantine.sh — PreToolUse:WebFetch hook
#
# Every WebFetch call is logged. Fetches to hosts NOT in the allowlist set a
# marker file so that subsequent Edit/Write hooks (Layer 3, planned) can detect
# potential external code copy attempts.
#
# Flow:
#   1. Parse URL from tool input (JSON on stdin)
#   2. Extract host from URL
#   3. If host in ALLOWED_DOMAINS: log "ALLOW" and exit 0
#   4. If host NOT in ALLOWED_DOMAINS: log "QUARANTINE" + write marker, exit 0
#      (quarantine is advisory — Layer 3 hook will enforce)
#
# Self-test:
#   CLAUDE_HOOK_SELFTEST=1 bash external_content_quarantine.sh
#
# See: .claude/rules/external-code-zero-trust.md
#      llm#194 — Phase 1: Layer 2 implementation

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION — edit this list to add/remove trusted domains
# ═══════════════════════════════════════════════════════════════════════════

# Hosts in this list are logged as ALLOW (no quarantine marker set).
# Hosts not in this list are logged as QUARANTINE (marker set).
# Subdomains are NOT automatically trusted — add them explicitly.
ALLOWED_DOMAINS=(
  # Anthropic — Claude documentation and API references
  "anthropic.com"
  "docs.anthropic.com"

  # GitHub — trusted for JohnGavin/* repos; raw content
  "github.com"
  "raw.githubusercontent.com"

  # Owner's own published domains
  "johngavin.github.io"
  "johngavin.r-universe.dev"

  # R ecosystem documentation
  "cran.r-project.org"
  "r-lib.github.io"
  "tidyverse.org"
  "tidyverse.github.io"
  "posit-dev.github.io"
  "quarto.org"
  "shiny.posit.co"
  "shinylive.io"
  "rstudio.github.io"
  "blogs.rstudio.com"
  "r-universe.dev"
  "docs.ropensci.org"
  "wlandau.github.io"
  "shikokuchuo.net"

  # Reference and learning
  "machinelearningmastery.com"
  "blog.r-hub.io"
  "www.r-bloggers.com"
  "forum.posit.co"
  "www.andrewheiss.com"
  "blog.vincentqiao.com"
  "www.tidy-finance.org"

  # Project-specific reference domains (finance, gov)
  "www.gov.uk"
  "www.fca.org.uk"

  # Self
  "puntofisso.net"
  "blog.stephenturner.us"
)

# ═══════════════════════════════════════════════════════════════════════════
# PATHS
# ═══════════════════════════════════════════════════════════════════════════

STATE_DIR="$HOME/.claude/state"
LOG_FILE="$STATE_DIR/quarantine.log"
MARKER_FILE="$STATE_DIR/external-content-pending"

mkdir -p "$STATE_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# HELPER: parse URL from JSON using python3 (same pattern as other hooks)
# ═══════════════════════════════════════════════════════════════════════════

parse_url() {
  local json="$1"
  printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    url = d.get('tool_input', {}).get('url', '')
    if not url:
        url = d.get('url', '')
    print(url)
except Exception:
    print('')
" 2>/dev/null || echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# HELPER: check if host is in the allowlist
# ═══════════════════════════════════════════════════════════════════════════

is_allowed() {
  local host="$1"
  for domain in "${ALLOWED_DOMAINS[@]}"; do
    if [ "$host" = "$domain" ]; then
      return 0
    fi
  done
  return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# HELPER: extract host from URL
# ═══════════════════════════════════════════════════════════════════════════

extract_host() {
  local url="$1"
  # Strip protocol, then take first path component, then strip port/query
  printf '%s' "$url" | sed 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||' | cut -d'/' -f1 | cut -d':' -f1 | cut -d'?' -f1
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST MODE
# ═══════════════════════════════════════════════════════════════════════════

if [ "${CLAUDE_HOOK_SELFTEST:-}" = "1" ]; then
  PASS=0
  FAIL=0

  run_test() {
    local name="$1"
    local input_json="$2"
    local expect_marker="$3"   # "yes" or "no"
    local expect_verdict="$4"  # "ALLOW" or "QUARANTINE"

    # Clean up marker before each test
    rm -f "$MARKER_FILE"

    # Run main logic in a subshell (skip SELFTEST to avoid recursion)
    stdout_out=$(printf '%s' "$input_json" | \
      env -u CLAUDE_HOOK_SELFTEST bash "$0" 2>/dev/null || true)

    marker_exists="no"
    [ -f "$MARKER_FILE" ] && marker_exists="yes"

    if [ "$marker_exists" = "$expect_marker" ] && \
       echo "$stdout_out" | grep -q "$expect_verdict"; then
      echo "  PASS: $name"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: $name"
      echo "    expected marker=$expect_marker verdict=$expect_verdict"
      echo "    got     marker=$marker_exists stdout='$stdout_out'"
      FAIL=$((FAIL + 1))
    fi
  }

  echo "=== external_content_quarantine.sh self-test ==="

  # Test 1: Allowlisted domain — no marker set
  run_test "allowlisted domain (github.com)" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://github.com/JohnGavin/llm/issues/194"}}' \
    "no" "ALLOW"

  # Test 2: Non-allowlisted domain — marker set
  run_test "off-allowlist domain (evil.example.com)" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://evil.example.com/hook.sh"}}' \
    "yes" "QUARANTINE"

  # Test 3: Non-allowlisted SaaS (the inciting incident pattern)
  run_test "SaaS solicitation pattern (vercel.app)" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://landing-ianymu.vercel.app/audit/"}}' \
    "yes" "QUARANTINE"

  # Test 4: Anthropic domain — allowlisted
  run_test "anthropic.com docs" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://docs.anthropic.com/en/api/getting-started"}}' \
    "no" "ALLOW"

  # Test 5: Malformed input (no URL field) — should not crash, should allow
  run_test "malformed input (no url field)" \
    '{"tool_name":"WebFetch","tool_input":{}}' \
    "no" "ALLOW"

  # Test 6: Empty input — should not crash, should allow
  run_test "empty input" \
    '{}' \
    "no" "ALLOW"

  # Test 7: Unknown subdomain — not automatically trusted
  run_test "unknown subdomain of github.com is quarantined" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://malicious-subdomain.github.com/payload"}}' \
    "yes" "QUARANTINE"

  # Clean up marker after tests
  rm -f "$MARKER_FILE"

  TOTAL=$((PASS + FAIL))
  echo "=== $PASS/$TOTAL PASS ==="
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# MAIN LOGIC
# ═══════════════════════════════════════════════════════════════════════════

# Parse tool input from stdin (Claude passes JSON)
INPUT=$(cat)

# Extract URL from tool input using python3
URL=$(parse_url "$INPUT")

# If we can't parse a URL, allow (conservative — don't block on parse failure)
if [ -z "$URL" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ALLOW (no url parsed) input=$(printf '%s' "$INPUT" | head -c 100)" >> "$LOG_FILE"
  echo "ALLOW: (no url)"
  exit 0
fi

# Extract host from URL
HOST=$(extract_host "$URL")

if [ -z "$HOST" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ALLOW (no host parsed) url=$URL" >> "$LOG_FILE"
  echo "ALLOW: (no host)"
  exit 0
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
AGENT_ID="${CLAUDE_AGENT_ID:-${CLAUDE_SESSION_ID:-unknown}}"

if is_allowed "$HOST"; then
  # Trusted domain — log ALLOW
  echo "[$TIMESTAMP] ALLOW host=$HOST url=$URL agent=$AGENT_ID" >> "$LOG_FILE"
  echo "ALLOW: $HOST"
  exit 0
else
  # Untrusted domain — log QUARANTINE and set marker
  echo "[$TIMESTAMP] QUARANTINE host=$HOST url=$URL agent=$AGENT_ID" >> "$LOG_FILE"

  # Write marker file (consumed by Layer 3 hook when implemented)
  printf 'timestamp=%s\nhost=%s\nurl=%s\nagent=%s\n' \
    "$TIMESTAMP" "$HOST" "$URL" "$AGENT_ID" > "$MARKER_FILE"

  # Emit advisory warning to stderr (does NOT block — Layer 2 is advisory)
  cat >&2 <<EOF

WARNING: WebFetch QUARANTINE -- $HOST is not in the trusted-domain allowlist.

  URL: $URL
  Marker set: $MARKER_FILE

  Per external-code-zero-trust rule: if you re-implement any idea from this
  content, start from scratch. Do NOT copy code directly from fetched content.

  To document a justified use:
    ALLOW_EXTERNAL_COPY="<reason>" <command>

  Quarantine log: $LOG_FILE

EOF

  echo "QUARANTINE: $HOST"
  # Exit 0 -- quarantine is advisory at Layer 2. Layer 3 will enforce.
  exit 0
fi
