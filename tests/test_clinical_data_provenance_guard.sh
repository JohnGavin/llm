#!/usr/bin/env bash
# tests/test_clinical_data_provenance_guard.sh — runs the hook's own
# --selftest as the tests/test_*.sh suite CI selects on.
#
# The hook (.claude/hooks/clinical_data_provenance_guard.sh) is a
# PreToolUse:Artifact WARN-only guard that flags content shaped like a
# hand-transcribed clinical/lab value (reproducible-ingestion rule,
# AGENTS.md). Its selftest fixtures use synthetic values only (this repo
# is public) but exercise the same detection shapes: value+unit,
# analyte-word+number, mid-line position, and several fail-open cases
# (missing file, directory, unreadable file, malformed JSON, no
# file_path key) plus an always-exit-0 (never-blocks) check.
#
# Usage: bash tests/test_clinical_data_provenance_guard.sh
# Exit 0: every selftest case passes. Exit 1: one or more failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/clinical_data_provenance_guard.sh"

# Claude Code runs the hook directly, so it must be executable, not merely present.
if [ ! -x "$HOOK" ]; then
  echo "FAIL   hook missing or not executable: $HOOK"
  exit 1
fi

"$HOOK" --selftest
