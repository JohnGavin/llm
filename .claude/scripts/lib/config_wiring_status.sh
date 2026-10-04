#!/usr/bin/env bash
# config_wiring_status.sh — sourced by .claude/hooks/session_init.sh (banner `config:` field).
#
# Is the user-level config under $HOME/.claude wired to the llm repo?
#   settings.json -> <repo>/.claude/settings.json
#   CLAUDE.md     -> <repo>/AGENTS.md
#   rules         -> <repo>/.claude/rules
# Each must be a symlink whose fully resolved target is that exact path.
#
# Three outcomes (checks-must-distinguish-unknown):
#   config:ok                 all three wired
#   config:DRIFT(a,b)         the named ones are not (regular file, wrong
#                             target, dangling or absent)
#   config:?                  the check itself could not run (repo root or
#                             HOME unresolvable)
#
# Portable: no `readlink -f` / `realpath` (absent or different on BSD macOS);
# follows the link chain with plain `readlink`. Never fails under `set -e`.

# Print a path with every symlink in it resolved; return 1 if it cannot be.
_cws_resolve() {
  local p="$1" n=0 t d
  while [ -L "$p" ] && [ "$n" -lt 20 ]; do
    t=$(readlink "$p") || return 1
    case "$t" in
      /*) p="$t" ;;
      *) p="$(dirname "$p")/$t" ;;
    esac
    n=$((n + 1))
  done
  if [ -L "$p" ] || [ ! -e "$p" ]; then return 1; fi
  if [ -d "$p" ]; then
    (cd -P "$p" 2>/dev/null && pwd -P) || return 1
  else
    d=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "$d" "$(basename "$p")"
  fi
}

# Main-checkout root of the repo containing directory $1 (worktree-safe via
# the git common dir). Prints nothing if $1 is not inside a git repo.
config_wiring_repo_root() {
  local dir="$1" gc common
  gc=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 0
  [ -n "$gc" ] || return 0
  case "$gc" in /*) ;; *) gc="$dir/$gc" ;; esac
  common=$(cd -P "$gc" 2>/dev/null && pwd -P) || return 0
  dirname "$common"
  return 0
}

# config_wiring_status <home> <repo_root>  -> prints the banner token
config_wiring_status() {
  local home="${1:-}" root="${2:-}" rroot name want got drift=""
  if [ -z "$home" ] || [ -z "$root" ] || [ ! -d "$root/.claude" ]; then
    echo "config:?"; return 0
  fi
  rroot=$(cd -P "$root" 2>/dev/null && pwd -P) || { echo "config:?"; return 0; }
  for name in settings.json CLAUDE.md rules; do
    case "$name" in
      settings.json) want="$rroot/.claude/settings.json" ;;
      CLAUDE.md) want="$rroot/AGENTS.md" ;;
      rules) want="$rroot/.claude/rules" ;;
    esac
    got=""
    if [ -L "$home/.claude/$name" ]; then
      got=$(_cws_resolve "$home/.claude/$name") || got=""
    fi
    if [ "$got" != "$want" ]; then
      drift="${drift:+$drift,}$name"
    fi
  done
  if [ -n "$drift" ]; then echo "config:DRIFT($drift)"; else echo "config:ok"; fi
  return 0
}
