#!/usr/bin/env bash
# roborev_install_post_merge_hook.sh — install a post-merge git hook that
# triggers a roborev review for commits that arrive via git pull / git merge.
#
# Background:
#   The post-commit hook covers local commits but NOT remote-merged PRs.
#   When a developer does `git pull`, the newly-arrived commits bypass
#   post-commit entirely.  A post-merge hook fires on every successful merge
#   that changes HEAD (fast-forward, octopus, recursive) — that's exactly
#   when pull-merged PRs arrive locally.
#
#   The hook runs:
#     roborev review --since ORIG_HEAD --branch <current-branch>
#
#   ORIG_HEAD is set by git to the pre-merge HEAD, so this naturally scopes
#   the review to the commits that just arrived.  Rebase merges are excluded
#   because they do NOT set ORIG_HEAD in the same way (see note below).
#
# Usage:
#   roborev_install_post_merge_hook.sh [--repo <path>] [--dry-run]
#   roborev_install_post_merge_hook.sh [--repo <path>] --uninstall
#   roborev_install_post_merge_hook.sh --selftest
#
# Flags:
#   --repo <path>   Git repository to install into. Default: current directory.
#   --dry-run       Print what would happen; do not create or modify any files.
#   --uninstall     Remove the hook (restores backup if present).
#   --selftest      Run the fixture-repo install + mock-merge self-test.
#   --help          Show this message.
#
# Idempotency:
#   If a post-merge hook already exists, it is backed up to
#   post-merge.pre-roborev.bak and the new roborev hook is appended AFTER it.
#   Re-running the installer on a repo that already has the roborev hook is a
#   no-op (detected by a marker string in the existing hook body).
#
# MANUAL INSTALL ONLY: this script is never auto-invoked.
# Run it explicitly after reviewing its output with --dry-run.
#
# Issue: JohnGavin/llm#217

set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# ── Phase-1.6 shim guard (JohnGavin/llm#386) ─────────────────────────────────
if [ ! -x "${HOME}/.local/bin/roborev" ]; then
  echo "WARNING: ~/.local/bin/roborev shim not installed." >&2
  echo "  The codex_with_fallback.sh wrapper will NOT intercept reviews." >&2
  echo "  Install: ~/docs_gh/llm/.claude/scripts/install_roborev_primary_shim.sh" >&2
  echo "" >&2
fi

ROBOREV="${ROBOREV:-/usr/local/bin/roborev}"
ROBOREV_DB="${ROBOREV_DB:-${HOME}/.roborev/reviews.db}"
# Marker string written into the hook to detect prior installation
HOOK_MARKER="roborev post-merge hook — installed by roborev_install_post_merge_hook.sh"

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//' | head -40
}

# ── Argument parsing ───────────────────────────────────────────────────────────

REPO_PATH=""
DRY_RUN=0
UNINSTALL=0
SELFTEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      shift
      [ $# -gt 0 ] || { echo "ERROR: --repo requires an argument" >&2; exit 1; }
      REPO_PATH="$1"; shift ;;
    --dry-run)   DRY_RUN=1;    shift ;;
    --uninstall) UNINSTALL=1;  shift ;;
    --selftest)  SELFTEST=1;   shift ;;
    -h|--help)   usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# ── Self-test mode ─────────────────────────────────────────────────────────────
if [ "$SELFTEST" -eq 1 ] || [ "${CLAUDE_HOOK_SELFTEST:-0}" = "1" ]; then
  echo "roborev_install_post_merge_hook: running self-test..."

  FIXTURE_DIR=$(mktemp -d /tmp/roborev_pmhook_test_XXXXXX)
  trap 'rm -rf "$FIXTURE_DIR"' EXIT

  # Unset the selftest env var so sub-invocations run in normal (non-selftest) mode.
  unset CLAUDE_HOOK_SELFTEST

  # Set up a minimal git repo
  git -C "$FIXTURE_DIR" init -q
  git -C "$FIXTURE_DIR" config user.email "test@test.com"
  git -C "$FIXTURE_DIR" config user.name "Test"
  echo "init" > "$FIXTURE_DIR/file.txt"
  git -C "$FIXTURE_DIR" add file.txt
  git -C "$FIXTURE_DIR" commit -q -m "initial"

  # 1. Dry-run install should not write any files
  bash "$0" --repo "$FIXTURE_DIR" --dry-run
  if [ -f "$FIXTURE_DIR/.git/hooks/post-merge" ]; then
    echo "FAIL: dry-run wrote post-merge hook (should not)" >&2; exit 1
  fi
  echo "  [1/5] dry-run: PASS (no file written)"

  # 2. Real install
  bash "$0" --repo "$FIXTURE_DIR"
  if [ ! -f "$FIXTURE_DIR/.git/hooks/post-merge" ]; then
    echo "FAIL: hook not installed at $FIXTURE_DIR/.git/hooks/post-merge" >&2; exit 1
  fi
  if [ ! -x "$FIXTURE_DIR/.git/hooks/post-merge" ]; then
    echo "FAIL: hook is not executable" >&2; exit 1
  fi
  if ! grep -q "$HOOK_MARKER" "$FIXTURE_DIR/.git/hooks/post-merge" 2>/dev/null; then
    echo "FAIL: marker string not found in installed hook" >&2; exit 1
  fi
  echo "  [2/5] install: PASS (hook written + executable + marker present)"

  # 3. Re-install is idempotent (marker detected, no second backup created)
  MTIME_BEFORE=$(stat -f '%m' "$FIXTURE_DIR/.git/hooks/post-merge" 2>/dev/null || echo "0")
  DRY_RUN=0 bash "$0" --repo "$FIXTURE_DIR"
  MTIME_AFTER=$(stat -f '%m' "$FIXTURE_DIR/.git/hooks/post-merge" 2>/dev/null || echo "0")
  if [ "$MTIME_BEFORE" != "$MTIME_AFTER" ]; then
    echo "FAIL: re-install modified the hook (should be idempotent)" >&2; exit 1
  fi
  echo "  [3/5] idempotency: PASS (re-install was no-op)"

  # 4. Mock fast-forward merge — hook fires but roborev is absent, exits 0 (fail-open)
  # Simulate ORIG_HEAD by creating a prior commit
  echo "v2" > "$FIXTURE_DIR/file.txt"
  git -C "$FIXTURE_DIR" add file.txt
  git -C "$FIXTURE_DIR" commit -q -m "v2"
  ORIG_HEAD=$(git -C "$FIXTURE_DIR" rev-parse HEAD~1)
  export ORIG_HEAD
  # Run hook directly (simulating what git would do)
  set +e
  ROBOREV=/usr/bin/false bash "$FIXTURE_DIR/.git/hooks/post-merge" 2>/dev/null
  HOOK_EXIT=$?
  set -e
  if [ "$HOOK_EXIT" -ne 0 ]; then
    echo "FAIL: hook should exit 0 when roborev is absent (fail-open)" >&2; exit 1
  fi
  echo "  [4/5] fail-open (missing roborev): PASS (hook exits 0)"

  # 5. Uninstall
  DRY_RUN=0 bash "$0" --repo "$FIXTURE_DIR" --uninstall
  if [ -f "$FIXTURE_DIR/.git/hooks/post-merge" ]; then
    echo "FAIL: uninstall left hook file behind" >&2; exit 1
  fi
  echo "  [5/5] uninstall: PASS (hook removed)"

  echo ""
  echo "roborev_install_post_merge_hook: self-test PASSED (5/5)"
  exit 0
fi

# ── Resolve repo root ──────────────────────────────────────────────────────────

if [ -z "$REPO_PATH" ]; then
  REPO_PATH=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -z "$REPO_PATH" ]; then
    echo "ERROR: not inside a git repository and --repo not specified" >&2
    exit 1
  fi
fi

if ! git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: $REPO_PATH is not a git repository" >&2
  exit 1
fi

GIT_DIR=$(git -C "$REPO_PATH" rev-parse --git-dir)
case "$GIT_DIR" in
  /*) : ;;
  *) GIT_DIR="${REPO_PATH}/${GIT_DIR}" ;;
esac

HOOK_PATH="${GIT_DIR}/hooks/post-merge"
BACKUP_PATH="${HOOK_PATH}.pre-roborev.bak"
HOOKS_DIR="${GIT_DIR}/hooks"

# ── Uninstall mode ─────────────────────────────────────────────────────────────

if [ "$UNINSTALL" -eq 1 ]; then
  echo "roborev_install_post_merge_hook: uninstalling from ${REPO_PATH}"

  if [ ! -e "$HOOK_PATH" ]; then
    echo "  No post-merge hook found at ${HOOK_PATH} — nothing to remove"
    exit 0
  fi

  if ! grep -q "$HOOK_MARKER" "$HOOK_PATH" 2>/dev/null; then
    echo "  WARNING: post-merge hook at ${HOOK_PATH} does not appear to be our hook"
    echo "  Refusing to remove. Remove manually if intended."
    exit 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] would remove ${HOOK_PATH}"
    if [ -f "$BACKUP_PATH" ]; then
      echo "  [dry-run] would restore backup from ${BACKUP_PATH}"
    fi
    exit 0
  fi

  rm -f "$HOOK_PATH"
  echo "  Removed ${HOOK_PATH}"

  if [ -f "$BACKUP_PATH" ]; then
    mv "$BACKUP_PATH" "$HOOK_PATH"
    chmod +x "$HOOK_PATH"
    echo "  Restored backup: ${BACKUP_PATH} → ${HOOK_PATH}"
  fi

  echo "roborev_install_post_merge_hook: uninstall complete"
  exit 0
fi

# ── Install mode: pre-flight checks ──────────────────────────────────────────

echo "roborev_install_post_merge_hook: installing into ${REPO_PATH}"

# Check for idempotency — already installed?
if [ -f "$HOOK_PATH" ] && grep -q "$HOOK_MARKER" "$HOOK_PATH" 2>/dev/null; then
  echo "  post-merge hook already installed (marker detected) — no changes made."
  echo "  To reinstall, run --uninstall first."
  exit 0
fi

# ── Chain existing hook if present ────────────────────────────────────────────

CHAIN_CALL=""
if [ -e "$HOOK_PATH" ] && [ ! -L "$HOOK_PATH" ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    cp "$HOOK_PATH" "$BACKUP_PATH"
    echo "  Backed up existing post-merge hook to: ${BACKUP_PATH}"
  else
    echo "  [dry-run] would back up existing hook to: ${BACKUP_PATH}"
  fi
  CHAIN_CALL='# Chain the original post-merge hook (backed up at install time)
if [ -x "'"${BACKUP_PATH}"'" ]; then
    "'"${BACKUP_PATH}"'"
fi
'
fi

# ── Build hook content ─────────────────────────────────────────────────────────
#
# The hook detects fast-forward merges by checking that ORIG_HEAD is set and
# non-empty (git sets it for merge, pull --rebase does not set it reliably).
# It then calls:
#   roborev review --since ORIG_HEAD --branch <current-branch>
#
# Fail-open: any error exits 0 so the merge is never blocked.
#
HOOK_CONTENT="#!/usr/bin/env bash
# ${HOOK_MARKER}
# Installed: $(date '+%Y-%m-%d')
# Issue: JohnGavin/llm#217

${CHAIN_CALL}
# ── roborev post-merge review ─────────────────────────────────────────────────
# Fires when 'git pull' or 'git merge' completes. Reviews commits that just
# arrived from remote so PR-merged commits don't slip past roborev.
#
# Skip conditions:
#   - ORIG_HEAD not set (rebase merge, cherry-pick, or git am)
#   - ORIG_HEAD equals current HEAD (no new commits, merge was a no-op)
#   - roborev binary not found
#
ROBOREV_BIN=\"\${ROBOREV:-/usr/local/bin/roborev}\"

# Use the shim if available (Phase-1.6 codex fallback, llm#386)
if [ -x \"\${HOME}/.local/bin/roborev\" ]; then
  ROBOREV_BIN=\"\${HOME}/.local/bin/roborev\"
fi

if [ ! -x \"\$ROBOREV_BIN\" ]; then
  exit 0  # fail-open: roborev not installed
fi

if [ -z \"\${ORIG_HEAD:-}\" ]; then
  exit 0  # not a regular merge (rebase, am, cherry-pick)
fi

CURRENT_HEAD=\$(git rev-parse HEAD 2>/dev/null) || exit 0

if [ \"\$ORIG_HEAD\" = \"\$CURRENT_HEAD\" ]; then
  exit 0  # merge was a no-op (already up to date)
fi

CURRENT_BRANCH=\$(git branch --show-current 2>/dev/null || echo '')

if [ -n \"\$CURRENT_BRANCH\" ]; then
  \"\$ROBOREV_BIN\" review --since \"\$ORIG_HEAD\" --branch \"\$CURRENT_BRANCH\" >/dev/null 2>&1 || true
else
  \"\$ROBOREV_BIN\" review --since \"\$ORIG_HEAD\" >/dev/null 2>&1 || true
fi

exit 0  # always exit 0 — never block the merge
"

if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "[dry-run] would write ${HOOK_PATH}:"
  echo "--- begin hook ---"
  printf '%s\n' "$HOOK_CONTENT"
  echo "--- end hook ---"
  echo ""
  echo "Pass without --dry-run to install."
  exit 0
fi

# ── Write hook ────────────────────────────────────────────────────────────────

mkdir -p "$HOOKS_DIR"
printf '%s\n' "$HOOK_CONTENT" > "$HOOK_PATH"
chmod +x "$HOOK_PATH"

echo "  Installed: ${HOOK_PATH}"
echo ""
echo "roborev_install_post_merge_hook: installation complete"
echo ""
echo "Next steps:"
echo "  1. Pull from remote to verify the hook fires:"
echo "     git pull && tail -5 ~/.claude/logs/roborev_poll_merges.log"
echo "  2. Self-test: CLAUDE_HOOK_SELFTEST=1 bash $0"
echo "  3. Monitor: tail -f ~/.claude/logs/roborev_poll_merges.log"
echo ""
echo "Install on each watched repo separately:"
echo "  bash ~/docs_gh/llm/.claude/scripts/roborev_install_post_merge_hook.sh --repo <path>"
