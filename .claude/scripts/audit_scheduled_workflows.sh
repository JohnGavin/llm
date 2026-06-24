#!/usr/bin/env bash
# audit_scheduled_workflows.sh — Phase 0 audit for issue #656
#
# Finds all on:schedule GitHub Actions workflows across JohnGavin repos.
# Classifies each as SAFE (self-committing) or AT-RISK (non-committing).
# Reports enabled/disabled state.
#
# PURE READ-ONLY: no writes to any repo, no workflow enable/disable.
#
# Usage:
#   ./audit_scheduled_workflows.sh [--quiet]
#
# Flags:
#   --quiet   Print table only (suppress progress messages)
#
# Requirements: gh (authenticated), jq, base64
#
# Exit codes:
#   0   Success (even if AT-RISK workflows found)
#   1   Hard failure (gh not found, not authenticated, jq missing, etc.)
#
# Portability: \s is NOT portable in grep -E on macOS (BSD grep).
# Always use [[:space:]] for whitespace character classes.

set -euo pipefail

QUIET=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
  esac
done

log() {
  if [ "$QUIET" -eq 0 ]; then
    printf '%s\n' "$*" >&2
  fi
}

# ──────────────────────────────────────────────
# 0. Verify prerequisites
# ──────────────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
  printf 'ERROR: gh not found in PATH\n' >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  printf 'ERROR: gh not authenticated\n' >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'ERROR: jq not found in PATH\n' >&2
  exit 1
fi
if ! command -v base64 >/dev/null 2>&1; then
  printf 'ERROR: base64 not found in PATH\n' >&2
  exit 1
fi

# ──────────────────────────────────────────────
# 1. Build repo list
# ──────────────────────────────────────────────
SCRIPT_DIR="$(dirname "$0")"
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"
# The script lives at <worktree>/.claude/scripts/ — navigate up to repo root
LLM_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANONICAL_CSV="$LLM_ROOT/.claude/data/canonical_projects.csv"

declare -A SEEN_REPOS

# Seed from canonical_projects.csv (column 3 = repo, skip header)
if [ -f "$CANONICAL_CSV" ]; then
  log "[1/3] Reading canonical projects from $CANONICAL_CSV"
  while IFS=',' read -r _slug _display_name repo _kind _is_active _notes; do
    # Skip header and blank lines
    [ "$repo" = "repo" ] && continue
    [ -z "$repo" ] && continue
    # Only include repos with JohnGavin/ prefix (skip local-only entries)
    case "$repo" in
      JohnGavin/*) SEEN_REPOS["$repo"]=1 ;;
    esac
  done < "$CANONICAL_CSV"
else
  log "[1/3] canonical_projects.csv not found at $CANONICAL_CSV, using gh list only"
fi

log "[1/3] Canonical repos loaded: ${#SEEN_REPOS[@]}"

# Union with repos pushed within last 90 days (non-archived)
log "[2/3] Querying repos pushed in last 90 days..."

# Portable date: try GNU date first, then BSD date (macOS)
NINETY_DAYS_AGO=""
if date -u -d '90 days ago' '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
  NINETY_DAYS_AGO="$(date -u -d '90 days ago' '+%Y-%m-%dT%H:%M:%SZ')"
elif date -u -v-90d '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
  NINETY_DAYS_AGO="$(date -u -v-90d '+%Y-%m-%dT%H:%M:%SZ')"
fi

gh repo list JohnGavin --limit 200 \
  --json name,pushedAt,isArchived \
  2>/dev/null > /tmp/_aw_repolist.json

if [ -n "$NINETY_DAYS_AGO" ]; then
  jq -r --arg cutoff "$NINETY_DAYS_AGO" \
    '.[] | select(.isArchived == false) | select(.pushedAt >= $cutoff) | "JohnGavin/" + .name' \
    /tmp/_aw_repolist.json 2>/dev/null
else
  # Fallback: no date filtering, just skip archived
  log "[2/3] WARNING: could not compute 90-day cutoff date; scanning all non-archived repos"
  jq -r '.[] | select(.isArchived == false) | "JohnGavin/" + .name' \
    /tmp/_aw_repolist.json 2>/dev/null
fi > /tmp/_aw_active_repos.txt

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  SEEN_REPOS["$repo"]=1
done < /tmp/_aw_active_repos.txt

log "[2/3] Total unique repos to scan: ${#SEEN_REPOS[@]}"

# ──────────────────────────────────────────────
# 2. Scan each repo for on:schedule workflows
# ──────────────────────────────────────────────
log "[3/3] Scanning workflows..."

# Print table header
printf '%-30s | %-40s | %-30s | %-22s | %s\n' \
  "REPO" "WORKFLOW" "SCHEDULE(cron)" "STATE" "CLASS"
printf -- '%.0s-' $(seq 1 130)
printf '\n'

TOTAL_SCHEDULED=0
SAFE_COUNT=0
ATRISK_COUNT=0
DISABLED_COUNT=0
ATRISK_LIST=""
DISABLED_LIST=""
UNCLASSIFIABLE=""

for repo in "${!SEEN_REPOS[@]}"; do
  repo_short="${repo#JohnGavin/}"

  # List workflow files (404 = no .github/workflows dir — skip gracefully)
  files_json=$(gh api "repos/$repo/contents/.github/workflows" \
    --header "Accept: application/vnd.github.v3+json" \
    2>/dev/null) || {
    continue
  }

  # Validate it's a JSON array (could be a JSON object on error)
  if ! printf '%s\n' "$files_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    continue
  fi

  # Fetch workflow run-state from Actions API (one call per repo, covers all workflows)
  states_json=$(gh api "repos/$repo/actions/workflows" \
    2>/dev/null) || {
    states_json='{"workflows":[]}'
  }

  file_count=$(printf '%s\n' "$files_json" | jq 'length' 2>/dev/null) || continue
  if [ -z "$file_count" ] || [ "$file_count" -eq 0 ]; then
    continue
  fi

  i=0
  while [ "$i" -lt "$file_count" ]; do
    file_name=$(printf '%s\n' "$files_json" | jq -r ".[$i].name" 2>/dev/null)
    file_path=$(printf '%s\n' "$files_json" | jq -r ".[$i].path" 2>/dev/null)

    # Only process YAML workflow files
    case "$file_name" in
      *.yml|*.yaml) ;;
      *) i=$((i + 1)); continue ;;
    esac

    # Fetch workflow file content (base64-encoded by GitHub API)
    content_b64=$(gh api "repos/$repo/contents/$file_path" \
      --header "Accept: application/vnd.github.v3+json" \
      --jq '.content' \
      2>/dev/null) || {
      UNCLASSIFIABLE="${UNCLASSIFIABLE}  - ${repo_short}/${file_name}: could not fetch content\n"
      i=$((i + 1))
      continue
    }

    # Decode — strip embedded newlines before decode (portable for both GNU/BSD base64)
    wf_content=$(printf '%s' "$content_b64" | tr -d '\n' | base64 --decode 2>/dev/null) || {
      UNCLASSIFIABLE="${UNCLASSIFIABLE}  - ${repo_short}/${file_name}: base64 decode failed\n"
      i=$((i + 1))
      continue
    }

    # Detect on:schedule / cron: — look for a 'cron:' key in the YAML
    # Use [[:space:]] not \s — \s is not portable in BSD grep -E (macOS)
    if ! printf '%s\n' "$wf_content" | grep -qE '^[[:space:]]*-?[[:space:]]*cron:'; then
      i=$((i + 1))
      continue
    fi

    TOTAL_SCHEDULED=$((TOTAL_SCHEDULED + 1))

    # Extract first cron expression
    cron_expr=$(printf '%s\n' "$wf_content" \
      | grep -E '^[[:space:]]*-?[[:space:]]*cron:' \
      | head -1 \
      | sed "s/.*cron:[[:space:]]*//" \
      | tr -d "'" \
      | tr -d '"' \
      | sed 's/^[[:space:]]*//' \
      | sed 's/[[:space:]]*$//') || cron_expr="(unknown)"

    # Look up workflow state via Actions API (match on path)
    wf_state=$(printf '%s\n' "$states_json" \
      | jq -r --arg fpath "$file_path" \
        '.workflows[] | select(.path == $fpath) | .state' \
        2>/dev/null) || wf_state=""
    [ -z "$wf_state" ] && wf_state="unknown"

    if [ "$wf_state" = "disabled_inactivity" ] || [ "$wf_state" = "disabled_manually" ]; then
      DISABLED_COUNT=$((DISABLED_COUNT + 1))
      DISABLED_LIST="${DISABLED_LIST}  - ${repo_short}/${file_name} [state=${wf_state}]\n"
    fi

    # Classify: SAFE = body contains a git-commit/git-push pattern
    # Patterns covered:
    #   - bare 'git commit' / 'git push' steps
    #   - stefanzweifel/git-auto-commit-action (most popular auto-commit action)
    #   - EndBug/add-and-commit
    #   - actions-gh-pages / peaceiris/actions-gh-pages (gh-pages deploy via force-push)
    #   - ad-m/github-push-action
    wf_class="AT-RISK"
    # [[:space:]]+ is portable across BSD and GNU grep; \s+ is not.
    if printf '%s\n' "$wf_content" | grep -qiE \
      '(git[[:space:]]+commit|git[[:space:]]+push|git-auto-commit|add-and-commit|stefanzweifel/git-auto-commit-action|EndBug/add-and-commit|peaceiris/actions-gh-pages|ad-m/github-push-action)'; then
      wf_class="SAFE"
      SAFE_COUNT=$((SAFE_COUNT + 1))
    else
      ATRISK_COUNT=$((ATRISK_COUNT + 1))
      ATRISK_LIST="${ATRISK_LIST}  - ${repo_short}/${file_name} [state=${wf_state}, cron=${cron_expr}]\n"
    fi

    # Truncate long values for table display
    wf_display="${file_name%.yml}"
    wf_display="${wf_display%.yaml}"
    if [ "${#wf_display}" -gt 38 ]; then
      wf_display="${wf_display:0:35}..."
    fi
    cron_display="$cron_expr"
    if [ "${#cron_display}" -gt 28 ]; then
      cron_display="${cron_display:0:25}..."
    fi

    printf '%-30s | %-40s | %-30s | %-22s | %s\n' \
      "$repo_short" "$wf_display" "$cron_display" "$wf_state" "$wf_class"

    i=$((i + 1))
  done
done

# ──────────────────────────────────────────────
# 3. Summary
# ──────────────────────────────────────────────
printf '\n'
printf '%.0s═' $(seq 1 70)
printf '\nSUMMARY\n'
printf '%.0s─' $(seq 1 70)
printf '\n'
printf '  Total scheduled workflows found : %d\n' "$TOTAL_SCHEDULED"
printf '  SAFE  (self-committing)         : %d\n' "$SAFE_COUNT"
printf '  AT-RISK (non-committing)        : %d\n' "$ATRISK_COUNT"
printf '  Already disabled                : %d\n' "$DISABLED_COUNT"
printf '%.0s─' $(seq 1 70)
printf '\n'

if [ -n "$ATRISK_LIST" ]; then
  printf '\nAT-RISK workflows (non-committing — at risk of auto-disable after 60d inactivity):\n'
  printf '%b' "$ATRISK_LIST"
else
  printf '\nNo AT-RISK workflows found.\n'
fi

if [ -n "$DISABLED_LIST" ]; then
  printf '\nAlready-disabled workflows (require re-enable + commit-keepalive fix):\n'
  printf '%b' "$DISABLED_LIST"
fi

if [ -n "$UNCLASSIFIABLE" ]; then
  printf '\nUnclassifiable (could not fetch/decode content):\n'
  printf '%b' "$UNCLASSIFIABLE"
fi

printf '%.0s═' $(seq 1 70)
printf '\n'

# Cleanup temp files
rm -f /tmp/_aw_repolist.json /tmp/_aw_active_repos.txt

exit 0
