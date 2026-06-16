#!/usr/bin/env bash
# branch_gc.sh — daily sweep of merged + squash-merged local branches.
#
# Companion to worktree_gc.sh (which handles worktree directories). This script
# handles the branch *refs* that survive after a worktree is removed or after a
# PR is merged via squash. See:
#   - `branch-salvage-workflow` rule for the 3-step check this implements
#   - `housekeeping-framework` rule for the 5-point template
#   - `cron-auto-pull-discipline` rule for the auto-pull block
#   - `unified-observability-schema` rule for the events table
#   - llm#585 for the original design and Phase A scope
#
# Phase A scope: step 1 (patch-id) + step 2 (closing-PR squash-merge) for
# every repo under ~/docs_gh/*/. Step 3 (unique-strings re-implementation
# detection) deferred to Phase B together with the email Section 3c.
#
# Usage:
#   bash .claude/scripts/branch_gc.sh                   # dry-run (default)
#   bash .claude/scripts/branch_gc.sh --apply           # actually delete
#   SELFTEST=1 bash .claude/scripts/branch_gc.sh        # offline self-test
#
# Env overrides:
#   BRANCH_GC_GRACE_DAYS=14       # days since closing PR before squash-delete
#   BRANCH_GC_MIN_AGE_DAYS=7      # skip branches newer than this
#   BRANCH_GC_PROTECTED_RE='^(main|master|HEAD)$|^release/|^prod/'
#   BRANCH_GC_NOTES_TTL_DAYS=30   # auto-prune notes/branch-gc after this
#   DEFAULT_REPOS_ROOT=$HOME/docs_gh
#   SKIP_CRON_PULL=1              # skip the auto-pull (testing)
#   BRANCH_GC_NO_DB=1             # skip duckdb writes (testing)

set -euo pipefail

# ─── launchd-safe PATH (llm#591) ──────────────────────────────────────────────
# Under launchd's default PATH, `command -v duckdb` fails and every DB write
# silently no-ops (log said events=326 but branch_gc_events had 0 rows). Same
# line as worktree_gc.sh.
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# Never block on a credential prompt — launchd has no TTY, so a dead or
# auth-gated remote hangs the whole sweep (llm#591: one fetch hung 4h).
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -oBatchMode=yes -oConnectTimeout=10"

# Bounded execution for network commands; passthrough when timeout is absent
# (macOS has no native timeout; homebrew/nix coreutils provide it).
_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$@"
  else
    shift
    "$@"
  fi
}

# ─── Config ───────────────────────────────────────────────────────────────────

BRANCH_GC_GRACE_DAYS="${BRANCH_GC_GRACE_DAYS:-14}"
BRANCH_GC_MIN_AGE_DAYS="${BRANCH_GC_MIN_AGE_DAYS:-7}"
BRANCH_GC_PROTECTED_RE="${BRANCH_GC_PROTECTED_RE:-^(main|master|HEAD)$|^release/|^prod/}"
BRANCH_GC_NOTES_TTL_DAYS="${BRANCH_GC_NOTES_TTL_DAYS:-30}"
DEFAULT_REPOS_ROOT="${DEFAULT_REPOS_ROOT:-$HOME/docs_gh}"
LOG="${BRANCH_GC_LOG:-$HOME/.claude/logs/branch_gc.log}"
DB="${UNIFIED_DB_PATH:-$HOME/.claude/logs/unified.duckdb}"
SCRIPT_PATH="$(realpath "$0")"

# CLI flags
APPLY=0
for arg in "$@"; do
  [ "$arg" = "--apply" ] && APPLY=1
done

# ─── Helpers ──────────────────────────────────────────────────────────────────

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG" >&2; }

# Emit one row to branch_gc_events (no-op if duckdb absent or BRANCH_GC_NO_DB=1).
db_emit() {
  local project="$1" branch="$2" sha="$3" action="$4" closing_pr="$5" age_days="$6" reason="$7"
  [ "${BRANCH_GC_NO_DB:-0}" = "1" ] && return 0
  command -v duckdb >/dev/null 2>&1 || return 0
  [ -f "$DB" ] || return 0
  local id
  id="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  [ -z "$id" ] && id="$(date +%s%N)"
  local pr_sql="NULL"
  [ -n "$closing_pr" ] && pr_sql="$closing_pr"
  duckdb "$DB" >/dev/null 2>&1 <<SQL || true
INSERT OR IGNORE INTO branch_gc_events
  (id, fired_at, source, project, branch_name, branch_tip_sha, action, closing_pr, age_days, reason)
VALUES
  ('${id}', current_timestamp, 'branch_gc.sh',
   '$(printf '%s' "$project" | sed "s/'/''/g")',
   '$(printf '%s' "$branch"  | sed "s/'/''/g")',
   '${sha}', '${action}', ${pr_sql}, ${age_days},
   '$(printf '%s' "$reason"  | sed "s/'/''/g")');
SQL
}

# housekeeping_runs heartbeat: start row.
hk_start() {
  [ "${BRANCH_GC_NO_DB:-0}" = "1" ] && { echo "no-db"; return 0; }
  command -v duckdb >/dev/null 2>&1 || { echo "no-duckdb"; return 0; }
  [ -f "$DB" ] || { echo "no-db-file"; return 0; }
  local id
  id="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  [ -z "$id" ] && id="$(date +%s%N)"
  duckdb "$DB" >/dev/null 2>&1 <<SQL || true
INSERT OR IGNORE INTO housekeeping_runs
  (id, task, source_script, started_at, status, rows_written)
VALUES
  ('${id}', 'branch_gc', '${SCRIPT_PATH}', current_timestamp, 'running', 0);
SQL
  echo "$id"
}

# housekeeping_runs heartbeat: end row.
hk_end() {
  local run_id="$1" status="$2" rows="$3" err="${4:-}"
  [ "$run_id" = "no-db" ] || [ "$run_id" = "no-duckdb" ] || [ "$run_id" = "no-db-file" ] && return 0
  command -v duckdb >/dev/null 2>&1 || return 0
  [ -f "$DB" ] || return 0
  local err_sql="NULL"
  [ -n "$err" ] && err_sql="'$(printf '%s' "$err" | sed "s/'/''/g")'"
  duckdb "$DB" >/dev/null 2>&1 <<SQL || true
UPDATE housekeeping_runs
SET ended_at = current_timestamp,
    status = '${status}',
    rows_written = ${rows},
    error_text = ${err_sql}
WHERE id = '${run_id}';
SQL
}

# Resolve the default branch for a repo (origin/HEAD → fallback to main).
default_branch_of() {
  local repo="$1"
  local out
  out="$(git -C "$repo" rev-parse --abbrev-ref origin/HEAD 2>/dev/null || true)"
  out="${out#origin/}"
  if [ -z "$out" ] || [ "$out" = "HEAD" ]; then
    if git -C "$repo" rev-parse --verify main >/dev/null 2>&1; then
      out="main"
    elif git -C "$repo" rev-parse --verify master >/dev/null 2>&1; then
      out="master"
    else
      out="main"
    fi
  fi
  echo "$out"
}

# Auto-pull every repo's default branch (per cron-auto-pull-discipline rule).
auto_pull_all() {
  [ -n "${SKIP_CRON_PULL:-}" ] && { log "skip-pull: SKIP_CRON_PULL set"; return 0; }
  local repo def
  for repo in "$DEFAULT_REPOS_ROOT"/*/; do
    [ -d "$repo/.git" ] || continue
    def="$(default_branch_of "$repo")"
    _timeout 30 git -C "$repo" fetch origin "$def" 2>/dev/null || continue
    if git -C "$repo" merge --ff-only "origin/$def" 2>/dev/null; then
      log "deploy: $(basename "$repo") → $(git -C "$repo" rev-parse --short HEAD)"
    fi
  done
}

# Is the branch checked out by any worktree of this repo?
is_checked_out() {
  local repo="$1" branch="$2"
  git -C "$repo" worktree list --porcelain 2>/dev/null \
    | awk '/^branch /{sub("refs/heads/","",$2); print $2}' \
    | grep -Fxq "$branch"
}

# Tip age in days (integer floor).
tip_age_days() {
  local repo="$1" branch="$2"
  local tip_ts now_ts
  tip_ts="$(git -C "$repo" log -1 --format=%ct "$branch" 2>/dev/null || echo 0)"
  [ "$tip_ts" -eq 0 ] && { echo 0; return; }
  now_ts="$(date +%s)"
  echo $(( (now_ts - tip_ts) / 86400 ))
}

# Branch-fully-in-default check. Returns 0 (true) if branch is reachable from
# the default branch (covers fast-forward merge — cherry output is empty in
# that case) OR if every cherry line is '-' (patch-id merged via cherry-pick
# or rebase).
cherry_all_minus() {
  local repo="$1" branch="$2" def="$3"
  # Case A: branch has zero commits ahead of default → fully merged
  local ahead
  ahead="$(git -C "$repo" rev-list --count "${def}..${branch}" 2>/dev/null || echo 1)"
  [ "$ahead" = "0" ] && return 0
  # Case B: patch-id equivalence
  local out plus minus
  out="$(git -C "$repo" cherry "$def" "$branch" 2>/dev/null || true)"
  plus="$(printf '%s\n' "$out" | grep -c '^+' || true)"
  minus="$(printf '%s\n' "$out" | grep -c '^-' || true)"
  [ "$plus" = "0" ] && [ "$minus" -gt 0 ]
}

# Detect closing-PR squash-merge: look for #N in branch name OR latest commits,
# then check if the issue was closed by a merged PR whose head branch was this
# branch (or a sibling worktree of it).
# Echoes the PR number if squash-merged, empty otherwise.
closing_squash_pr() {
  local repo="$1" branch="$2"
  command -v gh >/dev/null 2>&1 || { echo ""; return; }
  # First try the branch name pattern: feat/issue-NNN-..., fix/NNN-...
  local issue_num=""
  issue_num="$(printf '%s' "$branch" | grep -oE '(^|[/_-])(issue[-_]?)?([0-9]+)' | grep -oE '[0-9]+' | head -1 || true)"
  # Fall back to last 5 commit subjects
  if [ -z "$issue_num" ]; then
    issue_num="$(git -C "$repo" log -5 --format=%s "$branch" 2>/dev/null \
                  | grep -oE '#[0-9]+' | head -1 | tr -d '#' || true)"
  fi
  [ -z "$issue_num" ] && { echo ""; return; }
  # Try to find a merged PR for this branch head
  local repo_slug pr
  repo_slug="$(git -C "$repo" remote get-url origin 2>/dev/null \
                | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?.*|\1|')"
  [ -z "$repo_slug" ] && { echo ""; return; }
  # Look for a merged PR by head-ref matching the branch name
  pr="$(_timeout 15 gh -R "$repo_slug" pr list --state merged --head "$branch" --limit 1 \
        --json number --jq '.[0].number' 2>/dev/null || true)"
  [ -n "$pr" ] && { echo "$pr"; return; }
  # Otherwise look for merged PR closing the issue we found
  pr="$(_timeout 15 gh -R "$repo_slug" pr list --search "is:merged closes:#${issue_num}" --limit 1 \
        --json number --jq '.[0].number' 2>/dev/null || true)"
  [ -n "$pr" ] && { echo "$pr"; return; }
  echo ""
}

# Tag a deleted SHA in git notes (ref=branch-gc) for recovery.
tag_for_recovery() {
  local repo="$1" branch="$2" sha="$3" reason="$4"
  git -C "$repo" notes --ref=branch-gc add -f \
    -m "deleted=$(date -u +%Y-%m-%dT%H:%M:%SZ) branch=${branch} reason=${reason}" \
    "$sha" 2>/dev/null || true
}

# Decide + (optionally) act on a single branch. Echoes the action.
process_branch() {
  local repo="$1" project="$2" branch="$3" def="$4"
  local sha age action="" reason="" closing_pr=""
  sha="$(git -C "$repo" rev-parse "$branch" 2>/dev/null || echo "")"
  [ -z "$sha" ] && return 0
  age="$(tip_age_days "$repo" "$branch")"

  # Protected
  if printf '%s' "$branch" | grep -qE "$BRANCH_GC_PROTECTED_RE"; then
    action="kept_protected"; reason="protected regex match"
  # Default branch (extra guard, in case origin/HEAD differs)
  elif [ "$branch" = "$def" ]; then
    action="kept_protected"; reason="default branch ($def)"
  # Checked out
  elif is_checked_out "$repo" "$branch"; then
    action="kept_checked_out"; reason="branch is currently checked out"
  # Too young (active session may still need it)
  elif [ "$age" -lt "$BRANCH_GC_MIN_AGE_DAYS" ]; then
    action="kept_young"; reason="age ${age}d < BRANCH_GC_MIN_AGE_DAYS=${BRANCH_GC_MIN_AGE_DAYS}"
  # Step 1: fully patch-id merged
  elif cherry_all_minus "$repo" "$branch" "$def"; then
    action="deleted_merged"; reason="git cherry $def $branch all '-'"
  else
    # Step 2: closing PR squash-merge?
    closing_pr="$(closing_squash_pr "$repo" "$branch")"
    if [ -n "$closing_pr" ]; then
      if [ "$age" -ge "$BRANCH_GC_GRACE_DAYS" ]; then
        action="deleted_squash"; reason="closing PR #${closing_pr} squash-merged, age ${age}d >= grace ${BRANCH_GC_GRACE_DAYS}d"
      else
        action="kept_grace"; reason="closing PR #${closing_pr} squash-merged but age ${age}d < grace ${BRANCH_GC_GRACE_DAYS}d"
      fi
    else
      action="kept_unmerged"; reason="not patch-id merged, no closing squash-PR detected"
    fi
  fi

  # Execute deletion if applicable
  if [ "$APPLY" = "1" ] && { [ "$action" = "deleted_merged" ] || [ "$action" = "deleted_squash" ]; }; then
    tag_for_recovery "$repo" "$branch" "$sha" "$action"
    # Use -D since squash-merged branches aren't ancestors (-d would refuse)
    if ! git -C "$repo" branch -D "$branch" >/dev/null 2>&1; then
      action="kept_delete_failed"
      reason="git branch -D failed (worktree lock?)"
    fi
  elif { [ "$action" = "deleted_merged" ] || [ "$action" = "deleted_squash" ]; }; then
    # Dry-run: report would-delete
    action="kept_dryrun"
    reason="${reason} (dry-run, no --apply)"
  fi

  log "  [$action] $project/$branch ($sha, age=${age}d) — $reason"
  db_emit "$project" "$branch" "$sha" "$action" "$closing_pr" "$age" "$reason"
  echo "$action"
}

# Auto-prune branch-gc notes older than TTL.
prune_old_notes() {
  local repo="$1"
  git -C "$repo" rev-parse --verify refs/notes/branch-gc >/dev/null 2>&1 || return 0
  # Notes themselves are commits; gc'ing them by date is non-trivial.
  # Skipped for Phase A: 30-day reflog plus the notes ref itself gives recovery.
  # Phase B will add periodic notes pruning by parsing message timestamps.
  return 0
}

# ─── SELFTEST ─────────────────────────────────────────────────────────────────
# 12 cases against tmp repos. No network. No duckdb writes.

selftest() {
  local TMP PASS=0 FAIL=0
  TMP="$(mktemp -d)"
  trap "rm -rf '$TMP'" EXIT
  export BRANCH_GC_NO_DB=1
  export SKIP_CRON_PULL=1
  export BRANCH_GC_MIN_AGE_DAYS=0   # selftest commits are seconds old

  # Helper: report a case
  _case() {
    local name="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
      echo "  PASS: $name (got=$got)"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: $name (got=$got, want=$want)"
      FAIL=$((FAIL + 1))
    fi
  }

  # Build a tmp repo with several branches
  local REPO="$TMP/repo"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email "test@test"
  git -C "$REPO" config user.name "test"
  echo "a" > "$REPO/a"; git -C "$REPO" add a; git -C "$REPO" commit -q -m "init"

  # Case 1: protected (main) — kept_protected
  _case "main protected" "$(process_branch "$REPO" testproj main main)" "kept_protected"

  # Case 2: brand-new branch with unique commit, age=0 — kept_unmerged (not merged)
  git -C "$REPO" checkout -q -b feat/new
  echo "new" > "$REPO/new"; git -C "$REPO" add new; git -C "$REPO" commit -q -m "new"
  git -C "$REPO" checkout -q main
  _case "feat/new unmerged dry-run" "$(process_branch "$REPO" testproj feat/new main)" "kept_unmerged"

  # Case 3: branch fast-forward-merged into main (cherry all-minus) — kept_dryrun (no --apply)
  git -C "$REPO" checkout -q -b chore/ff
  echo "ff" > "$REPO/ff"; git -C "$REPO" add ff; git -C "$REPO" commit -q -m "ff"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --ff-only chore/ff -q
  _case "chore/ff merged dry-run" "$(process_branch "$REPO" testproj chore/ff main)" "kept_dryrun"

  # Case 4: same as 3 but APPLY=1 → deleted_merged
  APPLY=1
  git -C "$REPO" checkout -q -b chore/ff2
  echo "ff2" > "$REPO/ff2"; git -C "$REPO" add ff2; git -C "$REPO" commit -q -m "ff2"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --ff-only chore/ff2 -q
  _case "chore/ff2 merged apply" "$(process_branch "$REPO" testproj chore/ff2 main)" "deleted_merged"
  # Verify it's actually gone
  if git -C "$REPO" rev-parse --verify chore/ff2 >/dev/null 2>&1; then
    _case "chore/ff2 ref gone after delete" "still-present" "absent"
  else
    _case "chore/ff2 ref gone after delete" "absent" "absent"
  fi
  # And a recovery note exists
  if git -C "$REPO" notes --ref=branch-gc list 2>/dev/null | head -1 | grep -q .; then
    _case "recovery note created" "yes" "yes"
  else
    _case "recovery note created" "no" "yes"
  fi
  APPLY=0

  # Case 5: checked-out branch — kept_checked_out
  git -C "$REPO" checkout -q -b feat/active
  echo "active" > "$REPO/active"; git -C "$REPO" add active; git -C "$REPO" commit -q -m "active"
  _case "checked-out branch kept" "$(process_branch "$REPO" testproj feat/active main)" "kept_checked_out"
  git -C "$REPO" checkout -q main

  # Case 6: too-young branch — kept_young (raise min age)
  BRANCH_GC_MIN_AGE_DAYS=365
  git -C "$REPO" checkout -q -b feat/baby
  echo "baby" > "$REPO/baby"; git -C "$REPO" add baby; git -C "$REPO" commit -q -m "baby"
  git -C "$REPO" checkout -q main
  _case "young branch kept" "$(process_branch "$REPO" testproj feat/baby main)" "kept_young"
  BRANCH_GC_MIN_AGE_DAYS=0

  # Case 7: release/ branch — protected
  git -C "$REPO" branch release/1.0 main
  _case "release/1.0 protected" "$(process_branch "$REPO" testproj release/1.0 main)" "kept_protected"

  # Case 8: master pattern protected (set extra branch)
  git -C "$REPO" branch master main
  _case "master protected" "$(process_branch "$REPO" testproj master main)" "kept_protected"

  # Case 9: tag_for_recovery succeeds on a SHA
  local sha
  sha="$(git -C "$REPO" rev-parse main)"
  tag_for_recovery "$REPO" "test-branch" "$sha" "test"
  if git -C "$REPO" notes --ref=branch-gc show "$sha" 2>/dev/null | grep -q 'branch=test-branch'; then
    _case "tag_for_recovery writes note" "yes" "yes"
  else
    _case "tag_for_recovery writes note" "no" "yes"
  fi

  # Case 10: default_branch_of returns 'main' when no origin
  local def
  def="$(default_branch_of "$REPO")"
  _case "default_branch fallback" "$def" "main"

  # Case 11: tip_age_days computes a non-negative integer
  local age
  age="$(tip_age_days "$REPO" main)"
  if [ "$age" -ge 0 ] 2>/dev/null; then
    _case "tip_age_days non-negative" "yes" "yes"
  else
    _case "tip_age_days non-negative" "no" "yes"
  fi

  # Case 12: cherry_all_minus on a fresh branch — false (not merged)
  if cherry_all_minus "$REPO" feat/new main; then
    _case "cherry_all_minus on unmerged" "yes" "no"
  else
    _case "cherry_all_minus on unmerged" "no" "no"
  fi

  echo
  echo "SELFTEST: $PASS pass, $FAIL fail"
  [ "$FAIL" -eq 0 ]
}

# ─── Main ─────────────────────────────────────────────────────────────────────

if [ "${SELFTEST:-0}" = "1" ]; then
  selftest
  exit $?
fi

log "=== branch_gc start (apply=$APPLY, grace=${BRANCH_GC_GRACE_DAYS}d, min_age=${BRANCH_GC_MIN_AGE_DAYS}d) ==="
# Make a missing duckdb visible in the log instead of silently skipping all
# DB writes (the llm#591 failure mode).
log "db: duckdb=$(command -v duckdb || echo ABSENT) db_file=$([ -f "$DB" ] && echo "$DB" || echo ABSENT)"

# Auto-pull main on every repo (deploy discipline).
auto_pull_all

RUN_ID="$(hk_start)"
EVENTS=0
PER_ACTION=""

for repo in "$DEFAULT_REPOS_ROOT"/*/; do
  [ -d "$repo/.git" ] || continue
  project="$(basename "$repo")"
  def="$(default_branch_of "$repo")"
  log "-- repo $project (default=$def) --"

  # Iterate local heads
  while IFS= read -r branch; do
    [ -z "$branch" ] && continue
    # Skip worktree-agent-* and HEAD; the harness manages those
    case "$branch" in
      worktree-agent-*) continue ;;
      HEAD) continue ;;
    esac
    a="$(process_branch "$repo" "$project" "$branch" "$def")"
    EVENTS=$((EVENTS + 1))
    PER_ACTION="${PER_ACTION}${a}\n"
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/)

  prune_old_notes "$repo"
done

# Summary
log "=== branch_gc summary ==="
printf '%b' "$PER_ACTION" | sort | uniq -c | sort -rn | while read -r cnt act; do
  [ -z "$cnt" ] && continue
  log "  $cnt $act"
done
log "[done] events=$EVENTS apply=$APPLY"

hk_end "$RUN_ID" "ok" "$EVENTS" ""

# Stamp for cron_catchup.sh catch-up detection
mkdir -p "${HOME}/.claude/logs/stamps"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.claude/logs/stamps/branch-gc.stamp"

exit 0
