#!/usr/bin/env bash
# branch_harvest_audit.sh — Phase 7g auditor for stranded feat branches.
#
# Reports unmerged feat/cc-* (and feat/*) branches that touch user-facing
# surfaces OR were session-limit-interrupted. Designed for silent operation:
# emits nothing when the project is clean. See:
#   ~/docs_gh/llm/.claude/rules/branch-harvest-on-fork.md
#
# Exit codes:
#   0  audit ran (may or may not have findings)
#   2  not a git repo OR upstream default unresolvable; treated as fail-open
#   3  selftest mode + a test failed
#
# Env:
#   CLAUDE_BRANCH_HARVEST=0      skip entirely (logged)
#   CLAUDE_HOOK_SELFTEST=1       run the embedded selftest battery and exit
#   BRANCH_HARVEST_STALE_DAYS    override default 3 days
#   BRANCH_HARVEST_KEYWORDS_EXTRA  OR-joined into the surface keyword regex
#   BRANCH_HARVEST_REPO          path to the repo to audit (default: $PWD)

set -u
set -o pipefail

LOG="${HOME}/.claude/logs/branch_harvest.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '%s %s\n' "$(ts)" "$*" >> "$LOG"; }

# ---- Skip mechanism ----------------------------------------------------------
if [ "${CLAUDE_BRANCH_HARVEST:-1}" = "0" ]; then
  log "SKIP CLAUDE_BRANCH_HARVEST=0 cwd=$PWD"
  exit 0
fi

# ---- Selftest battery (defined here so the main body can call into it) -------
if [ "${CLAUDE_HOOK_SELFTEST:-0}" = "1" ]; then
  selftest_dir="$(mktemp -d -t branch_harvest_selftest.XXXX)"
  trap 'rm -rf "$selftest_dir"' EXIT
  pass=0
  fail=0
  total=0

  _ok()   { total=$((total+1)); pass=$((pass+1)); printf '  PASS  %s\n' "$*"; }
  _fail() { total=$((total+1)); fail=$((fail+1)); printf '  FAIL  %s\n' "$*"; }

  # Build a synthetic repo with a clean branch, a session-interrupted branch,
  # a surface-touching stale branch, and a non-feature branch. Then assert
  # the audit flags the right ones.
  cd "$selftest_dir"
  git init -q -b main
  git config user.email selftest@local
  git config user.name selftest
  echo init > seed; git add seed; git commit -q -m 'init'

  # Branch 1 — clean, recent, off-topic
  git checkout -q -b feat/cc-clean-recent
  echo a > a; git add a; git commit -q -m 'feat(infra): rotate token'

  # Branch 2 — session-limit-interrupted (should flag)
  git checkout -q main
  git checkout -q -b feat/cc-wip-interrupt
  echo b > b; git add b
  GIT_COMMITTER_DATE='2026-05-01T00:00:00Z' \
  GIT_AUTHOR_DATE='2026-05-01T00:00:00Z' \
    git commit -q -m 'WIP: agent V UI overhaul (session-limit-interrupted)'

  # Branch 3 — surface-touching, stale (should flag)
  git checkout -q main
  git checkout -q -b feat/cc-dashboard-stale
  echo c > c; git add c
  GIT_COMMITTER_DATE='2026-05-15T00:00:00Z' \
  GIT_AUTHOR_DATE='2026-05-15T00:00:00Z' \
    git commit -q -m 'feat(dashboard): swap donut for table'

  # Branch 4 — worktree-agent name (should be ignored)
  git checkout -q main
  git checkout -q -b worktree-agent-deadbeef
  echo d > d; git add d
  GIT_COMMITTER_DATE='2026-05-01T00:00:00Z' \
  GIT_AUTHOR_DATE='2026-05-01T00:00:00Z' \
    git commit -q -m 'fix(dashboard): WIP something'

  # Branch 5 — non-cc feat (will be considered)
  git checkout -q main
  git checkout -q -b feat/some-feature-stale
  echo e > e; git add e
  GIT_COMMITTER_DATE='2026-05-01T00:00:00Z' \
  GIT_AUTHOR_DATE='2026-05-01T00:00:00Z' \
    git commit -q -m 'feat(model): tweak'

  git checkout -q main

  # Run the audit
  output="$(BRANCH_HARVEST_REPO="$selftest_dir" \
            CLAUDE_HOOK_SELFTEST=0 \
            CLAUDE_BRANCH_HARVEST=1 \
            BRANCH_HARVEST_STALE_DAYS=3 \
            bash "$0" 2>&1)" || true

  echo "$output" | grep -q 'feat/cc-wip-interrupt' \
    && _ok 'flags session-limit-interrupted branch' \
    || _fail 'did not flag session-limit-interrupted branch'

  echo "$output" | grep -q 'feat/cc-dashboard-stale' \
    && _ok 'flags surface-touching stale branch' \
    || _fail 'did not flag surface-touching stale branch'

  echo "$output" | grep -q 'feat/cc-clean-recent' \
    && _fail 'should NOT flag clean recent off-topic branch' \
    || _ok 'does not flag clean recent off-topic branch'

  echo "$output" | grep -q 'worktree-agent-deadbeef' \
    && _fail 'should ignore worktree-agent-* branches' \
    || _ok 'ignores worktree-agent-* branches'

  # Add a git note to silence the wip-interrupt branch; rerun; should not flag
  tip_sha="$(git -C "$selftest_dir" rev-parse feat/cc-wip-interrupt)"
  git -C "$selftest_dir" notes --ref=harvest add -m \
    'archived 2026-06-02 — selftest' "$tip_sha"
  output2="$(BRANCH_HARVEST_REPO="$selftest_dir" \
             CLAUDE_HOOK_SELFTEST=0 \
             CLAUDE_BRANCH_HARVEST=1 \
             BRANCH_HARVEST_STALE_DAYS=3 \
             bash "$0" 2>&1)" || true
  echo "$output2" | grep -q 'feat/cc-wip-interrupt' \
    && _fail 'git-note archived branch was still flagged' \
    || _ok 'git-note archived branch is now silent'

  # Skip mechanism
  output3="$(CLAUDE_BRANCH_HARVEST=0 \
             BRANCH_HARVEST_REPO="$selftest_dir" \
             bash "$0" 2>&1)" || true
  [ -z "$output3" ] \
    && _ok 'CLAUDE_BRANCH_HARVEST=0 produces no output' \
    || _fail 'CLAUDE_BRANCH_HARVEST=0 produced output'

  printf '\nbranch_harvest_audit selftest: %d/%d PASS\n' "$pass" "$total"
  [ "$fail" -eq 0 ] && exit 0 || exit 3
fi

# ---- Resolve target repo -----------------------------------------------------
repo="${BRANCH_HARVEST_REPO:-$PWD}"
cd "$repo" 2>/dev/null || { log "FAIL cd $repo"; exit 2; }

git rev-parse --git-dir >/dev/null 2>&1 || {
  log "SKIP not-a-git-repo cwd=$repo"
  exit 0
}

# Resolve the upstream default branch (main / master / something else).
# `git rev-parse --abbrev-ref origin/HEAD` can return the literal string
# "HEAD" when the symbolic ref isn't set on the remote — treat that as
# "not resolvable" and fall back through main → master.
upstream="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|^origin/||')"
if [ -z "$upstream" ] || [ "$upstream" = "HEAD" ]; then
  if git rev-parse --verify --quiet main >/dev/null 2>&1; then
    upstream="main"
  elif git rev-parse --verify --quiet master >/dev/null 2>&1; then
    upstream="master"
  else
    log "SKIP no-upstream-default cwd=$repo"
    exit 0
  fi
fi
git rev-parse --verify --quiet "$upstream" >/dev/null 2>&1 || {
  log "SKIP upstream-not-found upstream=$upstream cwd=$repo"
  exit 0
}

# Stale threshold (days)
stale_days="${BRANCH_HARVEST_STALE_DAYS:-3}"
# Reference epoch: now minus stale_days
now_epoch="$(date -u +%s)"
stale_epoch=$(( now_epoch - stale_days * 86400 ))

# Surface-keyword regex (case-insensitive). Project override is OR-joined.
default_kw='dashboard|vignette|readme|\.qmd|\.css|\.scss|model/|R/|app/|plumber|shiny|figure|chart|plot|table|caption|font|render|website|docs/'
extra_kw="${BRANCH_HARVEST_KEYWORDS_EXTRA:-}"
# Also read project-level CLAUDE.md
if [ -f .claude/CLAUDE.md ]; then
  proj_extra="$(grep -E '^branch-harvest-keywords:' .claude/CLAUDE.md 2>/dev/null \
                | head -1 | sed -E 's/^branch-harvest-keywords:[[:space:]]*//')"
  if [ -n "${proj_extra:-}" ]; then
    extra_kw="${extra_kw:+$extra_kw|}$proj_extra"
  fi
fi
keyword_re="${extra_kw:+($default_kw|$extra_kw)}"
keyword_re="${keyword_re:-$default_kw}"

# Project-level skip regex
skip_re=""
if [ -f .claude/CLAUDE.md ]; then
  skip_re="$(grep -E '^branch-harvest-skip:' .claude/CLAUDE.md 2>/dev/null \
             | head -1 | sed -E 's/^branch-harvest-skip:[[:space:]]*//')"
fi

# Enforce mode? (advisory by default; future hook can act on this)
enforce=0
if [ -f .claude/CLAUDE.md ] && \
   grep -qE '^branch-harvest:[[:space:]]*enforce' .claude/CLAUDE.md 2>/dev/null; then
  enforce=1
fi

# ---- Walk unmerged feat branches --------------------------------------------
# `git branch --no-merged <upstream>` outputs lines prefixed by one of:
#   "  "  — local branch, not currently checked out
#   "* "  — current branch
#   "+ "  — checked out in another worktree
# Strip any leading combination of space/asterisk/plus; keep feat/* names;
# skip worktree-agent-* (harness-managed).
unmerged="$(git branch --no-merged "$upstream" 2>/dev/null \
            | sed -E 's/^[[:space:]*+]+//' \
            | grep -E '^feat/' \
            | grep -vE '^worktree-agent-' || true)"

if [ -z "$unmerged" ]; then
  log "OK no-unmerged-feat-branches upstream=$upstream cwd=$repo"
  exit 0
fi

flagged_blocks=""
flagged_n=0

while IFS= read -r branch; do
  [ -n "$branch" ] || continue
  if [ -n "$skip_re" ] && printf '%s' "$branch" | grep -qE "$skip_re"; then
    continue
  fi

  # Tip date (epoch) for staleness
  tip_iso="$(git log -1 --format=%cI "$branch" 2>/dev/null)"
  if [ -z "$tip_iso" ]; then
    continue
  fi
  # Normalise the ISO timestamp for macOS `date -j`:
  # - replace `Z` with `+0000`
  # - strip the colon from `+HH:MM` → `+HHMM`
  norm_iso="${tip_iso/Z/+0000}"
  norm_iso="$(printf '%s' "$norm_iso" \
               | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/')"
  tip_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%S%z' "$norm_iso" '+%s' 2>/dev/null \
                || date -u -d "$tip_iso" '+%s' 2>/dev/null \
                || echo 0)"

  # Git note exemption (per-branch silence)
  tip_sha="$(git rev-parse "$branch" 2>/dev/null)"
  note_body="$(git notes --ref=harvest show "$tip_sha" 2>/dev/null || true)"
  if printf '%s\n' "$note_body" | grep -qE '^(archived|harvested) '; then
    continue
  fi

  # Last 5 commit subjects
  recent="$(git log -5 --format='%h  %s' "$branch" 2>/dev/null)"

  # Flag detection
  flags=""
  if printf '%s\n' "$recent" \
     | grep -qE '(session-limit-interrupted|^[a-f0-9]+  WIP:|\(WIP\))'; then
    flags="${flags:+$flags, }SESSION_INTERRUPTED"
  fi
  if printf '%s\n' "$recent" | grep -qiE "$keyword_re"; then
    flags="${flags:+$flags, }SURFACE_TOUCHED"
  fi
  stale=0
  if [ "$tip_epoch" -gt 0 ] && [ "$tip_epoch" -lt "$stale_epoch" ]; then
    flags="${flags:+$flags, }STALE"
    stale=1
  fi

  # Report iff SESSION_INTERRUPTED OR (SURFACE_TOUCHED AND STALE)
  report=0
  case "$flags" in
    *SESSION_INTERRUPTED*) report=1 ;;
  esac
  if [ $report -eq 0 ] && [ $stale -eq 1 ] && \
     printf '%s' "$flags" | grep -q 'SURFACE_TOUCHED'; then
    report=1
  fi
  [ $report -eq 1 ] || continue

  # Compute days stale (integer)
  if [ "$tip_epoch" -gt 0 ]; then
    days_stale=$(( (now_epoch - tip_epoch) / 86400 ))
  else
    days_stale=0
  fi

  flagged_n=$((flagged_n + 1))
  block="$(printf '  %s (%dd stale) [%s]\n%s' \
            "$branch" "$days_stale" "$flags" \
            "$(printf '%s\n' "$recent" | sed 's/^/    /')")"
  flagged_blocks="${flagged_blocks:+$flagged_blocks
}$block"

done <<EOF
$unmerged
EOF

if [ "$flagged_n" -eq 0 ]; then
  log "OK no-flagged upstream=$upstream cwd=$repo"
  exit 0
fi

# ---- Emit the user-visible report -------------------------------------------
mode_suffix=""
[ "$enforce" = "1" ] && mode_suffix=" (enforce)"

printf 'branch-harvest: %d unmerged feat %s flagged%s\n' \
  "$flagged_n" "$([ "$flagged_n" = 1 ] && echo branch || echo branches)" "$mode_suffix"
printf '%s\n' "$flagged_blocks"
printf '→ Triage: harvest | archive | discard.\n'
printf '  See ~/docs_gh/llm/.claude/rules/branch-harvest-on-fork.md. Log: %s\n' "$LOG"

log "REPORT n=$flagged_n upstream=$upstream cwd=$repo"
exit 0
