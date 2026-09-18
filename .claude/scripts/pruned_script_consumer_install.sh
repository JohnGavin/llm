#!/usr/bin/env bash
# pruned_script_consumer_install.sh — wire pruned_script_consumer_precommit.sh
# into a repo's pre-commit hook, idempotently (llm#1067).
#
# Mirrors indeterminate_hook_install.sh's install pattern exactly — same
# reasons apply: .git/hooks/ is not version-controlled, so the wiring itself
# must be a committed, idempotent, self-testing script rather than a hand
# edit that silently vanishes on a fresh clone or hooks-dir reset.
#
# NOT run automatically by this dispatch. Installing a gate into the live,
# shared .git/hooks/pre-commit of the main checkout is a deliberate step for
# a human (or a follow-up dispatch scoped to do exactly that) to take
# knowingly — not something a worktree-scoped agent should do as a side
# effect of fixing the two items in llm#1067.
#
# Usage:
#   pruned_script_consumer_install.sh [--repo <path>] [--dry-run] [--uninstall]
#   pruned_script_consumer_install.sh --selftest
#
# Exit: 0 ok · 1 failed · 2 usage
#
# llm#1067

set -uo pipefail

MARKER="# >>> pruned-script-consumer-check gate (llm#1067) >>>"
END_MARKER="# <<< pruned-script-consumer-check gate <<<"
REPO="."
DRY_RUN=0
UNINSTALL=0
SELFTEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    (--repo)      REPO="${2:-}"; shift 2 ;;
    (--dry-run)   DRY_RUN=1; shift ;;
    (--uninstall) UNINSTALL=1; shift ;;
    (--selftest)  SELFTEST=1; shift ;;
    (-h|--help)   echo "Usage: $(basename "$0") [--repo <path>] [--dry-run] [--uninstall] | --selftest" >&2; exit 2 ;;
    (*)           echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Resolve the directory git ACTUALLY reads hooks from (respects
# core.hooksPath — see indeterminate_hook_install.sh's header for why this
# matters: writing to .git/hooks while git reads elsewhere installs a hook
# git never runs).
_hooks_dir() {
  local repo="$1" hp gitdir
  hp="$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)"
  if [ -n "$hp" ]; then
    case "$hp" in
      (/*) printf '%s' "$hp" ;;
      (*)  printf '%s/%s' "$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" "$hp" ;;
    esac
    return 0
  fi
  gitdir="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$gitdir" in
    (/*) printf '%s/hooks' "$gitdir" ;;
    (*)  printf '%s/%s/hooks' "$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" "$gitdir" ;;
  esac
}

_block() {
  cat <<BLOCK
$MARKER
# Blocks a commit that deletes a file under .claude/scripts/, .claude/hooks/,
# .claude/templates/, or bin/ while a surviving consumer under \$HOME/docs_gh
# still references its basename (llm#1067). Installed by
# pruned_script_consumer_install.sh — re-run it rather than editing this
# block by hand. Kill switch: SKIP_CONSUMER_CHECK=1.
if [ -x "\$HOME/.claude/scripts/pruned_script_consumer_precommit.sh" ]; then
  "\$HOME/.claude/scripts/pruned_script_consumer_precommit.sh" || exit 1
fi
$END_MARKER
BLOCK
}

run_install() {
  local hooks_dir hook
  hooks_dir="$(_hooks_dir "$REPO")" || { echo "FATAL: not a git repo: $REPO" >&2; return 1; }
  hook="$hooks_dir/pre-commit"

  echo "hooks dir: $hooks_dir"

  if [ "$UNINSTALL" -eq 1 ]; then
    if [ ! -f "$hook" ] || ! grep -qF "$MARKER" "$hook" 2>/dev/null; then
      echo "not installed — nothing to remove"; return 0
    fi
    [ "$DRY_RUN" -eq 1 ] && { echo "[dry-run] would remove the gate block from $hook"; return 0; }
    local tmp; tmp="$(mktemp)"
    awk -v s="$MARKER" -v e="$END_MARKER" '
      index($0,s){skip=1} !skip{print} index($0,e){skip=0}' "$hook" > "$tmp"
    cat "$tmp" > "$hook"; rm -f "$tmp"
    echo "removed"; return 0
  fi

  if [ -f "$hook" ] && grep -qF "$MARKER" "$hook" 2>/dev/null; then
    echo "already installed — no change (idempotent)"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would append to $hook:"
    _block | sed 's/^/    /'
    return 0
  fi

  mkdir -p "$hooks_dir"
  if [ ! -f "$hook" ]; then
    printf '#!/bin/sh\n' > "$hook"
  fi
  # Append, never overwrite — other gates already live here.
  printf '\n' >> "$hook"
  _block >> "$hook"
  chmod +x "$hook"
  echo "installed"
  return 0
}

selftest() {
  local T pass=0 fail=0
  T="$(mktemp -d)"
  ok(){ pass=$((pass+1)); echo "  PASS: $1"; }
  bad(){ fail=$((fail+1)); echo "  FAIL: $1"; }
  echo "pruned_script_consumer_install.sh --selftest"

  git -C "$T" init -q 2>/dev/null
  # Pin core.hooksPath LOCALLY — do not depend on, or write into, this
  # machine's ambient (possibly global) core.hooksPath. See
  # indeterminate_hook_install.sh's identical selftest note for why this
  # is not optional.
  git -C "$T" config --local core.hooksPath "$T/.git/hooks" 2>/dev/null
  printf '#!/bin/sh\necho pre-existing-gate\n' > "$T/.git/hooks/pre-commit"
  chmod +x "$T/.git/hooks/pre-commit"

  REPO="$T" DRY_RUN=0 UNINSTALL=0 run_install >/dev/null 2>&1
  grep -qF "$MARKER" "$T/.git/hooks/pre-commit" && ok "installs the gate block" || bad "gate block missing"
  grep -qF "pre-existing-gate" "$T/.git/hooks/pre-commit" && ok "preserves an existing hook body" || bad "clobbered the existing hook"
  [ -x "$T/.git/hooks/pre-commit" ] && ok "hook stays executable" || bad "hook not executable"

  local n1 n2
  n1="$(grep -cF "$MARKER" "$T/.git/hooks/pre-commit")"
  REPO="$T" run_install >/dev/null 2>&1
  n2="$(grep -cF "$MARKER" "$T/.git/hooks/pre-commit")"
  [ "$n1" = "$n2" ] && [ "$n2" = "1" ] && ok "re-install is idempotent (still 1 block)" || bad "duplicated on re-install ($n1 -> $n2)"

  local T2; T2="$(mktemp -d)"
  git -C "$T2" init -q 2>/dev/null
  mkdir -p "$T2/custom-hooks"
  git -C "$T2" config core.hooksPath "$T2/custom-hooks"
  [ "$(_hooks_dir "$T2")" = "$T2/custom-hooks" ] && ok "honours core.hooksPath" || bad "ignored core.hooksPath"
  REPO="$T2" run_install >/dev/null 2>&1
  grep -qF "$MARKER" "$T2/custom-hooks/pre-commit" && ok "installs into the configured hooksPath" || bad "installed into the wrong dir"

  REPO="$T" UNINSTALL=1 run_install >/dev/null 2>&1
  if grep -qF "$MARKER" "$T/.git/hooks/pre-commit"; then
    bad "uninstall left the block"
  else
    grep -qF "pre-existing-gate" "$T/.git/hooks/pre-commit" && ok "uninstall removes only our block" || bad "uninstall ate the rest of the hook"
  fi

  rm -rf "$T" "$T2"
  echo "  $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}

[ "$SELFTEST" -eq 1 ] && { selftest; exit $?; }
run_install
exit $?
