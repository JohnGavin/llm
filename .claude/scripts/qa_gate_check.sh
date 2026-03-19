#!/bin/bash
# Hook: Check qa_quality_gate target timestamp before commit/PR
#
# Ensures the QA gate has been run recently. If _targets/objects/qa_quality_gate
# is stale (older than 1 hour) or missing, this hook warns but does not block.
# The agent should run plan_qa_gates targets before claiming quality gate compliance.
#
# Usage: Run during pre-commit or pre-PR as part of the 9-step workflow.
# Steps 4/6/8 of r-package-workflow SKILL.md require quality gate scores.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

QA_GATE_PATH="_targets/objects/qa_quality_gate"

# Check if we're in an R package with targets
if [ ! -f "_targets.R" ]; then
  echo -e "${YELLOW}No _targets.R found, skipping QA gate check${NC}"
  exit 0
fi

if [ ! -f "$QA_GATE_PATH" ]; then
  echo -e "${RED}WARN: qa_quality_gate target not found${NC}"
  echo "  Run: timeout 600 Rscript -e 'targets::tar_make(names = starts_with(\"qa_\"), callr_function = NULL)'"
  echo "  This is required at Steps 4 (commit), 6 (PR), and 8 (merge) of the workflow."
  exit 0  # Warn, don't block
fi

# Check staleness: warn if older than 1 hour
QA_MTIME=$(stat -f %m "$QA_GATE_PATH" 2>/dev/null || stat -c %Y "$QA_GATE_PATH" 2>/dev/null)
NOW=$(date +%s)
AGE_SECONDS=$((NOW - QA_MTIME))
AGE_MINUTES=$((AGE_SECONDS / 60))

if [ "$AGE_SECONDS" -gt 3600 ]; then
  echo -e "${YELLOW}WARN: qa_quality_gate is ${AGE_MINUTES} minutes old (>60 min stale threshold)${NC}"
  echo "  Re-run QA gates for fresh score before commit/PR."
else
  echo -e "${GREEN}OK: qa_quality_gate is ${AGE_MINUTES} minutes old (fresh)${NC}"
fi
