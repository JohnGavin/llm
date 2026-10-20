#!/usr/bin/env bash
# roborev_open_above_threshold.sh — list OPEN roborev reviews for one repo
# whose maximum parsed finding severity is ABOVE that repo's effective
# autoclose threshold. Shared by /bye (session-end.md) and session_init.sh so
# a verdict that lands after a session ended is seen by the next session.
#
# Usage: roborev_open_above_threshold.sh [--repo <name>] [--db <path>]
#   --repo  repo name as roborev records it (repos.name). Default: basename of
#           the MAIN checkout (git --git-common-dir), so worktrees resolve to
#           the project name, not the branch name (llm#1276).
#   --db    reviews.db path. Default: $ROBOREV_DB or ~/.roborev/reviews.db.
#
# Output (stdout): one `job_id=<id> max=<severity>` line per review, then a
# final `count=<n>`. NEVER prints review text, file paths or finding bodies
# (the repo may hold private or health data).
#
# Exit: 0 = none above threshold, 1 = at least one, 3 = INDETERMINATE (db
# missing/unreadable, threshold unresolved, parser failure; the reason is on
# stderr). An error path never shares the exit of "none"
# (checks-must-distinguish-unknown).
#
# Threshold resolution is REUSED from roborev_severity_autoclose.sh (its
# _sev_ordinal/_repo_threshold/_global_threshold functions are extracted, not
# copied) and severity from lib/roborev_classify.py review_severity_ordinal().
# Precedence: ROBOREV_SEVERITY_AUTOCLOSE_THRESHOLD env, per-repo
# .roborev.toml [autoclose] severity_threshold, ~/.roborev/config.toml, off.
# threshold=off: every open review with a parsed severity counts (nothing is
# auto-closed). Reviews with no parsed severity are NOT counted here: they are
# a separate data-quality bucket.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SELF_DIR}/lib"
AUTOCLOSE="${SELF_DIR}/roborev_severity_autoclose.sh"

indeterminate() { echo "roborev_open_above_threshold: INDETERMINATE: $*" >&2; exit 3; }

REPO=""
DB="${ROBOREV_DB:-${HOME}/.roborev/reviews.db}"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || { echo "--repo requires an argument" >&2; exit 2; }; REPO="$2"; shift 2 ;;
    --db)   [ $# -ge 2 ] || { echo "--db requires an argument" >&2; exit 2; }; DB="$2"; shift 2 ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

MAIN_ROOT=""
if [ -z "$REPO" ]; then
  _common=$(git rev-parse --git-common-dir 2>/dev/null) || _common=""
  [ -n "$_common" ] || indeterminate "no --repo given and not inside a git repository"
  case "$_common" in /*) : ;; *) _common="$(pwd)/$_common" ;; esac
  MAIN_ROOT=$(cd "$(dirname "$_common")" 2>/dev/null && pwd) || MAIN_ROOT=""
  [ -n "$MAIN_ROOT" ] || indeterminate "could not resolve the main checkout root"
  REPO=$(basename "$MAIN_ROOT")
fi

[ -f "$DB" ] || indeterminate "reviews db not found"
[ -r "$DB" ] || indeterminate "reviews db not readable"
[ -x /usr/bin/python3 ] || indeterminate "no /usr/bin/python3"
[ -f "$AUTOCLOSE" ] || indeterminate "roborev_severity_autoclose.sh not found beside this script"

# Reuse the autoclose script's threshold helpers (top-level, unindented defs;
# sourcing the whole script would run its argument parsing and side effects).
FN_FILE=$(mktemp "${TMPDIR:-/tmp}/rv_oat_fn.XXXXXX") || indeterminate "mktemp failed"
trap 'rm -f "$FN_FILE"' EXIT
sed -n '/^_sev_ordinal() {/,/^}/p;/^_sev_name() {/,/^}/p;/^_repo_threshold() {/,/^}/p;/^_global_threshold() {/,/^}/p' \
  "$AUTOCLOSE" > "$FN_FILE"
for _f in _sev_ordinal _sev_name _repo_threshold _global_threshold; do
  grep -q "^${_f}() {" "$FN_FILE" || indeterminate "could not extract ${_f} from roborev_severity_autoclose.sh"
done
# shellcheck disable=SC1090
source "$FN_FILE"

# Open reviews for the repo as pipe-delimited rows: job_id|sev_ordinal|root.
# sev_ordinal is empty when no severity parsed (those rows are skipped).
_rows_py() {
  /usr/bin/python3 - "$DB" "$REPO" "$LIB_DIR" <<'PYEOF'
import sqlite3, sys
db_path, repo, lib_dir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, lib_dir)
try:
    from roborev_classify import review_severity_ordinal
except Exception as e:
    sys.stderr.write("could not import roborev_classify: %s\n" % type(e).__name__)
    sys.exit(3)
try:
    con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    rows = con.execute("""
        SELECT rv.job_id, rv.output, rv.structured_output, rp.root_path
        FROM reviews rv
        JOIN review_jobs rj ON rj.id = rv.job_id
        JOIN repos rp ON rp.id = rj.repo_id
        WHERE rv.closed = 0 AND rp.name = ?
        ORDER BY rv.job_id
    """, (repo,)).fetchall()
    con.close()
except Exception as e:
    sys.stderr.write("reviews db query failed: %s\n" % type(e).__name__)
    sys.exit(3)
for job_id, out, structured, root in rows:
    try:
        sev = review_severity_ordinal(out, structured)
    except Exception as e:
        sys.stderr.write("severity parse failed: %s\n" % type(e).__name__)
        sys.exit(3)
    if sev is None:
        continue
    print("%s|%s|%s" % (job_id, sev, (root or "").replace("|", " ")))
PYEOF
}

ROWS=$(_rows_py)
_rc=$?
[ "$_rc" -eq 0 ] || indeterminate "severity/db read failed (rc=${_rc})"

COUNT=0
OUT=""
while IFS= read -r _row; do
  [ -n "$_row" ] || continue
  _id=${_row%%|*}; _rest=${_row#*|}
  _sev=${_rest%%|*}; _root=${_rest#*|}

  _thr=""
  if [ -n "${ROBOREV_SEVERITY_AUTOCLOSE_THRESHOLD:-}" ]; then
    _thr="$ROBOREV_SEVERITY_AUTOCLOSE_THRESHOLD"
  else
    _thr=$(_repo_threshold "$_root")
    if [ -z "$_thr" ] && [ -n "$MAIN_ROOT" ]; then
      _thr=$(_repo_threshold "$MAIN_ROOT")
    fi
    [ -n "$_thr" ] || _thr=$(_global_threshold)
    [ -n "$_thr" ] || _thr="off"
  fi
  _thr=$(printf '%s' "$_thr" | tr '[:upper:]' '[:lower:]')
  _t_ord=$(_sev_ordinal "$_thr")
  [ "$_t_ord" -ge 0 ] || indeterminate "threshold unresolved (unrecognised value '${_thr}')"

  # threshold=off (0): every parsed severity (>=1) is above it.
  if [ "$_sev" -gt "$_t_ord" ]; then
    COUNT=$((COUNT + 1))
    OUT="${OUT}job_id=${_id} max=$(_sev_name "$_sev")
"
  fi
done <<EOF
$ROWS
EOF

printf '%s' "$OUT"
echo "count=${COUNT}"
[ "$COUNT" -eq 0 ] && exit 0
exit 1
