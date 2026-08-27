#!/usr/bin/env bash
# test_roborev_eval_run.sh — regression cover for roborev_eval_run.sh's
# classification logic (llm#1044).
#
# Thin wrapper around `roborev_eval_run.sh --selftest`, kept as a separate
# file under .claude/tests/ so it's discoverable alongside this repo's other
# test_*.sh scripts, per this repo's existing --selftest convention (see
# check_qmd_fence_parity.sh --selftest).
#
# This does NOT call the live roborev binary -- it exercises
# roborev_eval_classify.py's classify()/find_severities() against mocked
# review text. See roborev_eval_run.sh for the live-fixture runner.
#
# Usage: .claude/tests/test_roborev_eval_run.sh
# Exit: 0 if all classification cases PASS, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/../scripts/roborev_eval_run.sh" --selftest
