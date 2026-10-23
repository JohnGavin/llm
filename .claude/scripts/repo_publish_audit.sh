#!/usr/bin/env bash
# repo_publish_audit.sh -- the "fresh audit" behind the private -> public gate
# (llm#1392, parent llm#1382). Called by .claude/hooks/repo_visibility_guard.sh;
# also run by hand (or by an assistant) to RECORD an audit.
#
#   repo_publish_audit.sh --fingerprint --dir DIR
#   repo_publish_audit.sh --verify      --repo KEY --dir DIR
#   repo_publish_audit.sh --record      --repo KEY --dir DIR
#
# KEY is owner/name (or a bare name for a repo that does not exist yet). DIR is
# the local clone whose history would be published.
#
# What "fresh audit" means. A repo may be made public only when the ledger holds
# a record that a FULL-HISTORY scan of exactly what is about to be published
# came back with ZERO findings, within the freshness window. The scan is
# private_data_scan.sh --full-history run as a public repo (the private-term
# rule, the generic patterns, the deny-list, the document and image gates all
# apply; the per-repo allow-list does not, because a repo being published has a
# remote). Zero is the bar: unlike the scheduled audit's new-versus-known
# ledger, a "known" finding is still published.
#
# Tip fingerprint. sha256 over the sorted "<object name> <ref name>" lines of
# EVERY ref in DIR (git for-each-ref: branches, tags, remotes, stash, notes).
# That is a superset of what a push publishes and matches what the scan reads
# (git rev-list --all), so any new commit, moved branch, new tag or deleted ref
# changes the fingerprint and voids the record. The default-branch tip alone
# would miss a second branch or tag; this rule has no such gap.
#
# Store. The existing ledger table private_data_history_unit_state in
# unified.duckdb, one row per repo under the key "publish:<owner/name>" (the
# scheduled --all-public audit keys its rows by plain owner/name, so the two
# never touch each other's rows). ref_hash = the tip fingerprint; denylist_hash
# = hash of the deny-list file plus the private-term list (header line left out,
# so a re-generated list with the same terms keeps the record); scanner_hash =
# scanner + this script; last_outcome PASS or FAIL; last_full_scan_epoch.
# Hashes only, never a matched value.
#
# --verify result (stdout RESULT=... and DETAIL=..., never a matched value or a
# private name) and exit code (0 / 1 / 2 / 3, checks-must-distinguish-unknown):
#   0  RESULT=PASS             record is clean, for this tip, in the window
#   1  RESULT=NO_RECORD        nothing recorded for this repo
#      RESULT=TIP_MISMATCH     the record is for different refs
#      RESULT=FINDINGS         the record says the scan found something
#      RESULT=CONTEXT_CHANGED  deny-list, term list or scanner changed since
#      RESULT=STALE            older than the window
#   2  usage error
#   3  RESULT=INDETERMINATE    could not be decided: no ledger, ledger
#      unreadable or locked, term list or deny-list missing, empty or stale, a
#      required tool missing, timeout, not a git repository, no refs.
#      Never read as a pass.
# --record: 0 clean and recorded; 1 findings (recorded as FAIL; prints counts
# per rule only); 3 INDETERMINATE (nothing recorded); 2 usage.
#
# The scan inside --record is bounded by REPO_PUBLISH_AUDIT_SCAN_TIMEOUT
# (default 1800 s); the ledger calls by 10 s (the hook's own limit is 30 s).
#
# Env (the first four are test seams): UNIFIED_DB_PATH, PRIVATE_TERMS_FILE,
# PRIVATE_VALUES_FILE, SCANNER, REPO_PUBLISH_AUDIT_MAX_AGE_HOURS (default 24),
# PRIVATE_TERMS_MAX_AGE_DAYS (default 7, as the scanner).
#
# Bash 3.2 compatible. Never auto-remediates; never writes outside the ledger.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOME_DIR="${HOME:-}"
DB="${UNIFIED_DB_PATH:-${HOME_DIR}/.claude/logs/unified.duckdb}"
TERMS="${PRIVATE_TERMS_FILE:-${HOME_DIR}/.config/private_terms.txt}"
VALUES="${PRIVATE_VALUES_FILE:-${HOME_DIR}/.config/private_values.env}"
SCANNER="${SCANNER:-${SCRIPT_DIR}/private_data_scan.sh}"
RB_LIB="${REPO_PUBLISH_RUN_BOUNDED:-${SCRIPT_DIR}/../hooks/lib/run_bounded.sh}"
MAX_AGE_H="${REPO_PUBLISH_AUDIT_MAX_AGE_HOURS:-24}"
TERMS_MAX_DAYS="${PRIVATE_TERMS_MAX_AGE_DAYS:-7}"
SCAN_TIMEOUT="${REPO_PUBLISH_AUDIT_SCAN_TIMEOUT:-1800}"
DB_TIMEOUT=10
TABLE="private_data_history_unit_state"

TMPD=""
cleanup() { [ -z "$TMPD" ] || rm -rf "$TMPD"; }
trap cleanup EXIT

out() { printf 'RESULT=%s\nDETAIL=%s\n' "$1" "$2"; }
indet() { out INDETERMINATE "$1"; exit 3; }
usage() { echo "usage: repo_publish_audit.sh --fingerprint --dir DIR | --verify --repo KEY --dir DIR | --record --repo KEY --dir DIR" >&2; exit 2; }

MODE=""; REPO=""; DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fingerprint|--verify|--record) MODE="${1#--}"; shift ;;
    --repo) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --dir)  [ $# -ge 2 ] || usage; DIR="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$MODE" ] || usage
[ -n "$DIR" ] || usage
if [ "$MODE" != "fingerprint" ]; then
  [ -n "$REPO" ] || usage
  printf '%s' "$REPO" | grep -qE '^[a-z0-9._-]+(/[a-z0-9._-]+)?$' || { echo "repo_publish_audit: --repo must be lowercase owner/name or name" >&2; exit 2; }
fi

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else return 1; fi
}

iso_to_epoch() {
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null
}

# bounded SECONDS CMD... -> the command's status; 124 timeout, 125 no bounding tool
bounded() {
  if [ -r "$RB_LIB" ]; then
    # shellcheck disable=SC1090
    . "$RB_LIB"
    run_bounded "$@"
  else
    return 125
  fi
}

fingerprint() {
  local refs
  git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || indet "not a git repository (or unreadable): the audit needs the local clone that will be published"
  refs="$(git -C "$DIR" for-each-ref --format='%(objectname) %(refname)' 2>/dev/null)" || indet "could not list the refs of the repository"
  [ -n "$refs" ] || indet "the repository has no refs (nothing to fingerprint)"
  printf '%s\n' "$refs" | LC_ALL=C sort | sha256_stdin || indet "no sha256 tool (shasum or sha256sum) on PATH"
}

# Term list: present, non-empty, header with a parseable, recent generated= time.
terms_check() {
  local first gen epoch now age
  [ -f "$TERMS" ] && [ -r "$TERMS" ] || indet "private-term list missing or unreadable"
  [ -s "$TERMS" ] || indet "private-term list is empty"
  first="$(head -n 1 "$TERMS" | tr -d '\r')"
  case "$first" in
    "# private_terms v1 "*generated=*) : ;;
    *) indet "private-term list has no '# private_terms v1 generated=' header" ;;
  esac
  gen="${first#*generated=}"; gen="${gen%% *}"
  epoch="$(iso_to_epoch "$gen")" || indet "private-term list header has an unparseable generated= time"
  now="$(date -u +%s)"
  [ "$epoch" -le $((now + 86400)) ] || indet "private-term list header time is in the future"
  age=$(( (now - epoch) / 86400 ))
  printf '%s' "$TERMS_MAX_DAYS" | grep -qE '^[0-9]+$' || indet "PRIVATE_TERMS_MAX_AGE_DAYS is not a whole number"
  [ "$age" -le "$TERMS_MAX_DAYS" ] || indet "private-term list is stale (${age} days old, limit ${TERMS_MAX_DAYS})"
  tail -n +2 "$TERMS" | grep -qE '^[[:space:]]*[^#[:space:]]' || indet "private-term list has a header but no terms"
}

context_hashes() { # sets DLH and SCH
  [ -f "$VALUES" ] && [ -r "$VALUES" ] && [ -s "$VALUES" ] || indet "deny-list file missing, unreadable or empty"
  [ -r "$SCANNER" ] || indet "scanner not found or unreadable"
  local a b
  a="$(sha256_stdin < "$VALUES")" || indet "no sha256 tool (shasum or sha256sum) on PATH"
  b="$(tail -n +2 "$TERMS" | tr -d '\r' | sha256_stdin)" || indet "no sha256 tool on PATH"
  DLH="$(printf '%s%s' "$a" "$b" | sha256_stdin)"
  SCH="$({ sha256_stdin < "$SCANNER"; sha256_stdin < "${BASH_SOURCE[0]}"; } | sha256_stdin)"
  [ -n "$DLH" ] && [ -n "$SCH" ] || indet "could not hash the audit inputs"
}

need_tools() {
  command -v git >/dev/null 2>&1 || indet "git is not on PATH"
  command -v duckdb >/dev/null 2>&1 || indet "duckdb is not on PATH (the ledger cannot be read)"
  [ -r "$RB_LIB" ] || indet "run_bounded helper not found (no way to bound the ledger call)"
}

db_read() { # SQL -> stdout; rc 0 ok
  [ -f "$DB" ] || return 2
  bounded "$DB_TIMEOUT" duckdb -init /dev/null -readonly -csv -noheader "$DB" -c "$1" 2>"$TMPD/dberr"
}

db_write() {
  [ -f "$DB" ] || return 2
  bounded "$DB_TIMEOUT" duckdb -init /dev/null -bail "$DB" -c "$1" >/dev/null 2>"$TMPD/dberr"
}

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/repo_publish_audit.XXXXXX")" || { echo "repo_publish_audit: cannot create a temp dir" >&2; exit 3; }

case "$MODE" in
fingerprint)
  command -v git >/dev/null 2>&1 || indet "git is not on PATH"
  fingerprint
  ;;
verify)
  need_tools
  printf '%s' "$MAX_AGE_H" | grep -qE '^[0-9]+$' || indet "REPO_PUBLISH_AUDIT_MAX_AGE_HOURS is not a whole number"
  terms_check
  context_hashes
  FP="$(fingerprint)" || { printf '%s\n' "$FP"; exit 3; }
  [ -f "$DB" ] || indet "ledger database not found"
  row="$(db_read "SELECT ref_hash, denylist_hash, scanner_hash, last_outcome, last_full_scan_epoch FROM ${TABLE} WHERE repo = 'publish:${REPO}'")" \
    || indet "ledger unreadable, locked or table missing ($(head -c 160 "$TMPD/dberr" | tr '\n' ' '))"
  if [ -z "$row" ]; then out NO_RECORD "no audit recorded for this repository"; exit 1; fi
  IFS=',' read -r r_ref r_dl r_sc r_out r_ep <<EOF
$row
EOF
  printf '%s' "${r_ep:-}" | grep -qE '^[0-9]+$' || indet "ledger row is malformed"
  now="$(date -u +%s)"
  [ "$r_ep" -le $((now + 300)) ] || indet "ledger row is dated in the future (clock skew?)"
  if [ "$r_ref" != "$FP" ]; then out TIP_MISMATCH "the recorded audit is for different refs than the ones that would be published"; exit 1; fi
  if [ "$r_out" != "PASS" ]; then out FINDINGS "the recorded audit of these refs found something (outcome ${r_out})"; exit 1; fi
  if [ "$r_dl" != "$DLH" ] || [ "$r_sc" != "$SCH" ]; then out CONTEXT_CHANGED "the deny-list, private-term list or scanner changed since the audit"; exit 1; fi
  age_s=$(( now - r_ep ))
  if [ "$age_s" -gt $(( MAX_AGE_H * 3600 )) ]; then out STALE "the recorded audit is $(( age_s / 3600 )) h old (limit ${MAX_AGE_H} h)"; exit 1; fi
  out PASS "clean full-history audit of these refs, $(( age_s / 60 )) min old"
  exit 0
  ;;
record)
  need_tools
  terms_check
  context_hashes
  [ -f "$DB" ] || indet "ledger database not found (apply the schema: bash .claude/scripts/housekeeping_schema_apply.sh)"
  FP="$(fingerprint)" || { printf '%s\n' "$FP"; exit 3; }
  env REPO_ROOT="$DIR" PRIVATE_DATA_SCAN_VISIBILITY=public UNIFIED_DB_PATH="$DB" \
      PRIVATE_TERMS_FILE="$TERMS" PRIVATE_VALUES_FILE="$VALUES" \
      bash "$SCANNER" --full-history --require-denylist --tsv >"$TMPD/scan.out" 2>"$TMPD/scan.err" </dev/null &
  spid=$!
  # bound the scan with a watchdog (the scan is a long-running child)
  ( sleep "$SCAN_TIMEOUT"; kill "$spid" 2>/dev/null ) >/dev/null 2>&1 &
  wpid=$!
  wait "$spid"; rc=$?
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  if [ "$rc" -ge 128 ]; then indet "the scan was killed (timeout ${SCAN_TIMEOUT} s or signal ${rc})"; fi
  nrows="$(grep -c "^FINDING$(printf '\t')" "$TMPD/scan.out")"; nrows="${nrows:-0}"
  hdr="$(grep -oE '^private-data-scan: [0-9]+ finding' "$TMPD/scan.out" | grep -oE '[0-9]+' | head -1)"
  outcome=""
  case "$rc" in
    0) grep -q '^private-data-scan: clean' "$TMPD/scan.out" && outcome=PASS || indet "the scanner exited 0 without a clean summary line" ;;
    1) if [ -n "$hdr" ] && [ "$hdr" = "$nrows" ] && [ "$nrows" -gt 0 ]; then outcome=FAIL
       else indet "the scanner exited 1 without a findings summary (internal error: $(head -c 160 "$TMPD/scan.err" | tr '\n' ' '))"; fi ;;
    3) indet "the scanner reported INDETERMINATE: $(head -c 200 "$TMPD/scan.err" | tr '\n' ' ')" ;;
    *) indet "the scanner exited with unexpected code ${rc}" ;;
  esac
  FP2="$(fingerprint)" || { printf '%s\n' "$FP2"; exit 3; }
  [ "$FP2" = "$FP" ] || indet "the refs changed while the scan was running; run the audit again"
  db_write "INSERT OR REPLACE INTO ${TABLE} VALUES ('publish:${REPO}', '${FP}', '${DLH}', '${SCH}', '${outcome}', $(date -u +%s))" \
    || indet "could not write the ledger record ($(head -c 160 "$TMPD/dberr" | tr '\n' ' '))"
  if [ "$outcome" = "PASS" ]; then
    out PASS "recorded: clean full-history audit, ${FP:0:12}"
    exit 0
  fi
  echo "findings: ${nrows} (counts per rule; locations and values are never printed here)"
  awk -F'\t' '$1=="FINDING"{c[$6]++} END{for (r in c) printf "  rule=%s count=%d\n", r, c[r]}' "$TMPD/scan.out" | LC_ALL=C sort
  out FINDINGS "recorded as FAIL: ${nrows} finding(s); remediate (see repo-visibility-gate rule), then run the audit again"
  exit 1
  ;;
esac
