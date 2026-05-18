#!/usr/bin/env bash
# roborev_commit_msg_validator.sh — commit-msg git hook
#
# Validates roborev citations in commit messages against the local reviews DB.
# Installed as: <repo>/.git/hooks/commit-msg (via --install flag)
#
# Usage (as git hook — git passes msg file as $1):
#   roborev_commit_msg_validator.sh <msg-file>
#
# Install into a repo:
#   roborev_commit_msg_validator.sh --install /path/to/repo
#
# Self-test (8 cases):
#   roborev_commit_msg_validator.sh --self-test
#
# Bypass (emergency only — never silent):
#   SKIP_ROBOREV_VALIDATOR=1 git commit -m "..."
#
# Configuration:
#   ROBOREV_DB — override DB path (default: ~/.roborev/reviews.db)
#
# Behaviour:
#   - No citations in message → exit 0 (passthrough)
#   - ID exists and closed=0  → exit 0 (valid open citation)
#   - ID exists and closed=1  → exit 1 (duplicate close attempt)
#   - ID does not exist        → exit 1 (typo or stale citation)
#   - DB unreachable           → exit 0 (fail-open, warning to stderr)
#
# Issue: #163 Phase 2
# Pattern: \(closes roborev #(\d+(?:[ ,]+#?\d+)*)\)

set -euo pipefail

SCRIPT_PATH="$(realpath "$0")"
ROBOREV_DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"

# ── Self-test mode ──────────────────────────────────────────────────────────
if [ "${1:-}" = "--self-test" ]; then
  _pass=0
  _fail=0
  _TMPDIR="$(mktemp -d)"
  _TMPDB="$_TMPDIR/test_reviews.db"
  _TMPMSG="$_TMPDIR/commit_msg.txt"

  # Cleanup on exit
  trap 'rm -rf "$_TMPDIR"' EXIT

  # Build test DB: id=99001 (open), id=99002 (closed), 99003 absent
  /usr/bin/python3 - "$_TMPDB" <<'PY'
import sqlite3, sys
db = sys.argv[1]
conn = sqlite3.connect(db)
conn.execute("""
  CREATE TABLE reviews (
    id      INTEGER PRIMARY KEY,
    closed  INTEGER NOT NULL DEFAULT 0
  )
""")
conn.execute("INSERT INTO reviews (id, closed) VALUES (99001, 0)")
conn.execute("INSERT INTO reviews (id, closed) VALUES (99002, 1)")
conn.commit()
conn.close()
PY

  _run_case() {
    local desc="$1"
    local msg="$2"
    local expected_exit="$3"
    local env_extra="${4:-}"

    printf '%s' "$msg" > "$_TMPMSG"

    local actual_exit=0
    if [ -n "$env_extra" ]; then
      env ROBOREV_DB="$_TMPDB" $env_extra bash "$SCRIPT_PATH" "$_TMPMSG" >/dev/null 2>&1 || actual_exit=$?
    else
      env ROBOREV_DB="$_TMPDB" bash "$SCRIPT_PATH" "$_TMPMSG" >/dev/null 2>&1 || actual_exit=$?
    fi

    if [ "$actual_exit" -eq "$expected_exit" ]; then
      printf '  PASS  [%s]\n' "$desc"
      _pass=$((_pass + 1))
    else
      printf '  FAIL  [%s] -- expected exit %s, got exit %s\n' \
        "$desc" "$expected_exit" "$actual_exit"
      _fail=$((_fail + 1))
    fi
  }

  echo "=== roborev_commit_msg_validator.sh self-test ==="

  _run_case \
    "valid open citation #99001" \
    "fix: thing (closes roborev #99001)" \
    0

  _run_case \
    "already-closed #99002" \
    "fix: thing (closes roborev #99002)" \
    1

  _run_case \
    "nonexistent #99003" \
    "fix: thing (closes roborev #99003)" \
    1

  _run_case \
    "multi: one bad (#99001,#99002)" \
    "fix: thing (closes roborev #99001,#99002)" \
    1

  _run_case \
    "passthrough — no citation" \
    "docs: routine update" \
    0

  _run_case \
    "wontfix form with open #99001" \
    "chore(triage): wontfix [reason: dormant] (closes roborev #99001)" \
    0

  # DB unreachable → fail-open
  printf '%s' "fix: thing (closes roborev #99001)" > "$_TMPMSG"
  _actual_exit=0
  env ROBOREV_DB="/nonexistent/path/reviews.db" bash "$SCRIPT_PATH" "$_TMPMSG" >/dev/null 2>&1 || _actual_exit=$?
  if [ "$_actual_exit" -eq 0 ]; then
    printf '  PASS  [DB unreachable → fail-open]\n'
    _pass=$((_pass + 1))
  else
    printf '  FAIL  [DB unreachable → fail-open] -- expected exit 0, got exit %s\n' "$_actual_exit"
    _fail=$((_fail + 1))
  fi

  # Bypass via SKIP_ROBOREV_VALIDATOR=1 with a bad citation
  printf '%s' "fix: thing (closes roborev #99002)" > "$_TMPMSG"
  _actual_exit=0
  env ROBOREV_DB="$_TMPDB" SKIP_ROBOREV_VALIDATOR=1 bash "$SCRIPT_PATH" "$_TMPMSG" >/dev/null 2>&1 || _actual_exit=$?
  if [ "$_actual_exit" -eq 0 ]; then
    printf '  PASS  [SKIP_ROBOREV_VALIDATOR bypass]\n'
    _pass=$((_pass + 1))
  else
    printf '  FAIL  [SKIP_ROBOREV_VALIDATOR bypass] -- expected exit 0, got exit %s\n' "$_actual_exit"
    _fail=$((_fail + 1))
  fi

  echo ""
  echo "=== Results: $_pass passed, $_fail failed (of 8) ==="
  [ "$_fail" -eq 0 ] && exit 0 || exit 1
fi

# ── Installer mode ──────────────────────────────────────────────────────────
if [ "${1:-}" = "--install" ]; then
  REPO_PATH="${2:-}"
  if [ -z "$REPO_PATH" ]; then
    echo "Usage: $0 --install <repo-path>" >&2
    exit 1
  fi

  # Verify it's a git repo
  if ! git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: $REPO_PATH is not a git repository" >&2
    exit 1
  fi

  GIT_DIR="$(git -C "$REPO_PATH" rev-parse --git-dir)"
  # Make absolute if relative
  case "$GIT_DIR" in
    /*) : ;;
    *) GIT_DIR="$REPO_PATH/$GIT_DIR" ;;
  esac

  HOOK_PATH="$GIT_DIR/hooks/commit-msg"
  BACKUP_PATH="$HOOK_PATH.pre-validator.bak"

  # Ensure script is executable
  chmod +x "$SCRIPT_PATH"

  # Backup any existing hook
  if [ -e "$HOOK_PATH" ] && [ ! -L "$HOOK_PATH" ]; then
    cp "$HOOK_PATH" "$BACKUP_PATH"
    echo "Backed up existing commit-msg hook to: $BACKUP_PATH"
  fi

  # Remove any existing hook (symlink or file)
  rm -f "$HOOK_PATH"

  # Create symlink
  ln -s "$SCRIPT_PATH" "$HOOK_PATH"
  echo "Installed: $HOOK_PATH -> $SCRIPT_PATH"
  echo "Run '$SCRIPT_PATH --self-test' to verify."
  exit 0
fi

# ── Normal hook execution ────────────────────────────────────────────────────

# Emergency bypass — never silent
if [ -n "${SKIP_ROBOREV_VALIDATOR:-}" ]; then
  echo "roborev_commit_msg_validator: SKIPPED (SKIP_ROBOREV_VALIDATOR is set)" >&2
  exit 0
fi

MSG_FILE="${1:-}"
if [ -z "$MSG_FILE" ] || [ ! -f "$MSG_FILE" ]; then
  # No message file (unusual invocation) — passthrough
  exit 0
fi

MSG="$(cat "$MSG_FILE")"

# Extract all roborev IDs from citations.
# Pattern: (closes roborev #N) or (closes roborev #N,#M,...) or (closes roborev #N #M)
# Handles: single, multi-comma, multi-space, optional # prefix after first
IDS="$(/usr/bin/python3 - "$MSG" <<'PY'
import sys, re

msg = sys.argv[1]

# Find all "(closes roborev #NNN...)" blocks
# Group captures everything after the first # up to the closing )
BLOCK_RE = re.compile(
    r'\(\s*closes\s+roborev\s+#(\d+(?:(?:[\s,]+#?\d+))*)\s*\)',
    re.IGNORECASE
)

ids = []
for m in BLOCK_RE.finditer(msg):
    raw = m.group(1)
    # Extract all digit sequences from the raw match
    nums = re.findall(r'\d+', raw)
    ids.extend(nums)

print('\n'.join(ids))
PY
)"

# No citations → passthrough
if [ -z "$IDS" ]; then
  exit 0
fi

# Build a newline-separated list and deduplicate, preserving order
UNIQUE_IDS="$(printf '%s\n' "$IDS" | awk '!seen[$0]++')"

# Validate all IDs in a single Python/SQLite call (one process, all IDs).
# NOTE: cannot use bare RESULT="$(cmd)" with set -e when cmd may exit non-zero,
# because bash exits the script at the assignment. Use || to capture exit code.
PYTHON_EXIT=0
RESULT="$(/usr/bin/python3 - "$ROBOREV_DB" "$UNIQUE_IDS" <<'PY'
import sys, sqlite3

db_path = sys.argv[1]
ids_raw = sys.argv[2]

ids = [i.strip() for i in ids_raw.splitlines() if i.strip()]

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True,
                           timeout=1.0)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
except Exception as e:
    # DB unreachable → fail-open
    print(f"WARN:unreachable:{e}")
    sys.exit(0)

errors = []
for id_str in ids:
    try:
        row_id = int(id_str)
    except ValueError:
        errors.append(f"INVALID:{id_str}")
        continue

    cur.execute("SELECT closed FROM reviews WHERE id = ?", (row_id,))
    row = cur.fetchone()
    if row is None:
        errors.append(f"NOTFOUND:{row_id}")
    elif row["closed"] == 1:
        errors.append(f"ALREADYCLOSED:{row_id}")
    # closed=0 → valid, no error

conn.close()

if errors:
    for e in errors:
        print(e)
    sys.exit(1)

sys.exit(0)
PY
)" || PYTHON_EXIT=$?

# Check for fail-open warning
if echo "$RESULT" | grep -q "^WARN:unreachable:"; then
  echo "roborev_commit_msg_validator: WARNING — DB unreachable, skipping validation" >&2
  echo "  DB path: $ROBOREV_DB" >&2
  exit 0
fi

# On validation errors, emit clear diagnostics
if [ "$PYTHON_EXIT" -ne 0 ]; then
  echo "" >&2
  echo "roborev_commit_msg_validator: commit blocked — citation errors found" >&2
  echo "" >&2
  while IFS= read -r line; do
    case "$line" in
      NOTFOUND:*)
        ID="${line#NOTFOUND:}"
        echo "  ERROR: roborev #${ID} does not exist in the DB" >&2
        echo "         (Check for typos, or the review may be in a different project)" >&2
        ;;
      ALREADYCLOSED:*)
        ID="${line#ALREADYCLOSED:}"
        echo "  ERROR: roborev #${ID} is already closed" >&2
        echo "         (Remove this citation or use a different review ID)" >&2
        ;;
      INVALID:*)
        ID="${line#INVALID:}"
        echo "  ERROR: '${ID}' is not a valid roborev ID" >&2
        ;;
    esac
  done <<< "$RESULT"
  echo "" >&2
  echo "  Bypass (emergency only): SKIP_ROBOREV_VALIDATOR=1 git commit ..." >&2
  echo "" >&2
  exit 1
fi

exit 0
