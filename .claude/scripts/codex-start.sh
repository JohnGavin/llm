#!/usr/bin/env bash
# codex-start.sh - Launch Codex with overnight digest surfacing.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUMMARY_SCRIPT="$SCRIPT_DIR/codex_show_overnight_learning.sh"

if [ "${CODEX_START_SKIP_OVERNIGHT:-0}" != "1" ] && [ -x "$SUMMARY_SCRIPT" ]; then
  "$SUMMARY_SCRIPT" || true
fi

exec /usr/local/bin/codex "$@"
