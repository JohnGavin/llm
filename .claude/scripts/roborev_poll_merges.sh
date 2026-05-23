#!/usr/bin/env bash
# roborev_poll_merges.sh — catchup poller for commits roborev's post-commit
#
# Portability: this script is invoked by launchd, which provides only a bare
# PATH (/usr/bin:/bin:/usr/sbin:/sbin). Prepend coreutils paths so that git,
# sqlite3, and roborev are visible on both Homebrew and Nix Macs.
# Portability fixes (#181 Theme 2 — roborev id 1509):
#   - Shebang changed from /opt/homebrew/bin/bash (Apple Silicon only) to
#     #!/usr/bin/env bash so the script runs on Intel Macs and non-Homebrew
#     setups. PATH export ensures launchd's bare env finds coreutils binaries.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# hook missed (remote-merged PRs don't fire local post-commit).
#
# For each repo in ~/.roborev/reviews.db's repos table:
#   1. Resolve local HEAD
#   2. Look up the most-recent reviewed commit_sha for that repo
#   3. If HEAD ≠ last_sha AND HEAD is descendant of last_sha → enqueue
#      `roborev review --since <last_sha>` from inside the repo
#
# Network-free: does NOT `git fetch` (would not affect local HEAD anyway —
# PRs only become local HEAD when the user does `git pull`).
#
# Status: tracked in JohnGavin/llm#148 (sub-fix 1 of 3).
#
# Usage:
#   roborev_poll_merges.sh                # dry-run (default)
#   roborev_poll_merges.sh --apply        # enqueue real review jobs
#
# Exit codes:
#   0 ok (including "nothing to do" and "roborev/sqlite missing")
#   1 unexpected error

set -eo pipefail

DRY_RUN=1
case "${1:-}" in
  --apply)   DRY_RUN=0 ;;
  --dry-run|"") DRY_RUN=1 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "unknown arg: $1" >&2; exit 1 ;;
esac

DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
SQLITE="${SQLITE:-/usr/bin/sqlite3}"
ROBOREV="${ROBOREV:-/usr/local/bin/roborev}"
GIT="${GIT:-/usr/bin/git}"
LOG="$HOME/.claude/logs/roborev_poll_merges.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Quietly succeed if any required binary missing (laptop vs CI portability)
for cmd in "$DB" "$SQLITE" "$ROBOREV" "$GIT"; do
  if [ ! -e "$cmd" ]; then
    log "skip: $cmd not found"
    echo "roborev_poll_merges: skipped ($cmd missing)"
    exit 0
  fi
done

# Pull all repos from roborev's DB (single source of truth).
# NOTE: portable while-read loop instead of `mapfile` — launchd uses macOS
# system bash 3.2 (/bin/bash), which lacks mapfile (a bash-4+ builtin).
# This script must run under that interpreter without modification.
REPOS=()
while IFS= read -r _line; do
  REPOS+=("$_line")
done < <(
  "$SQLITE" "$DB" "SELECT id || '|' || name || '|' || root_path FROM repos;"
)

total=0; behind=0; enqueued=0; skipped=0
for line in "${REPOS[@]}"; do
  IFS='|' read -r repo_id name root_path <<<"$line"
  total=$((total + 1))

  # Repo gone? skip
  if [ ! -d "$root_path/.git" ] && [ ! -f "$root_path/.git" ]; then
    skipped=$((skipped + 1))
    log "skip: $name — no .git at $root_path"
    continue
  fi

  head_sha=$("$GIT" -C "$root_path" rev-parse HEAD 2>/dev/null) || { skipped=$((skipped + 1)); continue; }

  # Latest reviewed SHA for this repo (any not-cancelled status counts)
  last_sha=$("$SQLITE" "$DB" "
    SELECT c.sha FROM review_jobs rj
    JOIN commits c ON c.id = rj.commit_id
    WHERE rj.repo_id = $repo_id
      AND rj.status IN ('done','running','queued','failed')
    ORDER BY rj.enqueued_at DESC LIMIT 1;
  ")

  if [ -z "$last_sha" ]; then
    # No reviews yet — let the post-commit hook handle the first one
    log "skip: $name — no prior reviews (post-commit will catch first)"
    skipped=$((skipped + 1))
    continue
  fi

  # Idempotency anchor: range reviews set commit_id=NULL (no commits row for the
  # range tip), so the old JOIN on commits.sha always returned 0 for range jobs,
  # making every poll enqueue a duplicate. Fix: also match against the END of
  # git_ref (the reviewed tip SHA) for range jobs.
  # Fixes JohnGavin/llm#198 Bug 2 / roborev #4013.
  head_review_count=$("$SQLITE" "$DB" "
      SELECT COUNT(*) FROM review_jobs rj
      LEFT JOIN commits c ON c.id = rj.commit_id
      WHERE rj.repo_id = $repo_id
        AND rj.status IN ('done','running','queued','failed')
        AND (
          c.sha = '$head_sha'
          OR rj.git_ref = '$head_sha'
          OR rj.git_ref LIKE '%..$head_sha'
        );
  ")
  if [ "$head_review_count" -gt 0 ]; then
    log "skip: $name — HEAD($head_sha) already has $head_review_count review(s)"
    skipped=$((skipped + 1))
    continue
  fi

  [ "$head_sha" = "$last_sha" ] && continue   # up to date

  # last_sha must be an ancestor of HEAD, else the branch diverged
  if ! "$GIT" -C "$root_path" merge-base --is-ancestor "$last_sha" "$head_sha" 2>/dev/null; then
    log "skip: $name — HEAD($head_sha) not descendant of last reviewed ($last_sha)"
    skipped=$((skipped + 1))
    continue
  fi

  n=$("$GIT" -C "$root_path" rev-list --count "$last_sha..$head_sha" 2>/dev/null || echo 0)
  behind=$((behind + 1))

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry] $name: $n commit(s) behind, would enqueue: roborev review --since $last_sha"
    echo "[dry] $name: $n commit(s) behind ($last_sha..$head_sha)"
  else
    if (cd "$root_path" && "$ROBOREV" review --since "$last_sha" >/dev/null 2>&1); then
      enqueued=$((enqueued + n))
      log "applied: $name: $n commit(s) enqueued (since $last_sha)"
      echo "$name: $n enqueued"
    else
      log "fail: $name: roborev review --since $last_sha failed"
      echo "$name: enqueue FAILED"
    fi
  fi
done

mode="dry-run"; [ "$DRY_RUN" -eq 0 ] && mode="applied"
log "summary [$mode]: repos=$total behind=$behind enqueued=$enqueued skipped=$skipped"
echo "roborev_poll_merges [$mode]: repos=$total behind=$behind enqueued=$enqueued skipped=$skipped"
