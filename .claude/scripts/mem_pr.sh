#!/usr/bin/env bash
# mem_pr.sh — Session-end batch PR for memory/rule prose edits (llm#770,
# Option A).
#
# Problem this fixes (llm#510 root cause, llm#770):
#   Orchestrator sessions routinely leave uncommitted `.claude/memory/*.md`,
#   `.claude/rules/*.md`, and `CHANGELOG.md` edits in the MAIN checkout.
#   That keeps the tree chronically dirty, which is exactly the condition
#   cron_deploy_pull.sh (llm#510) has to work around every run (autostash +
#   retry instead of a clean fast-forward). This script routes those prose
#   edits into a branch + PR at session end so the checkout goes back to
#   clean between sessions. It NEVER pushes to main directly — always via
#   PR (see pr-shipping-discipline rule) — and the caller must merge.
#
# What it does:
#   1. Finds dirty (modified OR untracked) files limited to the prose
#      pathspecs below.
#   2. If none are dirty: logs "nothing to route" and exits 0 (no-op).
#   3. If the repo is NOT currently on the default branch `main` (e.g. a
#      `feat/cc-*` orchestrator session branch): logs a skip and exits 0.
#      Routing memory edits from a session branch would base the memory PR
#      on that branch instead of main — the stale-base hazard from llm#304.
#   4. Otherwise: creates branch `chore/memory-<UTC timestamp>` off current
#      HEAD, stages ONLY the prose pathspecs, commits, pushes, and opens a
#      PR (base main, never merged). Prints the PR URL on stdout.
#
# Pathspecs routed (prose only — never code):
#   .claude/memory/**
#   .claude/rules/**
#   CHANGELOG.md
#
# Usage:
#   .claude/scripts/mem_pr.sh [repo_root]
#   (repo_root defaults to the llm main checkout: ~/docs_gh/llm)
#
# Opt-out:
#   SKIP_MEM_PR=1 .claude/scripts/mem_pr.sh
#
# Safety (defense in depth):
#   After `git add -- <prose pathspecs>`, the script verifies every staged
#   file actually matches a prose pathspec. If anything else were ever
#   staged (e.g. a future pathspec typo), it aborts loudly, unstages,
#   deletes the throwaway branch, and returns non-zero WITHOUT committing
#   or pushing anything.
#
# Exit codes:
#   0  — no-op (nothing dirty, SKIP_MEM_PR set, or not on main), or PR opened
#   1  — genuine failure (not a git repo, safety check tripped, push/PR failed)
#
# Refs: llm#770 (this script), llm#510 (root cause), llm#304 (stale-base hazard)

set -euo pipefail

_MEMPR_DEFAULT_REPO="${HOME}/docs_gh/llm"
REPO_ROOT="${1:-${_MEMPR_DEFAULT_REPO}}"

log() {
  printf 'mem_pr: %s\n' "$1"
}

if [ -n "${SKIP_MEM_PR:-}" ]; then
  log "SKIP_MEM_PR set — no-op"
  exit 0
fi

if ! git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
  log "ERROR: ${REPO_ROOT} is not a git repo — aborting"
  exit 1
fi

# Prose-only pathspecs (llm#770). .claude/memory/** already covers
# MEMORY.md, so no separate entry is needed for it.
PROSE_PATHSPECS=(
  ".claude/memory/**"
  ".claude/rules/**"
  "CHANGELOG.md"
)

# ── Step 1: any dirty prose paths at all? ─────────────────────────────────
dirty_status="$(git -C "${REPO_ROOT}" status --porcelain -- "${PROSE_PATHSPECS[@]}" 2>/dev/null || true)"
if [ -z "${dirty_status}" ]; then
  log "nothing to route"
  exit 0
fi

# ── Step 2: branch guard — only route from the default branch (main) ─────
current_branch="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
if [ "${current_branch}" != "main" ]; then
  log "repo on ${current_branch}, not main — skipping to avoid basing memory PR on a session branch"
  exit 0
fi

n_files="$(echo "${dirty_status}" | wc -l | tr -d ' ')"
log "found ${n_files} dirty prose file(s) on main:"
while IFS= read -r line; do
  [ -n "${line}" ] && log "  ${line}"
done <<< "${dirty_status}"

# ── Step 3: create branch, stage ONLY prose paths, commit, push, open PR ─
branch_name="chore/memory-$(date -u +%Y%m%d-%H%M%S)"
git -C "${REPO_ROOT}" checkout -b "${branch_name}"

# On any failure from here on, restore the caller to main before exiting so
# a mid-flight error never leaves the main checkout stranded on the
# throwaway branch (which would itself jam the next cron pull).
_mempr_cleanup_branch() {
  git -C "${REPO_ROOT}" checkout main >/dev/null 2>&1 || true
  git -C "${REPO_ROOT}" branch -D "${branch_name}" >/dev/null 2>&1 || true
}

# Add each pathspec individually and ignore per-pathspec failures: `git add`
# is fatal ("did not match any files") if a single glob pathspec matches
# nothing, which happens routinely — most sessions touch only ONE of
# memory/rules/CHANGELOG, not all three. A combined `git add -- a b c`
# would abort on the first non-matching pathspec and never stage the
# others; adding them one at a time isolates each pathspec's outcome.
for _mempr_spec in "${PROSE_PATHSPECS[@]}"; do
  git -C "${REPO_ROOT}" add -- "${_mempr_spec}" 2>/dev/null || true
done

# Defense-in-depth: verify the staged set is a subset of the prose pathspecs.
staged_files="$(git -C "${REPO_ROOT}" diff --cached --name-only)"
outside_prose="$(echo "${staged_files}" | grep -vE '^(\.claude/memory/|\.claude/rules/|CHANGELOG\.md$)' || true)"
if [ -n "${outside_prose}" ]; then
  log "ABORT: staged files outside prose pathspecs detected — unstaging and bailing:"
  while IFS= read -r f; do
    [ -n "${f}" ] && log "  ${f}"
  done <<< "${outside_prose}"
  git -C "${REPO_ROOT}" reset >/dev/null 2>&1 || true
  _mempr_cleanup_branch
  exit 1
fi

if [ -z "${staged_files}" ]; then
  log "nothing staged after add (unexpected) — bailing without committing"
  _mempr_cleanup_branch
  exit 0
fi

commit_body="$(printf 'Files:\n%s\n\nRefs #770\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>' "$(echo "${staged_files}" | sed 's/^/  - /')")"

if ! git -C "${REPO_ROOT}" commit -m "chore(memory): route session prose edits to PR (#770)" -m "${commit_body}"; then
  log "ERROR: commit failed — cleaning up branch"
  _mempr_cleanup_branch
  exit 1
fi

if ! git -C "${REPO_ROOT}" push -u origin "${branch_name}"; then
  log "ERROR: push failed — leaving branch ${branch_name} in place locally for manual retry"
  git -C "${REPO_ROOT}" checkout main >/dev/null 2>&1 || true
  exit 1
fi

pr_body="$(printf 'Batches pending .claude/memory/**, .claude/rules/**, and CHANGELOG.md edits left dirty in the main checkout at session end (llm#510 root cause). Never pushes to main directly.\n\nRefs #770')"

if ! pr_url="$(cd "${REPO_ROOT}" && gh pr create --base main --head "${branch_name}" \
    --title "chore(memory): route session prose edits to PR (#770)" \
    --body "${pr_body}" 2>&1)"; then
  log "ERROR: gh pr create failed: ${pr_url}"
  log "branch ${branch_name} was pushed — a human can open the PR manually"
  git -C "${REPO_ROOT}" checkout main >/dev/null 2>&1 || true
  exit 1
fi

log "PR opened: ${pr_url}"
git -C "${REPO_ROOT}" checkout main >/dev/null 2>&1 || true
echo "${pr_url}"
