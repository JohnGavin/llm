#!/usr/bin/env bash
# tests/test_session_init_nix_state.sh — llm#1232
# The session banner must distinguish three nix states, not two:
#   in shell               -> nix:ok
#   installed, not in shell -> nix:not-in-shell
#   nix not found          -> nix:MISSING
#
# session_init.sh runs everything at top level, so the two small functions
# under test (phase_env, nix_summary) are extracted and run in isolation
# under `env -i` so the caller's IN_NIX_SHELL/PATH cannot leak in.
#
# Usage: bash tests/test_session_init_nix_state.sh

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "ok     $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL   $*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/session_init.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract a top-level function definition `name() {` ... first `^}`.
extract_fn() {
  awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$HOOK"
}

{
  extract_fn phase_env
  extract_fn nix_summary
} > "$TMP/fns.sh"

# Stub nix on PATH.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho stub\n' > "$TMP/bin/nix"
chmod +x "$TMP/bin/nix"

run_summary() {  # $@ = env assignments for env -i
  env -i "$@" /bin/bash -c 'source "$FNS"; nix_summary' 2>&1
}

# 1. IN_NIX_SHELL unset + stub nix on PATH -> not nix:MISSING (nix:not-in-shell)
out=$(run_summary FNS="$TMP/fns.sh" PATH="$TMP/bin" NIX_FALLBACK_BIN="$TMP/nonexistent/nix")
if [ "$out" = "nix:not-in-shell" ]; then ok "unset + nix on PATH -> $out"; else fail "unset + nix on PATH -> got '$out'"; fi

# 2. IN_NIX_SHELL unset + empty PATH + nonexistent fallback -> nix:MISSING
out=$(run_summary FNS="$TMP/fns.sh" PATH="" NIX_FALLBACK_BIN="$TMP/nonexistent/nix")
if [ "$out" = "nix:MISSING" ]; then ok "unset + no nix anywhere -> $out"; else fail "unset + no nix anywhere -> got '$out'"; fi

# 3. IN_NIX_SHELL=impure -> nix:ok (also with no nix on PATH)
out=$(run_summary FNS="$TMP/fns.sh" PATH="" IN_NIX_SHELL=impure NIX_FALLBACK_BIN="$TMP/nonexistent/nix")
if [ "$out" = "nix:ok" ]; then ok "IN_NIX_SHELL=impure -> $out"; else fail "IN_NIX_SHELL=impure -> got '$out'"; fi

# 4. Fallback path (not on PATH) counts as installed.
cp "$TMP/bin/nix" "$TMP/fallback_nix"
out=$(run_summary FNS="$TMP/fns.sh" PATH="" NIX_FALLBACK_BIN="$TMP/fallback_nix")
if [ "$out" = "nix:not-in-shell" ]; then ok "fallback path -> $out"; else fail "fallback path -> got '$out'"; fi

# 5. Other IN_NIX_SHELL values are in-shell.
for v in 1 pure; do
  out=$(run_summary FNS="$TMP/fns.sh" PATH="" IN_NIX_SHELL="$v" NIX_FALLBACK_BIN="$TMP/nonexistent/nix")
  if [ "$out" = "nix:ok" ]; then ok "IN_NIX_SHELL=$v -> $out"; else fail "IN_NIX_SHELL=$v -> got '$out'"; fi
done

# 6. Hook parses.
if bash -n "$HOOK"; then ok "bash -n session_init.sh"; else fail "bash -n session_init.sh"; fi

echo "---"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
