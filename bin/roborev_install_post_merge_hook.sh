#!/usr/bin/env bash
# roborev_install_post_merge_hook.sh <repo-path>
#
# Installs a post-merge git hook that triggers roborev review on the
# merged-in commits.  The hook runs `roborev review --since ORIG_HEAD`
# which reviews all commits between the pre-merge HEAD (exclusive) and
# the current HEAD (inclusive) — exactly the commits the merge brought in.
#
# Idempotent: re-running on a repo that already has our hook refreshes
# the marker comment but otherwise changes nothing.
#
# Safety: refuses to overwrite an UNRECOGNISED existing post-merge hook
# (one that lacks the installer marker comment).  Prints a warning and
# exits 0 so the all-repos wrapper can continue.
#
# Usage:
#   bin/roborev_install_post_merge_hook.sh /path/to/repo
#
# Part of: llm#217 Phase 3 — post-merge hook installer
# Installed-by marker (must stay on line ~14 for idempotency detection):
#   Installed by ~/docs_gh/llm/bin/roborev_install_post_merge_hook.sh

set -uo pipefail

INSTALLER_MARKER="Installed by ~/docs_gh/llm/bin/roborev_install_post_merge_hook.sh"

usage() {
    echo "Usage: $0 <repo-path>" >&2
    echo "  repo-path: path to a git working tree" >&2
    exit 1
}

# ── Argument validation ──────────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
    usage
fi

REPO_PATH="$1"

if [[ ! -d "${REPO_PATH}/.git" ]]; then
    echo "ERROR: not a git repository (no .git/ directory): ${REPO_PATH}" >&2
    exit 1
fi

HOOKS_DIR="${REPO_PATH}/.git/hooks"
HOOK_FILE="${HOOKS_DIR}/post-merge"

# ── Check for unrecognised existing hook ────────────────────────────────────
if [[ -f "${HOOK_FILE}" ]]; then
    if grep -qF "${INSTALLER_MARKER}" "${HOOK_FILE}" 2>/dev/null; then
        : # our hook — safe to overwrite / refresh
    else
        echo "SKIP: ${REPO_PATH} — existing post-merge hook not written by this installer." >&2
        echo "      Inspect ${HOOK_FILE} manually if you want to replace it." >&2
        exit 0
    fi
fi

# ── Write the hook ───────────────────────────────────────────────────────────
cat > "${HOOK_FILE}" <<'HOOK'
#!/usr/bin/env bash
# Installed by ~/docs_gh/llm/bin/roborev_install_post_merge_hook.sh
# Triggers a roborev review on the commits brought in by the merge.
# ORIG_HEAD is set automatically by git to the pre-merge HEAD SHA.
# `roborev review --since ORIG_HEAD` reviews all commits between
# ORIG_HEAD (exclusive) and HEAD (inclusive) — i.e. exactly the merged commits.
# Uses roborev_review.sh wrapper (#365) to route codex calls through
# codex_with_fallback.sh (429→gemini fallback + JSONL telemetry).
set -uo pipefail
REVIEW_WRAPPER="$HOME/docs_gh/llm/.claude/scripts/roborev_review.sh"
if [ -x "$REVIEW_WRAPPER" ]; then
  "$REVIEW_WRAPPER" --since "${1:-ORIG_HEAD}" --quiet > /dev/null 2>&1 || true
elif command -v roborev > /dev/null 2>&1; then
  roborev review --since "${1:-ORIG_HEAD}" --quiet > /dev/null 2>&1 || true
fi
HOOK

chmod +x "${HOOK_FILE}"

echo "OK: installed post-merge hook in ${REPO_PATH}"
