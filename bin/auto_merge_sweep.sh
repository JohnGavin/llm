#!/usr/bin/env bash
# bin/auto_merge_sweep.sh -- Auto-Merge Policy eligibility evaluator (llm#1471).
#
# REPORT-ONLY BY DEFAULT. Without --apply it reads GitHub and prints a verdict
# per PR and mutates nothing (tests/test_auto_merge_sweep.sh proves this with a
# stub gh call log). With --apply it merges each ELIGIBLE PR, see below.
#
# Usage:
#   bin/auto_merge_sweep.sh [--repo OWNER/NAME] [--apply] [--max N] [PR...]
# With no PR numbers, every open non-draft PR is evaluated.
#
# --apply, per ELIGIBLE PR, in order:
#   a. re-evaluate immediately before acting; if the head commit moved since the
#      first evaluation, skip (head-changed);
#   b. add the label auto-merged (it must already exist, else the PR is
#      INDETERMINATE label-missing and nothing is created or merged);
#   c. squash-merge with --match-head-commit <sha> so GitHub refuses if the head
#      moved. No admin override, no auto-merge queue, branch is kept;
#   d. at most --max N merge attempts per run (default 3);
#   e. if the merge fails, remove the label again and report it;
#   f. one line per action goes to $AUTO_MERGE_LOG (default
#      ~/.claude/logs/auto_merge_sweep.log): UTC time, PR, short sha, action,
#      reason. Never titles, bodies or secrets. A log write failure is reported
#      on stderr and does not abort.
#
# Output: one line per PR, "<pr><TAB><verdict><TAB><reason>", then
#   prs=N eligible=a not_eligible=b indeterminate=c merged=m failed=f
# With --apply each action also prints "<pr><TAB>ACTION<TAB><action> <reason>".
# Paths are printed; file contents and secrets never are.
#
# Exit codes (.claude/rules/exit-code-conventions.md):
#   0  ran; verdicts printed (even when none is eligible)
#   1  --apply only: at least one attempted merge FAILED
#   2  usage error
#   3  could not run at all (gh missing or not authenticated, PR list failed)
#
# Verdicts: ELIGIBLE / NOT-ELIGIBLE / INDETERMINATE. A PR that cannot be
# evaluated is INDETERMINATE, never ELIGIBLE and never silently NOT-ELIGIBLE
# (checks-must-distinguish-unknown). ELIGIBLE requires ALL of:
#   1. Author association OWNER (anyone else: untrusted-author), PR open, not draft.
#   2. Toggle: the "**Auto-Merge Policy:**" line in the repo's AGENTS.md says ON.
#   3. No hold label (HOLD_LABELS below).
#   4. mergeStateStatus is not DIRTY (a conflicting PR has no PR checks).
#   5. At least one check, and every check concluded SUCCESS.
#   6. The diff touches no path in .claude/state/auto_merge_exclusions.txt and
#      no script referenced from .claude/launchd/*.plist or
#      bin/launchd-recorders/* (reason scheduled-script, matched by basename).
#   7. bin/roborev_merge_gate.sh exits 0 (1 gate-block; 3 gate-indeterminate).
# The first definite NOT-ELIGIBLE reason wins over an INDETERMINATE one.
#
# Limits (stated, not hidden): AGENTS.md, the exclusion file and the scheduled
# set are read from the checkout this script lives in (override with
# AUTO_MERGE_REPO_DIR), so run it from an up-to-date base checkout. The file
# list comes from the paginated REST files endpoint; renames contribute both
# the new and the previous path. A failed fetch (files-api-failed) or a PR
# with more files than were returned (files-truncated) is INDETERMINATE.
#
# mergeStateStatus handling (from gh pr view):
#   UNKNOWN or empty  GitHub computes it lazily. The PR view is retried (3 views
#                     in all, AUTO_MERGE_RETRY_SLEEP seconds apart, default 3);
#                     still unknown -> INDETERMINATE merge-state-unknown. A
#                     failed gh call is never retried (INDETERMINATE view-failed).
#   DIRTY             NOT-ELIGIBLE merge-conflict
#   DRAFT             NOT-ELIGIBLE draft
#   BLOCKED           NOT-ELIGIBLE blocked-by-rules (a required check or review
#                     is missing; gh pr merge would be refused)
#   UNSTABLE          NOT-ELIGIBLE unstable (a non-required check failed)
#   BEHIND, CLEAN, HAS_HOOKS   no objection from this field
#
# Env overrides (used by the tests): AUTO_MERGE_REPO_DIR, AUTO_MERGE_GATE,
# AUTO_MERGE_EXCLUSIONS, AUTO_MERGE_LOG, AUTO_MERGE_RETRY_SLEEP.

set -u
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

# Labels that always block automatic merge (one per word, space separated).
HOLD_LABELS="needs-owner do-not-merge hold"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${AUTO_MERGE_REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
GATE="${AUTO_MERGE_GATE:-$REPO_DIR/bin/roborev_merge_gate.sh}"
EXCL_FILE="${AUTO_MERGE_EXCLUSIONS:-$REPO_DIR/.claude/state/auto_merge_exclusions.txt}"

LOG="${AUTO_MERGE_LOG:-$HOME/.claude/logs/auto_merge_sweep.log}"
MERGE_LABEL="auto-merged"
VIEW_TRIES=3
RETRY_SLEEP="${AUTO_MERGE_RETRY_SLEEP:-3}"
case "$RETRY_SLEEP" in ""|*[!0-9]*) RETRY_SLEEP=3 ;; esac

usage() {
  echo "usage: auto_merge_sweep.sh [--repo OWNER/NAME] [--apply] [--max N] [PR...]" >&2
}

REPO=""
PRS=""
APPLY=0
MAXM=3
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      if [ $# -lt 2 ]; then usage; exit 2; fi
      REPO="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --max)
      if [ $# -lt 2 ]; then usage; exit 2; fi
      case "$2" in
        ""|*[!0-9]*|0) echo "USAGE-ERROR: --max needs a positive integer" >&2; usage; exit 2 ;;
      esac
      MAXM="$2"; shift 2 ;;
    -h|--help) usage; exit 2 ;;
    *[!0-9]*|"") echo "USAGE-ERROR: not a PR number or known flag: $1" >&2; usage; exit 2 ;;
    *) PRS="$PRS $1"; shift ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "INDETERMINATE: gh is not on PATH; cannot evaluate any PR" >&2
  exit 3
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "INDETERMINATE: gh is not authenticated; cannot evaluate any PR" >&2
  exit 3
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "INDETERMINATE: python3 is not on PATH; cannot parse gh output" >&2
  exit 3
fi
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"
  if [ -z "$REPO" ]; then
    echo "INDETERMINATE: could not resolve the repo; pass --repo OWNER/NAME" >&2
    exit 3
  fi
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/auto_merge_sweep.XXXXXX")" || { echo "INDETERMINATE: mktemp failed" >&2; exit 3; }
trap 'rm -rf "$TMP"' EXIT

# ---- JSON field extraction (python3 reads the file named in argv) -----------
parse_view() {
  python3 - "$1" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print("STATE\t%s" % d.get("state", ""))
print("DRAFT\t%s" % ("true" if d.get("isDraft") else "false"))
print("MERGE\t%s" % d.get("mergeStateStatus", ""))
print("HEAD\t%s" % d.get("headRefOid", ""))
print("CHANGED\t%s" % d.get("changedFiles", ""))
for l in d.get("labels") or []:
    print("LABEL\t%s" % l.get("name", ""))
rollup = d.get("statusCheckRollup") or []
pending = bad = 0
for c in rollup:
    if c.get("__typename") == "StatusContext":
        s = c.get("state", "")
        ok = (s == "SUCCESS")
        pend = s in ("PENDING", "EXPECTED")
    else:
        ok = (c.get("status") == "COMPLETED" and c.get("conclusion") == "SUCCESS")
        pend = (c.get("status") != "COMPLETED")
    if not ok:
        if pend:
            pending += 1
        else:
            bad += 1
print("CHECKS\t%d\t%d\t%d" % (len(rollup), pending, bad))
PYEOF
}

# ---- Toggle -----------------------------------------------------------------
TOGGLE="unreadable"
if [ -r "$REPO_DIR/AGENTS.md" ]; then
  tline="$(grep -m1 '^\*\*Auto-Merge Policy:\*\*' "$REPO_DIR/AGENTS.md" 2>/dev/null)"
  tword="$(printf '%s\n' "$tline" | sed -E 's/^\*\*Auto-Merge Policy:\*\*[[:space:]]*([A-Za-z]+).*/\1/')"
  case "$tword" in
    ON) TOGGLE="on" ;;
    OFF) TOGGLE="off" ;;
    *) TOGGLE="unparsable" ;;
  esac
fi

# ---- Exclusion data (fail closed) ---------------------------------------------
EXCL_ERR=""
PATFILE="$TMP/patterns"
: > "$PATFILE"
if [ ! -r "$EXCL_FILE" ]; then
  EXCL_ERR="exclusions-unreadable"
else
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$EXCL_FILE" > "$PATFILE" 2>/dev/null
  if [ ! -s "$PATFILE" ]; then
    EXCL_ERR="exclusions-empty"
  else
    grep -E -f "$PATFILE" /dev/null >/dev/null 2>&1
    if [ $? -eq 2 ]; then EXCL_ERR="exclusions-invalid-regex"; fi
  fi
fi

# ---- Scheduled-script set, derived from launchd plists and recorders ----------
SCHEDFILE="$TMP/scheduled"
: > "$SCHEDFILE"
SCHED_ERR=""
sched_srcs=""
for f in "$REPO_DIR"/.claude/launchd/*.plist "$REPO_DIR"/bin/launchd-recorders/*; do
  if [ -f "$f" ]; then sched_srcs="$sched_srcs
$f"; fi
done
if [ -z "$sched_srcs" ]; then
  SCHED_ERR="scheduled-set-unreadable"
else
  printf '%s\n' "$sched_srcs" | while IFS= read -r f; do
    if [ -n "$f" ]; then
      grep -o -E '[A-Za-z0-9_.-]+\.(sh|R|py)' "$f" 2>/dev/null
    fi
  done | sort -u > "$SCHEDFILE"
  if [ ! -s "$SCHEDFILE" ]; then SCHED_ERR="scheduled-set-empty"; fi
fi

# ---- Per-PR evaluation --------------------------------------------------------
# Sets VERDICT and REASON. NOT-ELIGIBLE returns at once; INDETERMINATE is
# remembered (first one wins) and evaluation continues so a definite
# NOT-ELIGIBLE can still override it.
VERDICT=""
REASON=""
IND=""
HEADSHA=""
note_ind() { if [ -z "$IND" ]; then IND="$1"; fi; }
not_elig() { VERDICT="NOT-ELIGIBLE"; REASON="$1"; }

evaluate() {
  local n="$1" assoc view fields
  VERDICT=""; REASON=""; IND=""; HEADSHA=""

  assoc="$(gh api "repos/$REPO/pulls/$n" --jq .author_association 2>/dev/null)"
  if [ -z "$assoc" ]; then VERDICT="INDETERMINATE"; REASON="author-lookup-failed"; return; fi
  if [ "$assoc" != "OWNER" ]; then not_elig "untrusted-author"; return; fi

  view="$TMP/view_$n.json"
  fields="$TMP/fields_$n"
  # mergeStateStatus is computed lazily by GitHub: UNKNOWN/empty is transient.
  # Up to VIEW_TRIES views, pausing between them; a gh or parse failure is
  # never retried or hidden (it stays INDETERMINATE at once).
  local state draft merge changed try=1
  while :; do
    if ! gh pr view "$n" --repo "$REPO" --json number,state,isDraft,labels,mergeStateStatus,statusCheckRollup,changedFiles,headRefOid > "$view" 2>/dev/null; then
      VERDICT="INDETERMINATE"; REASON="view-failed"; return
    fi
    if ! parse_view "$view" > "$fields" 2>/dev/null; then
      VERDICT="INDETERMINATE"; REASON="view-unparsable"; return
    fi
    merge="$(awk -F'\t' '$1=="MERGE"{print $2}' "$fields")"
    case "$merge" in UNKNOWN|"") ;; *) break ;; esac
    if [ "$try" -ge "$VIEW_TRIES" ]; then break; fi
    try=$((try + 1))
    sleep "$RETRY_SLEEP"
  done

  state="$(awk -F'\t' '$1=="STATE"{print $2}' "$fields")"
  draft="$(awk -F'\t' '$1=="DRAFT"{print $2}' "$fields")"
  changed="$(awk -F'\t' '$1=="CHANGED"{print $2}' "$fields")"

  HEADSHA="$(awk -F'\t' '$1=="HEAD"{print $2}' "$fields")"
  if [ "$state" != "OPEN" ]; then not_elig "not-open"; return; fi
  if [ "$draft" = "true" ]; then not_elig "draft"; return; fi

  case "$TOGGLE" in
    off) not_elig "toggle-off"; return ;;
    on) ;;
    *) note_ind "toggle-$TOGGLE" ;;
  esac

  local l h
  for l in $(awk -F'\t' '$1=="LABEL"{print $2}' "$fields"); do
    for h in $HOLD_LABELS; do
      if [ "$l" = "$h" ]; then not_elig "hold-label:$h"; return; fi
    done
  done

  case "$merge" in
    DIRTY) not_elig "merge-conflict"; return ;;
    DRAFT) not_elig "draft"; return ;;
    UNKNOWN|"") note_ind "merge-state-unknown" ;;
  esac

  local total pending bad
  total="$(awk -F'\t' '$1=="CHECKS"{print $2}' "$fields")"
  pending="$(awk -F'\t' '$1=="CHECKS"{print $3}' "$fields")"
  bad="$(awk -F'\t' '$1=="CHECKS"{print $4}' "$fields")"
  if [ "${total:-0}" -eq 0 ]; then not_elig "no-checks"; return; fi
  if [ "${bad:-0}" -gt 0 ]; then not_elig "checks-not-success"; return; fi
  if [ "${pending:-0}" -gt 0 ]; then not_elig "checks-pending"; return; fi
  # Rulesets: BLOCKED = a required check or review is missing (gh pr merge
  # would be refused even though every check that ran passed); UNSTABLE = a
  # non-required check failed.
  case "$merge" in
    BLOCKED) not_elig "blocked-by-rules"; return ;;
    UNSTABLE) not_elig "unstable"; return ;;
  esac

  # Diff paths.
  if [ -n "$EXCL_ERR" ]; then note_ind "$EXCL_ERR"; fi
  if [ -n "$SCHED_ERR" ]; then note_ind "$SCHED_ERR"; fi
  # File list from the REST endpoint: a rename contributes BOTH its new path
  # (filename) and its old path (previous_filename); both are tested below.
  local ff="$TMP/files_$n" fr="$TMP/filesraw_$n" hit rc nlisted
  if ! gh api "repos/$REPO/pulls/$n/files" --paginate --jq '.[] | [.filename, (.previous_filename // "")] | @tsv' > "$fr" 2>/dev/null; then
    note_ind "files-api-failed"
    : > "$ff"
  else
    awk -F'\t' 'NF>=1 && $1!=""{print $1} NF>=2 && $2!=""{print $2}' "$fr" > "$ff"
    nlisted="$(awk -F'\t' 'NF>=1 && $1!=""{c++} END{print c+0}' "$fr")"
    if [ -n "$changed" ] && [ "$changed" -gt "$nlisted" ]; then note_ind "files-truncated"; fi
    if [ ! -s "$ff" ]; then note_ind "no-files-listed"; fi
  fi
  if [ -z "$EXCL_ERR" ] && [ -s "$ff" ]; then
    hit="$(grep -E -f "$PATFILE" "$ff" | head -1)"
    if [ -n "$hit" ]; then not_elig "excluded-path:$hit"; return; fi
  fi
  if [ -z "$SCHED_ERR" ] && [ -s "$ff" ]; then
    local bf="$TMP/base_$n"
    awk -F/ '{print $NF}' "$ff" > "$bf"
    hit="$(grep -F -x -f "$SCHEDFILE" "$bf" | head -1)"
    if [ -n "$hit" ]; then not_elig "scheduled-script:$hit"; return; fi
  fi

  # Merge gate (last: it is the slowest). Its 1 is a definite block.
  if [ ! -r "$GATE" ]; then
    note_ind "gate-unavailable"
  else
    bash "$GATE" --repo "$REPO" "$n" >/dev/null 2>&1
    rc=$?
    case "$rc" in
      0) ;;
      1) not_elig "gate-block"; return ;;
      3) note_ind "gate-indeterminate" ;;
      *) note_ind "gate-rc-$rc" ;;
    esac
  fi

  if [ -z "$HEADSHA" ]; then note_ind "head-sha-missing"; fi
  if [ -n "$IND" ]; then VERDICT="INDETERMINATE"; REASON="$IND"; return; fi
  VERDICT="ELIGIBLE"; REASON="all-conditions-met"
}

# ---- PR list ------------------------------------------------------------------
if [ -z "$PRS" ]; then
  if ! gh pr list --repo "$REPO" --state open --limit 200 --json number,isDraft > "$TMP/list.json" 2>/dev/null; then
    echo "INDETERMINATE: could not list open PRs for $REPO" >&2
    exit 3
  fi
  PRS="$(python3 - "$TMP/list.json" <<'PYEOF'
import json, sys
for p in json.load(open(sys.argv[1])):
    if not p.get("isDraft"):
        print(p["number"])
PYEOF
)"
  if [ $? -ne 0 ]; then
    echo "INDETERMINATE: could not parse the open PR list" >&2
    exit 3
  fi
fi

# ---- Apply helpers --------------------------------------------------------------
LOGWARNED=0
log_action() {  # pr sha action reason
  local d
  d="$(dirname "$LOG")"
  if mkdir -p "$d" 2>/dev/null && printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(printf '%s' "$2" | cut -c1-7)" "$3" "$4" >> "$LOG" 2>/dev/null; then
    :
  else
    echo "WARNING: could not write the action log $LOG" >&2
  fi
  printf '%s\tACTION\t%s %s\n' "$1" "$3" "$4"
}

LABEL_STATE=""   # "", "ok" or "missing" (checked once, only under --apply)
label_check() {
  if [ -z "$LABEL_STATE" ]; then
    if gh label list --repo "$REPO" --search "$MERGE_LABEL" --limit 100 --json name --jq '.[].name' 2>/dev/null | grep -qx "$MERGE_LABEL"; then
      LABEL_STATE="ok"
    else
      LABEL_STATE="missing"
    fi
  fi
}

ATTEMPTS=0; merged=0; failed=0
apply_one() {  # pr  (first evaluation was ELIGIBLE; HEADSHA is the evaluated head)
  local n="$1" sha1="$HEADSHA"
  if [ "$ATTEMPTS" -ge "$MAXM" ]; then log_action "$n" "$sha1" skipped "cap-reached"; return; fi
  label_check
  if [ "$LABEL_STATE" != "ok" ]; then
    VERDICT="INDETERMINATE"; REASON="label-missing"
    log_action "$n" "$sha1" skipped "label-missing"; return
  fi
  evaluate "$n"
  if [ "$VERDICT" != "ELIGIBLE" ]; then
    log_action "$n" "$sha1" skipped "reevaluated-$VERDICT-$REASON"; return
  fi
  if [ "$HEADSHA" != "$sha1" ]; then log_action "$n" "$sha1" skipped "head-changed"; return; fi
  if ! gh pr edit "$n" --repo "$REPO" --add-label "$MERGE_LABEL" >/dev/null 2>&1; then
    log_action "$n" "$sha1" skipped "label-add-failed"; return
  fi
  log_action "$n" "$sha1" labelled "ok"
  ATTEMPTS=$((ATTEMPTS + 1))
  if gh pr merge "$n" --repo "$REPO" --squash --match-head-commit "$sha1" >/dev/null 2>&1; then
    merged=$((merged + 1))
    log_action "$n" "$sha1" merged "squash"
  else
    failed=$((failed + 1))
    log_action "$n" "$sha1" merge-failed "gh-merge-nonzero"
    if gh pr edit "$n" --repo "$REPO" --remove-label "$MERGE_LABEL" >/dev/null 2>&1; then
      log_action "$n" "$sha1" unlabelled "after-merge-failure"
    else
      echo "WARNING: PR $n merge failed AND the $MERGE_LABEL label could not be removed" >&2
      log_action "$n" "$sha1" merge-failed "unlabel-failed"
    fi
  fi
}

total=0; el=0; ne=0; ind=0
for n in $PRS; do
  evaluate "$n"
  if [ "$VERDICT" = "ELIGIBLE" ]; then el=$((el + 1)); fi
  first_verdict="$VERDICT"; first_reason="$REASON"
  if [ "$APPLY" -eq 1 ] && [ "$first_verdict" = "ELIGIBLE" ]; then
    printf '%s\t%s\t%s\n' "$n" "$first_verdict" "$first_reason"
    apply_one "$n"
    # a label-missing downgrade is reported in the counts
    if [ "$VERDICT" = "INDETERMINATE" ] && [ "$REASON" = "label-missing" ]; then
      el=$((el - 1)); ind=$((ind + 1))
    fi
    total=$((total + 1))
    continue
  fi
  printf '%s\t%s\t%s\n' "$n" "$VERDICT" "$REASON"
  total=$((total + 1))
  case "$VERDICT" in
    ELIGIBLE) ;;
    NOT-ELIGIBLE) ne=$((ne + 1)) ;;
    *) ind=$((ind + 1)) ;;
  esac
done
echo "prs=$total eligible=$el not_eligible=$ne indeterminate=$ind merged=$merged failed=$failed"
if [ "$failed" -gt 0 ]; then exit 1; fi
exit 0
