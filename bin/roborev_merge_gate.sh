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
#   3   INDETERMINATE — the gate could not evaluate the PR,
#       OR an unresolved finding's severity text could not
#       be parsed (llm#1146)                                  (NOT a pass)
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
# Severity is parsed from the review output text ("**Severity**: High" or the
# bare "Severity: High" form) via the SHARED parser in
# .claude/scripts/lib/roborev_classify.py — the same module
# roborev_project_backlog.sh and session_init.sh's Phase 13d backlog banner
# already use.  Before llm#1146 this script carried its own inline copy of
# the regex, and that copy had NOT received the llm#972 fix (optional bold
# markers) applied to roborev_severity_autoclose.sh and send_roborev_email.R
# — 18% of open findings used the non-bold form and were silently invisible
# to the gate, which then answered PASS on PRs it should have blocked.  A
# finding whose severity still cannot be parsed (module unavailable, or text
# matching neither a real severity marker nor a recognised "review didn't
# run"/"no issues found" shape) is NEVER silently dropped: if it is
# unresolved (not cited, not acked) the gate answers INDETERMINATE (exit 3),
# never PASS.  See tests/test_roborev_classify.sh for the R/Python parity
# proof and .claude/scripts/lib/roborev_classify.py's own docstring for why
# R and Python keep parallel (not shared) implementations.
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
# Part of: JohnGavin/llm#241, JohnGavin/llm#1146
# Related:
#   ~/.claude/scripts/roborev_merge_gate.sh    — dry-run predecessor (keep as-is)
#   .claude/rules/roborev-resolution.md        — policy documentation
#   .claude/rules/exit-code-conventions.md     — 0/1/2/3 PASS/FAIL/usage/INDETERMINATE
#   .claude/scripts/lib/roborev_classify.py    — shared severity parser (llm#1146)
#   .github/PULL_REQUEST_TEMPLATE.md           — checklist row
#   tests/test_roborev_merge_gate.sh           — test suite
#   tests/test_roborev_classify.sh             — shared-parser parity tests

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

# llm#1146: resolve the shared severity-parsing module's directory here,
# where BASH_SOURCE still points at this script, and pass it positionally
# into the python heredoc in _query_open_findings (mirroring
# session_init.sh's Phase 13d pattern — see that hook's _rbb_lib_dir
# resolution for the same trick applied to the same module).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFY_LIB_DIR="$(cd "${SCRIPT_DIR}/../.claude/scripts/lib" 2>/dev/null && pwd)" || CLASSIFY_LIB_DIR=""

# ── Defaults ─────────────────────────────────────────────────────────────────
ROBOREV_DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
ACKS_JSONL="${ACKS_JSONL:-$HOME/.roborev/acks.jsonl}"
DEFAULT_MIN_SEVERITY="High"
EMIT_JSON=0
REPO=""    # auto-detected from gh repo view if not provided

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
#
# llm#1146: severity is parsed via the SHARED .claude/scripts/lib/
# roborev_classify.py module (imported below), not an inline regex — this
# script's own copy of the regex had NOT received the llm#972 fix (optional
# bold markers) that roborev_severity_autoclose.sh and send_roborev_email.R
# already carry, so a genuine "Severity: High" (no bold) marker was
# invisible to it.
#
# Returns a JSON OBJECT (not a bare array — this is a deliberate shape
# change from the pre-llm#1146 version):
#   {
#     "findings":     [{"id":N,"severity":"High","commit_sha":"abc","location":"...","problem":"..."}, ...],
#     "unparseable":  [{"id":N,"commit_sha":"abc","outcome":"not_reviewed"|"unclassified"}, ...],
#     "import_error": "<message>"   # present only if the shared module could not be imported
#   }
#
# "findings" = open, closed=0/verdict_bool=0 rows whose severity parsed AND
# is >= threshold — same meaning as the old bare array.
#
# "unparseable" = open rows whose severity could NOT be parsed AND whose
# text does not match the module's "passed" shape (i.e. genuinely "no
# issues found" text that landed with verdict_bool=0 due to the known
# verdict_bool/output-text inconsistency — llm#972 cause 2, documented in
# send_roborev_email.R). These are NEVER silently dropped: the caller must
# treat an unresolved (uncited/unacked) entry here as INDETERMINATE, never
# as "no findings at this severity" — that conflation is exactly the bug
# llm#1146 fixes. A "passed"-shaped unparseable row IS dropped, same as
# before, because it genuinely carries no finding to report.
_query_open_findings() {
  local shas_newline="$1"   # newline-separated SHAs
  local min_sev="$2"        # threshold string e.g. "high"
  local db="$3"
  local lib_dir="${4:-}"    # dir containing roborev_classify.py

  [ -f "$db" ] || { echo '{"findings":[],"unparseable":[]}'; return 0; }
  [ -z "$shas_newline" ] && { echo '{"findings":[],"unparseable":[]}'; return 0; }

  "$PYTHON" - "$db" "$min_sev" "$lib_dir" <<PYEOF
import sys, sqlite3, json, re

db_path = sys.argv[1]
min_sev  = sys.argv[2].strip().lower()
lib_dir  = sys.argv[3] if len(sys.argv) > 3 else ""

# llm#1146: fail CLOSED (never a silent PASS) if the shared severity parser
# cannot be imported at all — that is a stronger version of "cannot ask the
# question" than a single unparseable row, so it is reported back to bash
# as import_error and turned into an INDETERMINATE verdict by _main(),
# never silently degraded to a laxer inline regex.
IMPORT_ERROR = None
if lib_dir and lib_dir not in sys.path:
    sys.path.insert(0, lib_dir)
try:
    from roborev_classify import (
        parse_max_severity_ordinal,
        classify_unparseable_finding,
        SEVERITY_ORDINAL,
    )
except Exception as e:
    IMPORT_ERROR = f"{type(e).__name__}: {e}"

if IMPORT_ERROR is not None:
    print(json.dumps({"findings": [], "unparseable": [], "import_error": IMPORT_ERROR}))
    sys.exit(0)

def sev_idx(s):
    return SEVERITY_ORDINAL.get((s or "").strip().lower(), -1)

# Read SHAs from stdin (passed via heredoc below)
shas_raw = """${shas_newline}"""
shas = [s.strip() for s in shas_raw.splitlines() if s.strip()]

if not shas:
    print(json.dumps({"findings": [], "unparseable": []}))
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
    # Fail-open: DB error → pass gate (pre-existing behaviour, unchanged by
    # llm#1146 — this is a query/connection failure, not an unparseable
    # severity, and reviews.db's mere absence is already caught earlier in
    # _main() as its own INDETERMINATE case).
    print(json.dumps({"findings": [], "unparseable": []}))
    sys.exit(0)

loc_re = re.compile(r"\*\*(?:Location|File)\*\*:\s*([^\n]+)", re.IGNORECASE)
prb_re = re.compile(r"\*\*Problem\*\*:\s*([^\n]+)", re.IGNORECASE)

findings = []
unparseable = []
for (rid, output, sha) in rows:
    output = output or ""
    max_ord = parse_max_severity_ordinal(output)
    if max_ord is None:
        # llm#1146: previously "continue # skip (conservative: don't block
        # on unparseable)" — that silent skip WAS the bug. Distinguish text
        # that genuinely means "no issues" (dropped, same as before) from
        # text where the review never ran or matches no known shape at all
        # (surfaced as unparseable, never silently dropped).
        outcome = classify_unparseable_finding(output)
        if outcome == "passed":
            continue
        unparseable.append({
            "id":         rid,
            "commit_sha": sha[:12],
            "outcome":    outcome,
        })
        continue
    if max_ord < min_idx:
        continue  # below threshold
    loc_m   = loc_re.search(output)
    prb_m   = prb_re.search(output)
    location = loc_m.group(1).strip() if loc_m else "(location unknown)"
    problem  = prb_m.group(1).strip()[:120] if prb_m else "(see review output)"
    label = next(k for k, v in SEVERITY_ORDINAL.items() if v == max_ord)
    findings.append({
        "id":         rid,
        "severity":   label.capitalize(),
        "commit_sha": sha[:12],
        "location":   location,
        "problem":    problem,
    })

print(json.dumps({"findings": findings, "unparseable": unparseable}))
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

  # Query open findings (llm#1146: now {"findings":[...],"unparseable":[...]},
  # optionally with "import_error" — see _query_open_findings's own comment).
  local findings_json
  findings_json=$(_query_open_findings "$commit_shas" "${min_sev,,}" "$ROBOREV_DB" "$CLASSIFY_LIB_DIR")

  # llm#1146: if the shared severity parser could not even be imported, the
  # gate cannot tell High from Low for ANY finding on this PR. That is a
  # stronger version of the same "cannot ask the question" state as a
  # missing gh binary or an absent reviews.db (llm#1012) — same treatment:
  # INDETERMINATE, never a fall-through to PASS.
  local import_error
  import_error=$("$PYTHON" -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('import_error') or '')" "$findings_json")
  if [ -n "$import_error" ]; then
    GATE_INDETERMINATE_DETAIL="severity-parser module unavailable: ${import_error}"
    _exit_indeterminate "severity_parser_unavailable" "$pr_num"
  fi

  # Parse citations and acks
  local cited_json acked_json
  cited_json=$(_parse_citations "$commit_shas")
  acked_json=$(_parse_acked_ids "$ACKS_JSONL")

  # Compute unresolved = open - (cited ∪ acked), for the threshold-qualifying
  # findings AND, separately, for the severity-unparseable ones. The same
  # citation/ack resolution mechanism applies to both — an operator who
  # already wrote "closes roborev #N" or acked #N has addressed that finding
  # regardless of whether its severity text happened to parse.
  local unresolved_json unresolved_unparseable_json
  unresolved_json=$("$PYTHON" - "$findings_json" "$cited_json" "$acked_json" <<'PYEOF'
import sys, json

data     = json.loads(sys.argv[1])
findings = data.get("findings", [])
cited    = set(json.loads(sys.argv[2]))
acked    = set(json.loads(sys.argv[3]))
resolved = cited | acked

unresolved = [f for f in findings if f["id"] not in resolved]
print(json.dumps(unresolved))
PYEOF
)

  unresolved_unparseable_json=$("$PYTHON" - "$findings_json" "$cited_json" "$acked_json" <<'PYEOF'
import sys, json

data        = json.loads(sys.argv[1])
unparseable = data.get("unparseable", [])
cited       = set(json.loads(sys.argv[2]))
acked       = set(json.loads(sys.argv[3]))
resolved    = cited | acked

unresolved = [f for f in unparseable if f["id"] not in resolved]
print(json.dumps(unresolved))
PYEOF
)

  local unresolved_unparseable_count
  unresolved_unparseable_count=$("$PYTHON" -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$unresolved_unparseable_json")

  # llm#1146: an unresolved finding whose severity text could not be parsed
  # must never be silently absent from the verdict — that IS the bug this
  # fixes (18% of open findings used a non-bold "Severity: High" marker the
  # old inline regex could not see, and the gate answered PASS regardless).
  # "no findings at this severity" and "the gate could not parse N
  # findings' severity" are different results and must not share an exit or
  # a message (checks-must-distinguish-unknown) — so this check runs BEFORE
  # the PASS/BLOCK decision below, and always routes through
  # _exit_indeterminate rather than reusing the PASS/BLOCK exit paths.
  if [ "$unresolved_unparseable_count" -gt 0 ]; then
    local unparseable_detail
    unparseable_detail=$("$PYTHON" -c "
import json, sys
items = json.loads(sys.argv[1])
print(', '.join(f\"#{i['id']} ({i['commit_sha']}, {i['outcome']})\" for i in items))
" "$unresolved_unparseable_json")
    GATE_INDETERMINATE_DETAIL="${unresolved_unparseable_count} open finding(s) on this PR have a Severity marker the gate could not parse, and are not cited/acked: ${unparseable_detail}"
    _exit_indeterminate "unparseable_severity" "$pr_num"
  fi

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
