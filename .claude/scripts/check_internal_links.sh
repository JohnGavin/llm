#!/usr/bin/env bash
# check_internal_links.sh — fail on broken internal links in a rendered site.
#
# Scans every *.html under a docs dir for internal hyperlinks whose target file
# does not exist, resolving each href relative to the linking file's directory.
# Purpose: stop a Quarto/pkgdown render from shipping 404s (JohnGavin/llm#715).
#
# Usage:
#   check_internal_links.sh [DOCS_DIR]      # default: ./docs
#   SELFTEST=1 check_internal_links.sh      # run built-in self-test, exit 0/1
#
# Exit: 0 = no broken internal links; 1 = broken links found (listed on stderr);
#       2 = usage/environment error.
#
# What counts as an INTERNAL link to verify:
#   - href="something.html", href="../a/b.html", href="dir/", href="page.html#frag"
# Ignored (never flagged):
#   - external:  http://  https://  //host  mailto:  tel:  javascript:  data:
#   - in-page:   href="#anchor"  and empty href=""
#   - non-.html assets (css/js/png/…) — link-checking targets pages, not assets
#
# Portable: bash 3.2 (macOS) + GNU/BSD coreutils. No perl/python required.

set -uo pipefail

DOCS_DIR="${1:-docs}"

# ── strip a leading marker used by the self-test to avoid recursion ──────────
if [ "${SELFTEST:-0}" = "1" ]; then
  _tmp="$(mktemp -d "${TMPDIR:-/tmp}/linkcheck_selftest_XXXXXX")" || exit 2
  trap 'rm -rf "$_tmp"' EXIT
  mkdir -p "$_tmp/sub"
  # good.html: links to a sibling that exists, an external URL, and an anchor
  printf '%s\n' '<a href="target.html">ok</a> <a href="https://x.test/y.html">ext</a> <a href="#top">anch</a>' > "$_tmp/good.html"
  printf '%s\n' 'target' > "$_tmp/target.html"
  # bad.html: links to a sibling that does NOT exist
  printf '%s\n' '<a href="missing.html">dead</a> <a href="sub/also-missing.html#f">dead2</a>' > "$_tmp/bad.html"

  # Expect: with only good.html present it passes; with bad.html it fails.
  if ! SELFTEST=0 "$0" "$_tmp/goodonly" >/dev/null 2>&1; then :; fi
  mkdir -p "$_tmp/goodonly"
  cp "$_tmp/good.html" "$_tmp/target.html" "$_tmp/goodonly/" 2>/dev/null
  if ! SELFTEST=0 "$0" "$_tmp/goodonly" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: clean dir reported broken links" >&2; exit 1
  fi
  if SELFTEST=0 "$0" "$_tmp" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: dir with a dead link was reported clean" >&2; exit 1
  fi
  echo "SELFTEST PASS"
  exit 0
fi

if [ ! -d "$DOCS_DIR" ]; then
  echo "check_internal_links: docs dir not found: $DOCS_DIR" >&2
  exit 2
fi

# Normalise a path with .. and . segments (pure shell; no realpath dependency,
# and the target need not exist). Prints the cleaned path.
_normalise() {
  local path="$1" out=() seg IFS='/'
  # shellcheck disable=SC2086
  set -- $path
  for seg in "$@"; do
    case "$seg" in
      ''|'.') : ;;
      '..')   [ ${#out[@]} -gt 0 ] && unset 'out[${#out[@]}-1]' ;;
      *)      out+=("$seg") ;;
    esac
  done
  local joined=""
  for seg in "${out[@]:-}"; do joined="$joined/$seg"; done
  printf '%s' "${joined:-/}"
}

broken=0
report=""

while IFS= read -r html; do
  base_dir="$(dirname "$html")"
  # Extract href="..." values (double- or single-quoted).
  while IFS= read -r href; do
    [ -n "$href" ] || continue
    # Drop fragment and query.
    target="${href%%#*}"
    target="${target%%\?*}"
    [ -n "$target" ] || continue          # was a pure #anchor / empty
    case "$target" in
      http://*|https://*|//*|mailto:*|tel:*|javascript:*|data:*) continue ;;
    esac
    # Only verify links to pages (html) or directory indexes; skip assets.
    case "$target" in
      */) resolved_rel="${target}index.html" ;;
      *.html) resolved_rel="$target" ;;
      *) continue ;;
    esac
    case "$resolved_rel" in
      /*) resolved="$DOCS_DIR$resolved_rel" ;;        # site-absolute
      *)  resolved="$(_normalise "$base_dir/$resolved_rel")" ;;
    esac
    if [ ! -f "$resolved" ]; then
      broken=$((broken + 1))
      report="${report}${html#"$DOCS_DIR"/}  ->  ${href}   (missing: ${resolved})"$'\n'
    fi
  done < <(grep -oE 'href="[^"]*"|href='"'"'[^'"'"']*'"'"'' "$html" 2>/dev/null | sed -E 's/^href=["'"'"']//; s/["'"'"']$//')
done < <(find "$DOCS_DIR" -type f -name '*.html' 2>/dev/null)

if [ "$broken" -gt 0 ]; then
  echo "check_internal_links: $broken broken internal link(s) in $DOCS_DIR:" >&2
  printf '%s' "$report" >&2
  exit 1
fi
exit 0
