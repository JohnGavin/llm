#!/usr/bin/env bash
# tests/test_config_banner_symlinks.sh
# Exercises the session banner's `config:` field (.claude/scripts/lib/config_wiring_status.sh):
#   all three of ~/.claude/{settings.json,CLAUDE.md,rules} symlinked into the repo -> config:ok
#   settings.json a regular file                                                   -> config:DRIFT(settings.json)
#   several drifted / dangling / wrong-target / absent                              -> each named
#   repo root unresolvable (nonexistent dir, non-git dir, empty)                    -> config:?
# Runs against a temporary fake HOME and fake repo; never touches the real ~/.claude.
# Exit 0 = all pass. Exit 1 = at least one failure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB="$HERE/../.claude/scripts/lib/config_wiring_status.sh"
# shellcheck source=/dev/null
. "$LIB"

fails=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "PASS: $1 -> $3"; else echo "FAIL: $1 expected '$2' got '$3'"; fails=$((fails + 1)); fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cfgbanner.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd -P "$TMP" && pwd -P)"

REPO="$TMP/repo"; HOME_="$TMP/home"
mkdir -p "$REPO/.claude/rules" "$HOME_/.claude"
echo '{}' > "$REPO/.claude/settings.json"
echo '# agents' > "$REPO/AGENTS.md"

wire() { # (re)create the three correct links
  rm -rf "$HOME_/.claude/settings.json" "$HOME_/.claude/CLAUDE.md" "$HOME_/.claude/rules"
  ln -s "$REPO/.claude/settings.json" "$HOME_/.claude/settings.json"
  ln -s "$REPO/AGENTS.md" "$HOME_/.claude/CLAUDE.md"
  ln -s "$REPO/.claude/rules" "$HOME_/.claude/rules"
}

wire
check "all symlinked" "config:ok" "$(config_wiring_status "$HOME_" "$REPO")"

# relative symlink chain through an intermediate link still resolves
rm "$HOME_/.claude/rules"; ln -s "$REPO/.claude" "$TMP/mid"; ln -s "$TMP/mid/rules" "$HOME_/.claude/rules"
check "chained link resolves" "config:ok" "$(config_wiring_status "$HOME_" "$REPO")"

wire; rm "$HOME_/.claude/settings.json"; cp "$REPO/.claude/settings.json" "$HOME_/.claude/settings.json"
check "settings.json regular file" "config:DRIFT(settings.json)" "$(config_wiring_status "$HOME_" "$REPO")"

wire; rm "$HOME_/.claude/CLAUDE.md"; ln -s "$REPO/.claude/settings.json" "$HOME_/.claude/CLAUDE.md"
check "CLAUDE.md wrong target" "config:DRIFT(CLAUDE.md)" "$(config_wiring_status "$HOME_" "$REPO")"

wire; rm "$HOME_/.claude/rules"; mkdir "$HOME_/.claude/rules"
check "rules a real dir" "config:DRIFT(rules)" "$(config_wiring_status "$HOME_" "$REPO")"

wire; rm "$HOME_/.claude/settings.json"; rm "$HOME_/.claude/rules"; ln -s "$TMP/nowhere" "$HOME_/.claude/rules"
check "absent + dangling named" "config:DRIFT(settings.json,rules)" "$(config_wiring_status "$HOME_" "$REPO")"

wire
check "repo root nonexistent" "config:?" "$(config_wiring_status "$HOME_" "$TMP/nope")"
check "repo root empty" "config:?" "$(config_wiring_status "$HOME_" "")"
check "home empty" "config:?" "$(config_wiring_status "" "$REPO")"
mkdir -p "$TMP/notgit"
check "non-git dir -> empty root -> ?" "config:?" "$(config_wiring_status "$HOME_" "$(config_wiring_repo_root "$TMP/notgit")")"

# repo-root discovery is worktree-safe: from a worktree it yields the MAIN checkout
git -C "$TMP" init -q main_co
git -C "$TMP/main_co" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$TMP/main_co" worktree add -q "$TMP/wt" -b wtb
check "root from main checkout" "$TMP/main_co" "$(config_wiring_repo_root "$TMP/main_co")"
check "root from worktree = main" "$TMP/main_co" "$(config_wiring_repo_root "$TMP/wt")"

echo "fails=$fails"
[ "$fails" -eq 0 ]
