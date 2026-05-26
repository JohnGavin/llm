#!/usr/bin/env bash
# r_btw_codex_mcp.sh - Start the r-btw MCP server from the llm Nix shell env.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ENV_SCRIPT="$REPO_ROOT/nix-shell-root"

if [ ! -f "$ENV_SCRIPT" ]; then
  echo "Missing Nix shell env script: $ENV_SCRIPT" >&2
  echo "Rebuild it with: caffeinate -i $REPO_ROOT/default.sh" >&2
  exit 1
fi

# The GC-root env script starts with a warning banner that triggers harmless
# command-not-found lines under `set -e`. Disable errexit only for sourcing.
set +e
# shellcheck disable=SC1090
source "$ENV_SCRIPT" >/dev/null 2>&1
SOURCE_STATUS=$?
set -e

if [ "$SOURCE_STATUS" -ne 0 ]; then
  echo "Failed to source Nix env script: $ENV_SCRIPT" >&2
  exit "$SOURCE_STATUS"
fi

if ! command -v Rscript >/dev/null 2>&1; then
  echo "Rscript not found after sourcing $ENV_SCRIPT" >&2
  exit 1
fi

exec Rscript --vanilla -e 'btw::btw_mcp_server()'
