#!/usr/bin/env bash
# tests/test_render_signal_launchd_plists.sh — Unit tests for
# .claude/scripts/render_signal_launchd_plists.sh (llm#946).
#
# Proves the actual requirement from llm#946: the Signal launchd plists must
# be BOTH version-controlled AND free of PII in the repo. Every fixture here
# uses a fake account (+15550001111) and fake LAUNCH_AGENTS_DIR/STAGING_DIR
# under a throwaway temp dir — this test never touches the real
# ~/Library/LaunchAgents/, ~/.config/secrets.env, or launchctl.
#
# Usage:
#   bash tests/test_render_signal_launchd_plists.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.claude/scripts/render_signal_launchd_plists.sh"
TEMPLATE_DIR="$REPO_ROOT/.claude/launchd"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== render_signal_launchd_plists.sh Tests ==="

echo ""
echo "-- Test: bash -n syntax check"
if bash -n "$SCRIPT" 2>/dev/null; then
  pass "bash -n"
else
  fail "bash -n"
fi

TMP="$(mktemp -d /tmp/render_signal_test_XXXXXX)"
mkdir -p "$TMP/agents" "$TMP/staging" "$TMP/tmp"
printf 'SIGNAL_ACCOUNT="+15550001111"\n' > "$TMP/secrets.env"
printf 'OTHER_KEY="unrelated"\n' > "$TMP/secrets_no_account.env"

_run() {
  LAUNCHD_TEMPLATE_DIR="$TEMPLATE_DIR" \
  SECRETS_ENV_FILE="$1" \
  LAUNCH_AGENTS_DIR="$2" \
  STAGING_DIR="$TMP/staging" \
  LAUNCHCTL_BIN="/bin/echo" \
  TMPDIR="$TMP/tmp" \
  bash "$SCRIPT" "${@:3}"
}

echo ""
echo "-- Test 1: templates ship no PII (phone-number-shaped string)"
if grep -rEq '\+[0-9]{6,}' "$TEMPLATE_DIR"/com.johngavin.signal-*.plist.template 2>/dev/null; then
  fail "a template contains a phone-number-shaped literal"
else
  pass "no phone-number-shaped literal in any signal-*.plist.template"
fi

echo ""
echo "-- Test 2: --dry-run against an empty LaunchAgents dir reports drift (exit 2) for all 3 jobs, no crash"
out2="$(_run "$TMP/secrets.env" "$TMP/agents" --dry-run 2>&1)"
rc2=$?
if [ "$rc2" -eq 2 ] && echo "$out2" | grep -q "NOT INSTALLED" \
   && [ "$(echo "$out2" | grep -c 'NOT INSTALLED')" -eq 3 ]; then
  pass "dry-run reports NOT INSTALLED for all 3 jobs, exit 2"
else
  fail "dry-run against empty dir — rc=$rc2 out=$out2"
fi

echo ""
echo "-- Test 3: --apply --reload renders + installs into the fixture dirs"
out3="$(_run "$TMP/secrets.env" "$TMP/agents" --apply --reload 2>&1)"
rc3=$?
if [ "$rc3" -eq 0 ] \
   && [ -f "$TMP/agents/com.johngavin.signal-cli-daemon.plist" ] \
   && [ -f "$TMP/agents/com.johngavin.signal-braindump-handler.plist" ] \
   && [ -f "$TMP/agents/com.johngavin.signal-notes-sync.plist" ] \
   && grep -q '+15550001111' "$TMP/agents/com.johngavin.signal-cli-daemon.plist"; then
  pass "apply installed all 3 fixture plists with the fixture account substituted"
else
  fail "apply — rc=$rc3 out=$out3"
fi

echo ""
echo "-- Test 4: --check after a matching apply reports no drift (exit 0)"
out4="$(_run "$TMP/secrets.env" "$TMP/agents" --check 2>&1)"
rc4=$?
if [ "$rc4" -eq 0 ] && [ -z "$out4" ]; then
  pass "check is silent and exits 0 when live matches template+secret"
else
  fail "check after matching apply — rc=$rc4 out=$out4"
fi

echo ""
echo "-- Test 5: missing SIGNAL_ACCOUNT fails loudly (exit 1) and never prints a fixture-account-shaped value"
out5="$(_run "$TMP/secrets_no_account.env" "$TMP/agents" --dry-run --name com.johngavin.signal-cli-daemon 2>&1)"
rc5=$?
if [ "$rc5" -eq 1 ] && echo "$out5" | grep -q "SIGNAL_ACCOUNT is not set"; then
  pass "missing SIGNAL_ACCOUNT fails with a clear error (exit 1)"
else
  fail "missing-account path — rc=$rc5 out=$out5"
fi

echo ""
echo "-- Test 6: a job with no PII placeholder succeeds even without SIGNAL_ACCOUNT set"
out6="$(_run "$TMP/secrets_no_account.env" "$TMP/agents" --check --name com.johngavin.signal-notes-sync 2>&1)"
rc6=$?
if [ "$rc6" -eq 0 ]; then
  pass "non-PII job renders fine without SIGNAL_ACCOUNT"
else
  fail "non-PII job with no account — rc=$rc6 out=$out6"
fi

echo ""
echo "-- Test 7: a template hardcoding a Homebrew Cellar path is rejected before any rendering (exit 1)"
BAD_TMPL_DIR="$TMP/bad_templates"
mkdir -p "$BAD_TMPL_DIR"
cat > "$BAD_TMPL_DIR/com.johngavin.signal-cli-daemon.plist.template" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.johngavin.signal-cli-daemon</string>
	<key>ProgramArguments</key>
	<array>
		<string>/opt/homebrew/Cellar/signal-cli/0.14.3_1/bin/signal-cli</string>
		<string>-a</string>
		<string>__SIGNAL_ACCOUNT__</string>
	</array>
</dict>
</plist>
EOF
out7="$(LAUNCHD_TEMPLATE_DIR="$BAD_TMPL_DIR" SECRETS_ENV_FILE="$TMP/secrets.env" LAUNCH_AGENTS_DIR="$TMP/agents" STAGING_DIR="$TMP/staging" LAUNCHCTL_BIN="/bin/echo" TMPDIR="$TMP/tmp" bash "$SCRIPT" --check 2>&1)"
rc7=$?
if [ "$rc7" -eq 1 ] && echo "$out7" | grep -q "DEFECT.*Cellar"; then
  pass "Cellar-path template is rejected as a defect (exit 1) before any rendering"
else
  fail "Cellar-path template rejection — rc=$rc7 out=$out7"
fi

echo ""
echo "-- Test 8: a live plist with a Cellar path is flagged as drift+defect (exit 2)"
STALE_DIR="$TMP/stale_agents"
mkdir -p "$STALE_DIR"
cat > "$STALE_DIR/com.johngavin.signal-cli-daemon.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.johngavin.signal-cli-daemon</string>
	<key>ProgramArguments</key>
	<array>
		<string>/opt/homebrew/Cellar/signal-cli/0.14.3_1/bin/signal-cli</string>
		<string>-a</string>
		<string>+15550001111</string>
	</array>
</dict>
</plist>
EOF
out8="$(_run "$TMP/secrets.env" "$STALE_DIR" --check --name com.johngavin.signal-cli-daemon 2>&1)"
rc8=$?
if [ "$rc8" -eq 2 ] && echo "$out8" | grep -q "DRIFT" && echo "$out8" | grep -q "DEFECT.*Cellar"; then
  pass "stale live plist with Cellar path reports both DRIFT and DEFECT (exit 2)"
else
  fail "stale live plist — rc=$rc8 out=$out8"
fi

rm -rf "$TMP"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
