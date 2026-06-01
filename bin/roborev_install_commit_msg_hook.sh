#!/usr/bin/env bash
# bin/roborev_install_commit_msg_hook.sh <repo-path>
#
# Installs a commit-msg git hook that validates any "closes roborev #N" or
# "acks roborev #N" citations in the commit message against
# ~/.roborev/reviews.db.
#
# For each cited review ID the hook checks:
#   1. The ID exists in the reviews table.
#   2. The ID is currently closed=0 (citing a closed finding is a no-op warn).
#   3. The ID's repo matches the current repo by basename heuristic
#      (cross-repo citations are flagged as a warning, not a hard error).
#
# If any cited ID does not exist in the DB the hook exits non-zero, aborting
# the commit.  A warning is printed for already-closed or cross-repo IDs.
#
# Emergency bypass: set ROBOREV_COMMIT_HOOK_SKIP=1 before committing.
#
# Idempotent: re-running on a repo that already has our hook refreshes the
# marker comment but otherwise changes nothing.
#
# Safety: refuses to overwrite an UNRECOGNISED existing commit-msg hook
# (one that lacks the installer marker comment).  Prints a warning and
# exits 0 so the all-repos wrapper can continue.
#
# Usage:
#   bin/roborev_install_commit_msg_hook.sh /path/to/repo
#
# Part of: JohnGavin/llm#352 — commit-msg citation validator
# Installed-by marker (must stay on line ~14 for idempotency detection):
#   Installed by ~/docs_gh/llm/bin/roborev_install_commit_msg_hook.sh

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

INSTALLER_MARKER="Installed by ~/docs_gh/llm/bin/roborev_install_commit_msg_hook.sh"

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
HOOK_FILE="${HOOKS_DIR}/commit-msg"

# ── Check for unrecognised existing hook ────────────────────────────────────
if [[ -f "${HOOK_FILE}" ]]; then
    if grep -qF "${INSTALLER_MARKER}" "${HOOK_FILE}" 2>/dev/null; then
        : # our hook — safe to overwrite / refresh
    else
        echo "SKIP: ${REPO_PATH} — existing commit-msg hook not written by this installer." >&2
        echo "      Inspect ${HOOK_FILE} manually if you want to replace it." >&2
        exit 0
    fi
fi

# ── Write the hook ───────────────────────────────────────────────────────────
cat > "${HOOK_FILE}" <<'HOOK'
#!/usr/bin/env bash
# Installed by ~/docs_gh/llm/bin/roborev_install_commit_msg_hook.sh
# Validates "closes roborev #N" / "acks roborev #N" citations in commit
# messages against ~/.roborev/reviews.db.
#
# Exit codes:
#   0   All citations valid (or no citations / DB absent / bypass active)
#   1   One or more cited IDs do not exist in the DB
#
# Bypass: ROBOREV_COMMIT_HOOK_SKIP=1
#
# Part of: JohnGavin/llm#352

set -uo pipefail

# ── Bypass ───────────────────────────────────────────────────────────────────
[ "${ROBOREV_COMMIT_HOOK_SKIP:-0}" = "1" ] && exit 0

# ── Validate argument ────────────────────────────────────────────────────────
msg_file="${1:?commit-msg hook requires the commit message file path as \$1}"
[ -f "${msg_file}" ] || { echo "roborev-hook: commit message file not found: ${msg_file}" >&2; exit 0; }

# ── Parse cited IDs ──────────────────────────────────────────────────────────
# Matches: closes roborev #N, close roborev #N, fixes roborev #N,
#          acks roborev #N, ack roborev #N (case-insensitive)
ids="$(grep -oiE '(close[sd]?|fix(es)?|acks?) roborev #[0-9]+' "${msg_file}" \
       | grep -oE '[0-9]+' | sort -un | tr '\n' ' ' | sed 's/ $//')"

[ -z "${ids}" ] && exit 0

# ── DB path ──────────────────────────────────────────────────────────────────
ROBOREV_DB="${ROBOREV_DB:-${HOME}/.roborev/reviews.db}"

# Fail-open: DB absent
if [ ! -f "${ROBOREV_DB}" ]; then
    echo "roborev-hook: WARN — reviews.db not found; skipping citation check" >&2
    exit 0
fi

# ── Repo name heuristic ──────────────────────────────────────────────────────
# Use the basename of the git common dir's parent (the repo root).
# For worktrees git rev-parse --show-toplevel gives the worktree root whose
# basename may be "agent-XXX"; use git worktree common dir instead.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
current_repo="$(basename "$(git -C "${repo_root}" rev-parse --git-common-dir 2>/dev/null \
    | sed 's|/\.git$||' | sed 's|\.git$||')" 2>/dev/null || basename "${repo_root}")"
# Strip worktree agent suffix patterns like "agent-XXXX" by falling back to
# the git common dir's parent directory name.
git_common="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
if [ -n "${git_common}" ]; then
    # git_common is .git or an absolute path ending in .git
    repo_from_common="$(basename "$(dirname "$(realpath "${git_common}" 2>/dev/null || echo "${git_common}")")")"
    current_repo="${repo_from_common}"
fi

# ── Validate via Python + sqlite3 ────────────────────────────────────────────
/usr/bin/python3 - "${ROBOREV_DB}" "${ids}" "${current_repo}" <<'PY'
import sys, sqlite3, os, re

db_path     = sys.argv[1]
ids_str     = sys.argv[2]
current_repo = sys.argv[3].strip()

# Parse IDs
cited_ids = [int(x) for x in ids_str.split() if x.strip().isdigit()]
if not cited_ids:
    sys.exit(0)

missing  = []
already_closed = []
cross_repo = []

try:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)

    for rid in cited_ids:
        row = con.execute("""
            SELECT r.id, r.closed, repos.name
            FROM   reviews r
            JOIN   review_jobs rj ON r.job_id = rj.id
            JOIN   repos           ON rj.repo_id = repos.id
            WHERE  r.id = ?
        """, (rid,)).fetchone()

        if row is None:
            missing.append(rid)
        else:
            (_, closed, repo_name) = row
            if closed == 1:
                already_closed.append(rid)
            if repo_name and repo_name.lower() != current_repo.lower():
                cross_repo.append((rid, repo_name))

    con.close()
except Exception as e:
    # Fail-open: DB error → allow commit
    print(f"roborev-hook: WARN — DB error ({e}); skipping citation check", file=sys.stderr)
    sys.exit(0)

# Warnings (non-fatal)
for rid in already_closed:
    print(f"roborev-hook: WARN  — roborev #{rid} is already closed=1 (citation is a no-op)", file=sys.stderr)

for (rid, repo_name) in cross_repo:
    if rid not in [r for r in already_closed]:  # avoid double-warning
        print(f"roborev-hook: WARN  — roborev #{rid} belongs to repo '{repo_name}', not '{current_repo}'",
              file=sys.stderr)

# Hard errors (fatal — block commit)
if missing:
    ids_str_fmt = ", ".join(f"#{r}" for r in sorted(missing))
    print(f"roborev-hook: ERROR — cited ID(s) not found in reviews.db: {ids_str_fmt}", file=sys.stderr)
    print(f"roborev-hook:         Verify the IDs with: roborev list", file=sys.stderr)
    print(f"roborev-hook:         To bypass: ROBOREV_COMMIT_HOOK_SKIP=1 git commit ...", file=sys.stderr)
    sys.exit(1)

sys.exit(0)
PY
HOOK

chmod +x "${HOOK_FILE}"

echo "OK: installed commit-msg hook in ${REPO_PATH}"
