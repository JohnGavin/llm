#!/usr/bin/env bash
# Ground-truth verification in bws_set_secret.sh (llm#1026).
#
# Drives the script through a pty-less path by feeding /dev/tty via a here-doc
# is not possible, so these tests exercise the verification LOGIC directly with
# the same helpers the script uses. The end-to-end tty path is covered by the
# no-tty refusal test in the script's own --selftest.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/.claude/scripts/lib/secret_ground_truth.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  PASS: $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL: $1"; }

echo "=== bws ground-truth verification ==="

# shellcheck source=/dev/null
. "$LIB"

_digest() { printf '%s' "$1" | shasum -a 256 | cut -c1-12; }

# 1. A verifier exists for SIGNAL_ACCOUNT and none for an unknown name.
[ -n "$(secret_ground_truth_cmd SIGNAL_ACCOUNT)" ] && ok "verifier registered for SIGNAL_ACCOUNT" \
                                                   || bad "no verifier for SIGNAL_ACCOUNT"
[ -z "$(secret_ground_truth_cmd NOT_A_REAL_SECRET)" ] && ok "no verifier invented for an unknown secret" \
                                                      || bad "invented a verifier"

# 2. Against a fixture accounts.json the verifier returns the number.
T="$(mktemp -d)"
mkdir -p "$T/.local/share/signal-cli/data"
cat > "$T/.local/share/signal-cli/data/accounts.json" <<'JSON'
{"accounts":[{"number":"+12025550111","path":"x"}]}
JSON
got="$(HOME="$T" bash -c ". '$LIB'; eval \"\$(secret_ground_truth_cmd SIGNAL_ACCOUNT)\"" 2>/dev/null)"
[ "$got" = "+12025550111" ] && ok "verifier reads the number from accounts.json" \
                            || bad "verifier returned '$got'"

# 3. A one-digit typo produces a DIFFERENT digest at the SAME length —
#    the exact 2026-08-25 failure that double entry could not catch.
a="+12025550111"; b="+12025550112"
[ "${#a}" -eq "${#b}" ] && ok "typo fixture has identical length to the truth" || bad "fixture lengths differ"
[ "$(_digest "$a")" != "$(_digest "$b")" ] && ok "digests differ for a one-digit typo" \
                                           || bad "digests collide"

# 4. Missing accounts.json => verifier FAILS (non-zero), so callers report
#    "cannot verify" rather than "mismatch" or "verified".
rm -f "$T/.local/share/signal-cli/data/accounts.json"
HOME="$T" bash -c ". '$LIB'; eval \"\$(secret_ground_truth_cmd SIGNAL_ACCOUNT)\"" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "absent accounts.json exits non-zero (unverifiable, not clean)" \
               || bad "absent accounts.json exited 0"

# 5. Multiple linked accounts => refuse to guess.
cat > "$T/.local/share/signal-cli/data/accounts.json" <<'JSON'
{"accounts":[{"number":"+12025550111"},{"number":"+12025550112"}]}
JSON
HOME="$T" bash -c ". '$LIB'; eval \"\$(secret_ground_truth_cmd SIGNAL_ACCOUNT)\"" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "two linked accounts => refuses to guess" || bad "picked one of two accounts"

# 6. The verifier never prints anything but the number.
cat > "$T/.local/share/signal-cli/data/accounts.json" <<'JSON'
{"accounts":[{"number":"+12025550111","username":"secret-ish"}]}
JSON
out="$(HOME="$T" bash -c ". '$LIB'; eval \"\$(secret_ground_truth_cmd SIGNAL_ACCOUNT)\"" 2>&1)"
[ "$out" = "+12025550111" ] && ok "verifier emits only the number" || bad "verifier emitted extra output"

rm -rf "$T"
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
