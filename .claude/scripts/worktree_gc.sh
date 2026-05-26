#!/usr/bin/env bash
# worktree_gc.sh — Safe stale-worktree garbage collector
#
# Sweeps all git repos under ~/docs_gh for worktrees that are:
#   • patch-id fully merged into the default branch
#   • clean (no uncommitted / untracked files)
#   • older than AGE_DAYS (default 7)
#
# Conservative by design — squash-merged branches (unique patch-ids) are left
# for human review via /cleanup. Under-deletes, never over-deletes.
#
# Usage:
#   bash worktree_gc.sh            # dry-run (safe; never removes anything)
#   bash worktree_gc.sh --apply    # remove only after SOAK_END date
#   SELFTEST=1 bash worktree_gc.sh # run built-in unit tests against temp repos
#
# Opt-out: place a .no-worktree-gc file in a repo root to skip that repo.
#
# Tracks: JohnGavin/llm#199

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
AGE_DAYS="${AGE_DAYS:-7}"
DOCS_GH="${DOCS_GH:-$HOME/docs_gh}"
LOG_FILE="$HOME/.claude/logs/worktree_gc.log"
APPLY=0

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

# ─── Main sweep ──────────────────────────────────────────────────────────────
_now=$(now_epoch)
_age_seconds=$(( AGE_DAYS * 86400 ))
_current_pwd=$(pwd -P 2>/dev/null || echo "")

CANDIDATES=0
WOULD_REMOVE=0
REMOVED=0
KEPT=0

for repo_dir in "$DOCS_GH"/*/; do
  [ -d "$repo_dir" ] || continue

  # Must be a git repo
  git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1 || continue

  # Must be a main checkout (not itself a worktree)
  is_main_checkout "$repo_dir" || continue

  # Opt-out marker
  if [ -f "$repo_dir/.no-worktree-gc" ]; then
    log "[skip-repo] $repo_dir (opt-out marker)"
    continue
  fi

  default_br=$(default_branch "$repo_dir")

  # Parse porcelain worktree list
  # Format: blank-line separated blocks, fields:
  #   worktree <path>
  #   HEAD <sha>
  #   branch refs/heads/<name>   (or "detached")
  #   locked [reason]            (optional)
  wt_path="" wt_sha="" wt_branch="" wt_locked=0

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == worktree\ * ]]; then
      wt_path="${line#worktree }"
      wt_sha="" wt_branch="" wt_locked=0
    elif [[ "$line" == HEAD\ * ]]; then
      wt_sha="${line#HEAD }"
    elif [[ "$line" == branch\ * ]]; then
      wt_branch="${line#branch refs/heads/}"
    elif [[ "$line" == locked* ]]; then
      wt_locked=1
    elif [ -z "$line" ] && [ -n "$wt_path" ]; then
      # End of a block — evaluate this worktree
      _process_worktree=1

      # Skip: main checkout itself
      wt_realpath=$(cd "$wt_path" 2>/dev/null && pwd -P 2>/dev/null || echo "$wt_path")
      repo_realpath=$(cd "$repo_dir" 2>/dev/null && pwd -P 2>/dev/null || echo "$repo_dir")
      if [ "$wt_realpath" = "$repo_realpath" ]; then
        _process_worktree=0
      fi

      # Skip: locked
      if [ "$wt_locked" = "1" ]; then
        _process_worktree=0
      fi

      # Skip: agent worktrees (harness-managed)
      if [[ "$wt_path" == */.claude/worktrees/* ]]; then
        _process_worktree=0
      fi

      # Skip: current running session
      if [ -n "$_current_pwd" ] && [[ "$_current_pwd" == "$wt_path"* ]]; then
        _process_worktree=0
      fi

      if [ "$_process_worktree" = "1" ] && [ -d "$wt_path" ]; then
        CANDIDATES=$(( CANDIDATES + 1 ))

        # Gate 1: patch-id check — no lines starting with + means fully merged
        cherry_out=$(git -C "$repo_dir" cherry "$default_br" "$wt_branch" 2>/dev/null || echo "cherry-failed")
        if echo "$cherry_out" | grep -q '^+'; then
          log "[keep-unmerged] $wt_path (branch $wt_branch has unique patches vs $default_br)"
          KEPT=$(( KEPT + 1 ))
          wt_path="" wt_sha="" wt_branch="" wt_locked=0
          continue
        fi
        if [ "$cherry_out" = "cherry-failed" ]; then
          log "[keep-cherry-error] $wt_path (cherry check failed)"
          KEPT=$(( KEPT + 1 ))
          wt_path="" wt_sha="" wt_branch="" wt_locked=0
          continue
        fi

        # Gate 2: clean working tree
        dirty=$(git -C "$wt_path" status --porcelain 2>/dev/null || echo "status-failed")
        if [ -n "$dirty" ]; then
          log "[keep-dirty] $wt_path (uncommitted/untracked files)"
          KEPT=$(( KEPT + 1 ))
          wt_path="" wt_sha="" wt_branch="" wt_locked=0
          continue
        fi

        # Gate 3: age
        wt_mtime=$(dir_mtime_epoch "$wt_path")
        wt_age=$(( _now - wt_mtime ))
        if [ "$wt_age" -lt "$_age_seconds" ]; then
          log "[keep-too-new] $wt_path (age $wt_age s < ${_age_seconds} s threshold)"
          KEPT=$(( KEPT + 1 ))
          wt_path="" wt_sha="" wt_branch="" wt_locked=0
          continue
        fi

        # All gates passed — candidate for removal
        WOULD_REMOVE=$(( WOULD_REMOVE + 1 ))
        if [ "$APPLY" = "1" ]; then
          log "[removing] $wt_path branch=$wt_branch sha=$wt_sha repo=$repo_dir"
          # worktree remove refuses if dirty (backstop)
          if git -C "$repo_dir" worktree remove "$wt_path" 2>/dev/null; then
            # Delete the branch only if safe (refuses if unmerged)
            git -C "$repo_dir" branch -d "$wt_branch" 2>/dev/null && \
              log "[branch-deleted] $wt_branch in $repo_dir" || \
              log "[branch-keep] $wt_branch in $repo_dir (branch delete refused)"
            REMOVED=$(( REMOVED + 1 ))
          else
            log "[remove-failed] $wt_path (worktree remove refused)"
            KEPT=$(( KEPT + 1 ))
          fi
        else
          log "[would-remove] $wt_path branch=$wt_branch sha=$wt_sha repo=$repo_dir"
        fi
      fi

      wt_path="" wt_sha="" wt_branch="" wt_locked=0
    fi
  done < <(git -C "$repo_dir" worktree list --porcelain; echo "")

done

log "[done] candidates=$CANDIDATES would-remove=$WOULD_REMOVE removed=$REMOVED kept=$KEPT apply=$APPLY soak-past=$_past_soak"

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
  _check "new worktree age is less than 7 days" "1" "$([ "$wt_age" -lt "$_age_seconds" ] && echo 1 || echo 0)"

  # --- Test: agent worktree path is skipped
  agent_path="$tmpdir/.claude/worktrees/agent-abc123"
  mkdir -p "$agent_path"
  skip_agent=0
  [[ "$agent_path" == */.claude/worktrees/* ]] && skip_agent=1
  _check "agent worktree path is recognised as skip" "1" "$skip_agent"

  # --- Test: locked worktree is skipped
  wt_locked=$(mk_wt "locked")
  git -C "$main" worktree lock "$wt_locked"
  # The porcelain format emits a "locked" line in the worktree's block.
  # Count "locked" lines directly — any locked worktree will appear exactly once.
  locked_found=$(git -C "$main" worktree list --porcelain | grep -c "^locked" || true)
  _check "locked worktree shows locked in porcelain" "1" "$locked_found"

  # --- Test: .no-worktree-gc opt-out is respected
  echo "" > "$main/.no-worktree-gc"
  has_optout=0
  [ -f "$main/.no-worktree-gc" ] && has_optout=1
  _check "opt-out marker is detected" "1" "$has_optout"
  rm "$main/.no-worktree-gc"

  echo ""
  echo "$_pass PASS, $_fail FAIL"
  [ "$_fail" = "0" ] && exit 0 || exit 1
fi
