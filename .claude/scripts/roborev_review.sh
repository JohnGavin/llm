#!/usr/bin/env bash
# roborev_review.sh — PATH-shim wrapper for `roborev review`.
#
# Purpose: prepend .claude/scripts/codex_shim/ to PATH before invoking
# roborev, so that roborev's internal `codex` calls resolve to our
# codex_with_fallback.sh trampoline (which adds 429→gemini fallback and
# JSONL telemetry).
#
# Usage: replace bare `roborev review ...` calls with
#          ~/.../roborev_review.sh [roborev review args...]
#        or equivalently set ROBOREV_REVIEW=.../roborev_review.sh.
#
# Opt-out: CODEX_SHIM_DISABLE=1 — passed through to the shim, which then
#          calls the real codex directly (no fallback, no telemetry).
#
# Tracked: JohnGavin/llm#365

set -uo pipefail

ROBOREV="${ROBOREV:-/usr/local/bin/roborev}"

# Resolve the shim directory relative to this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM_DIR="$SCRIPT_DIR/codex_shim"

if [ ! -d "$SHIM_DIR" ]; then
  echo "roborev_review: codex_shim directory not found: $SHIM_DIR" >&2
  echo "  Expected: .claude/scripts/codex_shim/" >&2
  exit 1
fi

if [ ! -x "$SHIM_DIR/codex" ]; then
  echo "roborev_review: codex shim not executable: $SHIM_DIR/codex" >&2
  exit 1
fi

# Per-repo opt-out (llm#1296): never queue a review for a marked / no-remote /
# private-root repo. Fail closed when the shared guard cannot be found.
_RRA_LIB=""
for _c in "$SCRIPT_DIR/../../git-hooks/lib/roborev_repo_allowed.sh" \
          "$HOME/docs_gh/llm/git-hooks/lib/roborev_repo_allowed.sh"; do
  [ -r "$_c" ] && { _RRA_LIB="$_c"; break; }
done
if [ -z "$_RRA_LIB" ]; then
  echo "roborev_review: repo guard not found; not queuing (fail closed)" >&2
  exit 0
fi
# shellcheck disable=SC1090
. "$_RRA_LIB"
if ! roborev_repo_allowed . >/dev/null; then
  exit 0
fi

# Prepend shim so roborev's PATH lookup for 'codex' hits our wrapper first.
export PATH="$SHIM_DIR:$PATH"

exec "$ROBOREV" review "$@"
