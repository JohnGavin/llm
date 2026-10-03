#!/bin/bash
# roborev_likely_fixed_report.sh -- scheduled, REPORT-ONLY "likely fixed" report.
#
# JohnGavin/llm#1274 option C. Runs .claude/scripts/roborev_revalidate.R in its
# dry-run mode once per repo that has open reviews, and writes ONE dated report
# with counts per verdict (likely-fixed / still-present / ambiguous /
# indeterminate) and the job ids behind them. It never closes anything.
#
# "Never --apply" is STRUCTURAL, not a convention:
#   * this wrapper takes no pass-through arguments; --apply (or any other
#     argument) is refused with exit 2 before anything runs;
#   * the revalidate argv is built from a fixed whitelist (--repo, --repo-root,
#     --min-severity, --out) and run_revalidate() aborts if "--apply" ever
#     appears in it;
#   * tests/test_roborev_likely_fixed_report.sh proves both with a stub runner.
# Closing a likely-fixed review stays a separate, manual step.
#
# Output (dir: $ROBOREV_LF_DIR, default ~/.claude/logs/roborev_revalidate):
#   likely_fixed_<YYYY-MM-DD>.md     the dated report
#   likely_fixed_latest.status       key=value state read by
#                                    .claude/scripts/roborev_likely_fixed_summary.sh
#                                    (the one-line surface in the daily roborev email)
#   lf_detail_<repo>_<date>.md       each repo's full roborev_revalidate.R report
#
# Exit codes (exit-code-conventions / checks-must-distinguish-unknown):
#   0  report written (counts may be anything, including all zero)
#   1  could not write the report/status (output dir unwritable)
#   2  usage error -- including any attempt to pass --apply
#   3  INDETERMINATE: revalidate could not run (sqlite3/R missing, reviews.db
#      unreadable, or a repo's run failed / produced an unparseable report).
#      A status file recording "indeterminate" is still written so the surface
#      says "not run", never "0 likely fixed".
#
# Env (all optional):
#   ROBOREV_DB              reviews.db path (default ~/.roborev/reviews.db)
#   ROBOREV_LF_DIR          output dir
#   ROBOREV_LF_MIN_SEVERITY default High
#   ROBOREV_LF_RUNNER       test seam: command run as `$RUNNER <revalidate.R> <args>`
#                           instead of Rscript-in-nix-shell
#
# Scheduling: .claude/launchd/com.claude.roborev-likely-fixed-report.plist
# (weekly; NOT loaded by this repo -- loading is a manual owner step).

set -uo pipefail

export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REVALIDATE_R="${REPO_ROOT}/.claude/scripts/roborev_revalidate.R"

# ── Arguments: none accepted ─────────────────────────────────────────────────
if [ "$#" -gt 0 ]; then
  for a in "$@"; do
    case "$a" in
      --apply|--apply=*)
        echo "roborev_likely_fixed_report: REFUSED: --apply is never accepted; this report is read-only (close reviews manually via roborev_revalidate.R)" >&2
        exit 2 ;;
    esac
  done
  echo "usage: roborev_likely_fixed_report.sh   (takes no arguments; configure via ROBOREV_LF_* env)" >&2
  exit 2
fi

DB="${ROBOREV_DB:-${HOME}/.roborev/reviews.db}"
LF_DIR="${ROBOREV_LF_DIR:-${HOME}/.claude/logs/roborev_revalidate}"
MIN_SEV="${ROBOREV_LF_MIN_SEVERITY:-High}"
export ROBOREV_DB="${DB}"

RUN_EPOCH="$(date +%s)"
RUN_DATE="$(date +%Y-%m-%d)"
RUN_TS="$(date +%Y-%m-%dT%H:%M:%S)"
STATUS_FILE="${LF_DIR}/likely_fixed_latest.status"
REPORT_FILE="${LF_DIR}/likely_fixed_${RUN_DATE}.md"

if ! mkdir -p "${LF_DIR}" 2>/dev/null || [ ! -w "${LF_DIR}" ]; then
  echo "roborev_likely_fixed_report: cannot write to ${LF_DIR}" >&2
  exit 1
fi

# Record a state that is NOT a result, then exit 3.
indeterminate() {
  local reason="$1"
  {
    echo "state=indeterminate"
    echo "run_epoch=${RUN_EPOCH}"
    echo "run_date=${RUN_DATE}"
    echo "reason=$(printf '%s' "${reason}" | tr '\n\t' '  ')"
  } > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "${STATUS_FILE}"
  echo "roborev_likely_fixed_report: INDETERMINATE: ${reason}" >&2
  exit 3
}

# ── Preconditions: observable without running anything heavy ─────────────────
command -v sqlite3 >/dev/null 2>&1 || indeterminate "sqlite3 not on PATH"
[ -f "${DB}" ] || indeterminate "reviews.db not found: ${DB}"
[ -r "${DB}" ] || indeterminate "reviews.db not readable: ${DB}"

REPOS_TSV="$(mktemp -t lf_repos.XXXXXX)"
WORK="$(mktemp -d -t lf_work.XXXXXX)"
trap 'rm -rf "${REPOS_TSV}" "${WORK}"' EXIT

if ! sqlite3 -readonly -separator $'\t' "${DB}" \
  "SELECT rep.name, MIN(rep.root_path)
     FROM reviews r
     JOIN review_jobs rj ON r.job_id = rj.id
     JOIN repos rep      ON rj.repo_id = rep.id
    WHERE r.closed = 0
    GROUP BY rep.name
    ORDER BY rep.name;" > "${REPOS_TSV}" 2>"${WORK}/sqlite.err"; then
  indeterminate "reviews.db unreadable: $(head -c 200 "${WORK}/sqlite.err")"
fi

# Nix target for R (GC-rooted drv preferred, as in roborev_daily_cron.sh).
NIX_TARGET="${HOME}/.claude/nix-gcroots/llm-shell.drv"
[ -e "${NIX_TARGET}" ] || NIX_TARGET="${REPO_ROOT}/default.nix"

# The ONLY place revalidate is invoked. Aborts if --apply is ever present.
run_revalidate() {
  local a
  for a in "$@"; do
    case "$a" in
      --apply*) echo "BUG: --apply reached run_revalidate" >&2; return 99 ;;
    esac
  done
  if [ -n "${ROBOREV_LF_RUNNER:-}" ]; then
    "${ROBOREV_LF_RUNNER}" "${REVALIDATE_R}" "$@"
  elif [ -n "${IN_NIX_SHELL:-}" ] && command -v Rscript >/dev/null 2>&1; then
    Rscript "${REVALIDATE_R}" "$@"
  elif command -v nix-shell >/dev/null 2>&1; then
    nix-shell "${NIX_TARGET}" --run "$(printf '%q ' Rscript "${REVALIDATE_R}" "$@")"
  else
    echo "neither a nix shell nor nix-shell is available" >&2
    return 127
  fi
}

# Pull a count out of a revalidate report's summary table.
cnt() { awk -F'|' -v k="$2" 'index($2,k){gsub(/ /,"",$3); print $3; exit}' "$1"; }

T_TOTAL=0; T_FIXED=0; T_PRESENT=0; T_AMBIG=0; T_INDET=0
N_REPOS=0; N_SKIPPED=0; N_FAILED=0
ROWS=""; IDS=""; SKIPPED_LIST=""; FAILED_LIST=""

while IFS=$'\t' read -r repo root; do
  [ -n "${repo}" ] || continue
  if [ ! -d "${root}" ]; then
    # No checkout to compare against: revalidate would call every finding
    # likely-fixed. Never run it; record as not checkable.
    N_SKIPPED=$((N_SKIPPED + 1))
    SKIPPED_LIST="${SKIPPED_LIST}- ${repo}: checkout not found\n"
    continue
  fi
  safe="$(printf '%s' "${repo}" | tr -c 'A-Za-z0-9._-' '_')"
  detail="${LF_DIR}/lf_detail_${safe}_${RUN_DATE}.md"
  rm -f "${detail}"
  out="${WORK}/${safe}.out"
  run_revalidate --repo "${repo}" --repo-root "${root}" \
    --min-severity "${MIN_SEV}" --out "${detail}" > "${out}" 2>&1
  rc=$?
  if [ "${rc}" -ne 0 ]; then
    N_FAILED=$((N_FAILED + 1))
    FAILED_LIST="${FAILED_LIST}- ${repo}: revalidate exited ${rc}\n"
    continue
  fi
  N_REPOS=$((N_REPOS + 1))
  if [ ! -f "${detail}" ]; then
    if grep -q "Nothing to revalidate" "${out}"; then
      ROWS="${ROWS}| ${repo} | 0 | 0 | 0 | 0 | 0 |\n"
      continue
    fi
    N_FAILED=$((N_FAILED + 1)); N_REPOS=$((N_REPOS - 1))
    FAILED_LIST="${FAILED_LIST}- ${repo}: no report produced\n"
    continue
  fi
  c_tot="$(cnt "${detail}" "Open reviews checked")"
  c_fix="$(cnt "${detail}" "Likely-fixed (candidate")"
  c_pre="$(cnt "${detail}" "Still-present (action")"
  c_amb="$(cnt "${detail}" "Ambiguous (needs")"
  c_ind="$(cnt "${detail}" "Indeterminate (unreadable")"
  ids="$(awk '
    /^## Likely-Fixed/   {s="likely-fixed";   next}
    /^## Still-Present/  {s="still-present";  next}
    /^## Ambiguous/      {s="ambiguous";      next}
    /^## Indeterminate/  {s="indeterminate";  next}
    /^## /               {s=""}
    s != "" && /^\| [0-9]+ \|/ { split($0,a,"|"); gsub(/ /,"",a[3]); print s "\t" a[3] }' "${detail}")"
  ok=1
  for v in "${c_tot}" "${c_fix}" "${c_pre}" "${c_amb}" "${c_ind}"; do
    case "${v}" in ''|*[!0-9]*) ok=0 ;; esac
  done
  if [ "${ok}" -eq 1 ]; then
    [ $((c_fix + c_pre + c_amb + c_ind)) -eq "${c_tot}" ] || ok=0
    n_ids="$(printf '%s' "${ids}" | grep -c . || true)"
    [ "${n_ids:-0}" -eq "${c_tot}" ] || ok=0
  fi
  if [ "${ok}" -ne 1 ]; then
    N_FAILED=$((N_FAILED + 1)); N_REPOS=$((N_REPOS - 1))
    FAILED_LIST="${FAILED_LIST}- ${repo}: report unparseable or counts inconsistent\n"
    continue
  fi
  T_TOTAL=$((T_TOTAL + c_tot)); T_FIXED=$((T_FIXED + c_fix)); T_PRESENT=$((T_PRESENT + c_pre))
  T_AMBIG=$((T_AMBIG + c_amb)); T_INDET=$((T_INDET + c_ind))
  ROWS="${ROWS}| ${repo} | ${c_tot} | ${c_fix} | ${c_pre} | ${c_amb} | ${c_ind} |\n"
  for v in likely-fixed still-present ambiguous indeterminate; do
    list="$(printf '%s\n' "${ids}" | awk -F'\t' -v v="$v" '$1==v{printf "%s%s", (n++?", ":""), $2}')"
    [ -n "${list}" ] && IDS="${IDS}${v}|${repo}|${list}\n"
  done
done < "${REPOS_TSV}"

# ── Report ────────────────────────────────────────────────────────────────────
{
  echo "# roborev \"likely fixed\" report (REPORT-ONLY)"
  echo
  echo "**Run:** ${RUN_TS}  |  **Min-severity:** ${MIN_SEV}  |  **Mode:** report-only (never --apply; nothing is closed)"
  echo
  echo "Verdicts come from roborev_revalidate.R's location heuristic against each repo's current working tree."
  echo "Closing a likely-fixed review is a separate manual step."
  echo
  echo "## Totals"
  echo
  echo "| Verdict | Count |"
  echo "|---|---|"
  echo "| Open reviews checked | ${T_TOTAL} |"
  echo "| Likely-fixed | ${T_FIXED} |"
  echo "| Still-present | ${T_PRESENT} |"
  echo "| Ambiguous | ${T_AMBIG} |"
  echo "| Indeterminate | ${T_INDET} |"
  echo "| Repos checked / not checkable / failed | ${N_REPOS} / ${N_SKIPPED} / ${N_FAILED} |"
  echo
  echo "## Per repo"
  echo
  echo "| repo | checked | likely-fixed | still-present | ambiguous | indeterminate |"
  echo "|---|---|---|---|---|---|"
  [ -n "${ROWS}" ] && printf '%b' "${ROWS}"
  echo
  echo "## Job ids"
  echo
  if [ -n "${IDS}" ]; then
    printf '%b' "${IDS}" | awk -F'|' '{print "- " $1 " / " $2 ": " $3}'
  else
    echo "_No open reviews at or above ${MIN_SEV}._"
  fi
  echo
  if [ -n "${SKIPPED_LIST}" ]; then
    echo "## Not checkable (no checkout; NOT counted as fixed)"
    echo
    printf '%b' "${SKIPPED_LIST}"
    echo
  fi
  if [ -n "${FAILED_LIST}" ]; then
    echo "## Failed (INDETERMINATE; counts above exclude these)"
    echo
    printf '%b' "${FAILED_LIST}"
    echo
  fi
  echo "Per-repo detail: ${LF_DIR}/lf_detail_*_${RUN_DATE}.md"
} > "${REPORT_FILE}"

if [ "${N_FAILED}" -gt 0 ]; then
  STATE="partial"
else
  STATE="ok"
fi
{
  echo "state=${STATE}"
  echo "run_epoch=${RUN_EPOCH}"
  echo "run_date=${RUN_DATE}"
  echo "likely_fixed=${T_FIXED}"
  echo "still_present=${T_PRESENT}"
  echo "ambiguous=${T_AMBIG}"
  echo "indeterminate=${T_INDET}"
  echo "repos=${N_REPOS}"
  echo "skipped=${N_SKIPPED}"
  echo "failed=${N_FAILED}"
  echo "report=${REPORT_FILE}"
} > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "${STATUS_FILE}"

echo "roborev_likely_fixed_report: ${STATE}: likely-fixed=${T_FIXED} still-present=${T_PRESENT} ambiguous=${T_AMBIG} indeterminate=${T_INDET} repos=${N_REPOS} skipped=${N_SKIPPED} failed=${N_FAILED}"
echo "report: ${REPORT_FILE}"

if [ "${N_FAILED}" -gt 0 ]; then
  echo "roborev_likely_fixed_report: INDETERMINATE for ${N_FAILED} repo(s); see report" >&2
  exit 3
fi
exit 0
