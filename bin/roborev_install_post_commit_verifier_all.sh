#!/usr/bin/env bash
# roborev_install_post_commit_verifier_all.sh
#
# Wrapper: iterates ~/docs_gh/* looking for git repositories and calls
# roborev_install_post_commit_verifier.sh on each one.
#
# Prints a summary at the end: installed=N chained=M skipped=K failed=L
# where:
#   installed — hook written by this installer (fresh or refreshed)
#   chained   — existing foreign hook detected; chaining instructions printed
#   skipped   — directory is not a git repo
#   failed    — installer exited non-zero
#
# Usage:
#   bin/roborev_install_post_commit_verifier_all.sh
#
# Issue: JohnGavin/llm#353

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/roborev_install_post_commit_verifier.sh"

if [ ! -x "${INSTALLER}" ]; then
  echo "ERROR: installer not found or not executable: ${INSTALLER}" >&2
  exit 1
fi

DOCS_DIR="${HOME}/docs_gh"

if [ ! -d "${DOCS_DIR}" ]; then
  echo "ERROR: ${DOCS_DIR} not found" >&2
  exit 1
fi

installed=0
chained=0
skipped=0
failed=0

for candidate in "${DOCS_DIR}"/*/; do
  repo="${candidate%/}"
  if [ ! -d "${repo}/.git" ]; then
    skipped=$((skipped+1))
    continue
  fi

  output=$("${INSTALLER}" "${repo}" 2>&1)
  exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAILED: ${repo} — ${output}" >&2
    failed=$((failed+1))
  elif printf '%s\n' "${output}" | grep -q '^CHAIN:'; then
    printf '%s\n' "${output}"
    chained=$((chained+1))
  else
    printf '%s\n' "${output}"
    installed=$((installed+1))
  fi
done

echo ""
echo "Summary: installed=${installed} chained=${chained} skipped=${skipped} failed=${failed}"
