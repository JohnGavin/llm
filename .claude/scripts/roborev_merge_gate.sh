#!/usr/bin/env bash
# roborev_merge_gate.sh — pre-merge check for open roborev findings on PR commits.
#
# Usage:
#   roborev_merge_gate.sh <pr#>
#   roborev_merge_gate.sh --branch <name>    (auto-detects PR# from branch)
#   roborev_merge_gate.sh --dry-run <pr#>    (explicit dry-run; default mode)
#   roborev_merge_gate.sh --enforce  <pr#>   (enforce mode — exit 1 on block; NOT active)
#
# Exit codes (dry-run mode — default):
#   0   Always exits 0 in dry-run mode (print verdict, never block)
#
# Exit codes (--enforce mode — for future use, NOT wired into CI):
#   0   gate-pass or gate-warn
#   1   gate-block (unresolved High/Critical findings)
#
# Verdicts:
#   [gate-pass]   All findings cited or no open findings at threshold
#   [gate-warn]   Open findings at medium severity only (warn, don't block)
#   [gate-block]  Open High/Critical findings not cited in PR commits
#
# Logs: ~/.claude/logs/merge_gate.log (one JSON line per invocation)
# Fail-open: exits 0 if DB absent, if gh command fails, or on any internal error.
#
# Self-test (direct function calls — no subprocess of $0):
#   SELFTEST=1 bash roborev_merge_gate.sh
#
# Tracked in JohnGavin/llm#241.

set -uo pipefail

# ── Depth / recursion guard ───────────────────────────────────────────────────
_DEPTH="${_ROBOREV_GATE_DEPTH:-0}"
if [ "$_DEPTH" -gt 2 ]; then
  echo "ERROR: roborev_merge_gate.sh: recursion depth $_DEPTH — aborting" >&2
  exit 2
fi
export _ROBOREV_GATE_DEPTH=$((_DEPTH + 1))

# ── Config ────────────────────────────────────────────────────────────────────
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
PYTHON="${PYTHON:-/usr/bin/python3}"
ROBOREV_DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
ACKS_JSONL="${ACKS_JSONL:-$HOME/.roborev/acks.jsonl}"
MERGE_GATE_LOG="${MERGE_GATE_LOG:-$HOME/.claude/logs/merge_gate.log}"

# Severity levels (ascending — used to determine "at or above threshold")
_SEV_ORDER=("low" "medium" "high" "critical")

# ── Functions (directly testable — no subprocess of $0) ──────────────────────

# Return 0 if $1 severity is >= $2 threshold (case-insensitive)
_sev_at_least() {
  local sev="${1,,}" thresh="${2,,}"
  local sev_idx=99 thresh_idx=99 i
  for i in "${!_SEV_ORDER[@]}"; do
    [[ "${_SEV_ORDER[$i]}" == "$sev" ]]    && sev_idx=$i
    [[ "${_SEV_ORDER[$i]}" == "$thresh" ]] && thresh_idx=$i
  done
  [ "$sev_idx" -ge "$thresh_idx" ]
}

# Read review_min_severity from .roborev.toml in $repo_dir (default: "medium")
_read_threshold() {
  local repo_dir="${1:-.}"
  local toml="$repo_dir/.roborev.toml"
  if [ ! -f "$toml" ]; then
    echo "medium"
    return 0
  fi
  # Parse review_min_severity = 'value' or "value"
  local val
  val=$(grep -E "^review_min_severity\s*=" "$toml" 2>/dev/null \
        | head -1 \
        | "$PYTHON" -c "
import sys, re
line = sys.stdin.read()
m = re.search(r'''[\"']([^\"']+)[\"']''', line)
print(m.group(1) if m else 'medium')
" 2>/dev/null) || val="medium"
  echo "${val:-medium}"
}

# Fetch PR commit SHAs via gh.  Echoes one SHA per line, or empty on failure.
_get_pr_commits() {
  local pr_num="$1"
  gh pr view "$pr_num" \
    --json commits \
    --jq '.commits[].oid' 2>/dev/null || echo ""
}

# Detect PR number from branch name (uses gh pr list).
# Echoes the PR number, or "" if not found.
_branch_to_pr() {
  local branch="$1"
  gh pr list --head "$branch" --state open --json number --jq '.[0].number' \
    2>/dev/null | grep -E '^[0-9]+$' || echo ""
}

# Query reviews.db for open findings whose commit_sha is in the provided list.
# commit_shas_csv: comma-separated quoted SHAs, e.g. "'abc','def'"
# threshold: e.g. "medium"
# Outputs TSV: id | severity | sha (one row per finding)
_query_open_findings() {
  local commit_shas_csv="$1"
  local threshold="$2"
  local db="$3"

  [ -f "$db" ] || return 0
  [ -z "$commit_shas_csv" ] && return 0

  "$PYTHON" -c "
import sys, sqlite3

db_path = sys.argv[1]
threshold = sys.argv[2]
shas_csv = sys.argv[3]

sev_order = ['low', 'medium', 'high', 'critical']
try:
    thresh_idx = sev_order.index(threshold.lower())
except ValueError:
    thresh_idx = 1  # default: medium

try:
    con = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)
    # Build SHA list — strip any quoting from CSV
    shas = [s.strip().strip(\"'\").strip('\"') for s in shas_csv.split(',') if s.strip()]
    if not shas:
        con.close()
        sys.exit(0)

    placeholders = ','.join('?' * len(shas))
    # reviews joins review_jobs via job_id; review_jobs joins commits via commit_id
    rows = con.execute('''
        SELECT r.id, rj.min_severity, c.sha
        FROM reviews r
        JOIN review_jobs rj ON r.job_id = rj.id
        JOIN commits c ON rj.commit_id = c.id
        WHERE c.sha IN ({ph})
          AND r.closed = 0
    '''.format(ph=placeholders), shas).fetchall()
    con.close()

    for rid, sev, sha in rows:
        sev = (sev or '').lower().strip() or 'medium'
        try:
            sev_idx = sev_order.index(sev)
        except ValueError:
            sev_idx = 1
        if sev_idx >= thresh_idx:
            print(f'{rid}\t{sev}\t{sha}')
except Exception as e:
    # Fail-open
    sys.exit(0)
" "$db" "$threshold" "$commit_shas_csv" 2>/dev/null || true
}

# Parse commit messages for "acks roborev #N" and "closes/fixes roborev #N" citations.
# Returns comma-separated integer IDs.
_parse_citations_from_commits() {
  local commit_shas="$1"  # newline-separated list
  [ -z "$commit_shas" ] && echo "" && return 0

  local all_msgs=""
  local sha
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    local msg
    msg=$(git log --format="%s%n%b" -1 "$sha" 2>/dev/null) || continue
    all_msgs="${all_msgs}${msg}"$'\n'
  done <<< "$commit_shas"

  "$PYTHON" -c "
import sys, re
text = sys.argv[1]
# Matches: closes/close/fixes/fix/wontfix/acks roborev #N (case-insensitive)
pattern = re.compile(
    r'(?:close[sd]?|fix(?:es)?|wontfix|acks?)\s+roborev\s*#(\d+)',
    re.IGNORECASE
)
ids = pattern.findall(text)
print(','.join(ids))
" "$all_msgs" 2>/dev/null || echo ""
}

# Check acks.jsonl for explicitly acked findings (written by roborev_ack.sh).
# Returns comma-separated IDs present in acks.jsonl.
_parse_acked_ids() {
  local acks_file="$1"
  if [ ! -f "$acks_file" ]; then
    echo ""
    return 0
  fi

  "$PYTHON" -c "
import sys, json

acks_file = sys.argv[1]
ids = []
try:
    with open(acks_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                ids.append(str(obj.get('id', '')))
            except Exception:
                continue
except Exception:
    pass
print(','.join(i for i in ids if i))
" "$acks_file" 2>/dev/null || echo ""
}

# Emit one JSON log line to MERGE_GATE_LOG.
_log_run() {
  local pr="$1" threshold="$2" open_count="$3" cited_count="$4"
  local unresolved_count="$5" high_count="$6" medium_count="$7"
  local verdict="$8" mode="$9"

  mkdir -p "$(dirname "$MERGE_GATE_LOG")" 2>/dev/null || true
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "unknown")

  printf '{"ts":"%s","pr":%s,"threshold":"%s","open_count":%d,"cited_count":%d,"unresolved_count":%d,"severity_breakdown":{"high":%d,"medium":%d},"verdict":"%s","mode":"%s"}\n' \
    "$ts" "${pr:-null}" "$threshold" \
    "$open_count" "$cited_count" "$unresolved_count" \
    "$high_count" "$medium_count" \
    "$verdict" "$mode" \
    >> "$MERGE_GATE_LOG" 2>/dev/null || true
}

# Core gate logic.  Returns 0 (pass/warn) or 1 (block) based on findings.
# Sets _GATE_VERDICT, _GATE_MSG as side-effects.
_GATE_VERDICT=""
_GATE_MSG=""
_run_gate() {
  local pr_num="$1"
  local threshold="$2"
  local mode="$3"         # "dry-run" or "enforce"
  local repo_dir="$4"

  # -- Fetch PR commits
  local commit_shas
  commit_shas=$(_get_pr_commits "$pr_num")
  if [ -z "$commit_shas" ]; then
    _GATE_VERDICT="gate-pass"
    _GATE_MSG="[gate-pass] PR #${pr_num}: no commits found via gh (fail-open)"
    _log_run "$pr_num" "$threshold" 0 0 0 0 0 "gate-pass" "$mode"
    return 0
  fi

  # -- Build quoted CSV of SHAs for SQL
  local commit_shas_csv
  commit_shas_csv=$(echo "$commit_shas" | while IFS= read -r sha; do
    [ -n "$sha" ] && printf "'%s'," "$sha"
  done | sed 's/,$//')

  # -- Query DB for open findings
  local findings_tsv
  findings_tsv=$(_query_open_findings "$commit_shas_csv" "$threshold" "$ROBOREV_DB")

  local open_count
  if [ -z "$findings_tsv" ]; then
    open_count=0
  else
    open_count=$(echo "$findings_tsv" | grep -c . 2>/dev/null) || open_count=0
  fi

  if [ "$open_count" -eq 0 ]; then
    _GATE_VERDICT="gate-pass"
    _GATE_MSG="[gate-pass] PR #${pr_num}: 0 open findings at >= ${threshold} severity"
    _log_run "$pr_num" "$threshold" 0 0 0 0 0 "gate-pass" "$mode"
    return 0
  fi

  # -- Parse citations from commit messages
  local cited_csv
  cited_csv=$(_parse_citations_from_commits "$commit_shas")

  # -- Parse acks from acks.jsonl
  local acked_csv
  acked_csv=$(_parse_acked_ids "$ACKS_JSONL")

  local all_resolved_csv="${cited_csv},${acked_csv}"

  # -- Compute unresolved and severity breakdown
  local unresolved_tsv high_count medium_count unresolved_count
  unresolved_tsv=$("$PYTHON" -c "
import sys

findings_raw = sys.argv[1]
resolved_csv = sys.argv[2]

resolved_ids = set()
for part in resolved_csv.split(','):
    part = part.strip()
    if part.isdigit():
        resolved_ids.add(int(part))

rows = []
for line in findings_raw.strip().split('\n'):
    if not line.strip():
        continue
    parts = line.split('\t')
    if len(parts) < 2:
        continue
    rid = int(parts[0]) if parts[0].isdigit() else -1
    sev = parts[1].strip().lower() if len(parts) > 1 else 'medium'
    sha = parts[2].strip() if len(parts) > 2 else ''
    if rid not in resolved_ids:
        rows.append(f'{rid}\t{sev}\t{sha}')

print('\n'.join(rows))
" "$findings_tsv" "$all_resolved_csv" 2>/dev/null || echo "")

  if [ -z "$unresolved_tsv" ]; then
    unresolved_count=0
  else
    unresolved_count=$(echo "$unresolved_tsv" | grep -c . 2>/dev/null) || unresolved_count=0
  fi

  if [ -z "$unresolved_tsv" ]; then
    high_count=0
    medium_count=0
  else
    high_count=$(echo "$unresolved_tsv" | grep -cE $'\t''(high|critical)'$'\t' 2>/dev/null) || high_count=0
    medium_count=$(echo "$unresolved_tsv" | grep -cE $'\t''medium'$'\t' 2>/dev/null) || medium_count=0
  fi

  # Count cited/acked (resolved)
  local cited_count
  cited_count=$((open_count - unresolved_count))
  [ "$cited_count" -lt 0 ] && cited_count=0

  if [ "$unresolved_count" -eq 0 ]; then
    _GATE_VERDICT="gate-pass"
    _GATE_MSG="[gate-pass] PR #${pr_num}: ${open_count} findings found, all cited/acked"
    _log_run "$pr_num" "$threshold" "$open_count" "$cited_count" 0 0 0 "gate-pass" "$mode"
    return 0
  fi

  if [ "$high_count" -gt 0 ]; then
    # High/Critical unresolved — would block in enforce mode
    _GATE_VERDICT="gate-block"
    _GATE_MSG="[gate-block] PR #${pr_num}: ${high_count} unresolved High/Critical + ${medium_count} Medium at >= ${threshold}. Run: roborev_ack.sh <id> --reason \"<text>\" --pr ${pr_num}"
    _log_run "$pr_num" "$threshold" "$open_count" "$cited_count" "$unresolved_count" "$high_count" "$medium_count" "gate-block" "$mode"
    if [ "$mode" = "enforce" ]; then
      return 1
    fi
    return 0
  fi

  # Medium-only unresolved
  _GATE_VERDICT="gate-warn"
  _GATE_MSG="[gate-warn] PR #${pr_num}: ${medium_count} unresolved Medium findings (non-blocking)"
  _log_run "$pr_num" "$threshold" "$open_count" "$cited_count" "$unresolved_count" 0 "$medium_count" "gate-warn" "$mode"
  return 0
}

# ── Self-test ─────────────────────────────────────────────────────────────────
_selftest() {
  local pass=0 fail=0

  _t() {
    local label="$1" expected="$2" got="$3"
    if [ "$got" = "$expected" ]; then
      pass=$((pass+1))
      printf "  PASS [%s]\n" "$label"
    else
      fail=$((fail+1))
      printf "  FAIL [%s]: expected='%s' got='%s'\n" "$label" "$expected" "$got"
    fi
  }

  # _sev_at_least
  local rc
  rc=0; _sev_at_least "high"     "medium"   || rc=$?; _t "sev_at_least: high>=medium"    0 "$rc"
  rc=0; _sev_at_least "critical" "high"     || rc=$?; _t "sev_at_least: critical>=high"  0 "$rc"
  rc=0; _sev_at_least "medium"   "medium"   || rc=$?; _t "sev_at_least: medium>=medium"  0 "$rc"
  rc=0; _sev_at_least "low"      "medium"   || rc=$?; _t "sev_at_least: low>=medium"     1 "$rc"
  rc=0; _sev_at_least "low"      "high"     || rc=$?; _t "sev_at_least: low>=high"       1 "$rc"

  # _read_threshold — missing file gives "medium"
  _t "read_threshold: no toml" "medium" "$(_read_threshold /tmp/no_such_dir_$$)"

  # _read_threshold — from a temp toml
  local tmpdir
  tmpdir=$(mktemp -d /tmp/gate_test_XXXXXX)
  printf "review_min_severity = 'high'\n" > "$tmpdir/.roborev.toml"
  _t "read_threshold: high" "high" "$(_read_threshold "$tmpdir")"
  printf "review_min_severity = \"medium\"\n" > "$tmpdir/.roborev.toml"
  _t "read_threshold: medium dq" "medium" "$(_read_threshold "$tmpdir")"
  rm -rf "$tmpdir"

  # _parse_citations_from_commits — stub with no git history; just test parsing function
  local extract_result
  extract_result=$("$PYTHON" -c "
import re
text = 'fixes roborev #10\nacks roborev #20\ncloses roborev#30'
pattern = re.compile(r'(?:close[sd]?|fix(?:es)?|wontfix|acks?)\s+roborev\s*#(\d+)', re.IGNORECASE)
ids = pattern.findall(text)
print(','.join(ids))
" 2>/dev/null || echo "")
  _t "citations: python regex" "10,20,30" "$extract_result"

  # _parse_acked_ids — missing file
  _t "acked_ids: missing file" "" "$(_parse_acked_ids /tmp/no_such_acks_$$)"

  # _parse_acked_ids — valid jsonl
  local tmp_acks
  tmp_acks=$(mktemp /tmp/test_acks_XXXXXX)
  printf '{"id":5,"reason":"wontfix","pr":100,"acked_at":"2026-05-23T00:00:00","acked_by":"johngavin"}\n' > "$tmp_acks"
  printf '{"id":7,"reason":"false pos","pr":101,"acked_at":"2026-05-23T00:00:01","acked_by":"johngavin"}\n' >> "$tmp_acks"
  _t "acked_ids: two entries" "5,7" "$(_parse_acked_ids "$tmp_acks")"
  rm -f "$tmp_acks"

  # _query_open_findings — missing DB → fail-open (no output)
  local out
  out=$(_query_open_findings "'abc123','def456'" "medium" "/tmp/no_db_$$" 2>/dev/null)
  _t "query: missing DB -> empty" "" "$out"

  # _log_run — writes to a temp log
  local tmp_log
  tmp_log=$(mktemp /tmp/gate_log_XXXXXX)
  MERGE_GATE_LOG="$tmp_log" _log_run "253" "medium" 3 1 2 2 0 "gate-block" "dry-run"
  local log_line
  log_line=$(cat "$tmp_log")
  local has_verdict has_pr
  has_verdict=$(echo "$log_line" | grep -c '"verdict":"gate-block"' || echo 0)
  has_pr=$(echo "$log_line" | grep -c '"pr":253' || echo 0)
  _t "log_run: verdict in log"  "1" "$has_verdict"
  _t "log_run: pr in log"       "1" "$has_pr"
  rm -f "$tmp_log"

  echo ""
  printf "%d/%d PASS\n" "$pass" "$((pass+fail))"
  [ "$fail" -eq 0 ] && return 0 || return 1
}

# ── Argument parsing ──────────────────────────────────────────────────────────
_usage() {
  cat >&2 <<'EOF'
Usage:
  roborev_merge_gate.sh [--dry-run] <pr#>
  roborev_merge_gate.sh --branch <name>
  roborev_merge_gate.sh --enforce  <pr#>   (NOT active — future use only)

Options:
  --dry-run   Default mode — print verdict, always exit 0
  --enforce   Print verdict + exit 1 on gate-block (NOT wired into CI yet)
  --branch    Detect PR# from open PRs for the named branch
  --help      Show this message

Exit codes (dry-run): always 0
Exit codes (--enforce): 0 = pass/warn, 1 = block
EOF
}

_main() {
  if [ "${SELFTEST:-0}" = "1" ]; then
    _selftest
    exit $?
  fi

  local mode="dry-run"
  local pr_num=""
  local branch=""
  local repo_dir
  repo_dir=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)   mode="dry-run" ; shift ;;
      --enforce)   mode="enforce" ; shift ;;
      --branch)    branch="$2"   ; shift 2 ;;
      --help|-h)   _usage ; exit 0 ;;
      [0-9]*)      pr_num="$1"   ; shift ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        _usage
        exit 2
        ;;
    esac
  done

  # Resolve branch to PR number
  if [ -n "$branch" ] && [ -z "$pr_num" ]; then
    pr_num=$(_branch_to_pr "$branch")
    if [ -z "$pr_num" ]; then
      echo "[gate-pass] No open PR found for branch '$branch' (fail-open)"
      exit 0
    fi
  fi

  if [ -z "$pr_num" ]; then
    _usage
    exit 2
  fi

  local threshold
  threshold=$(_read_threshold "$repo_dir")

  _run_gate "$pr_num" "$threshold" "$mode" "$repo_dir"
  local gate_rc=$?

  echo "$_GATE_MSG"

  if [ "$mode" = "enforce" ] && [ "$gate_rc" -ne 0 ]; then
    exit 1
  fi
  exit 0
}

_main "$@"
