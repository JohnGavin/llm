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
#   .claude/state/auto_merge_state_tables.txt         owner-signed state-table allow-list
# This file holds logic only. Portable: bash 3.2, BSD and GNU userland.
#
# Callers must set MC_TMP (a writable scratch dir) before mc_load.

# mc_load REPO_DIR EXCL_FILE [READONLY_FILE [STATE_TABLES_FILE]]
# Sets MC_PATFILE, MC_EXCL_ERR, MC_SCHEDFILE, MC_SCHED_ERR (fail closed: an
# unreadable, empty or invalid data source is reported, never treated as "no
# exclusions"). Also MC_RO_FILE / MC_RO_ERR for the owner-signed read-only
# checker list (.claude/state/readonly_checkers.txt unless READONLY_FILE is
# given). The list only ever RELAXES the scheduled-script reason, so an
# unreadable, empty or invalid list is simply "no relaxation" (never a hole).
# MC_ST_FILE / MC_ST_ERR: the owner-signed state-table allow-list
# (.claude/state/auto_merge_state_tables.txt unless STATE_TABLES_FILE is given),
# which relaxes ONLY the .claude/state/ exclusion for the exact paths it names, and
# only for a PR of Tier 2 class state-table. Entries must be .claude/state/<name>.tsv|txt
# and must not name any merge-machinery table; a bad entry makes the list invalid.
mc_load() {
  local repo_dir="$1" excl_file="$2" ro_file="${3:-$1/.claude/state/readonly_checkers.txt}" f sched_srcs=""
  local st_file="${4:-$1/.claude/state/auto_merge_state_tables.txt}"
  MC_EXCL_ERR=""; MC_SCHED_ERR=""; MC_RO_ERR=""; MC_ST_ERR=""
  MC_ST_FILE="$MC_TMP/statetables"
  : > "$MC_ST_FILE"
  if [ ! -r "$st_file" ]; then
    MC_ST_ERR="state-list-unreadable"
  else
    grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$st_file" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' > "$MC_ST_FILE"
    if [ ! -s "$MC_ST_FILE" ]; then
      MC_ST_ERR="state-list-empty"
    elif grep -v -E '^\.claude/state/[A-Za-z0-9_.-]+\.(tsv|txt)$' "$MC_ST_FILE" | grep -q . ; then
      MC_ST_ERR="state-list-invalid"
    elif grep -q -E -e '\.\.' -e 'auto_merge|readonly_checkers|scanner_policy|merge_history|merge_classify|tier2|exclusions' "$MC_ST_FILE"; then
      MC_ST_ERR="state-list-invalid"
    fi
  fi
  MC_PATFILE="$MC_TMP/patterns"
  MC_SCHEDFILE="$MC_TMP/scheduled"
  MC_RO_FILE="$MC_TMP/readonly"
  : > "$MC_PATFILE"; : > "$MC_SCHEDFILE"; : > "$MC_RO_FILE"
  if [ ! -r "$ro_file" ]; then
    MC_RO_ERR="readonly-list-unreadable"
  else
    grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$ro_file" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' > "$MC_RO_FILE"
    if [ ! -s "$MC_RO_FILE" ]; then
      MC_RO_ERR="readonly-list-empty"
    elif grep -q -e '\.\.' -e '^/' -e '[^A-Za-z0-9_./-]' "$MC_RO_FILE"; then
      MC_RO_ERR="readonly-list-invalid"
    fi
  fi
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

# mc_st_filter IN OUT
# Writes IN minus the paths on the state-table allow-list to OUT. With an unusable
# list it drops every .claude/state/ path instead, so the caller can answer
# INDETERMINATE for that class without a state path producing a verdict first.
mc_st_filter() {
  if [ -z "$MC_ST_ERR" ]; then
    grep -v -F -x -f "$MC_ST_FILE" "$1" > "$2" 2>/dev/null
  else
    grep -v -E '^\.claude/state/' "$1" > "$2" 2>/dev/null
  fi
  return 0
}

# mc_check_paths FILE_LIST [TIER2_CLASS]   (one path per line; renames list both paths)
# Sets MC_PATH_HIT (first path matching an exclusion regex) and MC_SCHED_HIT
# (first basename that is a scheduled script); both empty when nothing matches
# or the corresponding data source is in error. With TIER2_CLASS=state-table the
# paths on the owner-signed allow-list are not tested (MC_ST_RELAXED=1 when any was
# skipped); every other path, including any other .claude/state/ file, still is.
mc_check_paths() {
  local list="$1"
  MC_PATH_HIT=""; MC_SCHED_HIT=""; MC_ST_RELAXED=0
  [ -s "$list" ] || return 0
  if [ "${2:-}" = "state-table" ]; then
    mc_st_filter "$list" "$MC_TMP/paths.st"
    if [ -z "$MC_ST_ERR" ] && [ "$(wc -l < "$MC_TMP/paths.st")" -lt "$(wc -l < "$list")" ]; then MC_ST_RELAXED=1; fi
    list="$MC_TMP/paths.st"
    [ -s "$list" ] || return 0
  fi
  if [ -z "$MC_EXCL_ERR" ]; then
    MC_PATH_HIT="$(grep -E -f "$MC_PATFILE" "$list" | head -1)"
  fi
  if [ -z "$MC_SCHED_ERR" ]; then
    awk -F/ '{print $NF}' "$list" > "$MC_TMP/base.list"
    MC_SCHED_HIT="$(grep -F -x -f "$MC_SCHEDFILE" "$MC_TMP/base.list" | head -1)"
  fi
}

# mc_ro_listed PATH   true when PATH (repo-relative, exact) is on the owner-signed
# read-only checker list and the list loaded cleanly.
mc_ro_listed() {
  [ -z "$MC_RO_ERR" ] || return 1
  grep -F -x -q -- "$1" "$MC_RO_FILE"
}

# mc_sched_unlisted FILE_LIST
# Sets MC_SCHED_UNLISTED to the first path in FILE_LIST whose basename is a
# scheduled script and which is NOT on the read-only checker list ("" when every
# scheduled-script path is listed, or none is scheduled). With an unusable list
# nothing is listed, so every scheduled path counts.
mc_sched_unlisted() {
  local p b
  MC_SCHED_UNLISTED=""
  [ -s "$1" ] || return 0
  [ -z "$MC_SCHED_ERR" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    b="${p##*/}"
    if grep -F -x -q -- "$b" "$MC_SCHEDFILE" && ! mc_ro_listed "$p"; then
      MC_SCHED_UNLISTED="$p"; return 0
    fi
  done < "$1"
}

# mc_classify_merged FILE_LIST LABELS TIER2_CLASS
# For a MERGED PR. LABELS is space separated; TIER2_CLASS is the declared class
# from the PR body trailer or "-". Sets MC_CLASS, MC_REASONS (comma list of
# reason kinds, never paths), MC_MERGE_PATH, MC_APPROVAL.
# Read-only checkers: a SWEEP merge (auto-merged label) whose only scheduled-script
# paths are on .claude/state/readonly_checkers.txt is not an excluded class (reason
# readonly-checker, class readonly-checker); an UNLISTED scheduled script still is,
# also for a PR declaring Tier-2-Class: readonly-checker.
mc_classify_merged() {
  local ff="$1" labels="$2" t2="$3" l has_auto=0 has_t2=0 ro_relax=0 cc=""
  for l in $labels; do
    case "$l" in auto-merged) has_auto=1 ;; tier2) has_t2=1 ;; esac
  done
  # state-table: the allow-listed state paths are not an excluded class for a sweep
  # Tier 2 merge (same rule as the sweep); an unusable list relaxes nothing.
  if [ "$has_auto" -eq 1 ] && [ "$has_t2" -eq 1 ] && [ "$t2" = "state-table" ] && [ -z "$MC_ST_ERR" ]; then cc="state-table"; fi
  mc_check_paths "$ff" "$cc"
  mc_sched_unlisted "$ff"
  if [ "$has_auto" -eq 1 ] && [ -n "$MC_SCHED_HIT" ] && [ -z "$MC_SCHED_UNLISTED" ] && [ -z "$MC_RO_ERR" ]; then ro_relax=1; fi
  MC_REASONS=""
  if [ -n "$MC_PATH_HIT" ]; then MC_REASONS="path"; fi
  if [ "$MC_ST_RELAXED" -eq 1 ]; then MC_REASONS="${MC_REASONS:+$MC_REASONS,}state-table"; fi
  if [ -n "$MC_SCHED_HIT" ]; then
    if [ "$ro_relax" -eq 1 ]; then
      MC_REASONS="${MC_REASONS:+$MC_REASONS,}readonly-checker"
    else
      MC_REASONS="${MC_REASONS:+$MC_REASONS,}scheduled-script"
    fi
  fi
  if [ "$has_auto" -eq 1 ]; then MC_MERGE_PATH="sweep"; else MC_MERGE_PATH="owner-verb"; fi
  if [ -n "$MC_EXCL_ERR$MC_SCHED_ERR" ]; then
    MC_CLASS="unknown"
  elif [ -n "$MC_PATH_HIT" ]; then
    MC_CLASS="excluded:path"
  elif [ "$has_auto" -eq 1 ] && [ "$has_t2" -eq 1 ] && [ "$t2" = "readonly-checker" ] && [ -n "$MC_SCHED_UNLISTED" ]; then
    MC_CLASS="excluded:scheduled-script"
  elif [ "$has_auto" -eq 1 ] && [ "$has_t2" -eq 1 ]; then
    case "$t2" in ""|"-") MC_CLASS="tier2:unknown" ;; *) MC_CLASS="tier2:$t2" ;; esac
  elif [ "$ro_relax" -eq 1 ]; then
    MC_CLASS="readonly-checker"
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

# Basenames of term / allow / deny list files. A Tier 2 PR whose diff REMOVES a
# line from one stays owner-verb (removing an entry widens what is let through).
MC_LIST_FILE_RE='(^|/)[^/]*(term|allow|deny|block)[^/]*[.](txt|tsv|list|lst|csv)$'

# mc_tier2_check CLASS RAW_FILES_TSV TABLE HARDNEVER
# RAW_FILES_TSV columns: filename, previous_filename, additions, deletions.
# Applies the MECHANICAL Tier 2 conditions (the PR-body trailer is only a claim).
# Sets MC_T2_VERDICT = ok | ne (definitely not Tier 2 eligible) | ind (could not
# decide) and MC_T2_REASON. Table columns (TAB separated, '#' lines ignored):
#   class  max_changed_lines  required_path_globs(;)  forbidden_extra(ERE or -)  requires_tests(0|1)  enabled(0|1)
mc_tier2_check() {
  local cls="$1" raw="$2" table="$3" hn="$4"
  local row max globs forb rt en hit lines g p ok_any
  MC_T2_VERDICT="ok"; MC_T2_REASON=""
  if [ ! -r "$table" ]; then MC_T2_VERDICT="ind"; MC_T2_REASON="tier2-table-unreadable"; return; fi
  if [ ! -r "$hn" ]; then MC_T2_VERDICT="ind"; MC_T2_REASON="tier2-hardnever-unreadable"; return; fi
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$hn" > "$MC_TMP/t2_hn" 2>/dev/null
  if [ ! -s "$MC_TMP/t2_hn" ]; then MC_T2_VERDICT="ind"; MC_T2_REASON="tier2-hardnever-empty"; return; fi
  grep -E -f "$MC_TMP/t2_hn" /dev/null >/dev/null 2>&1
  if [ $? -eq 2 ]; then MC_T2_VERDICT="ind"; MC_T2_REASON="tier2-hardnever-invalid-regex"; return; fi

  row="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$table" | awk -F'\t' -v c="$cls" '$1==c{print; exit}')"
  if [ -z "$row" ]; then MC_T2_VERDICT="ne"; MC_T2_REASON="tier2-unknown-class:$cls"; return; fi
  max="$(printf '%s\n' "$row" | awk -F'\t' '{print $2}')"
  globs="$(printf '%s\n' "$row" | awk -F'\t' '{print $3}')"
  forb="$(printf '%s\n' "$row" | awk -F'\t' '{print $4}')"
  rt="$(printf '%s\n' "$row" | awk -F'\t' '{print $5}')"
  en="$(printf '%s\n' "$row" | awk -F'\t' '{print $6}')"
  case "$max" in ""|*[!0-9]*) MC_T2_VERDICT="ind"; MC_T2_REASON="tier2-table-malformed:$cls"; return ;; esac
  if [ "$en" != "1" ]; then MC_T2_VERDICT="ne"; MC_T2_REASON="tier2-class-disabled:$cls"; return; fi
  if [ -z "$globs" ] || [ "$globs" = "-" ]; then MC_T2_VERDICT="ind"; MC_T2_REASON="tier2-table-malformed:$cls"; return; fi
  # state-table needs its owner-signed allow-list: unusable means the sweep cannot tell
  if [ "$cls" = "state-table" ] && [ -n "$MC_ST_ERR" ]; then MC_T2_VERDICT="ind"; MC_T2_REASON="$MC_ST_ERR"; return; fi

  # every path (new and previous), one per line
  awk -F'\t' 'NF>=1 && $1!=""{print $1} NF>=2 && $2!=""{print $2}' "$raw" > "$MC_TMP/t2_paths"

  # 1. hard-never (always owner-verb). For state-table the paths on the allow-list
  # are the one thing exempt from the .claude/state/ hard-never regex; every other
  # path (including every other state file) is tested in full.
  cp "$MC_TMP/t2_paths" "$MC_TMP/t2_paths_hn"
  if [ "$cls" = "state-table" ]; then mc_st_filter "$MC_TMP/t2_paths" "$MC_TMP/t2_paths_hn"; fi
  hit="$(grep -E -f "$MC_TMP/t2_hn" "$MC_TMP/t2_paths_hn" | head -1)"
  if [ -n "$hit" ]; then MC_T2_VERDICT="ne"; MC_T2_REASON="tier2-hard-never:$hit"; return; fi
  hit="$(awk -F'\t' -v re="$MC_LIST_FILE_RE" '($4+0)>0 && $1 ~ re {print $1; exit}' "$raw")"
  if [ -n "$hit" ]; then MC_T2_VERDICT="ne"; MC_T2_REASON="tier2-list-removal:$hit"; return; fi

  # 2. every path must match one of the class's globs
  printf '%s\n' "$globs" | tr ';' '\n' > "$MC_TMP/t2_globs"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    ok_any=0
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      case "$p" in $g) ok_any=1; break ;; esac
    done < "$MC_TMP/t2_globs"
    if [ "$ok_any" -eq 0 ]; then MC_T2_VERDICT="ne"; MC_T2_REASON="tier2-path-not-allowed:$p"; return; fi
  done < "$MC_TMP/t2_paths"

  # 2b. readonly-checker: every changed path that is not a test file (new path and,
  # for a rename, previous path) must be on the owner-signed list, so the class can
  # only ever relax the scheduled-script reason for listed scripts. An unusable list
  # means the sweep cannot tell: indeterminate, never "all listed".
  if [ "$cls" = "readonly-checker" ]; then
    if [ -n "$MC_RO_ERR" ]; then MC_T2_VERDICT="ind"; MC_T2_REASON="$MC_RO_ERR"; return; fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in tests/*|.claude/tests/*) continue ;; esac
      if ! mc_ro_listed "$p"; then MC_T2_VERDICT="ne"; MC_T2_REASON="tier2-readonly-not-listed:$p"; return; fi
    done < "$MC_TMP/t2_paths"
  fi

  # 2c. state-table: every changed path that is not a test file must be on the
  # allow-list, and an allow-listed table may only GROW: a deleted line (an edit counts
  # as one), a rename of it or a deletion of it is owner-verb (removing a row from an
  # allow/deny/term-style table widens what is let through).
  if [ "$cls" = "state-table" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in tests/*|.claude/tests/*) continue ;; esac
      if ! grep -F -x -q -- "$p" "$MC_ST_FILE"; then MC_T2_VERDICT="ne"; MC_T2_REASON="tier2-state-not-listed:$p"; return; fi
    done < "$MC_TMP/t2_paths"
    hit="$(awk -F'\t' 'NR==FNR{l[$0]=1; next} ($1 in l || $2 in l) && (($4+0)>0 || $2!="") {print $1; exit}' "$MC_ST_FILE" "$raw")"
    if [ -n "$hit" ]; then MC_T2_VERDICT="ne"; MC_T2_REASON="tier2-state-table-removal:$hit"; return; fi
  fi

  # 3. extra per-class forbidden pattern
  if [ -n "$forb" ] && [ "$forb" != "-" ]; then
    printf '%s\n' "$forb" > "$MC_TMP/t2_forb"
    hit="$(grep -E -f "$MC_TMP/t2_forb" "$MC_TMP/t2_paths" 2>/dev/null | head -1)"
    if [ -n "$hit" ]; then MC_T2_VERDICT="ne"; MC_T2_REASON="tier2-forbidden-extra:$hit"; return; fi
  fi

  # 4. size
  lines="$(awk -F'\t' '{s += $3 + $4} END{print s + 0}' "$raw")"
  if [ "$lines" -gt "$max" ]; then MC_T2_VERDICT="ne"; MC_T2_REASON="tier2-too-large:$lines>$max"; return; fi

  # 5. tests: at least one changed file under tests/ or .claude/tests/ (a bare
  # edit of the test map does not count)
  if [ "$rt" = "1" ]; then
    hit="$(awk -F'\t' '$1 ~ /^(\.claude\/)?tests\// && $1 !~ /(^|\/)ci_test_map[.]tsv$/ {print $1; exit}' "$raw")"
    if [ -z "$hit" ]; then MC_T2_VERDICT="ne"; MC_T2_REASON="tier2-no-tests"; return; fi
  fi
}

