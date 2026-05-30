#!/usr/bin/env bash
# roborev_install_all_hooks_all_repos.sh
#
# Wrapper: iterates ~/docs_gh/* looking for git repositories and calls
# roborev_install_all_hooks.sh on each one.
#
# Summary line printed at the end: repos_installed=N repos_skipped=M repos_failed=K
#
# Usage:
#   bin/roborev_install_all_hooks_all_repos.sh
#   bin/roborev_install_all_hooks_all_repos.sh --dry-run
#
# Options:
#   --dry-run   Pass --dry-run through to each per-repo installer
#   --docs-dir PATH   Override the parent directory (default: ~/docs_gh)
#   --help      Show this message
#
# Part of: llm#356 Component 8
# Tracked in llm#163 automation loop

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/roborev_install_all_hooks.sh"

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//' | head -20
  exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────

DRY_RUN_FLAG=""
DOCS_DIR="${HOME}/docs_gh"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)           DRY_RUN_FLAG="--dry-run"; shift ;;
    --docs-dir)          shift; DOCS_DIR="$1"; shift ;;
    -h|--help)           usage ;;
    -*)                  echo "ERROR: unknown option: $1" >&2; exit 1 ;;
    *)                   echo "ERROR: unexpected argument: $1" >&2; exit 1 ;;
  esac
done

# ── Validate installer ────────────────────────────────────────────────────────

if [ ! -f "$INSTALLER" ]; then
  echo "ERROR: unified installer not found: $INSTALLER" >&2
  exit 1
fi

if [ ! -x "$INSTALLER" ]; then
  chmod +x "$INSTALLER" 2>/dev/null || true
fi

if [ ! -d "$DOCS_DIR" ]; then
  echo "ERROR: docs directory not found: $DOCS_DIR" >&2
  exit 1
fi

# ── Iterate repos ─────────────────────────────────────────────────────────────

repos_installed=0
repos_skipped=0
repos_failed=0

for candidate in "${DOCS_DIR}"/*/; do
  repo="${candidate%/}"

  if [ ! -d "${repo}/.git" ]; then
    continue
  fi

  # shellcheck disable=SC2086
  output="$("$INSTALLER" $DRY_RUN_FLAG "$repo" 2>&1)"
  exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "FAILED: $repo" >&2
    echo "$output" >&2
    repos_failed=$((repos_failed+1))
  else
    echo "$output"
    # Count as skipped if every hook was skipped, otherwise installed
    if echo "$output" | grep -qE "^Summary.*installed=0 "; then
      repos_skipped=$((repos_skipped+1))
    else
      repos_installed=$((repos_installed+1))
    fi
  fi

  echo "---"
done

echo ""
echo "All-repos summary: repos_installed=${repos_installed} repos_skipped=${repos_skipped} repos_failed=${repos_failed}"

if [ "$repos_failed" -gt 0 ]; then
  exit 1
fi

exit 0
