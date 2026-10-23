#!/usr/bin/env bash
# one_home_ext_lists_check.sh -- lint: each file-extension list has ONE home.
#
# Rule "One home per value" (AGENTS.md; dynamic-prose-values): every value has
# exactly one home and a hand-typed second copy is a defect even while correct.
# This lint applies it to the three extension lists the public-repo privacy
# gates share (llm#1436):
#
#   list      home (the only place it is typed)
#   DOC       .claude/scripts/private_data_scan.sh   DOC_FORMAT_EXTS  (documents)
#   IMAGE     .claude/scripts/private_data_scan.sh   IMAGE_EXTS       (raster images)
#   ARCHIVE   .claude/hooks/public_repo_file_import_guard.sh  ARCHIVE_EXTS
#
# A "literal copy" is any line, in any tracked or untracked-but-not-ignored text
# file, that contains EVERY member of a list as a whole word (so a glob such as
# "*.pdf|*.docx|...", a quoted list, a regex alternation or a prose enumeration
# all count) other than the home's own assignment line. A line that names only
# some members is not a copy of the list.
#
# Allow-list: .claude/state/one_home_ext_lists_allowlist.txt, one entry per line,
#   <repo-relative path> | <LIST> | <reason>
# An entry with no path, no list or no reason allows nothing. An entry that
# matches no copy any more is STALE and fails the check, so the list cannot rot.
#
# Exit codes (checks-must-distinguish-unknown):
#   0  PASS   no unallowed copy, no stale allow-list entry
#   1  FAIL   an unallowed copy, or a stale allow-list entry
#   2  usage
#   3  INDETERMINATE  a home list is unreadable/too short, the root is not a git
#      work tree, or the scan cannot see the home line itself (a blind scan)
#
# Usage: one_home_ext_lists_check.sh [--root DIR] [--allowlist FILE] [--quiet]
# Env seam: ONE_HOME_ALLOWLIST (same as --allowlist).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
ALLOW="${ONE_HOME_ALLOWLIST:-}"
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --allowlist) ALLOW="${2:-}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "usage: $0 [--root DIR] [--allowlist FILE] [--quiet]" >&2; exit 2 ;;
  esac
done
[ -d "$ROOT" ] || { echo "usage: --root is not a directory: $ROOT" >&2; exit 2; }
[ -n "$ALLOW" ] || ALLOW="$ROOT/.claude/state/one_home_ext_lists_allowlist.txt"

SCANNER_REL=".claude/scripts/private_data_scan.sh"
GUARD_REL=".claude/hooks/public_repo_file_import_guard.sh"

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
indeterminate() { printf 'INDETERMINATE: %s\n' "$*" >&2; exit 3; }

git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || indeterminate "$ROOT is not a git work tree; cannot enumerate files"

# home_members FILE VAR -> members, single-spaced ("" if unreadable/absent)
home_members() {
  local line
  line="$(grep -m1 "^$2=" "$ROOT/$1" 2>/dev/null || true)"
  line="${line#"$2"=\"}"
  line="${line%\"*}"
  set -f; set -- $line; set +f
  printf '%s' "$*"
}

# lists, one per line: LIST|home-file|VAR
LISTS="DOC|$SCANNER_REL|DOC_FORMAT_EXTS
IMAGE|$SCANNER_REL|IMAGE_EXTS
ARCHIVE|$GUARD_REL|ARCHIVE_EXTS"

# ── allow-list ───────────────────────────────────────────────────────────────
ALLOW_ENTRIES=""   # lines "path|LIST"
ignored=0
if [ -f "$ALLOW" ]; then
  while IFS= read -r raw || [ -n "$raw" ]; do
    case "$raw" in ''|'#'*) continue ;; esac
    p="${raw%% | *}"; rest="${raw#* | }"
    [ "$p" != "$raw" ] || { ignored=$((ignored + 1)); continue; }
    l="${rest%% | *}"; r="${rest#* | }"
    [ "$l" != "$rest" ] || { ignored=$((ignored + 1)); continue; }
    p="$(printf '%s' "$p" | sed 's/^ *//; s/ *$//')"
    l="$(printf '%s' "$l" | sed 's/^ *//; s/ *$//')"
    r="$(printf '%s' "$r" | sed 's/^ *//; s/ *$//')"
    if [ -z "$p" ] || [ -z "$l" ] || [ -z "$r" ]; then ignored=$((ignored + 1)); continue; fi
    ALLOW_ENTRIES="${ALLOW_ENTRIES}${p}|${l}"$'\n'
  done < "$ALLOW"
fi
[ "$ignored" -eq 0 ] || say "note: $ignored allow-list line(s) without path, list and reason were ignored"

fail=0
USED=""   # allow entries that matched a real copy

while IFS='|' read -r LIST HOME_REL VAR; do
  [ -n "$LIST" ] || continue
  members="$(home_members "$HOME_REL" "$VAR")"
  n=0; for _m in $members; do n=$((n + 1)); done
  [ "$n" -ge 2 ] || indeterminate "$LIST list unreadable or shorter than 2 members ($HOME_REL $VAR='$members')"
  first="${members%% *}"

  # Candidate lines: those mentioning the first member (case-insensitive), in
  # tracked + untracked-not-ignored files. -I skips binary files.
  hits="$(git -C "$ROOT" grep -nIi --untracked --exclude-standard -e "$first" -- . 2>/dev/null \
    | awk -v members="$members" '
        BEGIN { n = split(members, M, " ") }
        {
          s = $0
          i = index(s, ":"); path = substr(s, 1, i - 1); s = substr(s, i + 1)
          j = index(s, ":"); lineno = substr(s, 1, j - 1); text = substr(s, j + 1)
          t = tolower(text); gsub(/[^a-z0-9]+/, " ", t); t = " " t " "
          ok = 1
          for (k = 1; k <= n; k++) if (index(t, " " tolower(M[k]) " ") == 0) { ok = 0; break }
          if (ok) printf "%s\t%s\t%s\n", path, lineno, text
        }')"

  # Canary: the scan must see the home assignment itself, or it is blind.
  home_seen="$(printf '%s\n' "$hits" | awk -F'\t' -v h="$HOME_REL" -v v="$VAR" '$1==h && index($3, v "=")==1 {c++} END{print c+0}')"
  [ "$home_seen" -ge 1 ] || indeterminate "scan did not see the home line $VAR in $HOME_REL (blind scan)"

  copies="$(printf '%s\n' "$hits" | awk -F'\t' -v h="$HOME_REL" -v v="$VAR" 'NF>=3 && !($1==h && index($3, v "=")==1) {print $1 "\t" $2}')"
  [ -n "$copies" ] || continue
  while IFS=$'\t' read -r cpath cline; do
    [ -n "$cpath" ] || continue
    if printf '%s' "$ALLOW_ENTRIES" | grep -Fxq -- "${cpath}|${LIST}"; then
      USED="${USED}${cpath}|${LIST}"$'\n'
    else
      printf 'FAIL: literal copy of the %s list (home: %s %s) at %s:%s\n' "$LIST" "$HOME_REL" "$VAR" "$cpath" "$cline"
      fail=1
    fi
  done <<< "$copies"
done <<< "$LISTS"

# Stale allow-list entries: an entry that allows nothing must go.
while IFS= read -r e; do
  [ -n "$e" ] || continue
  if ! printf '%s' "$USED" | grep -Fxq -- "$e"; then
    printf 'FAIL: stale allow-list entry (matches no copy): %s\n' "$e"
    fail=1
  fi
done <<< "$ALLOW_ENTRIES"

if [ "$fail" -eq 0 ]; then
  say "PASS: DOC, IMAGE and ARCHIVE extension lists each have one home; $(printf "%s" "$USED" | sort -u | grep -c . || true) allow-listed mention file(s)"
  exit 0
fi
exit 1
