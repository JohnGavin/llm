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
# Squash-merged branches (unique patch-ids, invisible to `git cherry`) are
# ALSO eligible for removal (llm#820) once a merged GitHub PR is confirmed for
# the branch AND the same clean + age-eligible + not-locked/not-cwd guards
# pass. The branch tip is archived to refs/gc-archive/<branch> before any
# destructive git call, so it stays recoverable after removal. Disable this
# path with SQUASH_REMOVE_DISABLE=1 (falls back to would_remove_squash
# reporting only, never removing). Under-deletes, never over-deletes.
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

# ─── Sentinel sweep + log rotation helpers (JohnGavin/llm#884 steps 2-3) ─────
# Pure functions, sourced rather than duplicated so tests can exercise them
# directly against a fixture directory. sweep_stale_sentinels()/rotate_logs()
# defined there are called near the end of this script's main flow, gated on
# the SAME --apply flag as worktree removal (see APPLY below).
_gc_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -f "${_gc_script_dir}/sentinel_log_sweep.sh" ]; then
  # shellcheck source=./sentinel_log_sweep.sh
  source "${_gc_script_dir}/sentinel_log_sweep.sh"
fi

# ─── Timeout wrapper (macOS lacks GNU `timeout` by default) ─────────────────
# Used by is_squash_merged() to bound the `gh pr list` network call. Prefers
# GNU timeout, falls back to homebrew coreutils' gtimeout, falls back to no
# wrapper at all (gh calls are still guarded by `|| true` so a hang is the
# only residual risk, not a crash — see is_squash_merged() below).
_gc_timeout_bin=""
if command -v timeout >/dev/null 2>&1; then
  _gc_timeout_bin="timeout 15"
elif command -v gtimeout >/dev/null 2>&1; then
  _gc_timeout_bin="gtimeout 15"
fi

# ─── Soak gate ───────────────────────────────────────────────────────────────
# Dry-run only until this date (7 days after first commit).
# After SOAK_END, --apply actually removes. Before it, --apply is silently
# ignored and everything is treated as dry-run. Mirrors the soak pattern in
# ~/.claude/hooks/agent_push_guard.sh.
SOAK_END="2026-06-02"

# ─── Squash-merge detection + conservative live removal (llm#820) ───────────
# `git cherry` (patch-id based, see Gate 1 below) cannot see squash-merges —
# the squash commit's patch-id never matches any commit on the branch — so
# squash-merged worktrees used to pile up forever as `skipped_unmerged`. This
# adds a best-effort check: if a worktree's branch has a merged GitHub PR, it
# is logged as `would_remove_squash` for visibility, AND — live removal is
# NOW ACTIVE — the worktree is actually removed once it is ALSO clean, old
# enough for its location pattern, not locked, and not the current cwd. The
# branch tip is archived to refs/gc-archive/<branch> via `git update-ref`
# BEFORE the worktree/branch are deleted, so the pre-squash history is always
# recoverable. Set SQUASH_REMOVE_DISABLE=1 to fall back to detection/reporting
# only (no removal) if this path needs to be paused.
SQUASH_DETECT_ENABLED="${SQUASH_DETECT_ENABLED:-1}"
SQUASH_REMOVE_DISABLE="${SQUASH_REMOVE_DISABLE:-0}"
SQUASH_SOAK_END="2026-08-25"

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

# ─── Sentinel sweep + log rotation config (JohnGavin/llm#884) ───────────────
CLAUDE_RUNTIME_ROOT="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude}"
SENTINEL_AGE_DAYS="${SENTINEL_AGE_DAYS:-7}"
LOG_ROTATE_THRESHOLD_BYTES="${LOG_ROTATE_THRESHOLD_BYTES:-10485760}"  # 10 MB
LOG_ROTATE_KEEP_LINES="${LOG_ROTATE_KEEP_LINES:-2000}"

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
# Informational only — squash-merge detection never deletes regardless of
# this value (see the SQUASH_DETECT_ENABLED comment block above).
_squash_past_soak=$(python3 -c "print('yes' if '${_today}' >= '${SQUASH_SOAK_END}' else 'no')")

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

# ─── Helper: squash-merge detection (llm#820, llm#1019) — DETECTION ONLY ─────
# Prints a merged PR number to stdout if the given branch has a merged GitHub
# PR (i.e. was very likely squash-merged, which `git cherry` cannot detect
# because the squash commit's patch-id differs from every commit on the
# branch).
#
# RETURN CONTRACT (llm#1019 — the whole point of this function's shape):
#   0  the question was asked and answered.
#      stdout = PR number  → squash-merged
#      stdout = empty      → genuinely no merged PR for this branch
#   2  the question could NOT be asked. stdout carries the REASON in place of
#      the answer. The caller MUST count this separately and MUST NOT read it
#      as "not merged".
#
# Reason-on-stdout rather than a global: this is called as
# `_squash_pr=$(is_squash_merged ...)`, i.e. inside a command-substitution
# subshell, so any variable it assigns dies with that subshell. The first
# end-to-end run of this fix logged `retaining: unknown` for every branch for
# exactly that reason. The caller only reads stdout as a reason when rc=2,
# when there is no PR number to confuse it with.
#
# Before llm#1019 both outcomes were `return 0` with empty stdout. A revoked
# GH_TOKEN in the environment made every `gh pr list` exit 401, which the
# caller read as "no merged PR exists", so every squash-merged worktree was
# retained. Same command, same branch, two environments:
#
#   $ gh pr list ... --head worktree-agent-a09dab3b15c650366
#   HTTP 401: Bad credentials
#   $ env -u GH_TOKEN gh pr list ...
#   [{"mergedAt":"2026-08-23T07:13:16Z","number":1006}]
#
# would-remove-squash across the whole sweep: 0 with the poisoned token, 42
# without it. 42 provably merged worktrees, each retained at ~16 MB, growing
# without bound. That is the ~5 GB footprint.
#
# Note which cases are genuine NEGATIVES and stay `return 0`: no remote, or a
# remote that is not a parseable GitHub slug. A repo with no GitHub remote
# cannot have a merged GitHub PR, so "no" really is the answer, not a failure
# to ask. Only an inability to reach GitHub is indeterminate.
#
# Never fails the caller's `set -e`: callers use `|| _rc=$?`.
SQUASH_DETECT_WHY=""

# Last line of defence before anything derived from a remote URL or a tool's
# stderr reaches the log. The slug parse above already strips the common
# `user:pass@host` form; this catches whatever shape it does not anticipate,
# because a guard that only handles the case you already found is not a guard.
redact_credentials() {
  printf '%s' "$1" | sed -E \
    -e 's#(://)[^/@[:space:]]*@#\1<REDACTED>@#g' \
    -e 's#(gh[pousr]_)[A-Za-z0-9]{16,}#\1<REDACTED>#g' \
    -e 's#(github_pat_)[A-Za-z0-9_]{16,}#\1<REDACTED>#g'
}

is_squash_merged() {
  local _repo="$1" _branch="$2"

  if ! command -v gh >/dev/null 2>&1; then
    printf '%s' "gh not on PATH"
    return 2
  fi

  # `git config --get` exits 1 when the key is simply absent (a genuine "no
  # remote"), and >1 on a real failure (unreadable/corrupt config). Only the
  # latter is indeterminate.
  local _remote_url _git_rc=0
  _remote_url=$(git -C "$_repo" config --get remote.origin.url 2>/dev/null) || _git_rc=$?
  if [ "$_git_rc" -gt 1 ]; then
    printf '%s' "git config --get remote.origin.url failed (rc=$_git_rc)"
    return 2
  fi
  [ -z "$_remote_url" ] && return 0     # no remote → no GitHub PR. A real "no".

  # Strip any embedded credential BEFORE parsing. A remote of the form
  #   https://x-access-token:<token>@github.com/OWNER/REPO
  # is written by some CI/auth flows and is present on at least one repo here.
  # Two consequences, both fixed by this line:
  #   1. the old sed matched neither prefix, so the slug came out as the whole
  #      URL and `gh pr list -R <url>` could never work — squash detection was
  #      silently broken for that repo on top of the token problem;
  #   2. the reason string built below is LOGGED, so the token went into
  #      ~/.claude/logs/worktree_gc.log in plaintext. Observed for real on the
  #      first full run of this fix.
  local _slug
  _slug=$(printf '%s' "$_remote_url" \
            | sed -E 's#^[a-z+]+://[^/@]*@#https://#; s#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')
  [[ "$_slug" == */* ]] || return 0     # not a GitHub slug → a real "no".

  local _pr_json _gh_rc=0
  _pr_json=$($_gc_timeout_bin gh pr list -R "$_slug" --state merged --head "$_branch" \
               --json number,mergedAt --limit 1 2>&1) || _gh_rc=$?
  if [ "$_gh_rc" -ne 0 ]; then
    # 124 is `timeout`'s kill code; anything else is gh itself (auth, network,
    # rate limit). All are "could not ask", none are "not merged".
    local _gh_err _safe_slug
    _gh_err=$(redact_credentials "$(printf '%s' "$_pr_json" | tr '\n' ' ' | cut -c1-120)")
    _safe_slug=$(redact_credentials "$_slug")
    printf '%s' "gh pr list -R $_safe_slug --head $_branch failed (rc=$_gh_rc): $_gh_err"
    return 2
  fi
  [ -z "$_pr_json" ] && return 0        # gh answered with nothing → a real "no".

  # A payload that will not parse is also a failure to answer, not a "no".
  local _num _py_rc=0
  _num=$(printf '%s' "$_pr_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data[0].get('number', '') if data else '')
" 2>&1) || _py_rc=$?
  if [ "$_py_rc" -ne 0 ]; then
    local _py_err
    _py_err=$(redact_credentials "$(printf '%s' "$_num" | tr '\n' ' ' | cut -c1-120)")
    printf '%s' "could not parse gh output for $_branch: $_py_err"
    return 2
  fi

  printf '%s' "$_num"
  return 0
}

# ─── Preflight: can squash detection ask GitHub at all? (llm#1019) ───────────
# Runs ONCE at sweep start rather than per-worktree, so a broken credential
# produces one clear line instead of N identical ones — and, critically, so it
# appears even when the sweep finds no candidates at all. Advisory: it never
# disables detection or changes removal behaviour. Its only job is to make
# "the GC is retaining everything because it cannot reach GitHub" visible
# instead of looking like normal operation.
squash_detect_preflight() {
  if ! command -v gh >/dev/null 2>&1; then
    SQUASH_DETECT_PREFLIGHT="unavailable"
    log "[squash-detect-preflight] unavailable: gh not on PATH — squash-merged worktrees CANNOT be detected and will all be retained"
    return 0
  fi
  local _out _rc=0
  _out=$($_gc_timeout_bin gh auth status 2>&1) || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    SQUASH_DETECT_PREFLIGHT="unavailable"
    local _auth_err
    _auth_err=$(redact_credentials "$(printf '%s' "$_out" | tr '\n' ' ' | cut -c1-120)")
    log "[squash-detect-preflight] unavailable: gh auth status rc=$_rc ($_auth_err) — squash-merged worktrees CANNOT be detected and will all be retained"
    return 0
  fi
  SQUASH_DETECT_PREFLIGHT="ok"
  log "[squash-detect-preflight] ok"
  return 0
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
WOULD_REMOVE_SQUASH=0
REMOVED=0
REMOVED_SQUASH=0
KEPT=0
EVENTS_WRITTEN=0

# llm#1019 — `would-remove-squash=0` used to mean BOTH "nothing to remove" and
# "I could not check". These two counters split them apart, so the summary line
# can no longer report a confident zero it has not earned.
SQUASH_DETECT_FAILURES=0
SQUASH_DETECT_PREFLIGHT="unknown"

squash_detect_preflight

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

      # ─── Squash-merge detection + conservative removal (llm#820) ─────────
      # git cherry cannot see squash-merges. Before accepting the unmerged
      # verdict as final, check whether GitHub shows a merged PR for this
      # branch. If so, log a would_remove_squash event so it's always visible
      # — then, unless SQUASH_REMOVE_DISABLE=1, ALSO require the worktree to
      # be clean and age-eligible (same thresholds as Gates 2/3 below) before
      # actually removing it. Dry-run (APPLY=0) never removes anything here —
      # see the `[ "$APPLY" = "1" ]` guard below — so `--dry-run` still only
      # reports would_remove_squash, exactly as before this change.
      if [ "${SQUASH_DETECT_ENABLED}" = "1" ]; then
        # rc=2 means detection was UNAVAILABLE, not that the branch is
        # unmerged. Still fail-safe (the worktree is retained either way) —
        # but loudly, so a credential problem is visible as a credential
        # problem instead of as a sweep that found nothing (llm#1019).
        _squash_rc=0
        _squash_pr=$(is_squash_merged "$_repo_dir" "$wt_branch") || _squash_rc=$?
        if [ "$_squash_rc" -eq 2 ]; then
          SQUASH_DETECT_WHY="$_squash_pr"   # on rc=2 stdout carries the reason
          SQUASH_DETECT_FAILURES=$(( SQUASH_DETECT_FAILURES + 1 ))
          log "[squash-detect-unavailable] $wt_path branch=$wt_branch repo=$_repo_dir — classification degraded, retaining: ${SQUASH_DETECT_WHY:-unknown}"
          _squash_pr=""
        fi
        if [ -n "$_squash_pr" ]; then
          _squash_size_mb=$(dir_size_mb "$wt_path")
          _squash_reason="squash-merged via PR #${_squash_pr} in $_repo_dir"
          log "[would-remove-squash] $wt_path branch=$wt_branch pr=#${_squash_pr} repo=$_repo_dir size_mb=$_squash_size_mb"
          write_gc_event "$_label" "$_project" "$wt_path" "$wt_branch" "would_remove_squash" "$_squash_reason" "$_squash_size_mb"
          EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
          WOULD_REMOVE_SQUASH=$(( WOULD_REMOVE_SQUASH + 1 ))

          if [ "${SQUASH_REMOVE_DISABLE}" != "1" ]; then
            _squash_dirty=$(git -C "$wt_path" status --porcelain 2>/dev/null || echo "status-failed")
            _squash_mtime=$(dir_mtime_epoch "$wt_path")
            _squash_age=$(( _now - _squash_mtime ))

            if [ -z "$_squash_dirty" ] && [ "$_squash_age" -ge "$_age_seconds" ] && [ "$APPLY" = "1" ]; then
              # Capture rc rather than swallowing it: this decides whether a
              # worktree is about to be deleted, so "rev-parse failed" and
              # "rev-parse printed nothing" both abort the removal AND say
              # which happened. Behaviour was already fail-safe; llm#1019 adds
              # the reason to the log line.
              _tip_rc=0
              _tip_sha=$(git -C "$_repo_dir" rev-parse "$wt_branch" 2>&1) || _tip_rc=$?
              if [ "$_tip_rc" -ne 0 ] || [ -z "$_tip_sha" ]; then
                _tip_err=$(printf '%s' "$_tip_sha" | tr '\n' ' ' | cut -c1-100)
                log "[skip-squash-remove-failed] $wt_path (could not resolve branch tip sha: rc=$_tip_rc $_tip_err)"
                write_gc_event "$_label" "$_project" "$wt_path" "$wt_branch" "skipped_remove_failed" "squash removal: could not resolve tip sha" "$_squash_size_mb"
                EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
                KEPT=$(( KEPT + 1 ))
                continue
              fi

              _archive_ref="refs/gc-archive/${wt_branch}"
              if ! git -C "$_repo_dir" update-ref "$_archive_ref" "$_tip_sha" 2>/dev/null; then
                log "[skip-squash-remove-failed] $wt_path (could not archive tip to $_archive_ref — aborting removal)"
                write_gc_event "$_label" "$_project" "$wt_path" "$wt_branch" "skipped_remove_failed" "squash removal: archive update-ref failed" "$_squash_size_mb"
                EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
                KEPT=$(( KEPT + 1 ))
                continue
              fi

              log "[removing-squash] $wt_path branch=$wt_branch sha=$_tip_sha pr=#${_squash_pr} repo=$_repo_dir size_mb=$_squash_size_mb archive=$_archive_ref"
              if git -C "$_repo_dir" worktree remove "$wt_path" 2>/dev/null; then
                git -C "$_repo_dir" branch -D "$wt_branch" 2>/dev/null && \
                  log "[branch-deleted-squash] $wt_branch in $_repo_dir (archived at $_archive_ref)" || \
                  log "[branch-keep] $wt_branch in $_repo_dir (force-delete failed after worktree removal)"
                write_gc_event "$_label" "$_project" "$wt_path" "$wt_branch" "removed_squash" "squash-merged via PR #${_squash_pr}; archived at $_archive_ref" "$_squash_size_mb"
                EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
                REMOVED_SQUASH=$(( REMOVED_SQUASH + 1 ))
                continue
              else
                log "[remove-squash-failed] $wt_path (worktree remove refused)"
                write_gc_event "$_label" "$_project" "$wt_path" "$wt_branch" "skipped_remove_failed" "squash removal: worktree remove refused" "$_squash_size_mb"
                EVENTS_WRITTEN=$(( EVENTS_WRITTEN + 1 ))
                KEPT=$(( KEPT + 1 ))
                continue
              fi
            fi
          fi
        fi
      fi

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

# ─── Sentinel sweep + log rotation (JohnGavin/llm#884 steps 2-3) ─────────────
# Gated on the same --apply flag as worktree removal: dry-run by default (so
# manual/test invocations of this script never mutate ~/.claude/), the real
# sweep/rotation only runs when --apply is passed (the launchd job always
# passes --apply — see bin/launchd-recorders/worktree-gc).
SENTINELS_SWEPT=0
LOGS_ROTATED=0
if [ "$APPLY" = "1" ]; then
  sweep_stale_sentinels "$CLAUDE_RUNTIME_ROOT" "$SENTINEL_AGE_DAYS" 0 || true
  log "[sentinel-sweep] dir=$CLAUDE_RUNTIME_ROOT age_days=$SENTINEL_AGE_DAYS swept=$SENTINELS_SWEPT"
  rotate_logs "$CLAUDE_RUNTIME_ROOT/logs" "$LOG_ROTATE_THRESHOLD_BYTES" "$LOG_ROTATE_KEEP_LINES" 0 log || true
  log "[log-rotate] dir=$CLAUDE_RUNTIME_ROOT/logs threshold_bytes=$LOG_ROTATE_THRESHOLD_BYTES keep_lines=$LOG_ROTATE_KEEP_LINES rotated=$LOGS_ROTATED"
else
  sweep_stale_sentinels "$CLAUDE_RUNTIME_ROOT" "$SENTINEL_AGE_DAYS" 1 || true
  log "[sentinel-sweep-dryrun] dir=$CLAUDE_RUNTIME_ROOT age_days=$SENTINEL_AGE_DAYS would_sweep=$SENTINELS_SWEPT"
  rotate_logs "$CLAUDE_RUNTIME_ROOT/logs" "$LOG_ROTATE_THRESHOLD_BYTES" "$LOG_ROTATE_KEEP_LINES" 1 log || true
  log "[log-rotate-dryrun] dir=$CLAUDE_RUNTIME_ROOT/logs threshold_bytes=$LOG_ROTATE_THRESHOLD_BYTES keep_lines=$LOG_ROTATE_KEEP_LINES would_rotate=$LOGS_ROTATED"
fi

log "[done] candidates=$CANDIDATES would-remove=$WOULD_REMOVE would-remove-squash=$WOULD_REMOVE_SQUASH squash-detect=$SQUASH_DETECT_PREFLIGHT squash-detect-failures=$SQUASH_DETECT_FAILURES removed=$REMOVED removed-squash=$REMOVED_SQUASH kept=$KEPT events=$EVENTS_WRITTEN apply=$APPLY soak-past=$_past_soak squash-soak-past=$_squash_past_soak sentinels-swept=$SENTINELS_SWEPT logs-rotated=$LOGS_ROTATED"

# One loud line when squash detection could not run. Without it, a sweep that
# checked nothing looks identical in the log to a sweep that found nothing —
# which is how ~5 GB accumulated unnoticed (llm#1019).
if [ "$SQUASH_DETECT_PREFLIGHT" != "ok" ] || [ "$SQUASH_DETECT_FAILURES" -gt 0 ]; then
  log "[squash-detect-degraded] preflight=$SQUASH_DETECT_PREFLIGHT per-branch-failures=$SQUASH_DETECT_FAILURES — would-remove-squash=$WOULD_REMOVE_SQUASH is a FLOOR, not a count. Squash-merged worktrees are being retained because GitHub could not be asked, not because none exist. Check: gh auth status (a stale GH_TOKEN shadows the keyring credential — try env -u GH_TOKEN)."
fi

# Stamp for cron_catchup.sh catch-up detection
mkdir -p "${HOME}/.claude/logs/stamps"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.claude/logs/stamps/worktree-gc.stamp"

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

  # --- Tests: sweep_stale_sentinels (JohnGavin/llm#884 Finding 2) ────────────
  if command -v sweep_stale_sentinels >/dev/null 2>&1; then
    _sentinel_dir="$tmpdir/sentinels"
    mkdir -p "$_sentinel_dir"
    touch -t 202601010000 "$_sentinel_dir/.session_start_sha_old_proj"
    touch -t 202601010000 "$_sentinel_dir/.bye-requested.oldsid"
    touch -t 202601010000 "$_sentinel_dir/.bye-session-end-refine.oldsid"
    touch "$_sentinel_dir/.session_start_sha_new_proj"
    touch "$_sentinel_dir/.bye-requested"

    sweep_stale_sentinels "$_sentinel_dir" 7 1
    _check "sentinel dry-run counts 3 stale files" "3" "$SENTINELS_SWEPT"
    _check "sentinel dry-run leaves all 5 files in place" "5" "$(ls -A "$_sentinel_dir" | wc -l | tr -d '[:space:]')"

    sweep_stale_sentinels "$_sentinel_dir" 7 0
    _check "sentinel real sweep removes 3 stale files" "3" "$SENTINELS_SWEPT"
    _check "sentinel real sweep leaves the 2 fresh files" "2" "$(ls -A "$_sentinel_dir" | wc -l | tr -d '[:space:]')"

    sweep_stale_sentinels "$tmpdir/does_not_exist" 7 0
    _check "sentinel sweep on missing dir is a silent no-op" "0" "$SENTINELS_SWEPT"

    mkdir -p "$tmpdir/empty_sentinels"
    sweep_stale_sentinels "$tmpdir/empty_sentinels" 7 0
    _check "sentinel sweep on empty dir is a no-op" "0" "$SENTINELS_SWEPT"
  else
    echo "SKIP: sweep_stale_sentinels not sourced (sentinel_log_sweep.sh missing?)"
  fi

  # --- Tests: rotate_log_file / rotate_logs (JohnGavin/llm#884 Finding 3) ────
  if command -v rotate_logs >/dev/null 2>&1; then
    _logs_dir="$tmpdir/logs"
    mkdir -p "$_logs_dir"
    python3 -c "
for i in range(3000):
    print('line %d ' % i + 'x' * 50)
" > "$_logs_dir/big.log"
    echo "small" > "$_logs_dir/small.log"
    python3 -c "
for i in range(3000):
    print('line %d ' % i + 'x' * 50)
" > "$_logs_dir/unified.duckdb"

    _rot_thresh=10000
    _rot_keep=10

    rotate_logs "$_logs_dir" "$_rot_thresh" "$_rot_keep" 1
    _check "log-rotate dry-run counts 1 oversized file" "1" "$LOGS_ROTATED"
    _check "log-rotate dry-run leaves big.log untouched" "3000" "$(wc -l < "$_logs_dir/big.log" | tr -d '[:space:]')"
    _check "log-rotate dry-run never touches .duckdb" "3000" "$(wc -l < "$_logs_dir/unified.duckdb" | tr -d '[:space:]')"

    rotate_logs "$_logs_dir" "$_rot_thresh" "$_rot_keep" 0
    _check "log-rotate real run rotates 1 file" "1" "$LOGS_ROTATED"
    _check "log-rotate truncates big.log to keep_lines" "10" "$(wc -l < "$_logs_dir/big.log" | tr -d '[:space:]')"
    _check "log-rotate keeps exactly one .1 generation with full prior content" "3000" "$(wc -l < "$_logs_dir/big.log.1" | tr -d '[:space:]')"
    _check "log-rotate leaves small.log under threshold untouched" "1" "$(wc -l < "$_logs_dir/small.log" | tr -d '[:space:]')"
    _check "log-rotate NEVER touches .duckdb files" "3000" "$(wc -l < "$_logs_dir/unified.duckdb" | tr -d '[:space:]')"
    _check "log-rotate never creates a .duckdb.1 generation" "0" "$([ -f "$_logs_dir/unified.duckdb.1" ] && echo 1 || echo 0)"

    rotate_logs "$_logs_dir" "$_rot_thresh" "$_rot_keep" 0
    _check "log-rotate is idempotent (second run is a no-op)" "0" "$LOGS_ROTATED"

    mkdir -p "$tmpdir/empty_logs"
    rotate_logs "$tmpdir/empty_logs" "$_rot_thresh" "$_rot_keep" 0
    _check "log-rotate on empty dir is a no-op" "0" "$LOGS_ROTATED"

    rotate_logs "$tmpdir/does_not_exist_logs" "$_rot_thresh" "$_rot_keep" 0
    _check "log-rotate on missing dir is a silent no-op" "0" "$LOGS_ROTATED"
  else
    echo "SKIP: rotate_logs not sourced (sentinel_log_sweep.sh missing?)"
  fi

  # --- Tests: is_squash_merged distinguishes "no" from "could not ask" (llm#1019)
  #
  # The bug these cover: a revoked GH_TOKEN made every `gh pr list` exit 401,
  # is_squash_merged returned empty, and the caller read empty as "this branch
  # is not merged". 42 squash-merged worktrees were retained indefinitely.
  # An error path and a negative-result path must not share an exit.
  #
  # Note what is asserted alongside every rc: that a REAL negative still comes
  # back as rc=0. Tests that only check "failure gives rc=2" would also pass if
  # the function returned 2 unconditionally, which would disable removal
  # entirely — a different bug wearing the same green tick.
  _sq_bin="$tmpdir/sqbin"
  mkdir -p "$_sq_bin"

  # A git repo with a GitHub remote, so the slug parses.
  _sq_repo="$tmpdir/sqrepo"
  git init -q "$_sq_repo"
  git -C "$_sq_repo" remote add origin "git@github.com:JohnGavin/fake.git"

  # (1) gh absent → INDETERMINATE (rc=2), with a reason on stdout.
  _sq_out=$(PATH="$_sq_bin" is_squash_merged "$_sq_repo" "some-branch") && _sq_rc=0 || _sq_rc=$?
  _check "squash-detect: gh absent returns rc=2 (not a negative)" "2" "$_sq_rc"
  _check "squash-detect: gh absent gives a non-empty reason" "1" "$([ -n "$_sq_out" ] && echo 1 || echo 0)"

  # (2) gh present but failing the way a revoked token does → rc=2, and the
  #     reason must carry gh's own text so the cause is identifiable.
  cat > "$_sq_bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" >&2
exit 1
GHEOF
  chmod +x "$_sq_bin/gh"
  _sq_out=$(PATH="$_sq_bin:$PATH" is_squash_merged "$_sq_repo" "some-branch") && _sq_rc=0 || _sq_rc=$?
  _check "squash-detect: gh 401 returns rc=2 (not 'unmerged')" "2" "$_sq_rc"
  _check "squash-detect: gh 401 reason names the credential failure" "1" \
    "$(case "$_sq_out" in (*"401"*) echo 1 ;; (*) echo 0 ;; esac)"

  # (3) gh answering with an empty list → a REAL negative: rc=0, empty stdout.
  cat > "$_sq_bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "[]"
GHEOF
  chmod +x "$_sq_bin/gh"
  _sq_out=$(PATH="$_sq_bin:$PATH" is_squash_merged "$_sq_repo" "some-branch") && _sq_rc=0 || _sq_rc=$?
  _check "squash-detect: empty PR list is rc=0 (a real 'no')" "0" "$_sq_rc"
  _check "squash-detect: empty PR list prints nothing" "" "$_sq_out"

  # (4) gh finding a merged PR → rc=0 and the PR number.
  cat > "$_sq_bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo '[{"mergedAt":"2026-08-23T07:13:16Z","number":1006}]'
GHEOF
  chmod +x "$_sq_bin/gh"
  _sq_out=$(PATH="$_sq_bin:$PATH" is_squash_merged "$_sq_repo" "some-branch") && _sq_rc=0 || _sq_rc=$?
  _check "squash-detect: merged PR is rc=0" "0" "$_sq_rc"
  _check "squash-detect: merged PR number is returned" "1006" "$_sq_out"

  # (5) unparseable payload is a failure to answer, not a 'no'.
  cat > "$_sq_bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo 'not json at all'
GHEOF
  chmod +x "$_sq_bin/gh"
  _sq_out=$(PATH="$_sq_bin:$PATH" is_squash_merged "$_sq_repo" "some-branch") && _sq_rc=0 || _sq_rc=$?
  _check "squash-detect: unparseable gh output is rc=2, not a 'no'" "2" "$_sq_rc"

  # (5b) a remote with an embedded credential must produce a usable slug AND
  #      must never put the credential in a log line. Found the hard way: the
  #      first full run of this fix wrote a live GitHub token into
  #      worktree_gc.log, because the old slug parse handled neither the
  #      `https://user:pass@host/` form nor redaction. The embedded credential
  #      also meant the slug was the entire URL, so squash detection had never
  #      worked for that repo at all -- two bugs, one line.
  #
  #      The fixture token is built by concatenation so this file never
  #      contains a literal token-shaped string; secret_leak_guard cannot tell
  #      a fixture from the real thing, and it is right not to try.
  _fake_tok="ghp""_AAAABBBBCCCCDDDDEEEEFFFF00001111"
  _sq_credrepo="$tmpdir/sqcredrepo"
  git init -q "$_sq_credrepo"
  git -C "$_sq_credrepo" remote add origin \
    "https://x-access-token:${_fake_tok}@github.com/JohnGavin/fake.git"

  # gh echoes back the -R VALUE it was handed, so the test asserts which slug
  # actually reached it rather than inferring it. The argv position matters:
  # `gh pr list -R <slug> ...` puts the slug at $4, not $3 ($3 is the -R flag
  # itself). The first version of this test read $3, compared "-R" against the
  # expected slug, and failed while the parse it was checking was correct.
  cat > "$_sq_bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "SLUG_SEEN=$4" >&2
exit 1
GHEOF
  chmod +x "$_sq_bin/gh"
  _sq_out=$(PATH="$_sq_bin:$PATH" is_squash_merged "$_sq_credrepo" "some-branch") && _sq_rc=0 || _sq_rc=$?
  _check "squash-detect: credentialed remote parses to a bare OWNER/REPO slug" "1" \
    "$(case "$_sq_out" in (*"SLUG_SEEN=JohnGavin/fake"*) echo 1 ;; (*) echo 0 ;; esac)"
  _check "squash-detect: reason string carries NO token" "0" \
    "$(case "$_sq_out" in (*"$_fake_tok"*) echo 1 ;; (*) echo 0 ;; esac)"

  # redact_credentials directly. A helper tested only through one caller stops
  # being tested the moment that caller changes.
  _check "redact: strips user:pass@ from a URL" "0" \
    "$(case "$(redact_credentials "https://x-access-token:${_fake_tok}@github.com/o/r")" in (*"$_fake_tok"*) echo 1 ;; (*) echo 0 ;; esac)"
  _check "redact: strips a bare token" "0" \
    "$(case "$(redact_credentials "token is ${_fake_tok} here")" in (*"$_fake_tok"*) echo 1 ;; (*) echo 0 ;; esac)"
  _check "redact: leaves ordinary text alone" "no secrets in this line" \
    "$(redact_credentials 'no secrets in this line')"

  # (6) a repo with NO remote is a genuine negative — there cannot be a GitHub
  #     PR — so it must stay rc=0. Over-reporting indeterminate would make the
  #     new degraded-warning fire constantly and get ignored.
  _sq_norem="$tmpdir/sqnoremote"
  git init -q "$_sq_norem"
  cat > "$_sq_bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "[]"
GHEOF
  chmod +x "$_sq_bin/gh"
  _sq_out=$(PATH="$_sq_bin:$PATH" is_squash_merged "$_sq_norem" "some-branch") && _sq_rc=0 || _sq_rc=$?
  _check "squash-detect: repo with no remote is rc=0 (real 'no', not degraded)" "0" "$_sq_rc"

  echo ""
  echo "$_pass PASS, $_fail FAIL"
  [ "$_fail" = "0" ] && exit 0 || exit 1
fi
