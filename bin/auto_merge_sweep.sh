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
#   g. heartbeat: one housekeeping_runs row per --apply run (see hk_record below);
#      never in report mode.
#   h. merge history: after the PR loop, merge_history_sync.sh records the last
#      50 merged PRs in merge_events (fail-open: a failure prints a warning and
#      shows in the sync's own heartbeat; it never changes this exit code).
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
# Tier 2 (llm#1471, conservative): a PR whose body carries the trailer line
# "Tier-2-Class: <class>" is judged by .claude/state/auto_merge_tier2.tsv instead
# of the scheduled-script reason. The trailer is only a claim; the real gate is
# mechanical: the class exists and is enabled; no path matches
# auto_merge_exclusions.txt or auto_merge_tier2_hardnever.txt (which stay owner-
# verb always); every path matches the class globs; at most max_changed_lines;
# and at least one real test file changed. On top of every normal condition it
# needs the veto window: head commit and checks green for >= 4 h
# (AUTO_MERGE_TIER2_WINDOW_HOURS), no hold/do-not-merge label and no OWNER
# comment containing the word veto or hold. Inside the window the verdict is
# TIER2-WAITING <hours>h-left (exit code unchanged); a summary suffix
# tier2_waiting=N appears only when N > 0. At most 2 Tier 2 merges per UTC day
# (counted from the action log; skipped tier2-cap-reached). A Tier 2 merge adds
# the labels auto-merged and tier2 (tier2 must exist: else skipped
# tier2-label-missing) and logs "merged squash-tier2".
#
# Tier 2 class readonly-checker (llm#1471): the one class that relaxes the
# scheduled-script reason, and only for scripts on the owner-signed list
# .claude/state/readonly_checkers.txt. On top of the mechanical Tier 2 conditions,
# every changed path that is not a test file must be on that list (else NOT-ELIGIBLE
# tier2-readonly-not-listed:<path>; an unusable list is INDETERMINATE), and
# tests/test_readonly_checkers_guard.sh --scan must pass on the PR-HEAD content of
# each changed script (fetched through the contents API, never executed): exit 1 is
# NOT-ELIGIBLE readonly-guard-failed, exit 3 / a fetch failure is INDETERMINATE.
# Editing the list or the guard test is itself excluded (auto_merge_exclusions.txt).
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
# AUTO_MERGE_EXCLUSIONS, AUTO_MERGE_LOG, AUTO_MERGE_RETRY_SLEEP, AUTO_MERGE_LIB,
# AUTO_MERGE_SYNC, AUTO_MERGE_TIER2, AUTO_MERGE_TIER2_HARDNEVER,
# AUTO_MERGE_TIER2_WINDOW_HOURS, AUTO_MERGE_READONLY, AUTO_MERGE_READONLY_GUARD.

set -u
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

# Labels that always block automatic merge (one per word, space separated).
HOLD_LABELS="needs-owner do-not-merge hold"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${AUTO_MERGE_REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
GATE="${AUTO_MERGE_GATE:-$REPO_DIR/bin/roborev_merge_gate.sh}"
EXCL_FILE="${AUTO_MERGE_EXCLUSIONS:-$REPO_DIR/.claude/state/auto_merge_exclusions.txt}"
# Library and merge-history sync live next to this script's checkout, never in
# AUTO_MERGE_REPO_DIR (which only supplies the data files).
MC_LIB="${AUTO_MERGE_LIB:-$SCRIPT_DIR/../.claude/scripts/lib/merge_classify.sh}"
SYNC="${AUTO_MERGE_SYNC:-$SCRIPT_DIR/../.claude/scripts/merge_history_sync.sh}"
# Tier 2 (see the header): data files, veto window, daily cap. Rolling any of
# these back is a one-line change: enabled=0 in the table.
TIER2_TABLE="${AUTO_MERGE_TIER2:-$REPO_DIR/.claude/state/auto_merge_tier2.tsv}"
TIER2_HARDNEVER="${AUTO_MERGE_TIER2_HARDNEVER:-$REPO_DIR/.claude/state/auto_merge_tier2_hardnever.txt}"
TIER2_WINDOW_HOURS="${AUTO_MERGE_TIER2_WINDOW_HOURS:-4}"
TIER2_DAILY_CAP=2
# Read-only checker allowlist (class readonly-checker) and its guard test. The
# guard runs from this script's own checkout (trusted); only the scanned content
# comes from the PR.
READONLY_LIST="${AUTO_MERGE_READONLY:-$REPO_DIR/.claude/state/readonly_checkers.txt}"
GUARD="${AUTO_MERGE_READONLY_GUARD:-$SCRIPT_DIR/../tests/test_readonly_checkers_guard.sh}"
case "$TIER2_WINDOW_HOURS" in ""|*[!0-9.]*) TIER2_WINDOW_HOURS=4 ;; esac

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

# Heartbeat (--apply only, never in report mode): one housekeeping_runs row per
# run so the overnight email can report the job. task auto_merge_sweep, status
# ok on exit 0, failed on exit 1/3, rows_written = merged count. Counts and a
# status word only. Written to UNIFIED_DB_PATH if set; else to the default DB
# unless AUTO_MERGE_LOG is overridden (a test run). Fail-open: no duckdb, no DB
# file or an insert error never changes the job's own exit code.
HK_DB="${UNIFIED_DB_PATH:-}"
if [ -z "$HK_DB" ] && [ -z "${AUTO_MERGE_LOG:-}" ]; then
  HK_DB="$HOME/.claude/logs/unified.duckdb"
fi
hk_record() {  # $1 = exit code
  [ "$APPLY" -eq 1 ] || return 0
  [ -n "$HK_DB" ] && [ -f "$HK_DB" ] || return 0
  command -v duckdb >/dev/null 2>&1 || return 0
  local id now st
  id="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  [ -n "$id" ] || return 0
  case "$1" in 0) st="ok" ;; *) st="failed" ;; esac
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  duckdb -init /dev/null "$HK_DB" -c "
    INSERT OR IGNORE INTO housekeeping_runs
      (id, task, source_script, started_at, ended_at, status, rows_written)
    VALUES ('$id', 'auto_merge_sweep', 'bin/auto_merge_sweep.sh',
            TIMESTAMPTZ '$now', TIMESTAMPTZ '$now', '$st', ${merged:-0});
  " >/dev/null 2>&1 || true
}
TMP=""
on_exit() {
  local rc=$?
  if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
  hk_record "$rc"
}
trap on_exit EXIT

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

# ---- JSON field extraction (python3 reads the file named in argv) -----------
parse_view() {
  python3 - "$1" <<'PYEOF'
import calendar, json, re, sys, time
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
# Tier 2: the declared class (trailer line in the PR body; a claim, not proof)
# and the epoch of the later of the head commit and the last check completion.
m = re.search(r"^Tier-2-Class:[ \t]*([A-Za-z0-9_-]+)[ \t]*\r?$", d.get("body") or "", re.M)
print("TIER2\t%s" % (m.group(1).lower() if m else ""))
def ep(s):
    try:
        return calendar.timegm(time.strptime((s or "")[:19], "%Y-%m-%dT%H:%M:%S"))
    except Exception:
        return None
commits = d.get("commits") or []
head_ep = ep((commits[-1].get("committedDate") or commits[-1].get("authoredDate")) if commits else None)
done_ep = [ep(c.get("completedAt")) for c in rollup if c.get("completedAt") and not str(c.get("completedAt")).startswith("0001")]
done_ep = [x for x in done_ep if x]
print("T2EPOCH\t%s" % (max([head_ep] + done_ep) if head_ep else ""))
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

# ---- Exclusion and scheduled-script data (fail closed) -------------------------
# Logic lives in .claude/scripts/lib/merge_classify.sh, shared with
# merge_history_sync.sh so both classify a diff identically.
MC_TMP="$TMP"
if [ ! -r "$MC_LIB" ]; then
  echo "INDETERMINATE: classification library not readable: $MC_LIB" >&2
  exit 3
fi
. "$MC_LIB"
mc_load "$REPO_DIR" "$EXCL_FILE" "$READONLY_LIST"
EXCL_ERR="$MC_EXCL_ERR"; SCHED_ERR="$MC_SCHED_ERR"

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

# Class readonly-checker: run the guard test over the PR-HEAD content of every
# changed non-test script (all of them are on the owner-signed list by now). The
# content is fetched, never executed. Sets VERDICT (NOT-ELIGIBLE) or note_ind; leaves
# both untouched when the guard passes.
readonly_guard() {  # pr raw-files-tsv
  local n="$1" fr="$2" d="$TMP/ro_$n" p c cnt=0 rc args=""
  rm -rf "$d"; mkdir -p "$d"
  if [ ! -r "$GUARD" ]; then note_ind "readonly-guard-unavailable"; return; fi
  awk -F'\t' 'NF>=1 && $1!=""{print $1}' "$fr" > "$d/paths"
  while IFS= read -r p; do
    case "$p" in tests/*|.claude/tests/*|"") continue ;; esac
    cnt=$((cnt + 1))
    c="$d/c_$cnt.sh"
    if ! gh api "repos/$REPO/contents/$p?ref=$HEADSHA" -H "Accept: application/vnd.github.raw" > "$c" 2>/dev/null || [ ! -s "$c" ]; then
      note_ind "readonly-content-failed"; return
    fi
    args="$args $c"
  done < "$d/paths"
  if [ "$cnt" -eq 0 ]; then return; fi
  # shellcheck disable=SC2086
  bash "$GUARD" --scan $args >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) ;;
    1) not_elig "readonly-guard-failed" ;;
    *) note_ind "readonly-guard-indeterminate" ;;
  esac
}

evaluate() {
  local n="$1" assoc view fields
  VERDICT=""; REASON=""; IND=""; HEADSHA=""; T2_CLASS=""

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
    if ! gh pr view "$n" --repo "$REPO" --json number,state,isDraft,labels,mergeStateStatus,statusCheckRollup,changedFiles,headRefOid,body,commits > "$view" 2>/dev/null; then
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
  local ff="$TMP/files_$n" fr="$TMP/filesraw_$n" rc nlisted declared files_ok=1
  T2_CLASS=""
  if ! gh api "repos/$REPO/pulls/$n/files" --paginate --jq '.[] | [.filename, (.previous_filename // ""), .additions, .deletions] | @tsv' > "$fr" 2>/dev/null; then
    note_ind "files-api-failed"
    files_ok=0
    : > "$ff"
  else
    awk -F'\t' 'NF>=1 && $1!=""{print $1} NF>=2 && $2!=""{print $2}' "$fr" > "$ff"
    nlisted="$(awk -F'\t' 'NF>=1 && $1!=""{c++} END{print c+0}' "$fr")"
    if [ -n "$changed" ] && [ "$changed" -gt "$nlisted" ]; then note_ind "files-truncated"; files_ok=0; fi
    if [ ! -s "$ff" ]; then note_ind "no-files-listed"; files_ok=0; fi
  fi
  mc_check_paths "$ff"
  if [ -n "$MC_PATH_HIT" ]; then not_elig "excluded-path:$MC_PATH_HIT"; return; fi
  # Tier 2: a PR that declares a class (trailer) is judged by the class's
  # MECHANICAL conditions instead of the scheduled-script reason alone. The
  # exclusion-file paths above still apply to it in full.
  declared="$(awk -F'\t' '$1=="TIER2"{print $2}' "$fields")"
  if [ -n "$declared" ]; then
    T2_CLASS="$declared"
    if [ "$files_ok" -eq 1 ]; then
      mc_tier2_check "$declared" "$fr" "$TIER2_TABLE" "$TIER2_HARDNEVER"
      case "$MC_T2_VERDICT" in
        ne) not_elig "$MC_T2_REASON"; return ;;
        ind) note_ind "$MC_T2_REASON" ;;
        *)
          if [ "$declared" = "readonly-checker" ]; then
            readonly_guard "$n" "$fr"
            if [ -n "$VERDICT" ]; then return; fi
          fi ;;
      esac
    fi
  elif [ -n "$MC_SCHED_HIT" ]; then
    not_elig "scheduled-script:$MC_SCHED_HIT"; return
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
  if [ -z "$IND" ] && [ -n "$T2_CLASS" ]; then
    tier2_final "$n" "$fields"
    if [ -n "$VERDICT" ]; then return; fi
  fi
  if [ -n "$IND" ]; then VERDICT="INDETERMINATE"; REASON="$IND"; return; fi
  VERDICT="ELIGIBLE"; REASON="all-conditions-met"
}

# Tier 2, last gates (slow ones after the cheap ones): no owner veto comment,
# and the veto window has elapsed. Sets VERDICT/REASON only when the answer is
# not "go on": NOT-ELIGIBLE tier2-vetoed, TIER2-WAITING <hours>h-left, or
# INDETERMINATE when the comments or the green time cannot be read.
# Veto = a comment by the OWNER containing the word veto or hold (trusting only
# author_association OWNER, so a third party cannot block or unblock a merge).
tier2_final() {  # pr fields-file
  local n="$1" fields="$2" cm="$TMP/comments_$n" ep now left
  if ! gh api "repos/$REPO/issues/$n/comments" --paginate --jq '.[] | select(.author_association == "OWNER") | .body' > "$cm" 2>/dev/null; then
    VERDICT="INDETERMINATE"; REASON="tier2-comments-failed"; return
  fi
  if grep -qiE '(^|[^[:alnum:]_])(veto|hold)([^[:alnum:]_]|$)' "$cm"; then not_elig "tier2-vetoed"; return; fi
  ep="$(awk -F'\t' '$1=="T2EPOCH"{print $2}' "$fields")"
  case "$ep" in
    ""|*[!0-9]*) VERDICT="INDETERMINATE"; REASON="tier2-green-time-unknown"; return ;;
  esac
  now="$(date -u +%s)"
  left="$(awk -v e="$ep" -v n="$now" -v w="$TIER2_WINDOW_HOURS" 'BEGIN{l = w - (n - e) / 3600; if (l > 0) printf "%.1f", l}')"
  if [ -n "$left" ]; then VERDICT="TIER2-WAITING"; REASON="${left}h-left"; fi
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
T2LABEL="tier2"
T2LABEL_STATE=""   # "", "ok" or "missing" (checked once, only for a Tier 2 PR under --apply)
t2label_check() {
  if [ -z "$T2LABEL_STATE" ]; then
    if gh label list --repo "$REPO" --search "$T2LABEL" --limit 100 --json name --jq '.[].name' 2>/dev/null | grep -qx "$T2LABEL"; then
      T2LABEL_STATE="ok"
    else
      T2LABEL_STATE="missing"
    fi
  fi
}

# Tier 2 merges already done today (UTC), counted from the action log.
t2_merged_today() {
  local tab n
  tab="$(printf '\t')"
  if [ ! -r "$LOG" ]; then echo 0; return; fi
  n="$(grep -c "^$(date -u +%Y-%m-%d)T[^$tab]*$tab[0-9]*$tab[^$tab]*${tab}merged${tab}squash-tier2" "$LOG" 2>/dev/null)"
  echo "${n:-0}"
}

apply_one() {  # pr  (first evaluation was ELIGIBLE; HEADSHA is the evaluated head)
  local n="$1" sha1="$HEADSHA" t2 labels_add labels_rm mreason
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
  t2="$T2_CLASS"
  labels_add="--add-label $MERGE_LABEL"; labels_rm="--remove-label $MERGE_LABEL"; mreason="squash"
  if [ -n "$t2" ]; then
    # Tier 2: at most TIER2_DAILY_CAP per UTC day, and the tier2 label must exist
    if [ "$(t2_merged_today)" -ge "$TIER2_DAILY_CAP" ]; then log_action "$n" "$sha1" skipped "tier2-cap-reached"; return; fi
    t2label_check
    if [ "$T2LABEL_STATE" != "ok" ]; then log_action "$n" "$sha1" skipped "tier2-label-missing"; return; fi
    labels_add="$labels_add --add-label $T2LABEL"; labels_rm="$labels_rm --remove-label $T2LABEL"; mreason="squash-tier2"
  fi
  # shellcheck disable=SC2086
  if ! gh pr edit "$n" --repo "$REPO" $labels_add >/dev/null 2>&1; then
    log_action "$n" "$sha1" skipped "label-add-failed"; return
  fi
  log_action "$n" "$sha1" labelled "ok"
  ATTEMPTS=$((ATTEMPTS + 1))
  if gh pr merge "$n" --repo "$REPO" --squash --match-head-commit "$sha1" >/dev/null 2>&1; then
    merged=$((merged + 1))
    log_action "$n" "$sha1" merged "$mreason"
    # facts the sync cannot learn from GitHub later: an ELIGIBLE verdict means CI
    # was all SUCCESS and the merge gate exited 0 at this head commit
    printf '%s\t%s\t%s\n' "$n" "success" "PASS" >> "$TMP/facts.tsv"
  else
    failed=$((failed + 1))
    log_action "$n" "$sha1" merge-failed "gh-merge-nonzero"
    # shellcheck disable=SC2086
    if gh pr edit "$n" --repo "$REPO" $labels_rm >/dev/null 2>&1; then
      log_action "$n" "$sha1" unlabelled "after-merge-failure"
    else
      echo "WARNING: PR $n merge failed AND the $MERGE_LABEL label could not be removed" >&2
      log_action "$n" "$sha1" merge-failed "unlabel-failed"
    fi
  fi
}

# Merge history (--apply only): record the last merged PRs in merge_events.
# Fail-open: a sync failure never changes this script's exit code, but it is
# never silent (warning here; the sync writes its own failed heartbeat row).
run_sync() {
  if [ ! -r "$SYNC" ]; then
    echo "WARNING: merge history sync script not readable: $SYNC" >&2
    return 0
  fi
  : >> "$TMP/facts.tsv"
  bash "$SYNC" --repo "$REPO" --limit 50 --facts "$TMP/facts.tsv" >/dev/null
  local src=$?
  if [ "$src" -ne 0 ]; then
    echo "WARNING: merge history sync failed (exit $src); merge_events may be stale" >&2
  fi
  return 0
}

total=0; el=0; ne=0; ind=0; tw=0
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
    TIER2-WAITING) tw=$((tw + 1)) ;;
    *) ind=$((ind + 1)) ;;
  esac
done
if [ "$APPLY" -eq 1 ]; then run_sync; fi
summary="prs=$total eligible=$el not_eligible=$ne indeterminate=$ind merged=$merged failed=$failed"
if [ "$tw" -gt 0 ]; then summary="$summary tier2_waiting=$tw"; fi
echo "$summary"
if [ "$failed" -gt 0 ]; then exit 1; fi
exit 0
