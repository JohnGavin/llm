#!/usr/bin/env bash
# roborev_install_post_commit_verifier.sh <repo-path>
#
# Installs a post-commit git hook that asynchronously runs the roborev
# post-commit verifier whenever a commit message contains "closes roborev #N"
# citations.
#
# The hook:
#   - Parses cited finding IDs from the commit message via grep.
#   - Nohups ~/.claude/scripts/roborev_verify_closure.sh so it does NOT block
#     the git commit.
#   - Exits 0 immediately regardless of verifier outcome (fail-open).
#   - Respects ROBOREV_VERIFY_SKIP=1 to opt out per-invocation.
#
# Idempotent: re-running refreshes the marker comment but changes nothing else
# when the hook was previously installed by this script.
#
# Safety: refuses to overwrite an UNRECOGNISED existing post-commit hook that
# lacks the installer marker.  Instead prints a CHAIN: message with
# instructions for chaining manually.
#
# Usage:
#   bin/roborev_install_post_commit_verifier.sh /path/to/repo
#
# Issue: JohnGavin/llm#353
# Installed-by marker (must stay on line ~28 for idempotency detection):
#   Installed by ~/docs_gh/llm/bin/roborev_install_post_commit_verifier.sh

set -uo pipefail

# ── Phase-1.6 shim guard (JohnGavin/llm#386) ─────────────────────────────────
# Warn if the roborev primary shim is not installed.  The shim ensures the
# codex fallback wrapper (codex_with_fallback.sh) is on PATH for ALL roborev
# callers, including the daemon's primary review loop.
if [ ! -x "${HOME}/.local/bin/roborev" ]; then
  echo "WARNING: ~/.local/bin/roborev shim not installed." >&2
  echo "  The codex_with_fallback.sh wrapper will NOT intercept primary-loop reviews." >&2
  echo "  Install: ~/docs_gh/llm/.claude/scripts/install_roborev_primary_shim.sh" >&2
  echo "  Verify:  which roborev  # must show ~/.local/bin/roborev" >&2
  echo "" >&2
fi

INSTALLER_MARKER="Installed by ~/docs_gh/llm/bin/roborev_install_post_commit_verifier.sh"

# Resolve the verifier script path relative to this installer's location so
# that the script works from both the main checkout and worktrees.
# Canonical form: always use ~/docs_gh/llm (the permanent install location).
# ROBOREV_VERIFIER_SCRIPT env var overrides — used by tests.
_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "${_INSTALLER_DIR}/.." && pwd)"
VERIFIER_SCRIPT="${ROBOREV_VERIFIER_SCRIPT:-${_REPO_ROOT}/.claude/scripts/roborev_verify_closure.sh}"

usage() {
  echo "Usage: $0 <repo-path>" >&2
  echo "  repo-path: path to a git working tree (must contain .git/)" >&2
  exit 1
}

# ── Argument validation ───────────────────────────────────────────────────────

if [ $# -ne 1 ]; then
  usage
fi

REPO_PATH="$1"

if [ ! -d "${REPO_PATH}/.git" ]; then
  echo "ERROR: not a git repository (no .git/ directory): ${REPO_PATH}" >&2
  exit 1
fi

HOOKS_DIR="${REPO_PATH}/.git/hooks"
HOOK_FILE="${HOOKS_DIR}/post-commit"

# ── Check for unrecognised existing hook ──────────────────────────────────────

if [ -f "${HOOK_FILE}" ]; then
  if grep -qF "${INSTALLER_MARKER}" "${HOOK_FILE}" 2>/dev/null; then
    : # our hook — safe to overwrite / refresh
  else
    echo "CHAIN: ${REPO_PATH} already has a post-commit hook not written by this installer." >&2
    echo "       To add the verifier, append the following to ${HOOK_FILE}:" >&2
    echo "" >&2
    echo "  # ── roborev post-commit verifier (#353) ──────────────────────────────────" >&2
    echo "  [ \"\${ROBOREV_VERIFY_SKIP:-0}\" = \"1\" ] && exit 0" >&2
    echo "  _sha=\$(git rev-parse HEAD)" >&2
    echo "  _ids=\$(git log -1 --pretty=format:%B \"\$_sha\" \\" >&2
    echo "    | grep -oE 'closes roborev #[0-9]+' \\" >&2
    echo "    | grep -oE '[0-9]+' | sort -u)" >&2
    echo "  [ -z \"\$_ids\" ] && exit 0" >&2
    # shellcheck disable=SC2016
    echo "  nohup \"${VERIFIER_SCRIPT}\" \"\$_sha\" \$_ids >/dev/null 2>&1 &" >&2
    echo "" >&2
    exit 0
  fi
fi

# ── Write the hook ────────────────────────────────────────────────────────────

cat > "${HOOK_FILE}" <<HOOK
#!/usr/bin/env bash
# Installed by ~/docs_gh/llm/bin/roborev_install_post_commit_verifier.sh
# Post-commit verifier for roborev closure citations (JohnGavin/llm#353).
#
# When the commit message contains "closes roborev #N" (or "fixes/fix/close/
# wontfix roborev #N"), this hook asynchronously invokes the verifier so that
# a verdict JSON is produced without blocking git.
#
# Set ROBOREV_VERIFY_SKIP=1 to skip for a single commit.
[ "\${ROBOREV_VERIFY_SKIP:-0}" = "1" ] && exit 0

_sha=\$(git rev-parse HEAD 2>/dev/null || true)
[ -z "\$_sha" ] && exit 0

_msg=\$(git log -1 --pretty=format:%B "\$_sha" 2>/dev/null || true)
[ -z "\$_msg" ] && exit 0

# Parse "closes/fixes/fix/close/wontfix roborev #N" citations
_ids=\$(printf '%s\n' "\$_msg" \
  | grep -oiE '(closes?|fixes?|wontfix)[[:space:]]+roborev[[:space:]#]+[0-9]+([[:space:],#]+[0-9]+)*' \
  | grep -oE '[0-9]+' \
  | sort -u)
[ -z "\$_ids" ] && exit 0

VERIFIER="${VERIFIER_SCRIPT}"
if [ ! -x "\$VERIFIER" ]; then
  exit 0
fi

# nohup so the verifier runs asynchronously — never blocks git
# shellcheck disable=SC2086
nohup "\$VERIFIER" "\$_sha" \$_ids >/dev/null 2>&1 &

exit 0
HOOK

chmod +x "${HOOK_FILE}"

echo "OK: installed post-commit verifier hook in ${REPO_PATH}"
