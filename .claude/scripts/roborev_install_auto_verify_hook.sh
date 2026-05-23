#!/usr/bin/env bash
# roborev_install_auto_verify_hook.sh — install the auto-verifier as a post-commit hook
#
# Usage:
#   roborev_install_auto_verify_hook.sh [--repo <path>] [--dry-run]
#
# Flags:
#   --repo <path>   Path to the git repository to install into.
#                   Default: current directory (git rev-parse --show-toplevel).
#   --dry-run       Print what would happen; do not create or modify any files.
#   --uninstall     Remove the hook (restores backup if present).
#   --help          Show this message.
#
# What it does:
#   1. Verifies the repo is a git repository.
#   2. Verifies DB migration v2 has been applied (closures + fix_rejected_queue tables).
#   3. Backs up any existing post-commit hook as post-commit.pre-autoverify.bak
#   4. Creates a post-commit hook that calls roborev_auto_verify.sh --apply
#      (chaining the existing hook if one was present).
#
# MANUAL INSTALL ONLY: this script is never auto-invoked.
# Run it explicitly after reviewing its output with --dry-run.
#
# Pilot: designed for use with t_demos project first. Do NOT install on
# Critical-finding projects until the t_demos pilot completes (≥3 auto-closures,
# 0 wrong-closures).
#
# Issue: JohnGavin/llm#163 Slice 3

set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

VERIFIER_SCRIPT="$(dirname "$(realpath "$0")")/roborev_auto_verify.sh"
ROBOREV_DB="${ROBOREV_DB:-${HOME}/.roborev/reviews.db}"

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//' | head -30
}

# ── Argument parsing ───────────────────────────────────────────────────────────

REPO_PATH=""
DRY_RUN=0
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      shift
      [ $# -gt 0 ] || { echo "ERROR: --repo requires an argument" >&2; exit 1; }
      REPO_PATH="$1"; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    --uninstall)
      UNINSTALL=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

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

HOOK_PATH="${GIT_DIR}/hooks/post-commit"
BACKUP_PATH="${HOOK_PATH}.pre-autoverify.bak"
HOOKS_DIR="${GIT_DIR}/hooks"

# ── Uninstall mode ─────────────────────────────────────────────────────────────

if [ "$UNINSTALL" -eq 1 ]; then
  echo "roborev_install_auto_verify_hook: uninstalling from ${REPO_PATH}"

  if [ ! -e "$HOOK_PATH" ]; then
    echo "  No post-commit hook found at ${HOOK_PATH} — nothing to remove"
    exit 0
  fi

  # Verify this is actually our hook before removing
  if ! grep -q 'roborev_auto_verify' "$HOOK_PATH" 2>/dev/null; then
    echo "  WARNING: post-commit hook at ${HOOK_PATH} does not appear to be our hook"
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

  echo "roborev_install_auto_verify_hook: uninstall complete"
  exit 0
fi

# ── Install mode: pre-flight checks ──────────────────────────────────────────

echo "roborev_install_auto_verify_hook: installing into ${REPO_PATH}"

# Check verifier script exists
if [ ! -f "$VERIFIER_SCRIPT" ]; then
  echo "ERROR: verifier script not found at ${VERIFIER_SCRIPT}" >&2
  exit 1
fi

# Check DB migration v2 applied
if [ -f "$ROBOREV_DB" ]; then
  MIGRATION_OK=$(/usr/bin/python3 - "$ROBOREV_DB" <<'PY'
import sqlite3, sys
db = sys.argv[1]
try:
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2.0)
    rows = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('closures','fix_rejected_queue')"
    ).fetchall()
    conn.close()
    names = {r[0] for r in rows}
    if 'closures' in names and 'fix_rejected_queue' in names:
        print("ok")
    else:
        missing = {'closures','fix_rejected_queue'} - names
        print(f"missing:{','.join(missing)}")
except Exception as e:
    print(f"warn:{e}")
PY
  )

  if [ "$MIGRATION_OK" != "ok" ]; then
    echo "WARNING: DB migration v2 check: ${MIGRATION_OK}" >&2
    echo "  Run: sqlite3 ~/.roborev/reviews.db < ~/.claude/scripts/roborev_schema_migration_v2.sql" >&2
    echo "  Proceeding anyway (hook is fail-open and will skip until migration is applied)" >&2
  else
    echo "  DB migration v2: ok"
  fi
else
  echo "  DB not found at ${ROBOREV_DB} — hook is fail-open, will skip if DB absent"
fi

# Check verifier self-test
echo "  Running verifier self-test..."
if SELFTEST=1 bash "$VERIFIER_SCRIPT" >/dev/null 2>&1; then
  echo "  Self-test: PASS"
else
  echo "ERROR: verifier self-test failed — abort install" >&2
  echo "  Run: SELFTEST=1 bash ${VERIFIER_SCRIPT}" >&2
  exit 1
fi

# ── Build hook content ─────────────────────────────────────────────────────────

# Hook chains an existing post-commit hook if one is present.
# The chain calls the old hook first, then the verifier.
CHAIN_CALL=""
if [ -e "$HOOK_PATH" ] && [ ! -L "$HOOK_PATH" ]; then
  # There is an existing non-symlink hook — back it up and chain it
  if [ "$DRY_RUN" -eq 0 ]; then
    cp "$HOOK_PATH" "$BACKUP_PATH"
    echo "  Backed up existing post-commit hook to: ${BACKUP_PATH}"
  else
    echo "  [dry-run] would back up existing hook to: ${BACKUP_PATH}"
  fi
  CHAIN_CALL='# Chain the original hook
if [ -x "'"${BACKUP_PATH}"'" ]; then
    "'"${BACKUP_PATH}"'"
fi
'
fi

HOOK_CONTENT="#!/usr/bin/env bash
# roborev auto-verifier post-commit hook
# Installed by: roborev_install_auto_verify_hook.sh
# Verifier:     ${VERIFIER_SCRIPT}
# Issue:        JohnGavin/llm#163

${CHAIN_CALL}
# Invoke the auto-verifier (fail-open: never blocks the commit)
if [ -x '${VERIFIER_SCRIPT}' ]; then
    '${VERIFIER_SCRIPT}' --apply || true
fi
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
echo "roborev_install_auto_verify_hook: installation complete"
echo ""
echo "Next steps:"
echo "  1. Make a test commit with 'closes roborev #N' to verify the hook fires"
echo "  2. Confirm dry-run: SELFTEST=1 bash ${VERIFIER_SCRIPT}"
echo "  3. Monitor: tail -f ~/.claude/logs/roborev_auto_verify.log"
echo ""
echo "Pilot note: test on t_demos first. Expand only after ≥3 auto-closures, 0 wrong-closures."
