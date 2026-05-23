#!/usr/bin/env bash
# roborev_handoff.sh — hand off stale cross-repo roborev findings to their
# owning projects via GitHub issues or CURRENT_WORK.md inbox entries.
#
# Closes roborev #899 (#181 Theme 5) — staleness filter uses finished_at (not
# enqueued_at), so fresh reviews on long-queued jobs are not auto-closed.
# Fix landed in commit f2b851f (primary) and a05eb7f (warn on null finished_at).
# Jobs where finished_at IS NULL are excluded and produce a stderr WARN.
#
# Handles three populations (threshold = THRESHOLD_DAYS, default 7d):
#   Phase 1a  verdict=fail       → per-commit GH issue (label roborev-handoff)
#   Phase 1b  verdict=pass+notes → append to weekly digest issue (label roborev-digest)
#   Phase 1c  verdict=pass clean → silent roborev close (nothing surfaces)
#
# Mechanism A (default, GH issues) vs Mechanism B (CURRENT_WORK.md inbox):
#   A repo opts into B by creating <root>/.claude/.roborev-handoff-mode
#   containing the word "inbox".  All other content (or absent) → A.
#   If GH issues are disabled for the repo, A falls back to B automatically.
#
# "pass clean" = verdict_bool=1 AND output starts with "No issues found."
# "pass with comments" = verdict_bool=1 AND output has substantive content beyond that
#
# DB schema note (verified 2026-05-13):
#   reviews.verdict_bool  INTEGER  1=pass, 0=fail
#   reviews.output        TEXT     markdown review body  (NOT a "body" column)
#   (no "verdict" text column exists — the spec used "verdict" but the actual
#    column is verdict_bool)
#
# Implementation note: reviews.output contains newlines and pipe characters,
# so we use Python to query the DB and write per-job temp files instead of
# trying to split raw sqlite3 pipe-delimited output in bash.
#
# Tracked in JohnGavin/llm#149.
#
# Usage:
#   roborev_handoff.sh                            # dry-run all repos (default)
#   roborev_handoff.sh --apply                    # apply to all repos
#   ROBOREV_REPO=hello_t roborev_handoff.sh --apply   # apply to single repo only
#
# Exit codes:
#   0  ok (including "nothing to do" and "binary/db missing")
#   1  unexpected error

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
ROBOREV="${ROBOREV:-/usr/local/bin/roborev}"
SQLITE="${SQLITE:-/usr/bin/sqlite3}"
GH="${GH:-/usr/bin/gh}"
PYTHON="${PYTHON:-/usr/bin/python3}"
ROBOREV_DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
THRESHOLD_DAYS="${THRESHOLD_DAYS:-7}"
ROBOREV_REPO="${ROBOREV_REPO:-}"  # optional: restrict to a single repo by name
FINDINGS_DIR="${FINDINGS_DIR:-$HOME/.roborev/findings}"
LOG="$HOME/.claude/logs/roborev_handoff.log"
APPLY=0

case "${1:-}" in
  --apply)      APPLY=1 ;;
  --dry-run|"") APPLY=0 ;;
  -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
  *)            echo "unknown arg: $1" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$LOG")" "$FINDINGS_DIR"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Quietly succeed if required binaries/db missing (laptop vs CI portability)
for thing in "$PYTHON" "$ROBOREV" "$SQLITE" "$GH" "$ROBOREV_DB"; do
  if [ ! -e "$thing" ]; then
    log "skip: $thing not found"
    echo "roborev_handoff: skipped ($thing missing)"
    exit 0
  fi
done

# ── Temp workspace (cleaned on exit) ─────────────────────────────────────────
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# ── Python: export all stale done jobs to per-job JSON files ─────────────────
# This avoids shell pipe-splitting on multiline/pipe-containing output text.
"$PYTHON" - "$ROBOREV_DB" "$THRESHOLD_DAYS" "$WORKDIR" "$ROBOREV_REPO" <<'PYEOF'
import sys, json, sqlite3, os

db_path, threshold_days, workdir = sys.argv[1], int(sys.argv[2]), sys.argv[3]
filter_repo = sys.argv[4] if len(sys.argv) > 4 else ""
con = sqlite3.connect(db_path)
con.row_factory = sqlite3.Row

# Repos: skip llm; if ROBOREV_REPO env var set, restrict to that one repo
if filter_repo:
    repos = con.execute(
        "SELECT DISTINCT id, name, root_path, COALESCE(identity,'') AS identity "
        "FROM repos WHERE name = ? ORDER BY name, id",
        (filter_repo,)
    ).fetchall()
else:
    repos = con.execute(
        "SELECT DISTINCT id, name, root_path, COALESCE(identity,'') AS identity "
        "FROM repos WHERE name != 'llm' ORDER BY name, id"
    ).fetchall()

repo_file = os.path.join(workdir, "repos.jsonl")
with open(repo_file, "w") as f:
    for r in repos:
        f.write(json.dumps(dict(r)) + "\n")

# Stale done jobs with reviews, per repo
for r in repos:
    jobs = con.execute("""
        SELECT
            rj.id         AS job_id,
            COALESCE(c.sha,'') AS commit_sha,
            rv.verdict_bool,
            rv.output
        FROM review_jobs rj
        JOIN repos repo ON repo.id = rj.repo_id
        LEFT JOIN commits c ON c.id = rj.commit_id
        JOIN reviews rv ON rv.job_id = rj.id
        WHERE repo.id = ?
          AND rj.status = 'done'
          AND rj.finished_at IS NOT NULL
          AND (julianday('now') - julianday(rj.finished_at)) > ?
        ORDER BY rj.finished_at ASC
    """, (r["id"], threshold_days)).fetchall()

    jobs_file = os.path.join(workdir, f"jobs_{r['id']}.jsonl")
    with open(jobs_file, "w") as f:
        for j in jobs:
            f.write(json.dumps(dict(j)) + "\n")

    # Warn when done jobs lack finished_at — they are silently excluded above.
    # A non-zero count indicates review_jobs schema integrity issues.
    excluded = con.execute(
        "SELECT COUNT(*) FROM review_jobs rj "
        "WHERE rj.repo_id = ? AND rj.status = 'done' AND rj.finished_at IS NULL",
        (r["id"],)
    ).fetchone()[0]
    if excluded > 0:
        import sys as _sys
        print(
            f"WARN: {excluded} done-but-finished_at-null job(s) excluded from "
            f"handoff for repo '{r['name']}' — investigate review_jobs schema integrity",
            file=_sys.stderr,
        )

con.close()
PYEOF

# ── Helpers ───────────────────────────────────────────────────────────────────

# Extract owner/repo from identity URL:
#   https://github.com/JohnGavin/foo.git  → JohnGavin/foo
#   local:///...                           → empty string (no GH issues)
gh_owner_repo() {
  local identity="$1"
  case "$identity" in
    https://github.com/*)
      echo "$identity" | sed 's|https://github.com/||;s|\.git$||'
      ;;
    *)
      echo ""
      ;;
  esac
}

# Check whether a GH repo has issues enabled (returns 0=yes, 1=no)
gh_issues_enabled() {
  local owner_repo="$1"
  [ -z "$owner_repo" ] && return 1
  local enabled
  enabled=$("$GH" repo view "$owner_repo" --json hasIssuesEnabled -q '.hasIssuesEnabled' 2>/dev/null) || return 1
  [ "$enabled" = "true" ]
}

# Determine mode for a repo: "inbox" or "gh" (default)
repo_mode() {
  local root_path="$1"
  local marker="$root_path/.claude/.roborev-handoff-mode"
  if [ -f "$marker" ] && grep -q "^inbox$" "$marker" 2>/dev/null; then
    echo "inbox"
  else
    echo "gh"
  fi
}

# Classify review output: "pass-clean" | "pass-comments" | "fail"
classify_review() {
  local verdict_bool="$1"
  local output_trimmed="$2"
  if [ "$verdict_bool" -eq 0 ]; then
    echo "fail"
  elif echo "$output_trimmed" | grep -q "^No issues found\."; then
    echo "pass-clean"
  else
    echo "pass-comments"
  fi
}

# ── Counters ──────────────────────────────────────────────────────────────────
repos_total=0; repos_processed=0; repos_skipped=0
act_1a=0; act_1b=0; act_1c=0; act_b=0

# ── Main loop: per repo ───────────────────────────────────────────────────────
while IFS= read -r repo_json; do
  [ -z "$repo_json" ] && continue
  repo_id=$("$PYTHON" -c "import sys,json; d=json.loads(sys.argv[1]); print(d['id'])" "$repo_json")
  repo_name=$("$PYTHON" -c "import sys,json; d=json.loads(sys.argv[1]); print(d['name'])" "$repo_json")
  root_path=$("$PYTHON" -c "import sys,json; d=json.loads(sys.argv[1]); print(d['root_path'])" "$repo_json")
  identity=$("$PYTHON" -c "import sys,json; d=json.loads(sys.argv[1]); print(d['identity'])" "$repo_json")
  repos_total=$((repos_total + 1))

  # Skip repos with no .git on disk
  if [ ! -d "$root_path/.git" ] && [ ! -f "$root_path/.git" ]; then
    log "skip: $repo_name — no .git at $root_path"
    repos_skipped=$((repos_skipped + 1))
    continue
  fi

  repos_processed=$((repos_processed + 1))

  # Determine GH owner/repo and mode
  owner_repo=$(gh_owner_repo "$identity")
  mode=$(repo_mode "$root_path")

  # If mode=gh but issues disabled or no GH remote → fall back to B
  if [ "$mode" = "gh" ]; then
    if [ -z "$owner_repo" ]; then
      log "warn: $repo_name — no GitHub remote (identity=$identity), falling back to inbox mode"
      mode="inbox"
    elif ! gh_issues_enabled "$owner_repo" 2>/dev/null; then
      log "warn: $repo_name — GH issues disabled, falling back to inbox mode"
      mode="inbox"
    fi
  fi

  # Process stale done jobs for this repo
  jobs_file="$WORKDIR/jobs_${repo_id}.jsonl"
  [ ! -f "$jobs_file" ] && continue

  while IFS= read -r job_json; do
    [ -z "$job_json" ] && continue
    job_id=$("$PYTHON" -c "import sys,json; d=json.loads(sys.argv[1]); print(d['job_id'])" "$job_json")
    commit_sha=$("$PYTHON" -c "import sys,json; d=json.loads(sys.argv[1]); print(d['commit_sha'])" "$job_json")
    verdict_bool=$("$PYTHON" -c "import sys,json; d=json.loads(sys.argv[1]); print(d['verdict_bool'])" "$job_json")
    output=$("$PYTHON" -c "import sys,json; d=json.loads(sys.argv[1]); print(d['output'])" "$job_json")

    # Trim leading whitespace from output for classification
    output_trimmed=$(echo "$output" | sed 's/^[[:space:]]*//')
    commit_short="${commit_sha:0:7}"
    classification=$(classify_review "$verdict_bool" "$output_trimmed")

    case "$classification" in

      # ── Phase 1c: pass clean → silent close ────────────────────────────
      pass-clean)
        if [ "$APPLY" -eq 0 ]; then
          echo "[dry] $repo_name: would close pass-clean (job $job_id)"
        else
          if "$ROBOREV" close "$job_id" >/dev/null 2>&1; then
            log "1c: closed pass-clean job=$job_id repo=$repo_name"
          else
            log "fail: roborev close $job_id (1c)"
          fi
        fi
        act_1c=$((act_1c + 1))
        ;;

      # ── Mechanism B (inbox mode) ────────────────────────────────────────
      fail|pass-comments)
        if [ "$mode" = "inbox" ]; then
          current_work="$root_path/.claude/CURRENT_WORK.md"
          one_line=$(echo "$output_trimmed" | head -1)
          inbox_block=$(printf '\n## Inbox: roborev finding %s\n\n- commit: %s\n- job: %s\n- finding: %s\n- full: see `~/.roborev/findings/%s.md`\n' \
            "$(date -u +%Y-%m-%d)" "$commit_sha" "$job_id" "$one_line" "$job_id")

          if [ "$APPLY" -eq 0 ]; then
            echo "[dry] $repo_name: would append to inbox CURRENT_WORK.md (job $job_id, mode=inbox)"
          else
            # Idempotency: skip if already present
            if [ -f "$current_work" ] && grep -q "job: $job_id" "$current_work" 2>/dev/null; then
              log "skip: $repo_name job=$job_id already in CURRENT_WORK.md"
            else
              # Save full review to findings dir
              printf '%s\n' "$output" > "$FINDINGS_DIR/${job_id}.md"
              # Append to CURRENT_WORK.md (create if needed)
              mkdir -p "$(dirname "$current_work")"
              printf '%s\n' "$inbox_block" >> "$current_work"
              log "B: appended inbox job=$job_id repo=$repo_name findings=$FINDINGS_DIR/${job_id}.md"

              if "$ROBOREV" close "$job_id" >/dev/null 2>&1; then
                log "B: closed job=$job_id"
              else
                log "fail: roborev close $job_id (B) — inbox written but job not closed"
              fi
            fi
          fi
          act_b=$((act_b + 1))

        # ── Mechanism A: fail → per-commit GH issue (Phase 1a) ───────────
        elif [ "$classification" = "fail" ]; then
          if [ "$APPLY" -eq 0 ]; then
            echo "[dry] $repo_name: would create GH issue (commit $commit_short, job $job_id, label roborev-handoff)"
          else
            # Idempotency: search for existing issue with this commit sha
            existing=$(
              "$GH" issue list \
                --repo "$owner_repo" \
                --label roborev-handoff \
                --search "$commit_sha in:body" \
                --json number \
                -q '.[0].number' 2>/dev/null || echo ""
            )
            if [ -n "$existing" ]; then
              log "skip: $repo_name job=$job_id issue already exists (#$existing)"
            else
              issue_body=$(printf '## roborev review — commit `%s`\n\n%s\n\n---\n_roborev job: %s_\n' \
                "$commit_short" "$output" "$job_id")
              issue_url=$(
                "$GH" issue create \
                  --repo "$owner_repo" \
                  --title "roborev review for $commit_short" \
                  --label "roborev-handoff" \
                  --body "$issue_body" 2>/dev/null
              ) && {
                log "1a: created issue $issue_url job=$job_id repo=$repo_name"
                "$ROBOREV" close "$job_id" >/dev/null 2>&1 \
                  && log "1a: closed job=$job_id" \
                  || log "fail: roborev close $job_id (1a) — issue created but job not closed"
              } || {
                log "fail: gh issue create failed for job=$job_id repo=$repo_name (job left open)"
              }
            fi
          fi
          act_1a=$((act_1a + 1))

        # ── Mechanism A: pass-comments → weekly digest (Phase 1b) ─────────
        else
          iso_week=$(date -u +%G-W%V)
          digest_title="roborev pass-comments digest $iso_week"

          if [ "$APPLY" -eq 0 ]; then
            echo "[dry] $repo_name: would append to digest $iso_week (job $job_id)"
          else
            # Find open digest issue for this week
            digest_num=$(
              "$GH" issue list \
                --repo "$owner_repo" \
                --label roborev-digest \
                --state open \
                --search "\"$digest_title\" in:title" \
                --json number \
                -q '.[0].number' 2>/dev/null || echo ""
            )

            append_block=$(printf '\n---\n### Commit %s (job %s) — %s\n\n%s\n' \
              "$commit_short" "$job_id" "$(date -u +%F)" "$output")

            if [ -n "$digest_num" ]; then
              # Idempotency: check if job already in digest body
              existing_body=$(
                "$GH" issue view "$digest_num" --repo "$owner_repo" --json body -q '.body' 2>/dev/null || echo ""
              )
              if echo "$existing_body" | grep -q "job $job_id"; then
                log "skip: $repo_name job=$job_id already in digest #$digest_num"
              else
                new_body="${existing_body}${append_block}"
                "$GH" issue edit "$digest_num" --repo "$owner_repo" --body "$new_body" >/dev/null 2>&1 && {
                  log "1b: appended to digest #$digest_num job=$job_id repo=$repo_name"
                  "$ROBOREV" close "$job_id" >/dev/null 2>&1 \
                    && log "1b: closed job=$job_id" \
                    || log "fail: roborev close $job_id (1b) — appended but not closed"
                } || {
                  log "fail: gh issue edit #$digest_num failed for job=$job_id (job left open)"
                }
              fi
            else
              # Create new digest issue for this week
              issue_url=$(
                "$GH" issue create \
                  --repo "$owner_repo" \
                  --title "$digest_title" \
                  --label "roborev-digest" \
                  --body "$append_block" 2>/dev/null
              ) && {
                log "1b: created digest $issue_url job=$job_id repo=$repo_name"
                "$ROBOREV" close "$job_id" >/dev/null 2>&1 \
                  && log "1b: closed job=$job_id" \
                  || log "fail: roborev close $job_id (1b) — digest created but not closed"
              } || {
                log "fail: gh issue create digest failed for job=$job_id repo=$repo_name (job left open)"
              }
            fi
          fi
          act_1b=$((act_1b + 1))
        fi
        ;;
    esac
  done < "$jobs_file"

done < "$WORKDIR/repos.jsonl"

# ── Summary ───────────────────────────────────────────────────────────────────
mode_label="dry-run"; [ "$APPLY" -eq 1 ] && mode_label="applied"
summary="roborev_handoff [$mode_label]: repos=$repos_total processed=$repos_processed actions={1a:$act_1a,1b:$act_1b,1c:$act_1c,B:$act_b} skipped=$repos_skipped"
log "$summary"
echo "$summary"
