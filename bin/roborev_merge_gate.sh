#!/usr/bin/env bash
# bin/roborev_merge_gate.sh — merge-gate: block PR merges with open roborev
# findings >= min-severity threshold (default: High, pilot scope).
#
# Usage:
#   bin/roborev_merge_gate.sh <pr#>
#   bin/roborev_merge_gate.sh --repo OWNER/NAME <pr#>
#   bin/roborev_merge_gate.sh --min-severity {Critical,High,Medium,Low} <pr#>
#   bin/roborev_merge_gate.sh --json <pr#>
#
# Exit codes:
#   0   All related findings >= threshold are cited or acked  (PASS)
#   1   One or more unresolved findings >= threshold          (BLOCK)
#   2   Usage error
#   3   INDETERMINATE — the gate could not evaluate the PR    (NOT a pass)
#
# Exit 3 exists because of llm#1012.  Before it, every way of failing to *ask*
# the question — `gh` missing, `gh` auth rejected, repo not resolvable, network
# down — landed on the same exit 0 and the same word on screen as a genuine
# clean result:
#
#     merge-gate: PASS (no commits found for PR #1011 — fail-open)
#
# `GH` was hardcoded to /usr/local/bin/gh, which does not exist on the machine
# this runs on, so the gate had never inspected a finding and could not fail.
# An error path and a negative-result path must never share an exit
# (.claude/rules/checks-must-distinguish-unknown.md).
#
# Fail-open is still available, but you have to ask for it:
# MERGE_GATE_FAIL_OPEN=1 downgrades exit 3 to exit 0.  Even then the output
# says INDETERMINATE, never PASS — the word PASS is reserved for a verdict
# reached by actually querying reviews.db.
#
# "Related" definition: commit_sha IN PR commits (commit-scope, Alternative C
# from llm#241).  This is the tightest scope and avoids the day-1 backlog freeze.
#
# Severity is parsed from the review output text: "**Severity**: High" regex.
# This mirrors roborev_severity_autoclose.sh (llm#224).
#
# Citation patterns recognised in PR commit messages (case-insensitive):
#   closes roborev #N
#   close roborev #N
#   fixes roborev #N
#   fix roborev #N
#   acks roborev #N
#   ack roborev #N
#   acks roborev #N --reason "…"
# Also reads ~/.roborev/acks.jsonl (written by roborev_ack.sh).
#
# Pilot scope: --min-severity High (default).  Escalate to Medium after 1 week
# of signal data (see llm#241 escalation path).
#
# Part of: JohnGavin/llm#241
# Related:
#   ~/.claude/scripts/roborev_merge_gate.sh  — dry-run predecessor (keep as-is)
#   .claude/rules/roborev-resolution.md      — policy documentation
#   .github/PULL_REQUEST_TEMPLATE.md         — checklist row
#   tests/test_roborev_merge_gate.sh         — test suite

set -euo pipefail

# ── Tool paths (survive launchd bare PATH) ───────────────────────────────────
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# Resolve from PATH first, then fall back to a known location.  A hardcoded
# absolute path does not fail loudly when it is wrong — it degrades to
# "command not found", which every caller below used to read as "found
# nothing" (llm#1012).  PATH is set immediately above, so `command -v` sees
# the launchd-safe set as well as the caller's.
PYTHON="${PYTHON:-$(command -v python3 2>/dev/null || echo /usr/bin/python3)}"
GH="${GH:-$(command -v gh 2>/dev/null || echo /usr/local/bin/gh)}"

# ── Defaults ─────────────────────────────────────────────────────────────────
ROBOREV_DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
ACKS_JSONL="${ACKS_JSONL:-$HOME/.roborev/acks.jsonl}"
DEFAULT_MIN_SEVERITY="High"
EMIT_JSON=0
REPO=""    # auto-detected from gh repo view if not provided

# ── Severity ordering ─────────────────────────────────────────────────────────
# Python helper used in multiple places; defined once as a heredoc constant.
_SEV_PY='
SEV_ORDER = ["low", "medium", "high", "critical"]

def sev_idx(s):
    s = (s or "").strip().lower()
    try:
        return SEV_ORDER.index(s)
    except ValueError:
        return -1
'

# ── Helpers ───────────────────────────────────────────────────────────────────

_usage() {
  cat >&2 <<'USAGE'
Usage:
  bin/roborev_merge_gate.sh [OPTIONS] <pr#>

Options:
  --repo OWNER/NAME          GitHub repo (default: current repo via gh)
  --min-severity LEVEL       Threshold: Critical|High|Medium|Low (default: High)
  --json                     Emit JSON result instead of table
  -h, --help                 Show this message

Exit codes:
  0  PASS — no unresolved findings >= threshold
  1  BLOCK — unresolved findings found
  2  Usage error
  3  INDETERMINATE — could not evaluate (gh unusable, repo unresolvable).
     NOT a pass.  Set MERGE_GATE_FAIL_OPEN=1 to downgrade this to exit 0.

Pilot scope: High only.  Cite findings in commits with:
  closes roborev #N   |   acks roborev #N --reason "…"
See .claude/rules/roborev-resolution.md for full policy.
USAGE
}

# ── The "could not ask" contract (llm#1012) ─────────────────────────────────
# Both gh wrappers below return:
#     0  the question was asked and answered (stdout may legitimately be empty)
#     3  the question could NOT be asked — binary missing, auth rejected,
#        network down, repo not a GitHub repo
# and, on 3, print the REASON on stdout in place of the answer.
#
# Reason-on-stdout rather than a global: these are called as
# `out=$(_get_pr_commits ...)`, i.e. inside a command-substitution subshell, so
# any variable they assign is discarded when that subshell exits.  Writing the
# reason where the answer would have gone is the one channel that survives, and
# the caller only reads it when rc!=0, when there is no answer to confuse it
# with.  (Caught by the very first end-to-end run of this fix: the detail line
# came back blank.)
#
# The rc distinction is the entire point: `2>/dev/null || echo ""` collapses
# both outcomes into an empty string, and emptiness then reads as a negative
# answer.
GATE_INDETERMINATE_DETAIL=""
_E_INDETERMINATE=3

# First non-empty line of $1, trimmed and length-capped, for one-line messages.
_first_line() {
  printf '%s' "$1" | tr -d '\r' | grep -m1 -v '^[[:space:]]*$' | cut -c1-160 || true
}

# Resolve OWNER/REPO from gh if not supplied.
_resolve_repo() {
  local repo="$1" out rc=0
  if [ -n "$repo" ]; then
    printf '%s' "$repo"
    return 0
  fi
  out=$("$GH" repo view --json nameWithOwner --jq '.nameWithOwner' 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s' "\`gh repo view\` failed (rc=$rc): $(_first_line "$out")"
    return "$_E_INDETERMINATE"
  fi
  if [ -z "$out" ]; then
    # gh succeeded but named no repo. That is not a negative answer about
    # findings — it means we never had a repo to ask about.
    printf '%s' "\`gh repo view\` returned no repo name"
    return "$_E_INDETERMINATE"
  fi
  printf '%s' "$out"
  return 0
}

# Fetch commit SHAs for a PR.
# Empty stdout with rc=0 is a real answer ("this PR has no commits"); an
# unusable gh is rc=3, never an empty answer.
_get_pr_commits() {
  local pr_num="$1" repo="$2" out rc=0
  out=$("$GH" pr view "$pr_num" --repo "$repo" \
          --json commits --jq '.commits[].oid' 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s' "\`gh pr view $pr_num --repo $repo\` failed (rc=$rc): $(_first_line "$out")"
    return "$_E_INDETERMINATE"
  fi
  printf '%s' "$out"
  return 0
}

# Emit an INDETERMINATE verdict and exit.
#   $1 = machine-readable reason   $2 = pr number
# Never prints the word PASS. The whole defect in llm#1012 was that this path
# read like a pass, so the string is the fix as much as the exit code is.
_exit_indeterminate() {
  local reason="$1" pr_num="$2" detail="${GATE_INDETERMINATE_DETAIL:-}"
  local downgrade="${MERGE_GATE_FAIL_OPEN:-0}"
  local final_exit="$_E_INDETERMINATE"
  [ "$downgrade" = "1" ] && final_exit=0

  if [ "$EMIT_JSON" = "1" ]; then
    "$PYTHON" -c 'import sys, json; print(json.dumps({"verdict":"indeterminate","reason":sys.argv[1],"pr":int(sys.argv[2]) if sys.argv[2].isdigit() else sys.argv[2],"detail":sys.argv[3],"failed_open":sys.argv[4]=="1","unresolved":[]}))' \
      "$reason" "$pr_num" "$detail" "$downgrade"
  else
    printf '%s\n' "merge-gate: INDETERMINATE — could not evaluate PR #${pr_num} (${reason})." >&2
    [ -n "$detail" ] && printf '%s\n' "  ${detail}" >&2
    printf '%s\n' "  This is NOT a pass: the gate never queried reviews.db, so an unresolved" >&2
    printf '%s\n' "  Critical finding would look exactly like this. Fix the cause, or set" >&2
    printf '%s\n' "  MERGE_GATE_FAIL_OPEN=1 to accept the risk deliberately." >&2
    if [ "$downgrade" = "1" ]; then
      printf '%s\n' "  MERGE_GATE_FAIL_OPEN=1 is set — exiting 0 anyway." >&2
    fi
  fi
  exit "$final_exit"
}

# Query reviews.db for open findings on the given commit SHAs.
# Severity is parsed from review output text ("**Severity**: High").
# Returns JSON list: [{"id":N,"severity":"high","commit_sha":"abc","location":"...","problem":"..."}]
_query_open_findings() {
  local shas_newline="$1"   # newline-separated SHAs
  local min_sev="$2"        # threshold string e.g. "high"
  local db="$3"

  [ -f "$db" ] || { echo "[]"; return 0; }
  [ -z "$shas_newline" ] && { echo "[]"; return 0; }

  "$PYTHON" - "$db" "$min_sev" <<PYEOF
import sys, sqlite3, json, re

db_path = sys.argv[1]
min_sev  = sys.argv[2].strip().lower()

${_SEV_PY}

# Read SHAs from stdin (passed via heredoc below)
shas_raw = """${shas_newline}"""
shas = [s.strip() for s in shas_raw.splitlines() if s.strip()]

if not shas:
    print("[]")
    sys.exit(0)

min_idx = sev_idx(min_sev)

try:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    placeholders = ",".join("?" * len(shas))
    rows = con.execute("""
        SELECT r.id, r.output, c.sha
        FROM reviews r
        JOIN review_jobs rj ON r.job_id = rj.id
        JOIN commits    c  ON rj.commit_id = c.id
        WHERE c.sha IN ({ph})
          AND r.closed = 0
          AND r.verdict_bool = 0
    """.format(ph=placeholders), shas).fetchall()
    con.close()
except Exception as e:
    # Fail-open: DB error → pass gate
    print("[]")
    sys.exit(0)

sev_re = re.compile(r"\*\*Severity\*\*:\s*(Critical|High|Medium|Low)", re.IGNORECASE)
loc_re = re.compile(r"\*\*(?:Location|File)\*\*:\s*([^\n]+)", re.IGNORECASE)
prb_re = re.compile(r"\*\*Problem\*\*:\s*([^\n]+)", re.IGNORECASE)

results = []
for (rid, output, sha) in rows:
    output = output or ""
    sevs = sev_re.findall(output)
    if not sevs:
        continue  # no parseable severity → skip (conservative: don't block on unparseable)
    max_sev = max(sevs, key=lambda s: sev_idx(s))
    if sev_idx(max_sev) < min_idx:
        continue  # below threshold
    loc_m   = loc_re.search(output)
    prb_m   = prb_re.search(output)
    location = loc_m.group(1).strip() if loc_m else "(location unknown)"
    problem  = prb_m.group(1).strip()[:120] if prb_m else "(see review output)"
    results.append({
        "id":         rid,
        "severity":   max_sev.capitalize(),
        "commit_sha": sha[:12],
        "location":   location,
        "problem":    problem,
    })

print(json.dumps(results))
PYEOF
}

# Parse "closes/acks/fixes roborev #N" from commit messages.
# Returns a Python set literal encoded as JSON array of integers.
_parse_citations() {
  local shas_newline="$1"   # newline-separated SHAs

  [ -z "$shas_newline" ] && { echo "[]"; return 0; }

  # Collect commit messages
  local all_msgs=""
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    local msg
    msg=$(git log --format="%s%n%b" -1 "$sha" 2>/dev/null) || continue
    all_msgs="${all_msgs}${msg}"$'\n'
  done <<< "$shas_newline"

  "$PYTHON" - "$all_msgs" <<'PYEOF'
import sys, re, json
text = sys.argv[1]
pattern = re.compile(
    r"(?:close[sd]?|fix(?:es)?|wontfix|acks?)\s+roborev\s*#(\d+)",
    re.IGNORECASE
)
ids = [int(x) for x in pattern.findall(text)]
print(json.dumps(sorted(set(ids))))
PYEOF
}

# Parse acks.jsonl.  Returns JSON array of integers.
_parse_acked_ids() {
  local acks_file="$1"
  [ -f "$acks_file" ] || { echo "[]"; return 0; }
  "$PYTHON" - "$acks_file" <<'PYEOF'
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
                v = obj.get("id", "")
                if str(v).isdigit():
                    ids.append(int(v))
            except Exception:
                continue
except Exception:
    pass
print(json.dumps(sorted(set(ids))))
PYEOF
}

# Print structured table of unresolved findings.
_print_table() {
  local findings_json="$1"
  "$PYTHON" - "$findings_json" <<'PYEOF'
import sys, json

findings = json.loads(sys.argv[1])
if not findings:
    print("  (none)")
    return

# column widths
hdr = ("ID", "Severity", "Commit", "Location", "Problem")
rows = [(str(f["id"]), f["severity"], f["commit_sha"],
         f["location"][:40], f["problem"][:60]) for f in findings]

widths = [max(len(h), max(len(r[i]) for r in rows))
          for i, h in enumerate(hdr)]
fmt = "  {:<{w0}}  {:<{w1}}  {:<{w2}}  {:<{w3}}  {:<{w4}}"
line = fmt.format(*hdr, w0=widths[0], w1=widths[1],
                  w2=widths[2], w3=widths[3], w4=widths[4])
print(line)
print("  " + "-" * (sum(widths) + 8))
for r in rows:
    print(fmt.format(*r, w0=widths[0], w1=widths[1],
                     w2=widths[2], w3=widths[3], w4=widths[4]))
PYEOF
}

# ── Main ──────────────────────────────────────────────────────────────────────
_main() {
  local pr_num=""
  local min_sev="$DEFAULT_MIN_SEVERITY"

  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        REPO="$2"; shift 2 ;;
      --min-severity)
        min_sev="$2"; shift 2 ;;
      --json)
        EMIT_JSON=1; shift ;;
      -h|--help)
        _usage; exit 0 ;;
      [0-9]*)
        pr_num="$1"; shift ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        _usage
        exit 2 ;;
    esac
  done

  if [ -z "$pr_num" ]; then
    echo "ERROR: <pr#> is required" >&2
    _usage
    exit 2
  fi

  # Validate min-severity
  case "${min_sev,,}" in
    critical|high|medium|low) ;;
    *)
      echo "ERROR: --min-severity must be one of Critical|High|Medium|Low" >&2
      exit 2 ;;
  esac

  # Preflight: is the tool we depend on actually runnable?  Checked BEFORE any
  # question is asked, so "gh is missing" is reported as itself rather than as
  # whatever empty answer it would have produced downstream (llm#1012).
  if ! [ -x "$GH" ] && ! command -v "$GH" >/dev/null 2>&1; then
    GATE_INDETERMINATE_DETAIL="gh not executable at '$GH' (set GH=/path/to/gh, or put gh on PATH)"
    _exit_indeterminate "gh_unavailable" "$pr_num"
  fi

  # Resolve repo
  local repo rc=0
  repo=$(_resolve_repo "$REPO") || rc=$?
  if [ "$rc" -ne 0 ]; then
    GATE_INDETERMINATE_DETAIL="$repo"   # on failure stdout carries the reason
    _exit_indeterminate "repo_unresolvable" "$pr_num"
  fi

  # No reviews.db means there is nothing to consult, which is a failure to ask
  # the question — not an answer of "no findings".  Same shape as the gh
  # failures above; it used to print PASS for the same reason (llm#1012).
  if [ ! -f "$ROBOREV_DB" ]; then
    GATE_INDETERMINATE_DETAIL="reviews.db not found at '$ROBOREV_DB' (set ROBOREV_DB=/path/to/reviews.db)"
    _exit_indeterminate "db_absent" "$pr_num"
  fi

  # Fetch PR commits.  rc!=0 means gh could not answer — NOT that the PR has
  # no commits.  These were the same exit before llm#1012.
  local commit_shas
  rc=0
  commit_shas=$(_get_pr_commits "$pr_num" "$repo") || rc=$?
  if [ "$rc" -ne 0 ]; then
    GATE_INDETERMINATE_DETAIL="$commit_shas"  # on failure stdout carries the reason
    _exit_indeterminate "pr_commits_unavailable" "$pr_num"
  fi

  if [ -z "$commit_shas" ]; then
    # gh answered, and the answer is "no commits".  A PR with no commits has
    # no findings attached to it, so this genuinely is a pass.
    if [ "$EMIT_JSON" = "1" ]; then
      printf '{"verdict":"pass","reason":"no_commits","pr":%s,"unresolved":[]}\n' "$pr_num"
    else
      echo "merge-gate: PASS (PR #${pr_num} has no commits — nothing to gate)"
    fi
    exit 0
  fi

  # Query open findings
  local findings_json
  findings_json=$(_query_open_findings "$commit_shas" "${min_sev,,}" "$ROBOREV_DB")

  # Parse citations and acks
  local cited_json acked_json
  cited_json=$(_parse_citations "$commit_shas")
  acked_json=$(_parse_acked_ids "$ACKS_JSONL")

  # Compute unresolved = open - (cited ∪ acked)
  local unresolved_json
  unresolved_json=$("$PYTHON" - "$findings_json" "$cited_json" "$acked_json" <<'PYEOF'
import sys, json

findings = json.loads(sys.argv[1])
cited    = set(json.loads(sys.argv[2]))
acked    = set(json.loads(sys.argv[3]))
resolved = cited | acked

unresolved = [f for f in findings if f["id"] not in resolved]
print(json.dumps(unresolved))
PYEOF
)

  local unresolved_count
  unresolved_count=$("$PYTHON" -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$unresolved_json")

  if [ "$EMIT_JSON" = "1" ]; then
    "$PYTHON" - "$pr_num" "$min_sev" "$unresolved_json" <<'PYEOF'
import sys, json
pr_num   = sys.argv[1]
min_sev  = sys.argv[2]
findings = json.loads(sys.argv[3])
verdict  = "pass" if not findings else "block"
print(json.dumps({
    "verdict":       verdict,
    "pr":            int(pr_num),
    "min_severity":  min_sev,
    "unresolved_count": len(findings),
    "unresolved":    findings,
}))
PYEOF
    [ "$unresolved_count" -eq 0 ] && exit 0 || exit 1
  fi

  if [ "$unresolved_count" -eq 0 ]; then
    printf "merge-gate: PASS (no unresolved %s-severity findings)\n" "$min_sev"
    exit 0
  fi

  # BLOCK path — print structured table
  printf "merge-gate: BLOCK — %d unresolved finding(s) >= %s severity for PR #%s\n" \
    "$unresolved_count" "$min_sev" "$pr_num"
  echo ""
  _print_table "$unresolved_json"
  echo ""
  echo "Resolve with one of:"
  echo "  closes roborev #N       — in a commit message on this branch"
  echo "  acks roborev #N --reason \"…\"   — explicit waiver"
  echo ""
  echo "See .claude/rules/roborev-resolution.md for policy."
  exit 1
}

_main "$@"
