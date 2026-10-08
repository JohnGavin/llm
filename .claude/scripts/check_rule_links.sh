#!/usr/bin/env bash
# check_rule_links.sh — find broken relative markdown links between rule files.
#
# Scans <rules-dir>/**/*.md for `](target.md)` links and reports each whose
# target does not exist relative to the linking file. Skips: http(s)/mailto
# links, pure #anchor links, targets not ending in .md (after stripping any
# #anchor), and anything inside fenced code blocks or inline code spans.
#
# Usage:
#   check_rule_links.sh [rules-dir]     # default: <repo>/.claude/rules
#   check_rule_links.sh --selftest
#
# Exit codes (checks-must-distinguish-unknown):
#   0  no broken links
#   1  at least one broken link (each printed as BROKEN-LINK file:line -> target)
#   2  usage error / rules dir missing
#   3  INDETERMINATE: dir exists but no .md files were scanned (thin input is
#      never certified clean)
#
# Portable to bash 3.2 / BSD userland (no mapfile, no grep -P, no GNU find opts).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Emit "line<TAB>target" for each candidate link in one file.
_extract() { # <file>
  awk '
    /^[ \t]*(```|~~~)/ { infence = !infence; next }
    infence { next }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)
      while (match(line, /\]\([^)]*\)/)) {
        t = substr(line, RSTART + 2, RLENGTH - 3)
        sub(/[ \t].*$/, "", t)
        print NR "\t" t
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

_scan() { # <rules-dir>  -> prints BROKEN-LINK lines; sets SCANNED, BROKEN
  local dir="$1" f d line target path
  SCANNED=0; BROKEN=0
  while IFS= read -r f; do
    SCANNED=$((SCANNED + 1))
    d="$(dirname "$f")"
    while IFS="$(printf '\t')" read -r line target; do
      [ -n "$target" ] || continue
      case "$target" in
        http://*|https://*|mailto:*|\#*) continue ;;
      esac
      path="${target%%#*}"
      case "$path" in
        *.md) ;;
        *) continue ;;
      esac
      if [ ! -e "$d/$path" ]; then
        BROKEN=$((BROKEN + 1))
        printf 'BROKEN-LINK %s:%s -> %s\n' "$f" "$line" "$target"
      fi
    done < <(_extract "$f")
  done < <(find "$dir" -type f -name '*.md' | sort)
}

_main() { # <rules-dir>
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo "check_rule_links: not a directory: $dir" >&2
    return 2
  fi
  _scan "$dir"
  if [ "$SCANNED" -eq 0 ]; then
    echo "check_rule_links: INDETERMINATE — no .md files under $dir" >&2
    return 3
  fi
  if [ "$BROKEN" -gt 0 ]; then
    echo "check_rule_links: $BROKEN broken link(s) in $SCANNED file(s)"
    return 1
  fi
  echo "check_rule_links: OK — $SCANNED file(s), 0 broken links"
  return 0
}

_selftest() {
  local PASS=0 TOTAL=0 tmp rc
  _t() { # <name> <expected-rc> <actual-rc>
    TOTAL=$((TOTAL + 1))
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"
    else printf '  FAIL  %s (expected rc=%s got rc=%s)\n' "$1" "$2" "$3"; fi
  }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/check_rule_links_selftest_XXXXXX")"
  trap "rm -rf '$tmp'" EXIT

  # Case 1: good link + code-fence link + inline-code link + url + anchor -> 0
  mkdir -p "$tmp/ok/_companions"
  printf '# a\n' > "$tmp/ok/a.md"
  {
    printf 'See [a](../a.md) and [web](https://example.com/x.md) and [top](#t).\n'
    printf 'Inline `[x](missing-inline.md)` is code.\n'
    printf '```\n[y](missing-fence.md)\n```\n'
    printf 'Up: [a](../a.md#sec)\n'
  } > "$tmp/ok/_companions/b.md"
  rc=0; _main "$tmp/ok" >/dev/null 2>&1 || rc=$?
  _t "good + fenced + inline + url + anchor -> exit 0" 0 "$rc"

  # Case 2: broken link -> 1, and it is named in the output
  mkdir -p "$tmp/bad"
  printf '# a\n' > "$tmp/bad/a.md"
  printf 'Broken [m](missing.md).\n' > "$tmp/bad/c.md"
  rc=0; out="$(_main "$tmp/bad" 2>&1)" || rc=$?
  _t "broken link -> exit 1" 1 "$rc"
  case "$out" in *"c.md:1 -> missing.md"*) rc=0 ;; *) rc=9 ;; esac
  _t "broken link is named in output" 0 "$rc"

  # Case 3: companion link missing the ../ prefix is caught -> 1
  mkdir -p "$tmp/comp/_companions"
  printf '# a\n' > "$tmp/comp/a.md"
  printf '[a](a.md)\n' > "$tmp/comp/_companions/d.md"
  rc=0; _main "$tmp/comp" >/dev/null 2>&1 || rc=$?
  _t "companion link without ../ -> exit 1" 1 "$rc"

  # Case 4: missing dir -> 2 ; empty dir -> 3
  rc=0; _main "$tmp/nope" >/dev/null 2>&1 || rc=$?
  _t "missing dir -> exit 2" 2 "$rc"
  mkdir -p "$tmp/empty"
  rc=0; _main "$tmp/empty" >/dev/null 2>&1 || rc=$?
  _t "empty dir -> exit 3 (indeterminate)" 3 "$rc"

  echo ""
  echo "selftest: ${PASS}/${TOTAL} PASS"
  [ "$PASS" -eq "$TOTAL" ] && return 0
  return 1
}

case "${1:-}" in
  --selftest) _selftest; exit $? ;;
  -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
  --*) echo "usage: check_rule_links.sh [rules-dir] | --selftest" >&2; exit 2 ;;
  "") _main "$(cd "$SCRIPT_DIR/../rules" 2>/dev/null && pwd)" ; exit $? ;;
  *)  [ "$#" -le 1 ] || { echo "usage: check_rule_links.sh [rules-dir] | --selftest" >&2; exit 2; }
      _main "$1"; exit $? ;;
esac
