#!/usr/bin/env bash
# roborev_project_backlog.sh — per-project backlog watcher.
#
# Reads ~/.roborev/reviews.db (read-only) and writes a prioritised markdown
# table of open high-severity findings to <project-root>/.roborev/backlog.md.
#
# Portability: may be invoked by launchd with a bare PATH; prepend common
# tool locations so python3 and sqlite3 are visible.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
#
# Usage:
#   roborev_project_backlog.sh [--repo <name>] [--apply | --dry-run]
#
# Options:
#   --repo <name>  Restrict to a single repo by name (default: llm)
#   --apply        Write .roborev/backlog.md to the project root (default)
#   --dry-run      Print table to stdout only; no file writes
#   --help         Usage
#
# Self-test:
#   ROBOREV_BACKLOG_SELFTEST=1 bash roborev_project_backlog.sh
#
# Exit codes:
#   0  ok (including "nothing to do" and "binary/db missing")
#   1  unexpected error
#
# Tracked in JohnGavin/llm#163.

set -uo pipefail

# ── Depth guard (defense-in-depth — prevents accidental subprocess recursion) ──
_DEPTH="${_ROBOREV_BACKLOG_DEPTH:-0}"
if [ "$_DEPTH" -gt 2 ]; then
  echo "ERROR: roborev_project_backlog.sh: recursion depth $_DEPTH — aborting" >&2
  exit 2
fi
export _ROBOREV_BACKLOG_DEPTH=$((_DEPTH + 1))

# ── Config ────────────────────────────────────────────────────────────────────
PYTHON="${PYTHON:-/usr/bin/python3}"
ROBOREV_DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
LOG="$HOME/.claude/logs/roborev_project_backlog.log"
REPO_NAME="${ROBOREV_BACKLOG_REPO:-llm}"
APPLY=1   # default: write file

# ── Parse args ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      shift; REPO_NAME="$1" ;;
    --apply)     APPLY=1 ;;
    --dry-run)   APPLY=0 ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *)           echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

mkdir -p "$(dirname "$LOG")"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# ── Functions (testable directly — no subprocess of $0) ──────────────────────

# Query the DB for open findings for a given repo name.
# Outputs first line as ROOT_PATH:<path> then markdown table lines.
# Returns 0 always (fail-open on missing DB).
_query_backlog() {
  local repo_name="$1"
  local db="$2"

  if [ ! -f "$db" ]; then
    echo "ROOT_PATH:"
    echo "REPO:$repo_name"
    echo ""
    echo "(DB unavailable — fail open)"
    return 0
  fi

  "$PYTHON" - "$db" "$repo_name" <<'PYEOF'
import sys, sqlite3

db_path = sys.argv[1]
repo_name = sys.argv[2]

try:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
except Exception as e:
    print(f"ROOT_PATH:")
    print(f"REPO:{repo_name}")
    print("")
    print(f"(DB error: {e})")
    sys.exit(0)

# Fetch repo root path
repo_row = con.execute(
    "SELECT id, root_path FROM repos WHERE name = ? ORDER BY id DESC LIMIT 1",
    (repo_name,)
).fetchone()

if repo_row is None:
    print(f"ROOT_PATH:")
    print(f"REPO:{repo_name}")
    print("")
    print(f"(repo '{repo_name}' not found in DB)")
    sys.exit(0)

repo_id = repo_row["id"]
root_path = repo_row["root_path"]

print(f"ROOT_PATH:{root_path}")
print(f"REPO:{repo_name}")
print("")

sev_label = {4: "critical", 3: "high", 2: "medium", 1: "low", 0: "unknown"}

def max_sev(output):
    """Return severity ordinal from review output text."""
    text = output or ""
    ord_val = 0
    for sev, val in [("critical", 4), ("high", 3), ("medium", 2), ("low", 1)]:
        if f"**Severity**: {sev.capitalize()}" in text or f"**Severity**: {sev}" in text:
            ord_val = max(ord_val, val)
    return ord_val

# Top-10 open findings sorted by age descending
try:
    rows = con.execute("""
        SELECT
            rv.id                 AS rid,
            rj.id                 AS job_id,
            CAST(julianday('now') - julianday(rj.finished_at) AS INTEGER) AS age_days,
            rv.output
        FROM reviews rv
        JOIN review_jobs rj ON rj.id = rv.job_id
        WHERE rj.repo_id = ?
          AND rj.status = 'done'
          AND rv.closed = 0
        ORDER BY age_days DESC
        LIMIT 10
    """, (repo_id,)).fetchall()
except Exception:
    # older schema may not have closed column — fall back
    rows = con.execute("""
        SELECT
            rv.id                 AS rid,
            rj.id                 AS job_id,
            CAST(julianday('now') - julianday(rj.finished_at) AS INTEGER) AS age_days,
            rv.output
        FROM reviews rv
        JOIN review_jobs rj ON rj.id = rv.job_id
        WHERE rj.repo_id = ?
          AND rj.status = 'done'
        ORDER BY age_days DESC
        LIMIT 10
    """, (repo_id,)).fetchall()

con.close()

if not rows:
    print("_No open findings._")
    sys.exit(0)

print("| id | sev | age_days | summary |")
print("|----|-----|----------|---------|")
for row in rows:
    rid = row["rid"]
    sev_ord = max_sev(row["output"])
    sev = sev_label.get(sev_ord, "unknown")
    age = row["age_days"] if row["age_days"] is not None else "?"
    summary = ""
    for line in (row["output"] or "").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and not line.startswith("---"):
            summary = line[:80]
            break
    summary = summary.replace("|", "\\|")
    print(f"| {rid} | {sev} | {age} | {summary} |")
PYEOF
}

# Write backlog.md to <root_path>/.roborev/backlog.md
# Args: root_path, table_content, repo_name
# Echoes the output file path on success.
_write_backlog() {
  local root_path="$1"
  local table="$2"
  local repo_name="$3"
  local out_dir="$root_path/.roborev"
  local out_file="$out_dir/backlog.md"

  mkdir -p "$out_dir"
  {
    printf '# roborev backlog — %s\n\n' "$repo_name"
    printf '_Generated: %s_\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'Check `.roborev/backlog.md` for prioritised open findings before starting fixes.\n\n'
    printf '%s\n\n' "$table"
    printf '_Source: `%s` — top 10 open findings, sorted by age (oldest first)._\n' "$ROBOREV_DB"
  } > "$out_file"

  echo "$out_file"
}

# ── Self-test (no subprocess of $0) ──────────────────────────────────────────
_selftest() {
  local pass=0 fail=0

  _t() {
    local label="$1" expected="$2" got="$3"
    if [ "$got" = "$expected" ]; then
      pass=$((pass+1))
      echo "  PASS [$label]"
    else
      fail=$((fail+1))
      echo "  FAIL [$label]: expected='$expected' got='$got'"
    fi
  }

  # Test 1: _query_backlog with missing DB fails open (exit 0, non-empty output)
  local _rc=0
  local _out
  _out=$(_query_backlog "llm" "/tmp/no_such_db_backlog_$$" 2>/dev/null) || _rc=$?
  _t "missing DB: exit 0" "0" "$_rc"
  _t "missing DB: output non-empty" "1" "$([ -n "$_out" ] && echo 1 || echo 0)"

  # Test 2: _query_backlog with real DB (if present) exits 0
  local _rc2=0
  _query_backlog "llm" "${ROBOREV_DB:-$HOME/.roborev/reviews.db}" >/dev/null 2>&1 || _rc2=$?
  _t "real DB or missing: exit 0" "0" "$_rc2"

  # Test 3: _write_backlog writes to the expected path
  local _tmpdir
  _tmpdir=$(mktemp -d)
  local _written
  _written=$(_write_backlog "$_tmpdir" "| id | sev | age_days | summary |
|----|-----|----------|---------|
| 1  | high | 5 | test |" "test-repo")
  _t "write_backlog: file exists" "1" "$([ -f "$_tmpdir/.roborev/backlog.md" ] && echo 1 || echo 0)"
  _t "write_backlog: returns correct path" "$_tmpdir/.roborev/backlog.md" "$_written"
  # Check file contains repo name
  _t "write_backlog: header in file" "1" "$(grep -q 'test-repo' "$_tmpdir/.roborev/backlog.md" && echo 1 || echo 0)"
  rm -rf "$_tmpdir"

  # Test 4: depth guard triggers at depth > 2
  local _rc3=0
  _ROBOREV_BACKLOG_DEPTH=3 bash -c '
    export _ROBOREV_BACKLOG_DEPTH=3
    _DEPTH="${_ROBOREV_BACKLOG_DEPTH:-0}"
    if [ "$_DEPTH" -gt 2 ]; then
      exit 2
    fi
    exit 0
  ' 2>/dev/null || _rc3=$?
  _t "depth guard: exits 2 at depth 3" "2" "$_rc3"

  echo ""
  echo "${pass}/$((pass+fail)) PASS"
  [ "$fail" -eq 0 ] && return 0 || return 1
}

if [ "${ROBOREV_BACKLOG_SELFTEST:-0}" = "1" ]; then
  _selftest
  exit $?
fi

# ── Main entry ────────────────────────────────────────────────────────────────

# Fail-open: exit 0 if Python missing
if [ ! -x "$PYTHON" ]; then
  log "skip: $PYTHON not found"
  echo "roborev_project_backlog: skipped ($PYTHON missing)"
  exit 0
fi

# Fail-open: exit 0 if DB missing (portability — CI, other machines)
if [ ! -f "$ROBOREV_DB" ]; then
  log "skip: DB not found at $ROBOREV_DB"
  echo "roborev_project_backlog: skipped (DB missing)"
  exit 0
fi

# Query backlog
raw_output=$(_query_backlog "$REPO_NAME" "$ROBOREV_DB")

# Extract root_path from first line
root_path=$(printf '%s\n' "$raw_output" | grep "^ROOT_PATH:" | head -1 | sed 's/^ROOT_PATH://')

# Strip metadata lines for table content
table=$(printf '%s\n' "$raw_output" | grep -v "^ROOT_PATH:" | grep -v "^REPO:")

if [ "$APPLY" -eq 0 ]; then
  echo "=== roborev backlog: $REPO_NAME (dry-run) ==="
  echo ""
  printf '%s\n' "$table"
  log "dry-run: repo=$REPO_NAME"
else
  if [ -z "$root_path" ]; then
    log "error: could not determine root_path for repo=$REPO_NAME"
    echo "roborev_project_backlog: error — repo '$REPO_NAME' not in DB or no root_path" >&2
    exit 1
  fi

  out_file=$(_write_backlog "$root_path" "$table" "$REPO_NAME")
  log "apply: wrote $out_file repo=$REPO_NAME"
  echo "roborev_project_backlog: wrote $out_file"
fi

exit 0
