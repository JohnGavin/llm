#!/usr/bin/env bash
# roborev_project_backlog.sh — per-project backlog watcher + prioritizer.
#
# Reads ~/.roborev/reviews.db (read-only) and writes a prioritised markdown
# table of open high-severity findings to <project-root>/.roborev/backlog.md.
# Implements Components 1 and 2 of JohnGavin/llm#163.
#
# Portability: may be invoked by launchd with a bare PATH; prepend common
# tool locations so python3 and sqlite3 are visible.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
#
# Usage:
#   roborev_project_backlog.sh <project-name> [options]
#
# Arguments:
#   <project-name>          Repo name as stored in reviews.db (positional, required)
#
# Options:
#   --repo-root PATH        Project root directory (default: ~/docs_gh/<name>)
#   --out PATH              Output file path (default: <repo-root>/.roborev/backlog.md)
#   --top-n N               Number of top findings to show (default: 10)
#   --dry-run               Print table to stdout only; no file writes
#   --help                  Usage
#
# Legacy alias (backward compat):
#   --repo <name>           Same as positional <project-name>
#   --apply                 Write file (default; opposite of --dry-run)
#
# Self-test:
#   ROBOREV_BACKLOG_SELFTEST=1 bash roborev_project_backlog.sh
#
# Exit codes:
#   0  ok (including "nothing to do" and "binary/db missing")
#   1  unexpected error
#
# Priority formula (Component 2 — JohnGavin/llm#163):
#   priority = severity_weight × category_risk × (1 + log10(days_old)) × (1 + log10(file_touches_30d))
#   severity_weight: Critical=10, High=5, Medium=2, Low=1
#   category_risk: security=3, error-handling=2.5, async=2, dependency=1.5, test=1.5,
#                  performance=1.2, other=1, docs=0.5
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
REPO_NAME="${ROBOREV_BACKLOG_REPO:-}"
REPO_ROOT=""         # populated from --repo-root or default ~/docs_gh/<name>
OUT_FILE=""          # populated from --out or default <repo-root>/.roborev/backlog.md
TOP_N=10             # default top-N
APPLY=1              # default: write file

# ── Parse args ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)       shift; REPO_NAME="$1" ;;      # legacy alias
    --repo-root)  shift; REPO_ROOT="$1" ;;
    --out)        shift; OUT_FILE="$1" ;;
    --top-n)      shift; TOP_N="$1" ;;
    --apply)      APPLY=1 ;;
    --dry-run)    APPLY=0 ;;
    -h|--help)    sed -n '2,45p' "$0"; exit 0 ;;
    -*)           echo "unknown option: $1" >&2; exit 1 ;;
    *)
      # First positional arg = project name
      if [ -z "$REPO_NAME" ]; then
        REPO_NAME="$1"
      else
        echo "unexpected argument: $1 (project name already set to '$REPO_NAME')" >&2
        exit 1
      fi
      ;;
  esac
  shift
done

# Default repo name if still unset
[ -z "$REPO_NAME" ] && REPO_NAME="llm"

# Derive repo root from name if not explicitly provided
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$HOME/docs_gh/$REPO_NAME"
fi

mkdir -p "$(dirname "$LOG")"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# ── Functions (testable directly — no subprocess of $0) ──────────────────────

# Compute composite priority score from components.
# Args: severity_weight category_risk age_days file_touches_30d
# Output: floating-point priority score on stdout.
# Uses awk for portability (no python3 dependency here — called from shell context).
_compute_priority() {
  local sev_weight="$1"
  local cat_risk="$2"
  local age_days="${3:-1}"
  local touches="${4:-1}"

  # Clamp age_days and touches to minimum 1 to avoid log10(0)
  [ "${age_days:-0}" -lt 1 ] 2>/dev/null && age_days=1
  [ "${touches:-0}" -lt 1 ] 2>/dev/null && touches=1

  awk -v sw="$sev_weight" -v cr="$cat_risk" -v age="$age_days" -v t="$touches" '
    BEGIN {
      pi = sw * cr * (1 + log(age)/log(10)) * (1 + log(t)/log(10))
      printf "%.1f\n", pi
    }
  '
}

# Get file_touches_30d for a file path within a project root.
# Args: project_root file_path
# Output: integer touch count (defaults to 1 if unknown).
_get_file_touches() {
  local project_root="$1"
  local file_path="$2"

  if [ -z "$project_root" ] || [ ! -d "$project_root" ] || [ -z "$file_path" ]; then
    echo 1
    return 0
  fi

  local count
  count=$(git -C "$project_root" log \
    --since='30 days ago' \
    --name-only \
    --pretty=format: \
    -- "$file_path" 2>/dev/null \
    | grep -c "$file_path" 2>/dev/null) || count=0

  # Default to 1 if no data (prevents log10(0))
  [ "${count:-0}" -lt 1 ] && count=1
  echo "$count"
}

# Query the DB for open findings for a given repo name.
# Outputs first line as ROOT_PATH:<path> then markdown table lines.
# Returns 0 always (fail-open on missing DB).
_query_backlog() {
  local repo_name="$1"
  local db="$2"
  local root_path_override="${3:-}"  # optional: pass project root for file_touches
  local top_n="${4:-10}"             # optional: top-N, default 10

  if [ ! -f "$db" ]; then
    echo "ROOT_PATH:"
    echo "REPO:$repo_name"
    echo "OPEN_COUNT:0"
    echo ""
    echo "_0 open findings (DB unavailable — fail open)._"
    return 0
  fi

  "$PYTHON" - "$db" "$repo_name" "$root_path_override" "$top_n" <<'PYEOF'
import sys, sqlite3, math, re, subprocess, os

db_path = sys.argv[1]
repo_name = sys.argv[2]
root_path_override = sys.argv[3] if len(sys.argv) > 3 else ""
top_n = int(sys.argv[4]) if len(sys.argv) > 4 else 10

# ── Severity / category weight tables ────────────────────────────────────────
SEV_WEIGHT = {"critical": 10, "high": 5, "medium": 2, "low": 1, "unknown": 1}
CAT_RISK   = {
    "security": 3.0, "error-handling": 2.5, "async": 2.0,
    "dependency": 1.5, "test": 1.5, "performance": 1.2,
    "other": 1.0, "docs": 0.5,
}

def max_sev_ord(output):
    """Return (sev_label, sev_weight) for the highest severity in output text."""
    text = output or ""
    best_ord = 0
    best_label = "unknown"
    for sev, ord_val in [("critical", 4), ("high", 3), ("medium", 2), ("low", 1)]:
        if (f"**Severity**: {sev.capitalize()}" in text
                or f"**Severity**: {sev}" in text
                or f"Severity: {sev.capitalize()}" in text):
            if ord_val > best_ord:
                best_ord = ord_val
                best_label = sev
    return best_label, SEV_WEIGHT.get(best_label, 1)

def infer_category(output):
    """Infer risk category from review output text keywords."""
    text = (output or "").lower()
    # Priority order: check higher-risk categories first
    if any(w in text for w in ["sql injection", "xss", "csrf", "secret", "credential",
                                 "password", "token leak", "auth bypass", "privilege"]):
        return "security"
    if any(w in text for w in ["error handling", "exception", "try-catch", "tryCatch",
                                 "stop(", "abort", "condition", "error propagat"]):
        return "error-handling"
    if any(w in text for w in ["async", "promise", "future", "extendedtask",
                                 "reactive", "observer", "eventreactive"]):
        return "async"
    if any(w in text for w in ["dependency", "import", "require", "namespace",
                                 "package version", "library("]):
        return "dependency"
    if any(w in text for w in ["test", "testthat", "expect_", "mock", "fixture",
                                 "coverage"]):
        return "test"
    if any(w in text for w in ["performance", "slow", "memory", "allocation",
                                 "loop", "vectori", "n²", "o(n"]):
        return "performance"
    if any(w in text for w in ["doc", "roxygen", "@param", "@return", "@export",
                                 "readme", "vignette", "comment"]):
        return "docs"
    return "other"

def get_file_mention(output):
    """Extract first file path mentioned in output (for git log lookup)."""
    text = output or ""
    # Look for backtick-quoted paths or Location: markers
    for pattern in [
        r'`([^`]+\.[a-zA-Z]+)`',           # `path/file.ext`
        r'\*\*Location\*\*:\s*`?([^\n`]+)', # **Location**: path
        r'Location:\s*`?([^\n`]+)',          # Location: path
    ]:
        m = re.search(pattern, text)
        if m:
            candidate = m.group(1).strip().rstrip('`').split(':')[0]
            # Only return if it looks like a file path (has extension or slash)
            if '.' in candidate or '/' in candidate:
                return candidate
    return ""

def get_file_touches(root_path, file_path):
    """Count git log touches in last 30 days for the given file."""
    if not root_path or not file_path or not os.path.isdir(root_path):
        return 1
    try:
        result = subprocess.run(
            ["git", "-C", root_path, "log", "--since=30 days ago",
             "--name-only", "--pretty=format:", "--", file_path],
            capture_output=True, text=True, timeout=5
        )
        count = len([l for l in result.stdout.splitlines() if l.strip() == file_path
                     or (file_path and l.strip().endswith(os.path.basename(file_path)))])
        return max(count, 1)
    except Exception:
        return 1

def compute_priority(sev_weight, cat_risk, age_days, touches):
    """Composite priority = sw × cr × (1+log10(age)) × (1+log10(touches))."""
    age = max(age_days or 1, 1)
    t   = max(touches or 1, 1)
    return sev_weight * cat_risk * (1 + math.log10(age)) * (1 + math.log10(t))

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

repo_id   = repo_row["id"]
root_path = root_path_override or repo_row["root_path"] or ""

print(f"ROOT_PATH:{root_path}")
print(f"REPO:{repo_name}")
print("")

# Fetch open findings
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
        LIMIT 100
    """, (repo_id,)).fetchall()
except Exception:
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
        LIMIT 100
    """, (repo_id,)).fetchall()

con.close()

if not rows:
    print(f"OPEN_COUNT:0")
    print("_0 open findings._")
    sys.exit(0)

# Compute priority for each row, then sort DESC
scored = []
for row in rows:
    sev_label, sev_weight = max_sev_ord(row["output"])
    category = infer_category(row["output"])
    cat_risk  = CAT_RISK.get(category, 1.0)
    age       = row["age_days"] if row["age_days"] is not None else 1
    file_path = get_file_mention(row["output"])
    touches   = get_file_touches(root_path, file_path)
    priority  = compute_priority(sev_weight, cat_risk, age, touches)
    scored.append({
        "rid": row["rid"],
        "sev": sev_label,
        "category": category,
        "age_days": age,
        "file_touches_30d": touches,
        "priority": priority,
        "output": row["output"],
    })

# Sort by priority DESC, take top_n
scored.sort(key=lambda x: x["priority"], reverse=True)
top_list = scored[:top_n]

print(f"OPEN_COUNT:{len(scored)}")
print("| id | sev | category | age_days | touches | priority | summary |")
print("|----|-----|----------|----------|---------|----------|---------|")
for r in top_list:
    rid = r["rid"]
    sev = r["sev"]
    cat = r["category"]
    age = r["age_days"]
    t   = r["file_touches_30d"]
    pri = f"{r['priority']:.1f}"
    summary = ""
    for line in (r["output"] or "").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and not line.startswith("---"):
            summary = line[:80]
            break
    summary = summary.replace("|", "\\|")
    print(f"| {rid} | {sev} | {cat} | {age} | {t} | {pri} | {summary} |")

# Emit top-finding metadata for session_init banner use
top = top_list[0] if top_list else None
if top:
    print(f"TOP_FINDING_ID:{top['rid']}")
    print(f"TOP_FINDING_SEV:{top['sev']}")
    print(f"TOP_FINDING_CAT:{top['category']}")
PYEOF
}

# Write backlog.md to the project's .roborev/backlog.md (or --out path).
# Args: root_path, table_content, repo_name, [out_file_override]
# Echoes the output file path on success.
_write_backlog() {
  local root_path="$1"
  local table="$2"
  local repo_name="$3"
  local out_file_override="${4:-}"
  local out_file

  if [ -n "$out_file_override" ]; then
    out_file="$out_file_override"
  else
    out_file="$root_path/.roborev/backlog.md"
  fi

  mkdir -p "$(dirname "$out_file")"
  {
    printf '# roborev backlog — %s\n\n' "$repo_name"
    printf '_Generated: %s_\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'Check `%s` for prioritised open findings before starting fixes.\n\n' "$out_file"
    printf '%s\n\n' "$table"
    printf '_Source: `%s` — top-%s open findings, sorted by composite priority (severity × category-risk × age × file-heat)._\n' \
      "${ROBOREV_DB:-~/.roborev/reviews.db}" "${TOP_N:-10}"
  } > "$out_file"

  echo "$out_file"
}

# Append .roborev/ to <project-root>/.gitignore if not already present.
# Idempotent — safe to call multiple times.
_ensure_gitignore() {
  local root_path="$1"
  local gitignore="$root_path/.gitignore"

  [ -z "$root_path" ] && return 0
  [ ! -d "$root_path" ] && return 0

  # Already present
  if [ -f "$gitignore" ] && grep -qF '.roborev/' "$gitignore" 2>/dev/null; then
    return 0
  fi

  printf '\n# roborev per-project backlog (generated by roborev_project_backlog.sh)\n.roborev/\n' >> "$gitignore"
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
  _written=$(_write_backlog "$_tmpdir" "| id | sev | category | age_days | touches | priority | summary |
|----|-----|----------|----------|---------|----------|---------|
| 1  | high | security | 5 | 2 | 12.5 | test |" "test-repo")
  _t "write_backlog: file exists" "1" "$([ -f "$_tmpdir/.roborev/backlog.md" ] && echo 1 || echo 0)"
  _t "write_backlog: returns correct path" "$_tmpdir/.roborev/backlog.md" "$_written"
  # Check file contains repo name
  _t "write_backlog: header in file" "1" "$(grep -q 'test-repo' "$_tmpdir/.roborev/backlog.md" && echo 1 || echo 0)"
  # Check priority column is present in footer
  _t "write_backlog: priority mention in footer" "1" "$(grep -q 'priority' "$_tmpdir/.roborev/backlog.md" && echo 1 || echo 0)"
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

  # Test 5: _compute_priority returns a non-zero number
  local _pri
  _pri=$(_compute_priority 5 2.5 10 3)
  _t "compute_priority: non-empty output" "1" "$([ -n "$_pri" ] && echo 1 || echo 0)"
  # Critical/security/10days/3touches should be > 1
  local _pri_gt1
  _pri_gt1=$(awk -v p="$_pri" 'BEGIN { print (p > 1) ? 1 : 0 }')
  _t "compute_priority: result > 1" "1" "$_pri_gt1"

  # Test 6: _get_file_touches with empty project root returns 1
  local _touches
  _touches=$(_get_file_touches "" "some/file.R")
  _t "get_file_touches: empty root returns 1" "1" "$_touches"

  # Test 7: _query_backlog output with real DB has priority column header (if DB present)
  if [ -f "${ROBOREV_DB:-$HOME/.roborev/reviews.db}" ]; then
    local _qout
    _qout=$(_query_backlog "llm" "${ROBOREV_DB:-$HOME/.roborev/reviews.db}" 2>/dev/null)
    # Either "No open findings" or table with priority column
    local _has_priority=0
    echo "$_qout" | grep -q "priority" && _has_priority=1
    echo "$_qout" | grep -q "No open findings" && _has_priority=1
    _t "query_backlog: output has priority col or no-findings" "1" "$_has_priority"
  fi

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

# Query backlog (pass TOP_N to Python)
raw_output=$(_query_backlog "$REPO_NAME" "$ROBOREV_DB" "$REPO_ROOT" "$TOP_N")

# Extract metadata lines
db_root_path=$(printf '%s\n' "$raw_output" | grep "^ROOT_PATH:" | head -1 | sed 's/^ROOT_PATH://')
open_count=$(printf '%s\n' "$raw_output" | grep "^OPEN_COUNT:" | head -1 | sed 's/^OPEN_COUNT://')
top_id=$(printf '%s\n' "$raw_output" | grep "^TOP_FINDING_ID:" | head -1 | sed 's/^TOP_FINDING_ID://')
top_sev=$(printf '%s\n' "$raw_output" | grep "^TOP_FINDING_SEV:" | head -1 | sed 's/^TOP_FINDING_SEV://')
top_cat=$(printf '%s\n' "$raw_output" | grep "^TOP_FINDING_CAT:" | head -1 | sed 's/^TOP_FINDING_CAT://')

# Use --repo-root override if provided; else fall back to what the DB says; else ~/docs_gh/<name>
effective_root="${REPO_ROOT:-${db_root_path:-$HOME/docs_gh/$REPO_NAME}}"

# Strip metadata lines for table content
table=$(printf '%s\n' "$raw_output" \
  | grep -v "^ROOT_PATH:" \
  | grep -v "^REPO:" \
  | grep -v "^OPEN_COUNT:" \
  | grep -v "^TOP_FINDING_")

if [ "$APPLY" -eq 0 ]; then
  echo "=== roborev backlog: $REPO_NAME (dry-run) ==="
  echo "${open_count:-0} open findings"
  echo ""
  printf '%s\n' "$table"
  [ -n "$top_id" ] && echo "Top finding: #${top_id} (${top_sev}:${top_cat})"
  log "dry-run: repo=$REPO_NAME open=${open_count:-0}"
else
  out_file=$(_write_backlog "$effective_root" "$table" "$REPO_NAME" "${OUT_FILE:-}")
  _ensure_gitignore "$effective_root"
  log "apply: wrote $out_file repo=$REPO_NAME open=${open_count:-?} top=#${top_id}(${top_sev}:${top_cat})"
  echo "roborev_project_backlog: wrote $out_file (${open_count:-?} open findings)"
fi

exit 0
