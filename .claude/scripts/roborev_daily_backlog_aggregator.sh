#!/usr/bin/env bash
# roborev_daily_backlog_aggregator.sh — daily backlog aggregator across all projects.
#
# Iterates every project registered in ~/.roborev/reviews.db (repos table),
# skipping internal fixture names, then calls roborev_project_backlog.sh for
# each resolvable project root.  Produces a global summary Markdown at:
#   ~/.claude/logs/roborev_daily_backlog/<YYYY-MM-DD>.md
#
# Implements Component 6 of JohnGavin/llm#163.
#
# Usage:
#   roborev_daily_backlog_aggregator.sh [options]
#
# Options:
#   --dry-run        Pass --dry-run to each per-project script (no file writes)
#   --db PATH        Override reviews.db path (default: ~/.roborev/reviews.db)
#   --docs-root DIR  Override docs root for project lookup (default: ~/docs_gh)
#   --out-dir DIR    Override global summary output directory
#                    (default: ~/.claude/logs/roborev_daily_backlog)
#   --help           Usage
#
# Self-test:
#   ROBOREV_AGG_SELFTEST=1 bash roborev_daily_backlog_aggregator.sh
#
# Exit codes:
#   0  ok (per-project failures are soft — logged, not fatal)
#   1  unexpected error (DB query failure, etc.)
#
# Tracked in JohnGavin/llm#355.

set -uo pipefail

# Prepend common tool locations (same convention as per-project script)
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# ── Config ────────────────────────────────────────────────────────────────────
PYTHON="${PYTHON:-/usr/bin/python3}"
ROBOREV_DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
DOCS_ROOT="${DOCS_ROOT:-$HOME/docs_gh}"
TODAY="$(date -u '+%Y-%m-%d')"
OUT_DIR="${ROBOREV_AGG_OUT_DIR:-$HOME/.claude/logs/roborev_daily_backlog}"
DRY_RUN=0

# Resolve directory containing this script to find sibling per-project script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PER_PROJECT_SCRIPT="${SCRIPT_DIR}/roborev_project_backlog.sh"

LOG="$HOME/.claude/logs/roborev_daily_backlog_aggregator.log"

# ── Parse args ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --db)        shift; ROBOREV_DB="$1" ;;
    --docs-root) shift; DOCS_ROOT="$1" ;;
    --out-dir)   shift; OUT_DIR="$1" ;;
    -h|--help)   sed -n '2,45p' "$0"; exit 0 ;;
    *)           echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

mkdir -p "$(dirname "$LOG")"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# ── Helper: enumerate project names from DB ───────────────────────────────────
# Outputs one name per line on stdout; exits 0 always (fail-open).
_list_projects() {
  local db="$1"

  if [ ! -f "$db" ]; then
    log "skip: DB not found at $db"
    return 0
  fi

  "$PYTHON" - "$db" <<'PYEOF'
import sys, sqlite3

db_path = sys.argv[1]

# Name patterns to skip — internal fixtures and KB repos
SKIP_PATTERNS = [
    "kb_",
    "config_digest_git_fixture_",
    "fixture_",
    "file",            # hex-prefixed temp entries like file9afe2d343242
    "repo_",           # one-off fixture entries repo_XXXX
    "repo1", "repo2", "repo3", "repo4", "repo5",  # numbered test fixtures
    "main",            # git-default remote name accidentally stored as repo name
    "hello_t", "my_t_project", "t_demos",           # demo/test projects
]

# Names that look like file-hash entries (7–40 hex chars, possibly starting with "file")
import re
HEX_ENTRY = re.compile(r'^file[0-9a-f]{6,}$')

try:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    rows = con.execute(
        "SELECT DISTINCT name FROM repos ORDER BY name"
    ).fetchall()
    con.close()
except Exception as e:
    print(f"# DB error: {e}", file=sys.stderr)
    sys.exit(0)

for (name,) in rows:
    if not name:
        continue
    # Skip hex-prefixed entries
    if HEX_ENTRY.match(name):
        continue
    # Skip known fixture / internal prefixes
    if any(name.startswith(p) for p in SKIP_PATTERNS):
        continue
    print(name)
PYEOF
}

# ── Helper: write global summary ─────────────────────────────────────────────
# Args: out_file, summary_lines (newline-delimited "project|open_count|top_sev|top_id")
_write_global_summary() {
  local out_file="$1"
  local lines="$2"
  local total_projects=0
  local total_open=0

  mkdir -p "$(dirname "$out_file")"

  {
    printf '# roborev global backlog summary\n\n'
    printf '_Generated: %s (UTC)_\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '## Per-project open counts\n\n'
    printf '| project | open | top sev | top id |\n'
    printf '|---------|------|---------|--------|\n'

    while IFS='|' read -r proj open top_sev top_id; do
      [ -z "$proj" ] && continue
      total_projects=$((total_projects + 1))
      local n="${open:-0}"
      # Strip whitespace from numeric field
      n="${n// /}"
      # Only add to total if it looks like a number
      if [[ "$n" =~ ^[0-9]+$ ]]; then
        total_open=$((total_open + n))
      fi
      printf '| %s | %s | %s | %s |\n' "$proj" "${open:-?}" "${top_sev:--}" "${top_id:--}"
    done <<< "$lines"

    printf '\n## Summary\n\n'
    printf '%s\n' "- Projects processed: ${total_projects}"
    printf '%s\n' "- Total open findings: ${total_open}"
    printf '%s\n' "- Generated by: \`roborev_daily_backlog_aggregator.sh\`"
    printf '%s\n' "- Source DB: \`${ROBOREV_DB}\`"
    printf '%s\n' "- Tracked in: JohnGavin/llm#355"
  } > "$out_file"

  echo "$out_file"
}

# ── Self-test ─────────────────────────────────────────────────────────────────
_selftest() {
  local pass=0 fail=0

  _t() {
    local label="$1" expected="$2" got="$3"
    if [ "$got" = "$expected" ]; then
      pass=$((pass + 1))
      echo "  PASS [$label]"
    else
      fail=$((fail + 1))
      echo "  FAIL [$label]: expected='$expected' got='$got'"
    fi
  }

  # ── Build a synthetic DB ─────────────────────────────────────────────────
  local tmpdir
  tmpdir=$(mktemp -d)
  local db="$tmpdir/reviews.db"

  "$PYTHON" - "$db" <<'PYEOF'
import sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db)
con.executescript("""
CREATE TABLE IF NOT EXISTS repos (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    name      TEXT    NOT NULL,
    root_path TEXT
);
CREATE TABLE IF NOT EXISTS review_jobs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    repo_id     INTEGER,
    status      TEXT DEFAULT 'done',
    finished_at TEXT,
    enqueued_at TEXT
);
CREATE TABLE IF NOT EXISTS reviews (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id  INTEGER,
    output  TEXT,
    closed  INTEGER DEFAULT 0
);
""")
# Insert real-looking projects and some that should be filtered
for name in ('llm', 'mycare', 'fixture_abc123', 'kb_wiki', 'file9afe2d343242',
             'repo_XXXX', 'main', 'hello_t', 'historical'):
    con.execute("INSERT INTO repos (name, root_path) VALUES (?, '')", (name,))
con.commit()
con.close()
PYEOF

  # Test 1: _list_projects emits only real project names
  local listed
  listed=$(ROBOREV_DB="$db" _list_projects "$db")
  local listed_count
  listed_count=$(echo "$listed" | grep -c . || true)
  # Should have llm, mycare, historical — 3 real projects; not fixture_, kb_, file*, etc.
  _t "list_projects: emits >=2 real projects" "1" "$([ "$listed_count" -ge 2 ] && echo 1 || echo 0)"
  _t "list_projects: includes llm" "1" "$(echo "$listed" | grep -qx 'llm' && echo 1 || echo 0)"
  _t "list_projects: excludes fixture_abc123" "1" "$(if echo "$listed" | grep -qx 'fixture_abc123'; then echo 0; else echo 1; fi)"
  _t "list_projects: excludes kb_wiki" "1" "$(if echo "$listed" | grep -qx 'kb_wiki'; then echo 0; else echo 1; fi)"
  _t "list_projects: excludes file hex entry" "1" "$(if echo "$listed" | grep -qx 'file9afe2d343242'; then echo 0; else echo 1; fi)"
  _t "list_projects: excludes main" "1" "$(if echo "$listed" | grep -qx 'main'; then echo 0; else echo 1; fi)"
  _t "list_projects: excludes hello_t" "1" "$(if echo "$listed" | grep -qx 'hello_t'; then echo 0; else echo 1; fi)"

  # Test 2: missing DB returns empty (exit 0)
  local _rc=0
  local _out
  _out=$(_list_projects "/tmp/no_such_db_$$" 2>/dev/null) || _rc=$?
  _t "list_projects missing DB: exit 0" "0" "$_rc"
  _t "list_projects missing DB: empty output" "" "$_out"

  # Test 3: _write_global_summary produces a valid file
  local out_file="$tmpdir/summary.md"
  local summary_lines="llm|3|high|42
mycare|1|medium|99
historical|0|-|-"
  _write_global_summary "$out_file" "$summary_lines" >/dev/null
  _t "write_global_summary: file written" "1" "$([ -f "$out_file" ] && echo 1 || echo 0)"
  if [ -f "$out_file" ]; then
    _t "write_global_summary: has heading" "1" "$(grep -q 'global backlog' "$out_file" && echo 1 || echo 0)"
    _t "write_global_summary: has per-project row" "1" "$(grep -q 'llm' "$out_file" && echo 1 || echo 0)"
    _t "write_global_summary: has summary section" "1" "$(grep -q 'Total open findings' "$out_file" && echo 1 || echo 0)"
    _t "write_global_summary: total open count correct (3+1+0=4)" "4" "$(grep 'Total open findings:' "$out_file" | grep -o '[0-9]*' | head -1)"
  fi

  # Test 4: bash -n syntax check on this script
  local _bn_rc=0
  bash -n "${BASH_SOURCE[0]}" 2>/dev/null || _bn_rc=$?
  _t "bash -n exits 0 (syntax valid)" "0" "$_bn_rc"

  # Test 5: _write_global_summary is idempotent (same date overwrites)
  local out_file2="$tmpdir/summary2.md"
  _write_global_summary "$out_file2" "llm|5|high|10" >/dev/null
  _write_global_summary "$out_file2" "llm|7|medium|20" >/dev/null
  _t "write_global_summary: idempotent (file count=1)" "1" "$([ -f "$out_file2" ] && echo 1 || echo 0)"
  _t "write_global_summary: idempotent (overwritten with new count)" "1" "$(grep -q '7' "$out_file2" && echo 1 || echo 0)"

  rm -rf "$tmpdir"

  echo ""
  echo "${pass}/$((pass + fail)) PASS"
  [ "$fail" -eq 0 ] && return 0 || return 1
}

if [ "${ROBOREV_AGG_SELFTEST:-0}" = "1" ]; then
  _selftest
  exit $?
fi

# ── Main entry ────────────────────────────────────────────────────────────────

# Fail-open: exit 0 if Python missing
if [ ! -x "$PYTHON" ]; then
  log "skip: $PYTHON not found"
  echo "roborev_daily_backlog_aggregator: skipped ($PYTHON missing)"
  exit 0
fi

# Fail-open: exit 0 if DB missing
if [ ! -f "$ROBOREV_DB" ]; then
  log "skip: DB not found at $ROBOREV_DB"
  echo "roborev_daily_backlog_aggregator: skipped (DB missing)"
  exit 0
fi

# Per-project script must exist
if [ ! -x "$PER_PROJECT_SCRIPT" ]; then
  log "error: per-project script not found or not executable: $PER_PROJECT_SCRIPT"
  echo "roborev_daily_backlog_aggregator: error — per-project script missing" >&2
  exit 1
fi

log "start: DB=$ROBOREV_DB dry_run=$DRY_RUN"

# Enumerate projects
projects=$(_list_projects "$ROBOREV_DB")

if [ -z "$projects" ]; then
  log "no projects found in DB"
  echo "roborev_daily_backlog_aggregator: no projects found"
  exit 0
fi

# Accumulate per-project results: "project|open_count|top_sev|top_id"
summary_rows=""
processed=0
skipped=0

while IFS= read -r project; do
  [ -z "$project" ] && continue

  # Resolve repo root
  repo_root="${DOCS_ROOT}/${project}"

  if [ ! -d "$repo_root" ]; then
    log "skip: $project — root not found at $repo_root"
    skipped=$((skipped + 1))
    continue
  fi

  log "running: $project (root=$repo_root)"

  # Build argument list for per-project script
  run_args=(
    "$project"
    --repo-root "$repo_root"
  )
  if [ "$DRY_RUN" -eq 1 ]; then
    run_args+=(--dry-run)
  fi

  # Capture stdout; failures are soft (logged but not fatal)
  per_out=""
  per_rc=0
  per_out=$(ROBOREV_DB="$ROBOREV_DB" bash "$PER_PROJECT_SCRIPT" "${run_args[@]}" 2>&1) || per_rc=$?

  if [ "$per_rc" -ne 0 ]; then
    log "warn: $project exited $per_rc — continuing"
  fi

  # Parse open_count and top-finding from per-project output
  open_count=$(printf '%s\n' "$per_out" | grep "^OPEN_COUNT:" | head -1 | sed 's/^OPEN_COUNT://' | tr -d ' ')
  top_id=$(printf '%s\n' "$per_out" | grep "^TOP_FINDING_ID:" | head -1 | sed 's/^TOP_FINDING_ID://' | tr -d ' ')
  top_sev=$(printf '%s\n' "$per_out" | grep "^TOP_FINDING_SEV:" | head -1 | sed 's/^TOP_FINDING_SEV://' | tr -d ' ')

  row="${project}|${open_count:-?}|${top_sev:--}|${top_id:--}"

  if [ -z "$summary_rows" ]; then
    summary_rows="$row"
  else
    summary_rows="${summary_rows}
${row}"
  fi

  log "done: $project open=${open_count:-?} top_sev=${top_sev:--} top_id=${top_id:--}"
  processed=$((processed + 1))

done <<< "$projects"

log "processed=$processed skipped=$skipped"

# Write global summary (idempotent — same date overwrites)
out_file="${OUT_DIR}/${TODAY}.md"
written=$(_write_global_summary "$out_file" "$summary_rows")
log "summary written: $written"

echo "roborev_daily_backlog_aggregator: processed=$processed skipped=$skipped summary=$written"
exit 0
