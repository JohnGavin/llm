#!/usr/bin/env bash
# mem_pr.sh — route dirty memory/rule prose edits in the main checkout into
# ONE rolling PR (llm#770, llm#1446; root cause of llm#510).
#
# Why it exists:
#   Sessions edit `.claude/memory/*.md` (a symlink target shared by every
#   session, llm#144), `.claude/rules/*.md` and CHANGELOG.md in the MAIN
#   checkout. A chronically dirty main checkout jams the ff-only deploy pull
#   (llm#510). This script turns that dirt into a PR.
#
# Design (llm#1446). The old version switched the main checkout to a throwaway
# branch, which only worked when /bye had run, when the checkout sat on `main`
# and when no other session was using it; in practice it ran from the wrong
# directory and `timeout` was missing, so it never opened a PR. This version:
#   - runs on EVERY Stop event (session_stop.sh no longer gates it on /bye);
#   - NEVER touches the main checkout's HEAD, index or working tree: it copies
#     the dirty prose files into a temporary git worktree based on
#     origin/<rolling branch> (or origin/main), commits there, pushes, and
#     removes the temporary worktree;
#   - uses ONE rolling branch per UTC day, `chore/memory-<YYYYMMDD>`, and ONE
#     open PR for it (a second run adds a commit to the same branch);
#   - is idempotent: a file whose content is already on the branch adds nothing;
#   - is cheap when nothing is dirty (one `git ls-files`), rate-limited when
#     something is (MEM_PR_MIN_INTERVAL seconds, default 600) and serialised by
#     a lock directory, so concurrent sessions cannot race;
#   - never merges, never force-pushes, never uses --no-verify.
#
# Only these pathspecs are routed (prose only, never code):
#   .claude/memory/**   .claude/rules/**   CHANGELOG.md
# Every other dirty file (e.g. settings.local.json.*) is left alone.
#
# A dirty file whose copy on origin/main has moved on since the checkout's HEAD
# is skipped and reported ("stale base"): routing it would overwrite newer work.
#
# Usage:  .claude/scripts/mem_pr.sh [main_checkout]   (default ~/docs_gh/llm)
# Opt-out: SKIP_MEM_PR=1
# Env:    MEM_PR_STATE_DIR (lock + stamp; default ~/.claude/logs)
#         MEM_PR_MIN_INTERVAL (seconds, default 600)  MEM_PR_REMOTE (origin)
#         MEM_PR_BASE (main)
#
# Exit codes (checks-must-distinguish-unknown):
#   0  no-op (nothing dirty / already routed / throttled / locked / opt-out),
#      or PR opened/updated
#   1  genuine failure (not a repo, fetch/push/gh failed)
#   3  commit BLOCKED (e.g. the private-data scan rejected the files): reported
#      loudly, NEVER bypassed; the working tree is untouched

set -uo pipefail

REPO_ROOT="${1:-${HOME}/docs_gh/llm}"
REMOTE="${MEM_PR_REMOTE:-origin}"
BASE="${MEM_PR_BASE:-main}"
STATE_DIR="${MEM_PR_STATE_DIR:-${HOME}/.claude/logs}"
MIN_INTERVAL="${MEM_PR_MIN_INTERVAL:-600}"

log() { printf 'mem_pr: %s\n' "$1"; }

if [ -n "${SKIP_MEM_PR:-}" ]; then
  log "SKIP_MEM_PR set — no-op"
  exit 0
fi

if ! git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
  log "ERROR: ${REPO_ROOT} is not a git repo — aborting"
  exit 1
fi

PROSE_PATHSPECS=(
  ".claude/memory/**"
  ".claude/rules/**"
  "CHANGELOG.md"
)

# ── Step 1: candidate files (cheap, local, read-only) ────────────────────
present="$( { git -C "${REPO_ROOT}" ls-files -m -o --exclude-standard -- "${PROSE_PATHSPECS[@]}"; } 2>/dev/null | sort -u)"
deleted="$(git -C "${REPO_ROOT}" ls-files -d -- "${PROSE_PATHSPECS[@]}" 2>/dev/null | sort -u)"
# A path can be listed as modified AND deleted; deletion wins.
if [ -n "${deleted}" ] && [ -n "${present}" ]; then
  present="$(printf '%s\n' "${present}" | grep -vxF -f <(printf '%s\n' "${deleted}") || true)"
fi
if [ -z "${present}" ] && [ -z "${deleted}" ]; then
  log "nothing to route"
  exit 0
fi

# ── Step 2: lock (serialise concurrent sessions) ─────────────────────────
mkdir -p "${STATE_DIR}"
LOCK_DIR="${STATE_DIR}/mem_pr.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  lock_pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
  if [ -n "${lock_pid}" ] && kill -0 "${lock_pid}" 2>/dev/null; then
    log "another mem_pr run is active (pid ${lock_pid}) — no-op"
    exit 0
  fi
  log "removing stale lock (pid '${lock_pid}' not running)"
  rm -rf "${LOCK_DIR}"
  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    log "another mem_pr run took the lock — no-op"
    exit 0
  fi
fi
printf '%s\n' "$$" > "${LOCK_DIR}/pid"

WT_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/mem_pr.XXXXXX")"
WT="${WT_PARENT}/wt"
cleanup() {
  git -C "${REPO_ROOT}" worktree remove --force "${WT}" >/dev/null 2>&1 || true
  git -C "${REPO_ROOT}" worktree prune >/dev/null 2>&1 || true
  rm -rf "${WT_PARENT}" "${LOCK_DIR}"
}
trap cleanup EXIT

# ── Step 3: throttle (only when there IS something dirty) ────────────────
STAMP="${STATE_DIR}/mem_pr.last_attempt"
now="$(date +%s)"
last="$(cat "${STAMP}" 2>/dev/null || echo 0)"
case "${last}" in ''|*[!0-9]*) last=0 ;; esac
if [ $((now - last)) -lt "${MIN_INTERVAL}" ]; then
  log "throttled (last attempt $((now - last))s ago, min ${MIN_INTERVAL}s) — no-op"
  exit 0
fi
printf '%s\n' "${now}" > "${STAMP}"

# ── Step 4: fetch, pick the base ─────────────────────────────────────────
branch_name="chore/memory-$(date -u +%Y%m%d)"
if ! git -C "${REPO_ROOT}" fetch --quiet "${REMOTE}" 2>&1; then
  log "ERROR: git fetch ${REMOTE} failed"
  exit 1
fi
if ! git -C "${REPO_ROOT}" rev-parse --verify --quiet "refs/remotes/${REMOTE}/${BASE}" >/dev/null; then
  log "ERROR: ${REMOTE}/${BASE} not found"
  exit 1
fi
base_ref="${REMOTE}/${BASE}"
if git -C "${REPO_ROOT}" rev-parse --verify --quiet "refs/remotes/${REMOTE}/${branch_name}" >/dev/null; then
  base_ref="${REMOTE}/${branch_name}"
fi

if ! git -C "${REPO_ROOT}" worktree add --detach "${WT}" "${base_ref}" >/dev/null 2>&1; then
  log "ERROR: could not create temporary worktree on ${base_ref}"
  exit 1
fi

# ── Step 5: copy dirty prose into the temporary worktree ─────────────────
n_stale=0
n_copied=0
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  om="$(git -C "${REPO_ROOT}" rev-parse --verify --quiet "${REMOTE}/${BASE}:${f}" 2>/dev/null || true)"
  hd="$(git -C "${REPO_ROOT}" rev-parse --verify --quiet "HEAD:${f}" 2>/dev/null || true)"
  if [ -n "${om}" ] && [ "${om}" != "${hd}" ]; then
    wb="$(git -C "${REPO_ROOT}" hash-object -- "${f}" 2>/dev/null || true)"
    if [ "${wb}" != "${om}" ]; then
      log "stale base, left alone: ${f}"
      n_stale=$((n_stale + 1))
      continue
    fi
  fi
  mkdir -p "${WT}/$(dirname "${f}")"
  cp -p "${REPO_ROOT}/${f}" "${WT}/${f}"
  n_copied=$((n_copied + 1))
done <<< "${present}"
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  om="$(git -C "${REPO_ROOT}" rev-parse --verify --quiet "${REMOTE}/${BASE}:${f}" 2>/dev/null || true)"
  hd="$(git -C "${REPO_ROOT}" rev-parse --verify --quiet "HEAD:${f}" 2>/dev/null || true)"
  if [ "${om}" != "${hd}" ]; then
    log "stale base, left alone: ${f} (deleted locally)"
    n_stale=$((n_stale + 1))
    continue
  fi
  rm -f "${WT}/${f}"
  n_copied=$((n_copied + 1))
done <<< "${deleted}"

# ── Step 6: stage ONLY prose paths; already-routed content adds nothing ──
for spec in "${PROSE_PATHSPECS[@]}"; do
  git -C "${WT}" add -A -- "${spec}" 2>/dev/null || true
done
staged_files="$(git -C "${WT}" diff --cached --name-only)"
if [ -z "${staged_files}" ]; then
  log "already routed (${n_copied} candidate file(s) match ${base_ref}; ${n_stale} stale) — no-op"
  exit 0
fi
outside_prose="$(printf '%s\n' "${staged_files}" | grep -vE '^(\.claude/memory/|\.claude/rules/|CHANGELOG\.md$)' || true)"
if [ -n "${outside_prose}" ]; then
  log "ABORT: staged files outside prose pathspecs — nothing committed"
  exit 1
fi

# ── Step 7: commit (hooks, including the private-data scan, run — never bypassed)
commit_body="$(printf 'Files:\n%s\n\nRefs #1446, #770\nCo-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>' "$(printf '%s\n' "${staged_files}" | sed 's/^/  - /')")"
if ! commit_out="$(git -C "${WT}" commit -m "chore(memory): route session prose edits to PR (#1446)" -m "${commit_body}" 2>&1)"; then
  n_staged="$(printf '%s\n' "${staged_files}" | wc -l | tr -d ' ')"
  log "BLOCKED (exit 3): commit of ${n_staged} file(s) was rejected (e.g. private-data scan); not bypassed, main checkout untouched"
  printf '%s\n' "${commit_out}" | tail -n 5 | sed 's/^/mem_pr:   | /'
  exit 3
fi

# ── Step 8: push (fast-forward only) and open/update the ONE PR ──────────
if ! git -C "${WT}" push "${REMOTE}" "HEAD:refs/heads/${branch_name}" 2>&1; then
  log "ERROR: push to ${branch_name} failed"
  exit 1
fi

existing_pr="$( (cd "${WT}" && gh pr list --head "${branch_name}" --state open --json url --jq '.[0].url') 2>/dev/null || true)"
if [ -n "${existing_pr}" ]; then
  log "PR updated: ${existing_pr}"
  echo "${existing_pr}"
  exit 0
fi

pr_body="$(printf 'Routes memory/rules/CHANGELOG prose edits left dirty in the main checkout (llm#510 root cause) into one rolling PR per day. Opened by .claude/scripts/mem_pr.sh on a Stop event; never merged by the script.\n\nRefs #1446, #770')"
if ! pr_url="$( (cd "${WT}" && gh pr create --base "${BASE}" --head "${branch_name}" \
    --title "chore(memory): route session prose edits to PR (#1446)" \
    --body "${pr_body}") 2>&1)"; then
  log "ERROR: gh pr create failed: ${pr_url}"
  log "branch ${branch_name} was pushed — a human can open the PR manually"
  exit 1
fi
log "PR opened: ${pr_url}"
echo "${pr_url}"
exit 0
