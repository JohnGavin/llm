#!/usr/bin/env bash
# cron_deploy_pull.sh — Shared dirty-tolerant "pull latest main" helper for
# launchd cron wrappers (llm#510, attempt #3).
#
# Problem this fixes:
#   `git merge --ff-only origin/main` aborts whenever the main checkout's
#   working tree is dirty (very common — orchestrator sessions routinely
#   leave uncommitted .claude/memory/*.md edits). The abort was previously
#   swallowed by `2>/dev/null`, and every wrapper's `else` branch silently
#   ran stale code for weeks with no visible signal (llm#510 recurrence,
#   2026-07-11).
#
# What this helper does:
#   1. Fetches origin/main.
#   2. If already up to date (0 commits behind), logs and returns 0.
#   3. If behind and the tree is clean, does a plain ff-only merge.
#   4. If behind and the tree is DIRTY, auto-stashes (including untracked
#      files), retries the ff-only merge, then pops the stash back.
#      - If the stash pop conflicts, the fast-forward is KEPT (never
#        rolled back) and the stash entry is left on the stack for manual
#        resolution — local edits are never lost silently.
#   5. Always writes a machine-readable JSON status file so downstream
#      consumers (the daily email) can surface staleness to a human.
#
# Usage (source, then call — NOT executed directly):
#   # shellcheck disable=SC1091
#   source "${REPO_ROOT}/.claude/scripts/cron_deploy_pull.sh"
#   cron_deploy_pull "${REPO_ROOT}" log
#
# Arguments:
#   $1  Absolute path to the repo root to pull in.
#   $2  Name of an already-defined shell function to use for logging
#       (e.g. `log`). Invoked as `"$2" "message"`. Optional — if omitted
#       or not a defined function, logging is silently skipped.
#
# Respects SKIP_CRON_PULL exactly like the block it replaces: any non-empty
# value skips the pull entirely (used by manual/dry-run invocations).
#
# Env:
#   DEPLOY_STATUS_FILE   Override path for the JSON status file.
#                        Default: $HOME/.claude/logs/cron_deploy_status.json
#
# Return code: 0 on success (including "clean" and "autostashed" and
# "pop-conflict" — the pull itself succeeded in all three cases) or when
# skipped via SKIP_CRON_PULL. Non-zero ONLY when the ff-only merge itself
# could not be made to succeed (reason=ff-failed) — a genuine deploy
# failure, distinct from the informational pop-conflict case.
#
# Tracked in llm#510 (attempt #3).

cron_deploy_pull() {
  local repo="$1"
  local log_fn="${2:-}"
  local status_file="${DEPLOY_STATUS_FILE:-${HOME}/.claude/logs/cron_deploy_status.json}"

  _cdp_log() {
    if [ -n "${log_fn}" ] && declare -F "${log_fn}" >/dev/null 2>&1; then
      "${log_fn}" "$1"
    fi
  }

  _cdp_write_status() {
    local ok="$1" behind="$2" head_sha="$3" reason="$4"
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    mkdir -p "$(dirname "${status_file}")" 2>/dev/null || true
    printf '{"ok":%s,"behind":%s,"head":"%s","reason":"%s","ts":"%s"}\n' \
      "${ok}" "${behind}" "${head_sha}" "${reason}" "${ts}" \
      > "${status_file}" 2>/dev/null || true
  }

  if [ -n "${SKIP_CRON_PULL:-}" ]; then
    _cdp_log "deploy: SKIP_CRON_PULL set — not pulling"
    return 0
  fi

  git -C "${repo}" fetch origin main 2>/dev/null || true

  local behind head_sha
  behind="$(git -C "${repo}" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  [ -z "${behind}" ] && behind=0
  head_sha="$(git -C "${repo}" rev-parse --short HEAD 2>/dev/null || echo unknown)"

  if [ "${behind}" = "0" ]; then
    _cdp_log "deploy: up to date"
    _cdp_write_status true 0 "${head_sha}" "clean"
    return 0
  fi

  # Behind — try a straight ff-only merge first (clean-tree fast path).
  if git -C "${repo}" merge --ff-only origin/main 2>/dev/null; then
    head_sha="$(git -C "${repo}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    _cdp_log "deploy: ff to ${head_sha}"
    _cdp_write_status true 0 "${head_sha}" "clean"
    return 0
  fi

  _cdp_log "deploy: ff-only failed on first attempt (${behind} behind) — checking for dirty tree"

  if git -C "${repo}" diff --quiet 2>/dev/null && git -C "${repo}" diff --cached --quiet 2>/dev/null; then
    # Tree is clean but ff-only still failed — genuine divergence (local
    # commits ahead / diverged history), not a dirty-tree issue. Do not
    # stash; nothing to stash, and stashing would not fix divergence.
    head_sha="$(git -C "${repo}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    _cdp_log "deploy WARN: ff-only failed — running against ${head_sha} (${behind} behind; tree clean, likely diverged history)"
    _cdp_write_status false "${behind}" "${head_sha}" "ff-failed"
    return 1
  fi

  # Tree is dirty — auto-stash (including untracked) and retry.
  local stash_marker="cron-deploy-autostash-$$"
  if ! git -C "${repo}" stash push --include-untracked -m "${stash_marker}" 2>/dev/null; then
    head_sha="$(git -C "${repo}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    _cdp_log "deploy WARN: stash push failed — running against ${head_sha} (${behind} behind)"
    _cdp_write_status false "${behind}" "${head_sha}" "ff-failed"
    return 1
  fi

  if ! git -C "${repo}" merge --ff-only origin/main 2>/dev/null; then
    # Should be rare (tree was just made clean by the stash), but restore
    # the stash and bail without losing anything if it happens.
    git -C "${repo}" stash pop 2>/dev/null || true
    head_sha="$(git -C "${repo}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    _cdp_log "deploy WARN: ff-only failed even after autostash — running against ${head_sha} (${behind} behind)"
    _cdp_write_status false "${behind}" "${head_sha}" "ff-failed"
    return 1
  fi

  head_sha="$(git -C "${repo}" rev-parse --short HEAD 2>/dev/null || echo unknown)"

  if git -C "${repo}" stash pop 2>/dev/null; then
    _cdp_log "deploy: ff to ${head_sha} (autostashed + restored local edits)"
    _cdp_write_status true 0 "${head_sha}" "autostashed"
    return 0
  fi

  # Pop conflicted. The fast-forward already succeeded (HEAD is now
  # ${head_sha}) — keep it. Do NOT attempt to undo the merge: there is no
  # in-progress merge to abort once --ff-only has completed; the conflict
  # is confined to applying the stash back onto the working tree. Leave
  # the stash entry on the stack (visible via `git stash list`) so the
  # user's edits are preserved for manual `git stash pop` resolution.
  _cdp_log "deploy WARN: ff applied to ${head_sha} but stash pop CONFLICTED — local edits preserved in 'git stash list' (${stash_marker}); resolve manually with 'git stash pop'"
  _cdp_write_status false "${behind}" "${head_sha}" "pop-conflict"
  return 0
}
