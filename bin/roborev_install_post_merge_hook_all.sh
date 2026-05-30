#!/usr/bin/env bash
# roborev_install_post_merge_hook_all.sh
#
# Wrapper: iterates ~/docs_gh/* looking for git repositories and calls
# roborev_install_post_merge_hook.sh on each one.
#
# Summary line printed at the end: installed=N skipped=M failed=K
#
# Usage:
#   bin/roborev_install_post_merge_hook_all.sh
#
# Part of: llm#217 Phase 3 — all-repos post-merge hook installer wrapper

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/roborev_install_post_merge_hook.sh"

if [[ ! -x "${INSTALLER}" ]]; then
    echo "ERROR: installer not found or not executable: ${INSTALLER}" >&2
    exit 1
fi

DOCS_DIR="${HOME}/docs_gh"

if [[ ! -d "${DOCS_DIR}" ]]; then
    echo "ERROR: ${DOCS_DIR} not found" >&2
    exit 1
fi

installed=0
skipped=0
failed=0

for candidate in "${DOCS_DIR}"/*/; do
    # Strip trailing slash for display
    repo="${candidate%/}"
    if [[ ! -d "${repo}/.git" ]]; then
        continue
    fi
    output="$("${INSTALLER}" "${repo}" 2>&1)"
    exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        echo "FAILED: ${repo} — ${output}" >&2
        (( failed += 1 ))
    elif echo "${output}" | grep -q "^SKIP:"; then
        echo "${output}"
        (( skipped += 1 ))
    else
        echo "${output}"
        (( installed += 1 ))
    fi
done

echo ""
echo "Summary: installed=${installed} skipped=${skipped} failed=${failed}"
