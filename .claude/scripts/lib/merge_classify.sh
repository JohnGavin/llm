#!/usr/bin/env bash
# .claude/scripts/lib/merge_classify.sh -- SOURCED, never executed (llm#1471).
#
# ONE implementation of "which exclusion class does this diff fall in", used by
#   bin/auto_merge_sweep.sh                    (decides eligibility)
#   .claude/scripts/merge_history_sync.sh      (classifies merged PRs for merge_events)
# so the two can never disagree. The DATA stays in single homes:
#   .claude/state/auto_merge_exclusions.txt           exclusion regexes
#   .claude/launchd/*.plist + bin/launchd-recorders/*  derived scheduled-script set
#   .claude/state/auto_merge_tier2.tsv                Tier 2 classes
#   .claude/state/auto_merge_tier2_hardnever.txt      Tier 2 hard-never regexes
# This file holds logic only. Portable: bash 3.2, BSD and GNU userland.
#
# Callers must set MC_TMP (a writable scratch dir) before mc_load.

# mc_load REPO_DIR EXCL_FILE
# Sets MC_PATFILE, MC_EXCL_ERR, MC_SCHEDFILE, MC_SCHED_ERR (fail closed: an
# unreadable, empty or invalid data source is reported, never treated as "no
# exclusions").
mc_load() {
  local repo_dir="$1" excl_file="$2" f sched_srcs=""
  MC_EXCL_ERR=""; MC_SCHED_ERR=""
  MC_PATFILE="$MC_TMP/patterns"
  MC_SCHEDFILE="$MC_TMP/scheduled"
  : > "$MC_PATFILE"; : > "$MC_SCHEDFILE"
  if [ ! -r "$excl_file" ]; then
    MC_EXCL_ERR="exclusions-unreadable"
  else
    grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$excl_file" > "$MC_PATFILE" 2>/dev/null
    if [ ! -s "$MC_PATFILE" ]; then
      MC_EXCL_ERR="exclusions-empty"
    else
      grep -E -f "$MC_PATFILE" /dev/null >/dev/null 2>&1
      if [ $? -eq 2 ]; then MC_EXCL_ERR="exclusions-invalid-regex"; fi
    fi
  fi
  for f in "$repo_dir"/.claude/launchd/*.plist "$repo_dir"/bin/launchd-recorders/*; do
    if [ -f "$f" ]; then sched_srcs="$sched_srcs
$f"; fi
  done
  if [ -z "$sched_srcs" ]; then
    MC_SCHED_ERR="scheduled-set-unreadable"
  else
    printf '%s\n' "$sched_srcs" | while IFS= read -r f; do
      if [ -n "$f" ]; then
        grep -o -E '[A-Za-z0-9_.-]+\.(sh|R|py)' "$f" 2>/dev/null
      fi
    done | sort -u > "$MC_SCHEDFILE"
    if [ ! -s "$MC_SCHEDFILE" ]; then MC_SCHED_ERR="scheduled-set-empty"; fi
  fi
}

# mc_check_paths FILE_LIST   (one path per line; renames list both paths)
# Sets MC_PATH_HIT (first path matching an exclusion regex) and MC_SCHED_HIT
# (first basename that is a scheduled script); both empty when nothing matches
# or the corresponding data source is in error.
mc_check_paths() {
  MC_PATH_HIT=""; MC_SCHED_HIT=""
  [ -s "$1" ] || return 0
  if [ -z "$MC_EXCL_ERR" ]; then
    MC_PATH_HIT="$(grep -E -f "$MC_PATFILE" "$1" | head -1)"
  fi
  if [ -z "$MC_SCHED_ERR" ]; then
    awk -F/ '{print $NF}' "$1" > "$MC_TMP/base.list"
    MC_SCHED_HIT="$(grep -F -x -f "$MC_SCHEDFILE" "$MC_TMP/base.list" | head -1)"
  fi
}

# mc_classify_merged FILE_LIST LABELS TIER2_CLASS
# For a MERGED PR. LABELS is space separated; TIER2_CLASS is the declared class
# from the PR body trailer or "-". Sets MC_CLASS, MC_REASONS (comma list of
# reason kinds, never paths), MC_MERGE_PATH, MC_APPROVAL.
mc_classify_merged() {
  local ff="$1" labels="$2" t2="$3" l has_auto=0 has_t2=0
  mc_check_paths "$ff"
  MC_REASONS=""
  if [ -n "$MC_PATH_HIT" ]; then MC_REASONS="path"; fi
  if [ -n "$MC_SCHED_HIT" ]; then MC_REASONS="${MC_REASONS:+$MC_REASONS,}scheduled-script"; fi
  for l in $labels; do
    case "$l" in auto-merged) has_auto=1 ;; tier2) has_t2=1 ;; esac
  done
  if [ "$has_auto" -eq 1 ]; then MC_MERGE_PATH="sweep"; else MC_MERGE_PATH="owner-verb"; fi
  if [ -n "$MC_EXCL_ERR$MC_SCHED_ERR" ]; then
    MC_CLASS="unknown"
  elif [ -n "$MC_PATH_HIT" ]; then
    MC_CLASS="excluded:path"
  elif [ "$has_auto" -eq 1 ] && [ "$has_t2" -eq 1 ]; then
    case "$t2" in ""|"-") MC_CLASS="tier2:unknown" ;; *) MC_CLASS="tier2:$t2" ;; esac
  elif [ -n "$MC_SCHED_HIT" ]; then
    MC_CLASS="excluded:scheduled-script"
  else
    MC_CLASS="auto-unlisted"
  fi
  if [ "$MC_MERGE_PATH" != "sweep" ]; then
    MC_APPROVAL="owner-verb"
  else
    case "$MC_CLASS" in tier2:*) MC_APPROVAL="veto-lapsed" ;; *) MC_APPROVAL="none" ;; esac
  fi
}
