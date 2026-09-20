#!/usr/bin/env bash
# resolve_project_name.sh — print the canonical PROJECT name for a directory.
#
# Usage: resolve_project_name.sh [dir]        (default: current directory)
#
# WHY: sessions.project used to be `basename "$(pwd)"`. For a linked git
# worktree that yields the BRANCH slug (~/docs_gh/worktrees/<project>/<branch>
# -> "cc-2026..."; .claude/worktrees/agent-x -> "agent-x"), not the project.
# Measured 60d before this change: 517 of 2834 sessions (~18%) carried a
# branch slug (finding F7, .claude/incidents/2026-09-20-overnight-self-review-review.md).
#
# Resolution order:
#   1. Linked git worktree (git-common-dir != git-dir): basename of the main
#      repo that owns the common dir (strip a trailing ".git" for bare repos).
#   2. Path convention (worktree dir not usable as a git repo any more):
#        */worktrees/<project>/<branch...>   -> <project>
#        */<project>/.claude/worktrees/<x>   -> <project>
#   3. Anything else (normal checkout, non-git dir): basename of dir, i.e. the
#      pre-existing behaviour.
#
# FAIL-SAFE: never exits non-zero and always prints exactly one non-empty line
# (falls back to basename, then "unknown"). No network; only local git calls.
#
# Exit: always 0 (a hook helper; must never abort session start/stop).
# Selftest: resolve_project_name.sh --selftest   (0 pass / 1 fail)

_rpn_resolve() {
  local dir="${1:-$(pwd)}" base gd cd_ common name
  [ -d "$dir" ] || dir="$(pwd)"
  base="$(basename "$dir")"

  if command -v git >/dev/null 2>&1; then
    gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || gd=""
    common="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)" || common=""
    if [ -n "$gd" ] && [ -n "$common" ]; then
      # --git-common-dir may be relative to $dir
      case "$common" in
        /*) ;;
        *) common="$dir/$common" ;;
      esac
      cd_="$(cd "$common" 2>/dev/null && pwd -P)" || cd_=""
      gd="$(cd "$gd" 2>/dev/null && pwd -P)" || gd=""
      if [ -n "$cd_" ] && [ -n "$gd" ] && [ "$cd_" != "$gd" ]; then
        # Linked worktree.
        case "$cd_" in
          */.git) name="$(basename "$(dirname "$cd_")")" ;;
          *.git) name="$(basename "$cd_" .git)" ;;
          *) name="" ;;
        esac
        if [ -n "$name" ]; then
          printf '%s\n' "$name"
          return 0
        fi
      fi
    fi
  fi

  # Path convention fallback (deleted/unusable worktree, no git).
  local abs
  abs="$(cd "$dir" 2>/dev/null && pwd -P)" || abs="$dir"
  case "$abs" in
    */worktrees/*/*)
      name="${abs#*/worktrees/}"
      name="${name%%/*}"
      # .claude/worktrees/<x> has no project component after "worktrees/"
      case "$abs" in
        */.claude/worktrees/*)
          name="$(basename "${abs%%/.claude/worktrees/*}")" ;;
      esac
      ;;
    */.claude/worktrees/*)
      name="$(basename "${abs%%/.claude/worktrees/*}")"
      ;;
    *) name="" ;;
  esac
  if [ -n "$name" ]; then
    printf '%s\n' "$name"
    return 0
  fi

  printf '%s\n' "${base:-unknown}"
  return 0
}

_rpn_selftest() {
  local t rc=0 fails=0 got
  t="$(mktemp -d)" || { echo "selftest: mktemp failed" >&2; return 1; }
  t="$(cd "$t" && pwd -P)"
  local repo="$t/myproj"
  git init -q -b main "$repo" 2>/dev/null || git init -q "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$repo" worktree add -q "$t/worktrees/myproj/feat/x" -b feat/x 2>/dev/null \
    || git -C "$repo" worktree add -q -b feat/x "$t/worktrees/myproj/feat/x"
  git -C "$repo" worktree add -q -b agentbr "$repo/.claude/worktrees/agent-x" 2>/dev/null
  mkdir -p "$t/plain"

  _check() {
    got="$(_rpn_resolve "$1")"
    if [ "$got" = "$2" ]; then echo "PASS $3 -> $got"; else echo "FAIL $3: got '$got' want '$2'"; fails=$((fails+1)); fi
  }
  _check "$repo" "myproj" "normal checkout"
  _check "$t/worktrees/myproj/feat/x" "myproj" "convention worktree"
  _check "$repo/.claude/worktrees/agent-x" "myproj" "agent worktree"
  _check "$t/plain" "plain" "non-git dir"
  # Deleted-worktree path convention fallback (dir exists, no git metadata).
  mkdir -p "$t/nogit/worktrees/other/feat/y"
  _check "$t/nogit/worktrees/other/feat/y" "other" "path-convention fallback"

  rm -rf "$t"
  [ "$fails" -eq 0 ] || rc=1
  echo "selftest: $fails failure(s)"
  return $rc
}

case "${1:-}" in
  --selftest) _rpn_selftest; exit $? ;;
  *) _rpn_resolve "${1:-}"; exit 0 ;;
esac
