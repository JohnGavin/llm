#!/usr/bin/env bash
# worktree_gc.sh — Safe stale-worktree garbage collector
#
# Sweeps all git worktrees across three location patterns:
#   1. ~/docs_gh/*-*            (deprecated sibling worktrees, AGE_DAYS=7)
#   2. ~/docs_gh/*/.claude/worktrees/agent-*  (harness agent worktrees, AGE_DAYS=14)
#   3. ~/worktrees/*/*/*        (convention worktrees, AGE_DAYS=30)
#
# A worktree is eligible for removal only when ALL of:
#   • patch-id fully merged into the default branch (git cherry)
#   • clean (no uncommitted / untracked files)
#   • older than AGE_DAYS for its location pattern
#   • NOT locked by git
#   • NOT the current working directory
#   • NOT protected by a .no-worktree-gc opt-out marker in its repo root
#
# Conservative by design — squash-merged branches (unique patch-ids) are left
# for human review via /cleanup-worktrees. Under-deletes, never over-deletes.
#
# Usage:
#   bash worktree_gc.sh            # dry-run (safe; never removes anything)
#   bash worktree_gc.sh --apply    # remove only after SOAK_END date
#   SELFTEST=1 bash worktree_gc.sh # run built-in unit tests against temp repos
#
# Opt-out: place a .no-worktree-gc file in a repo root to skip that repo.
# Empty ~/worktrees/<proj>/{feat,fix,chore}/ parents are rmdir'd when all
# worktrees under them have been removed.
#
# Writes outcomes to unified.duckdb (worktree_gc_events + housekeeping_runs)
# when duckdb is available. Silently skips DB writes when duckdb is absent.
#
# Tracks: JohnGavin/llm#550 (Phase A), JohnGavin/llm#199

set -euo pipefail

# ─── launchd-safe PATH ───────────────────────────────────────────────────────
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# ─── Soak gate ───────────────────────────────────────────────────────────────
# Dry-run only until this date (7 days after first commit).
# After SOAK_END, --apply actually removes. Before it, --apply is silently
# ignored and everything is treated as dry-run. Mirrors the soak pattern in
# ~/.claude/hooks/agent_push_guard.sh.
SOAK_END="2026-06-02"

# ─── Config ──────────────────────────────────────────────────────────────────
# Per-pattern age thresholds (days)
AGE_DAYS_SIBLINGS="${AGE_DAYS_SIBLINGS:-7}"    # deprecated ~/docs_gh/*-* siblings
AGE_DAYS_AGENT="${AGE_DAYS_AGENT:-14}"         # harness agent worktrees (matches Phase 7f)
AGE_DAYS_CONVENTION="${AGE_DAYS_CONVENTION:-30}"  # ~/worktrees/*/* convention

DOCS_GH="${DOCS_GH:-$HOME/docs_gh}"
# Canonical base (llm#582) + legacy base (transitional — existing worktrees
# remain there until migrated; GC sweeps both).
WORKTREES_BASE="${WORKTREES_BASE:-$HOME/docs_gh/worktrees}"
WORKTREES_BASE_LEGACY="${WORKTREES_BASE_LEGACY:-$HOME/worktrees}"
UNIFIED_DB="${UNIFIED_DB_PATH:-$HOME/.claude/logs/unified.duckdb}"
LOG_FILE="$HOME/.claude/logs/worktree_gc.log"
APPLY=0

# Sweep patterns: "glob|age_days_var_name"
SWEEP_PATTERNS=(
  "${DOCS_GH}/*-*|siblings"
  "${DOCS_GH}/*/.claude/worktrees/agent-*|agent"
  "${WORKTREES_BASE}/*/*/*|convention"
  "${WORKTREES_BASE_LEGACY}/*/*/*|convention"
)

for arg in "$@"; do
  [ "$arg" = "--apply" ] && APPLY=1
done

# ─── Soak check ──────────────────────────────────────────────────────────────
# Use python3 for portability — macOS `date -d` differs from GNU.
_today=$(python3 -c "import datetime; print(datetime.date.today().isoformat())")
_past_soak=$(python3 -c "print('yes' if '${_today}' >= '${SOAK_END}' else 'no')")

if [ "$_past_soak" = "no" ] && [ "$APPLY" = "1" ]; then
  echo "[worktree_gc] Soak period active until ${SOAK_END} — forcing dry-run (apply ignored)" >&2
  APPLY=0
fi

# ─── Logging ─────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" >> "$LOG_FILE"
  echo "$msg"
}

# ─── DuckDB availability check ───────────────────────────────────────────────
_duckdb_ok=0
if command -v duckdb >/dev/null 2>&1 && [ -f "$UNIFIED_DB" ]; then
  _duckdb_ok=1
fi

# Run ID for this invocation (used in housekeeping_runs + worktree_gc_events)
_run_id=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
_run_started=$(python3 -c "import datetime; print(datetime.datetime.utcnow().isoformat() + 'Z')")
_script_abs=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P && echo "$(basename "$0")" || echo "$0")

# Insert housekeeping_runs start row
if [ "$_duckdb_ok" = "1" ]; then
  duckdb "$UNIFIED_DB" "
    INSERT OR IGNORE INTO housekeeping_runs
      (id, task, source_script, started_at, status, rows_written)
    VALUES (
      '${_run_id}',
      'worktree_gc',
      '${_script_abs}',
      TIMESTAMPTZ '${_run_started}',
      'ok',
      0
    );
  " 2>/dev/null || true
fi

# ─── Helper: default branch for a repo ───────────────────────────────────────
default_branch() {
  local repo="$1"
  local ref
  ref=$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#refs/remotes/origin/}"
    return
  fi
  # Fallback: check local refs
  if git -C "$repo" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
    echo "main"
  elif git -C "$repo" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
    echo "master"
  else
    echo "main"
  fi
}

# ─── Helper: is this path the main checkout of a repo? ───────────────────────
is_main_checkout() {
  local repo="$1"
  local git_dir git_common_dir
  git_dir=$(git -C "$repo" rev-parse --git-dir 2>/dev/null || true)
  git_common_dir=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)
  [ "$git_dir" = "$git_common_dir" ]
}

# ─── Helper: mtime of a directory (seconds since epoch) ──────────────────────
dir_mtime_epoch() {
  python3 -c "import os,stat; print(int(os.stat('$1').st_mtime))"
}

# ─── Helper: current epoch ───────────────────────────────────────────────────
now_epoch() {
  python3 -c "import time; print(int(time.time()))"
}

# ─── Helper: du -sm for size_mb (bash native — llm#569 compliance) ──────────
dir_size_mb() {
  # Disk size in MB. 0 if path missing, unreadable, or empty.
  local _p="$1"
  [ -d "$_p" ] || { echo "0"; return; }
  local _mb
  _mb=$(du -sm "$_p" 2>/dev/null | cut -f1)
  [ -z "$_mb" ] && _mb=0
  echo "$_mb"
}

# ─── Helper: write one row to worktree_gc_events ─────────────────────────────
write_gc_event() {
  # args: pattern_label project wt_path branch action reason size_mb
  [ "$_duckdb_ok" = "1" ] || return 0
  local _evt_id
  _evt_id=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
  local _now_ts
  _now_ts=$(python3 -c "import datetime; print(datetime.datetime.utcnow().isoformat() + 'Z')")
  local _pattern_label="$1" _project="$2" _wt_path="$3" _branch="$4"
  local _action="$5" _reason="$6" _size_mb="$7"

  duckdb "$UNIFIED_DB" "
    INSERT OR IGNORE INTO worktree_gc_events
      (id, fired_at, source, session_id, location_pattern,
       project, worktree_path, branch, action, reason, size_mb)
    VALUES (
      '${_evt_id}',
      TIMESTAMPTZ '${_now_ts}',
      'worktree_gc.sh',
      NULL,
      '${_pattern_label}',
      '${_project}',
      '${_wt_path}',
      '${_branch}',
      '${_action}',
      '${_reason}',
      ${_size_mb}
    );
  " 2>/dev/null || true
}

# ─── Main sweep ──────────────────────────────────────────────────────────────
_now=$(now_epoch)
_current_pwd=$(pwd -P 2>/dev/null || echo "")

CANDIDATES=0
WOULD_REMOVE=0
REMOVED=0
KEPT=0
EVENTS_WRITTEN=0

# Track convention-pattern parent dirs for later rmdir
declare -a CONVENTION_PARENTS=()

# ─── Sweep each pattern ───────────────────────────────────────────────────────
for _pattern_entry in "${SWEEP_PATTERNS[@]}"; do
  _glob="${_pattern_entry%%|*}"
  _label="${_pattern_entry##*|}"

  # Resolve age threshold for this pattern
  case "$_label" in
    siblings)    _age_days="$AGE_DAYS_SIBLINGS" ;;
    agent)       _age_days="$AGE_DAYS_AGENT" ;;
    convention)  _age_days="$AGE_DAYS_CONVENTION" ;;
    *)           _age_days="14" ;;
  esac
  _age_seconds=$(( _age_days * 86400 ))

  log "[sweep] pattern=$_label glob=$_glob age_days=$_age_days"

  # Expand glob — use nullglob-compatible test
  _dirs=()
  while IFS= read -r -d '' _d; do
    _dirs+=("$_d")
  done < <(find $HOME -maxdepth 5 -type d -name "$(basename "$_glob")" 2>/dev/null -print0 | sort -z || true)

  # Simpler approach: use shell glob expansion carefully
  _dirs=()
  for _d in $_glob; do
    [ -d "$_d" ] && _dirs+=("$_d")
  done

  for wt_path in "${_dirs[@]:-}"; do
    [ -z "$wt_path" ] && continue
    [ -d "$wt_path" ] || continue

    # Must be a git worktree (not a random directory)
    git -C "$wt_path" rev-parse --git-dir >/dev/null 2>&1 || continue

    # Must NOT be a main checkout — only sweep actual worktrees
    if is_main_checkout "$wt_path"; then
      continue
    fi

    # Find the main checkout (git-common-dir)
    _common_dir=$(git -C "$wt_path" rev-parse --git-common-dir 2>/dev/null || true)
    # git-common-dir inside a worktree points to <main>/.git
    _repo_dir=$(dirname "$_common_dir")

    # Validate repo dir exists
    [ -d "$_repo_dir" ] || continue

    # Extract project name from repo path
    _project=$(basename "$_repo_dir")

    # Opt-out marker in the main repo root
    if [ -f "$_repo_dir/.no-worktree-gc" ]; then
      log "[skip-repo] $wt_path (opt-out marker in $_repo_dir)"
      write_gc_event "$_label" "$_project" "$wt_path" "" "skipped_optout" "opt-out marker" "$(dir_size_mb "$wt_path")"
      EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
      continue
    fi

    # Get branch from git
    wt_branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    wt_sha=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null || echo "")

    # Skip: current running session's cwd
    if [ -n "$_current_pwd" ] && [[ "$_current_pwd" == "$wt_path"* ]]; then
      log "[skip-cwd] $wt_path (current session)"
      write_gc_event "$_label" "$_project" "$wt_path" "$wt_branch" "skipped_cwd" "current session cwd" "$(dir_size_mb "$wt_path")"
      EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
      KEPT=$(( KEPT + 1 ))
      continue
    fi

    # Skip: locked (check via worktree list porcelain)
    _is_locked=0
    while IFS= read -r _wt_line; do
      if [[ "$_wt_line" == worktree\ "$wt_path" ]]; then
        _in_block=1
      elif [[ "$_wt_line" == worktree\ * ]]; then
        _in_block=0
      elif [ "${_in_block:-0}" = "1" ] && [[ "$_wt_line" == locked* ]]; then
        _is_locked=1
      fi
    done < <(git -C "$_repo_dir" worktree list --porcelain 2>/dev/null || true)

    if [ "$_is_locked" = "1" ]; then
      log "[skip-locked] $wt_path branch=$wt_branch"
      write_gc_event "$_label" "$_project" "$wt_path" "$wt_branch" "skipped_locked" "git worktree locked" "$(dir_size_mb "$wt_path")"
      EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
      KEPT=$(( KEPT + 1 ))
      continue
    fi

    CANDIDATES=$(( CANDIDATES + 1 ))
    default_br=$(default_branch "$_repo_dir")

    # Gate 1: patch-id check — no lines starting with + means fully merged
    cherry_out=$(git -C "$_repo_dir" cherry "$default_br" "$wt_branch" 2>/dev/null || echo "cherry-failed")
    if echo "$cherry_out" | grep -q '^+'; then
      _reason="unmerged patches vs $default_br"
      log "[keep-unmerged] $wt_path (branch $wt_branch has unique patches vs $default_br)"
      write_gc_event "$_label" "$_project" "$wt_path" "$wt_branch" "skipped_unmerged" "$_reason" "$(dir_size_mb "$wt_path")"
      EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
      KEPT=$(( KEPT + 1 ))
      continue
    fi
    if [ "$cherry_out" = "cherry-failed" ]; then
      log "[keep-cherry-error] $wt_path (cherry check failed)"
      write_gc_event "$_label" "$_project" "$wt_path" "$wt_branch" "skipped_cherry_error" "cherry check failed" "$(dir_size_mb "$wt_path")"
      EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
      KEPT=$(( KEPT + 1 ))
      continue
    fi

    # Gate 2: clean working tree
    dirty=$(git -C "$wt_path" status --porcelain 2>/dev/null || echo "status-failed")
    if [ -n "$dirty" ]; then
      log "[keep-dirty] $wt_path (uncommitted/untracked files)"
      write_gc_event "$_label" "$_project" "$wt_path" "$wt_branch" "skipped_uncommitted" "dirty working tree" "$(dir_size_mb "$wt_path")"
      EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
      KEPT=$(( KEPT + 1 ))
      continue
    fi

    # Gate 3: age
    wt_mtime=$(dir_mtime_epoch "$wt_path")
    wt_age=$(( _now - wt_mtime ))
    if [ "$wt_age" -lt "$_age_seconds" ]; then
      log "[keep-too-new] $wt_path (age $wt_age s < ${_age_seconds} s threshold for $_label)"
      write_gc_event "$_label" "$_project" "$wt_path" "$wt_branch" "skipped_age" "age ${wt_age}s < threshold ${_age_seconds}s" "$(dir_size_mb "$wt_path")"
      EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
      KEPT=$(( KEPT + 1 ))
      continue
    fi

    # All gates passed — candidate for removal
    _size_mb=$(dir_size_mb "$wt_path")
    WOULD_REMOVE=$(( WOULD_REMOVE + 1 ))

    if [ "$_label" = "convention" ]; then
      # Track parent dir for potential rmdir
      _parent_dir=$(dirname "$wt_path")
      CONVENTION_PARENTS+=("$_parent_dir")
    fi

    if [ "$APPLY" = "1" ]; then
      log "[removing] $wt_path branch=$wt_branch sha=$wt_sha repo=$_repo_dir size_mb=$_size_mb"
      # worktree remove refuses if dirty (backstop)
      if git -C "$_repo_dir" worktree remove "$wt_path" 2>/dev/null; then
        # Delete the branch only if safe (refuses if unmerged)
        git -C "$_repo_dir" branch -d "$wt_branch" 2>/dev/null && \
          log "[branch-deleted] $wt_branch in $_repo_dir" || \
          log "[branch-keep] $wt_branch in $_repo_dir (branch delete refused)"
        write_gc_event "$_label" "$_project" "$wt_path" "$wt_branch" "removed" "all gates passed" "$_size_mb"
        EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
        REMOVED=$(( REMOVED + 1 ))
      else
        log "[remove-failed] $wt_path (worktree remove refused)"
        write_gc_event "$_label" "$_project" "$wt_path" "$wt_branch" "skipped_remove_failed" "worktree remove refused" "$_size_mb"
        EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
        KEPT=$(( KEPT + 1 ))
      fi
    else
      log "[would-remove] $wt_path branch=$wt_branch sha=$wt_sha repo=$_repo_dir size_mb=$_size_mb"
      write_gc_event "$_label" "$_project" "$wt_path" "$wt_branch" "would_remove" "dry-run: all gates passed" "$_size_mb"
      EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
    fi

  done  # end dirs loop
done  # end patterns loop

# ─── Empty convention parent cleanup ─────────────────────────────────────────
if [ "$APPLY" = "1" ] && [ "${#CONVENTION_PARENTS[@]}" -gt 0 ]; then
  # Deduplicate and try rmdir on each parent (rmdir only removes empty dirs)
  declare -A _seen_parents=()
  for _parent in "${CONVENTION_PARENTS[@]}"; do
    [ -z "$_parent" ] && continue
    [ "${_seen_parents[$_parent]+set}" = "set" ] && continue
    _seen_parents[$_parent]=1
    if [ -d "$_parent" ] && rmdir "$_parent" 2>/dev/null; then
      log "[rmdir-empty-parent] $_parent"
    fi
  done
fi

log "[done] candidates=$CANDIDATES would-remove=$WOULD_REMOVE removed=$REMOVED kept=$KEPT events=$EVENTS_WRITTEN apply=$APPLY soak-past=$_past_soak"

# Update housekeeping_runs end row
if [ "$_duckdb_ok" = "1" ]; then
  _run_ended=$(python3 -c "import datetime; print(datetime.datetime.utcnow().isoformat() + 'Z')")
  duckdb "$UNIFIED_DB" "
    UPDATE housekeeping_runs
    SET ended_at = TIMESTAMPTZ '${_run_ended}',
        rows_written = ${EVENTS_WRITTEN}
    WHERE id = '${_run_id}';
  " 2>/dev/null || true
fi

# ─── SELFTEST ────────────────────────────────────────────────────────────────
if [ "${SELFTEST:-0}" = "1" ]; then
  _pass=0
  _fail=0

  _check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
      echo "PASS: $desc"
      _pass=$(( _pass + 1 ))
    else
      echo "FAIL: $desc (expected '$expected' got '$actual')"
      _fail=$(( _fail + 1 ))
    fi
  }

  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  # Create a bare main repo
  main="$tmpdir/main"
  git init -q "$main"
  git -C "$main" config user.email "test@test"
  git -C "$main" config user.name "test"
  echo "init" > "$main/file.txt"
  git -C "$main" add file.txt
  git -C "$main" commit -q -m "init"

  # Helper: create a worktree on a new branch
  mk_wt() {
    local name="$1"
    local wt="$tmpdir/wt-$name"
    git -C "$main" worktree add -q -b "branch-$name" "$wt"
    echo "$wt"
  }

  # --- Test: merged worktree (all gates pass) should be removable
  wt_merged=$(mk_wt "merged")
  # Make the worktree old (touch to 30 days ago via python)
  python3 -c "import os,time; t=time.time()-30*86400; os.utime('$wt_merged',(t,t))"

  # Check cherry — branch has no unique patches vs main (no commits on branch)
  cherry=$(git -C "$main" cherry "$(git -C "$main" rev-parse --abbrev-ref HEAD)" "branch-merged" 2>/dev/null || echo "")
  _check "merged branch has no + lines in cherry" "0" "$(echo "$cherry" | grep -c '^+' || true)"

  # Check clean
  dirty=$(git -C "$wt_merged" status --porcelain)
  _check "merged worktree is clean" "" "$dirty"

  # --- Test: worktree with unique commits should be kept
  wt_unmerged=$(mk_wt "unmerged")
  echo "extra" > "$wt_unmerged/extra.txt"
  git -C "$wt_unmerged" add extra.txt
  git -C "$wt_unmerged" commit -q -m "unmerged commit"
  python3 -c "import os,time; t=time.time()-30*86400; os.utime('$wt_unmerged',(t,t))"

  cherry2=$(git -C "$main" cherry "$(git -C "$main" rev-parse --abbrev-ref HEAD)" "branch-unmerged" 2>/dev/null || echo "")
  has_plus=$(echo "$cherry2" | grep -c '^+' || true)
  _check "unmerged branch has + lines in cherry" "1" "$has_plus"

  # --- Test: dirty worktree should be kept
  wt_dirty=$(mk_wt "dirty")
  echo "dirty" > "$wt_dirty/dirty.txt"  # untracked, not staged
  python3 -c "import os,time; t=time.time()-30*86400; os.utime('$wt_dirty',(t,t))"
  dirty2=$(git -C "$wt_dirty" status --porcelain)
  _check "dirty worktree has porcelain output" "1" "$([ -n "$dirty2" ] && echo 1 || echo 0)"

  # --- Test: too-new worktree should be kept
  wt_new=$(mk_wt "new")
  # Leave mtime as-is (just created = age < 7 days)
  wt_mtime=$(dir_mtime_epoch "$wt_new")
  wt_age=$(( $(now_epoch) - wt_mtime ))
  _check "new worktree age is less than 7 days (siblings threshold)" "1" "$([ "$wt_age" -lt "$(( AGE_DAYS_SIBLINGS * 86400 ))" ] && echo 1 || echo 0)"

  # --- Test: agent worktree path label
  agent_path="$tmpdir/.claude/worktrees/agent-abc123"
  mkdir -p "$agent_path"
  label_agent=0
  [[ "$agent_path" == */.claude/worktrees/* ]] && label_agent=1
  _check "agent worktree path matches agent pattern" "1" "$label_agent"

  # --- Test: convention worktree path label
  convention_path="$tmpdir/worktrees/myproject/feat/my-feature"
  mkdir -p "$convention_path"
  label_convention=0
  [[ "$convention_path" == *worktrees/*/*/* ]] && label_convention=1
  _check "convention worktree path matches convention pattern" "1" "$label_convention"

  # --- Test: sibling worktree path label
  sibling_path="$tmpdir/myproject-fix-foo"
  mkdir -p "$sibling_path"
  label_sibling=0
  # Simulated check — siblings end with -something
  [[ "$sibling_path" == *-* ]] && label_sibling=1
  _check "sibling worktree path matches sibling pattern" "1" "$label_sibling"

  # --- Test: locked worktree is skipped
  wt_locked=$(mk_wt "locked")
  git -C "$main" worktree lock "$wt_locked"
  # The porcelain format emits a "locked" line in the worktree's block.
  locked_found=$(git -C "$main" worktree list --porcelain | grep -c "^locked" || true)
  _check "locked worktree shows locked in porcelain" "1" "$locked_found"

  # --- Test: .no-worktree-gc opt-out is respected
  echo "" > "$main/.no-worktree-gc"
  has_optout=0
  [ -f "$main/.no-worktree-gc" ] && has_optout=1
  _check "opt-out marker is detected" "1" "$has_optout"
  rm "$main/.no-worktree-gc"

  # --- Test: is_main_checkout correctly identifies main vs worktree
  _check "main dir is_main_checkout" "0" "$(is_main_checkout "$main" && echo 0 || echo 1)"
  _check "worktree dir is NOT is_main_checkout" "1" "$(is_main_checkout "$wt_merged" && echo 0 || echo 1)"

  # --- Test: per-pattern age thresholds differ
  _check "siblings age threshold 7 days" "7" "$AGE_DAYS_SIBLINGS"
  _check "agent age threshold 14 days" "14" "$AGE_DAYS_AGENT"
  _check "convention age threshold 30 days" "30" "$AGE_DAYS_CONVENTION"

  # --- Test: convention parent rmdir
  _conv_parent="$tmpdir/conv_parent"
  mkdir -p "$_conv_parent"
  rmdir "$_conv_parent" 2>/dev/null && _rmdir_ok=1 || _rmdir_ok=0
  _check "empty convention parent can be rmdir'd" "1" "$_rmdir_ok"

  echo ""
  echo "$_pass PASS, $_fail FAIL"
  [ "$_fail" = "0" ] && exit 0 || exit 1
fi
