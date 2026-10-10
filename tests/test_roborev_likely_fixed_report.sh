#!/usr/bin/env bash
# tests/test_roborev_likely_fixed_report.sh -- JohnGavin/llm#1274 option C.
#
# Covers bin/roborev_likely_fixed_report.sh (scheduled, REPORT-ONLY wrapper
# around roborev_revalidate.R) and .claude/scripts/roborev_likely_fixed_summary.sh
# (the one-line surface read by the daily roborev email):
#   (a) a report with the right per-verdict counts and job ids;
#   (b) --apply (or any argument) is refused with exit 2 and revalidate is
#       never invoked, and no normal run ever passes --apply to it;
#   (c) unreadable reviews.db -> exit 3, and the surface says "not run" (it
#       must also REPLACE an earlier good status, not leave it looking fresh);
#   (d) the summary says STALE once the report is older than its window;
#   (e) a failing repo run -> exit 3 / partial, never silently counted;
#       an uncheckable repo (no checkout) is never counted as fixed;
#   (f) inconsistent revalidate counts -> exit 3;
#   (g) optional: the REAL roborev_revalidate.R in report mode (SKIPped when
#       Rscript+jsonlite are unavailable).
# A stub runner stands in for revalidate (seam: ROBOREV_LF_RUNNER).
# Exits 0 if all pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRAPPER="${REPO_ROOT}/bin/roborev_likely_fixed_report.sh"
SUMMARY="${REPO_ROOT}/.claude/scripts/roborev_likely_fixed_summary.sh"

PASS=0; FAIL=0; SKIP=0
T="$(mktemp -d /tmp/test_lf_report_XXXXXX)"
trap 'rm -rf "${T}"' EXIT
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 -- ${2:-}"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1 -- ${2:-}"; SKIP=$((SKIP + 1)); }
check() { # desc, then a command that must succeed
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d" "command failed: $*"; fi
}

if [ ! -x "${WRAPPER}" ] || [ ! -x "${SUMMARY}" ]; then
  fail "wrapper and summary scripts exist and are executable" "${WRAPPER} / ${SUMMARY}"
  echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
  exit 1
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "SKIP ALL: sqlite3 not available"; exit 0
fi

# ── Fixture reviews.db ────────────────────────────────────────────────────────
mkdir -p "${T}/co/alpha" "${T}/co/beta" "${T}/co/gamma"
DB="${T}/reviews.db"
sqlite3 "${DB}" <<SQL
CREATE TABLE repos (id INTEGER PRIMARY KEY, root_path TEXT UNIQUE NOT NULL, name TEXT NOT NULL, identity TEXT);
CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER, git_ref TEXT);
CREATE TABLE reviews (id INTEGER PRIMARY KEY, job_id INTEGER, created_at TEXT, output TEXT, structured_output TEXT, closed INTEGER DEFAULT 0);
INSERT INTO repos VALUES (1,'${T}/co/alpha','alpha',NULL),(2,'${T}/co/beta','beta',NULL),(3,'${T}/co/gamma','gamma',NULL),(4,'${T}/co/missing','nocheckout',NULL);
INSERT INTO review_jobs VALUES (11,1,'aaaa1111'),(12,1,'aaaa2222'),(21,2,'bbbb1111'),(31,3,'cccc1111'),(41,4,'dddd1111');
INSERT INTO reviews VALUES
 (101,11,'2026-10-01',NULL,NULL,0),
 (102,12,'2026-10-01',NULL,NULL,0),
 (201,21,'2026-10-01',NULL,NULL,0),
 (301,31,'2026-10-01',NULL,NULL,0),
 (401,41,'2026-10-01',NULL,NULL,0);
SQL

# ── Stub revalidate runner: logs argv, fabricates a report in the real format ─
STUB="${T}/stub_runner.sh"
cat > "${STUB}" <<'STUBEOF'
#!/bin/bash
# $1 = path of roborev_revalidate.R (ignored); rest = its args
shift
echo "$*" >> "${STUB_LOG}"
repo=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in --repo) repo="$2"; shift 2 ;; --out) out="$2"; shift 2 ;; *) shift ;; esac
done
case "${repo}" in
  alpha)
    cat > "${out}" <<EOF
# roborev Stale-Finding Revalidation Report

## Summary

| Category | Count |
|---|---|
| Open reviews checked | ${STUB_ALPHA_TOTAL:-4} |
| Likely-fixed (candidate to close) | 2 |
| Still-present (action needed) | 1 |
| Ambiguous (needs human review) | 1 |
| Indeterminate (unreadable; never closed) | 0 |

## Likely-Fixed (Candidates to Close)

| review_id | job_id | created_at | git_ref | primary Location | why-classified | suggested command |
|---|---|---|---|---|---|---|
| 101 | 11 | 2026-10-01 | aaaa1111 | a.R:1 | gone | \`roborev close 11\` |
| 102 | 12 | 2026-10-01 | aaaa2222 | a.R:2 | gone | \`roborev close 12\` |

## Still-Present (Action Needed)

| review_id | job_id | primary Location | Problem excerpt |
|---|---|---|---|
| 103 | 13 | a.R:3 | still there |

## Ambiguous (Needs Human Review)

| review_id | job_id | primary Location | reason |
|---|---|---|---|
| 104 | 14 | a.R:4 | no pattern |

## Indeterminate (Unreadable; Never Closed)

_None._
EOF
    echo "Report written to: ${out}" ;;
  beta) echo "Fetched 0 open review(s) matching criteria."; echo "Nothing to revalidate." ;;
  gamma) echo "boom" >&2; exit 1 ;;
  *) echo "unexpected repo ${repo}" >&2; exit 1 ;;
esac
exit 0
STUBEOF
chmod +x "${STUB}"

run_wrapper() { # extra env via caller; prints nothing
  env ROBOREV_DB="${DB}" ROBOREV_LF_DIR="${LF}" ROBOREV_LF_RUNNER="${STUB}" STUB_LOG="${STUB_LOG}" \
    "$@" "${WRAPPER}"
}
status_val() { sed -n "s/^$1=//p" "${LF}/likely_fixed_latest.status" | head -1; }

# ── (b) --apply refused, revalidate never called ─────────────────────────────
LF="${T}/lf_b"; STUB_LOG="${T}/stub_b.log"
rm -rf "${LF}" "${STUB_LOG}"
env ROBOREV_DB="${DB}" ROBOREV_LF_DIR="${LF}" ROBOREV_LF_RUNNER="${STUB}" STUB_LOG="${STUB_LOG}" \
  "${WRAPPER}" --apply >"${T}/b.out" 2>"${T}/b.err"; rc=$?
[ "${rc}" -eq 2 ] && pass "(b) --apply refused with exit 2" || fail "(b) --apply refused with exit 2" "rc=${rc}"
[ ! -e "${STUB_LOG}" ] && pass "(b) revalidate never invoked when --apply is passed" || fail "(b) revalidate never invoked" "stub log exists: $(cat "${STUB_LOG}")"
grep -q "REFUSED" "${T}/b.err" && pass "(b) refusal message printed" || fail "(b) refusal message printed" "$(cat "${T}/b.err")"
env ROBOREV_DB="${DB}" ROBOREV_LF_DIR="${LF}" ROBOREV_LF_RUNNER="${STUB}" STUB_LOG="${STUB_LOG}" \
  "${WRAPPER}" --repo llm >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 2 ] && [ ! -e "${STUB_LOG}" ] && pass "(b) any pass-through argument refused (exit 2, no run)" || fail "(b) any argument refused" "rc=${rc}"
env ROBOREV_DB="${DB}" ROBOREV_LF_DIR="${LF}" ROBOREV_LF_RUNNER="${STUB}" STUB_LOG="${STUB_LOG}" \
  "${WRAPPER}" --apply=1 >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 2 ] && pass "(b) --apply=1 form refused" || fail "(b) --apply=1 form refused" "rc=${rc}"

# ── (a) correct counts and job ids (gamma fails, nocheckout skipped) ─────────
# First exercise the clean path by removing the failing repo.
sqlite3 "${DB}" "UPDATE reviews SET closed=1 WHERE id=301;"
LF="${T}/lf_a"; STUB_LOG="${T}/stub_a.log"; rm -rf "${LF}" "${STUB_LOG}"
run_wrapper env >"${T}/a.out" 2>"${T}/a.err"; rc=$?
[ "${rc}" -eq 0 ] && pass "(a) clean run exits 0" || fail "(a) clean run exits 0" "rc=${rc}: $(cat "${T}/a.err")"
[ "$(status_val likely_fixed)" = "2" ] && [ "$(status_val still_present)" = "1" ] \
  && [ "$(status_val ambiguous)" = "1" ] && [ "$(status_val indeterminate)" = "0" ] \
  && pass "(a) status counts 2/1/1/0" || fail "(a) status counts" "$(cat "${LF}/likely_fixed_latest.status" 2>&1)"
[ "$(status_val repos)" = "2" ] && [ "$(status_val skipped)" = "1" ] \
  && pass "(a) 2 repos checked (alpha, beta), 1 skipped (no checkout)" || fail "(a) repos/skipped" "$(cat "${LF}/likely_fixed_latest.status" 2>&1)"
REPORT="$(sed -n 's/^report=//p' "${LF}/likely_fixed_latest.status")"
if [ -f "${REPORT}" ] && grep -q "likely-fixed / alpha: 11, 12" "${REPORT}" \
   && grep -q "still-present / alpha: 13" "${REPORT}" && grep -q "ambiguous / alpha: 14" "${REPORT}"; then
  pass "(a) dated report lists the job ids per verdict"
else fail "(a) dated report lists job ids" "$(cat "${REPORT}" 2>&1)"; fi
case "${REPORT}" in *"likely_fixed_$(date +%Y-%m-%d).md") pass "(a) report is dated" ;; *) fail "(a) report is dated" "${REPORT}" ;; esac
grep -q "nocheckout: checkout not found" "${REPORT}" && pass "(a) uncheckable repo listed, not counted as fixed" || fail "(a) uncheckable repo listed"
grep -q -- "--apply" "${STUB_LOG}" && fail "(b) no normal run ever passes --apply" "$(cat "${STUB_LOG}")" || pass "(b) no normal run ever passes --apply to revalidate"
grep -q -- "--repo-root ${T}/co/alpha" "${STUB_LOG}" && pass "(a) revalidate given the repo's checkout root" || fail "(a) repo-root passed" "$(cat "${STUB_LOG}")"
line="$(ROBOREV_LF_DIR="${LF}" "${SUMMARY}")"; rc=$?
[ "${rc}" -eq 0 ] && echo "${line}" | grep -q "2 likely-fixed, 1 still-present, 1 ambiguous, 0 indeterminate" \
  && pass "(a) summary line shows the counts (exit 0)" || fail "(a) summary line" "rc=${rc} ${line}"

# ── (d) stale ────────────────────────────────────────────────────────────────
RUN_EPOCH="$(status_val run_epoch)"
line="$(ROBOREV_LF_DIR="${LF}" ROBOREV_LF_NOW_EPOCH=$((RUN_EPOCH + 7 * 86400)) "${SUMMARY}")"; rc=$?
[ "${rc}" -eq 0 ] && pass "(d) 7d old report still fresh for a weekly schedule" || fail "(d) 7d old still fresh" "rc=${rc} ${line}"
line="$(ROBOREV_LF_DIR="${LF}" ROBOREV_LF_NOW_EPOCH=$((RUN_EPOCH + 9 * 86400)) "${SUMMARY}")"; rc=$?
[ "${rc}" -eq 3 ] && echo "${line}" | grep -q "STALE" && ! echo "${line}" | grep -q "likely-fixed," \
  && pass "(d) 9d old report says STALE (exit 3), counts withheld" || fail "(d) stale" "rc=${rc} ${line}"
line="$(ROBOREV_LF_DIR="${T}/nonexistent" "${SUMMARY}")"; rc=$?
[ "${rc}" -eq 3 ] && echo "${line}" | grep -q "not run" \
  && pass "(d) no status file -> 'not run' (exit 3)" || fail "(d) missing status" "rc=${rc} ${line}"

# ── (h) no status file: say WHY, from launchd state (not-loaded vs pending) ──
# ROBOREV_LF_LAUNCHD_PRINT_FILE stands in for `launchctl print`; a path that
# does not exist stands for "not loaded".
cat > "${T}/lp_pending.txt" <<'LPEOF'
gui/501/com.claude.roborev-likely-fixed-report = {
	runs = 0
	last exit code = (never exited)
	event triggers = {
		x => {
			descriptor = {
				"Minute" => 30
				"Hour" => 8
				"Weekday" => 0
			}
		}
	}
}
LPEOF
line="$(ROBOREV_LF_DIR="${T}/nonexistent" ROBOREV_LF_LAUNCHD_PRINT_FILE="${T}/lp_pending.txt" "${SUMMARY}")"; rc=$?
[ "${rc}" -eq 3 ] && echo "${line}" | grep -qE "not run yet \(job loaded, 0 runs so far; first run due Sun [0-9]{4}-[0-9]{2}-[0-9]{2} 08:30\)" \
  && pass "(h) loaded + 0 runs -> 'not run yet', says when the first run is due" || fail "(h) pending" "rc=${rc} ${line}"
echo "${line}" | grep -q "NOT loaded" \
  && fail "(h) a loaded job must not read as not loaded" "${line}" || pass "(h) a loaded job is not reported as not loaded"
line="$(ROBOREV_LF_DIR="${T}/nonexistent" ROBOREV_LF_LAUNCHD_PRINT_FILE="${T}/no_such_print.txt" "${SUMMARY}")"; rc=$?
[ "${rc}" -eq 3 ] && echo "${line}" | grep -q "NOT loaded" \
  && pass "(h) job absent from launchd -> says NOT loaded" || fail "(h) not loaded" "rc=${rc} ${line}"
sed 's/runs = 0/runs = 3/; s/(never exited)/1/' "${T}/lp_pending.txt" > "${T}/lp_ran.txt"
line="$(ROBOREV_LF_DIR="${T}/nonexistent" ROBOREV_LF_LAUNCHD_PRINT_FILE="${T}/lp_ran.txt" "${SUMMARY}")"; rc=$?
[ "${rc}" -eq 3 ] && echo "${line}" | grep -q "ran 3 time(s), last exit 1 -- the wrapper wrote no status file" \
  && pass "(h) loaded + ran but no status file -> flagged as a defect with run count and exit" || fail "(h) ran-no-status" "rc=${rc} ${line}"

# ── (c) unreadable DB -> exit 3, replaces the earlier good status ────────────
env ROBOREV_DB="${T}/does_not_exist.db" ROBOREV_LF_DIR="${LF}" ROBOREV_LF_RUNNER="${STUB}" STUB_LOG="${STUB_LOG}" \
  "${WRAPPER}" >/dev/null 2>"${T}/c.err"; rc=$?
[ "${rc}" -eq 3 ] && pass "(c) missing reviews.db -> exit 3" || fail "(c) missing reviews.db -> exit 3" "rc=${rc}"
line="$(ROBOREV_LF_DIR="${LF}" "${SUMMARY}")"; rc=$?
[ "${rc}" -eq 3 ] && echo "${line}" | grep -q "not run" && ! echo "${line}" | grep -qE "[0-9]+ likely-fixed" \
  && pass "(c) surface says 'not run', not a count, and the earlier good status no longer reads fresh" || fail "(c) surface after failure" "rc=${rc} ${line}"
echo "this is not a database" > "${T}/garbage.db"
env ROBOREV_DB="${T}/garbage.db" ROBOREV_LF_DIR="${LF}" ROBOREV_LF_RUNNER="${STUB}" STUB_LOG="${STUB_LOG}" \
  "${WRAPPER}" >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 3 ] && pass "(c) corrupt reviews.db -> exit 3" || fail "(c) corrupt reviews.db -> exit 3" "rc=${rc}"

# ── (e) a failing repo -> exit 3 / partial ───────────────────────────────────
sqlite3 "${DB}" "UPDATE reviews SET closed=0 WHERE id=301;"
LF="${T}/lf_e"; rm -rf "${LF}"
run_wrapper env >/dev/null 2>"${T}/e.err"; rc=$?
[ "${rc}" -eq 3 ] && [ "$(status_val state)" = "partial" ] && [ "$(status_val failed)" = "1" ] \
  && pass "(e) failing repo run -> exit 3, state=partial" || fail "(e) failing repo" "rc=${rc} $(cat "${LF}/likely_fixed_latest.status" 2>&1)"
line="$(ROBOREV_LF_DIR="${LF}" "${SUMMARY}")"; rc=$?
[ "${rc}" -eq 3 ] && echo "${line}" | grep -q "PARTIAL" && pass "(e) surface flags PARTIAL (exit 3)" || fail "(e) partial surface" "rc=${rc} ${line}"

# ── (f) inconsistent counts -> exit 3 ────────────────────────────────────────
sqlite3 "${DB}" "UPDATE reviews SET closed=1 WHERE id=301;"
LF="${T}/lf_f"; rm -rf "${LF}"
run_wrapper env STUB_ALPHA_TOTAL=9 >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 3 ] && [ "$(status_val state)" = "partial" ] && pass "(f) counts that do not add up -> exit 3 (never trusted)" || fail "(f) inconsistent counts" "rc=${rc}"

# ── (g) real roborev_revalidate.R in report mode (optional) ──────────────────
if command -v Rscript >/dev/null 2>&1 && Rscript -e 'quit(status = !requireNamespace("jsonlite", quietly = TRUE))' >/dev/null 2>&1; then
  mkdir -p "${T}/real/co/r1"
  printf 'xvalue_extra <- 1\n' > "${T}/real/co/r1/kept.R"
  RDB="${T}/real/reviews.db"
  sqlite3 "${RDB}" <<SQL
CREATE TABLE repos (id INTEGER PRIMARY KEY, root_path TEXT UNIQUE NOT NULL, name TEXT NOT NULL, identity TEXT);
CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER, git_ref TEXT);
CREATE TABLE reviews (id INTEGER PRIMARY KEY, job_id INTEGER, created_at TEXT, output TEXT, structured_output TEXT, closed INTEGER DEFAULT 0);
INSERT INTO repos VALUES (1,'${T}/real/co/r1','r1',NULL);
INSERT INTO review_jobs VALUES (7,1,'eeee1111'),(8,1,'eeee2222');
INSERT INTO reviews VALUES
 (70,7,'2026-10-01','**Severity**: High
**Location**: gone_file.R:3
**Problem**: The helper \`vanished_helper\` is wrong',NULL,0),
 (80,8,'2026-10-01','**Severity**: High
**Location**: kept.R:1
**Problem**: Variable \`xvalue_extra\` misused',NULL,0);
SQL
  RUNNER="${T}/real_runner.sh"; printf '#!/bin/bash\nexec Rscript "$@"\n' > "${RUNNER}"; chmod +x "${RUNNER}"
  LF="${T}/lf_g"; rm -rf "${LF}"
  env ROBOREV_DB="${RDB}" ROBOREV_LF_DIR="${LF}" ROBOREV_LF_RUNNER="${RUNNER}" "${WRAPPER}" >"${T}/g.out" 2>"${T}/g.err"; rc=$?
  if [ "${rc}" -eq 0 ] && [ "$(status_val likely_fixed)" = "1" ] && [ "$(status_val still_present)" = "1" ] && grep -q "likely-fixed / r1: 7" "${LF}/likely_fixed_$(date +%Y-%m-%d).md"; then
    pass "(g) real revalidate in report mode: job 7 likely-fixed (file gone), nothing closed"
  else fail "(g) real revalidate" "rc=${rc} $(cat "${T}/g.err" "${LF}/likely_fixed_latest.status" 2>&1)"; fi
  [ "$(sqlite3 "${RDB}" 'SELECT COUNT(*) FROM reviews WHERE closed=1')" = "0" ] && pass "(g) no review was closed in the DB" || fail "(g) no review closed"
else
  skip "(g) real revalidate run" "Rscript with jsonlite not available"
fi

echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "${FAIL}" -eq 0 ]
