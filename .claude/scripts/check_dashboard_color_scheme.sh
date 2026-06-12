#!/usr/bin/env bash
# check_dashboard_color_scheme.sh — fail the build when a dark dashboard
# is missing the `color-scheme: dark` declaration.
#
# Why: Chrome ships "Auto Dark Mode for Web Contents" enabled by default
# since v96. Its heuristic mis-classifies intentionally-dark pages as
# light and inverts the page's lightness (black backgrounds → white,
# deep palettes → pastels) — in Chrome ONLY. The fix is declaring the
# page's colour scheme so Chrome's auto-dark leaves it alone:
#   <meta name="color-scheme" content="dark">   (head)
#   :root { color-scheme: dark; }               (CSS, redundant belt)
#
# Origin: premortem issue 0027 (5 merged iterations on the wrong layer),
# llm#584. See `accessibility` rule Part 2 Clause 0 and
# `mermaid-dashboard-pattern` Step 0.
#
# Usage:
#   check_dashboard_color_scheme.sh <dir>     # scan every *.html under <dir>
#   check_dashboard_color_scheme.sh --selftest
#
# Wire into Quarto (_quarto.yml):
#   project:
#     post-render:
#       - bash /Users/johngavin/docs_gh/llm/.claude/scripts/check_dashboard_color_scheme.sh docs
#
# Exit codes: 0 all HTML files carry both signals (or no HTML found);
#             1 at least one file is missing a signal; 2 usage error.

set -euo pipefail

# Both greps are intentionally permissive about quoting and whitespace:
#   meta:  name="color-scheme" ... content="dark"  (either attribute order)
#   css:   color-scheme: dark  (with or without space, inline or stylesheet)
META_RE='name=["'\'']color-scheme["'\''][^>]*content=["'\'']dark["'\'']|content=["'\'']dark["'\''][^>]*name=["'\'']color-scheme["'\'']'
CSS_RE='color-scheme[[:space:]]*:[[:space:]]*dark'

check_file() {
  # Returns 0 when BOTH signals present, prints what is missing otherwise.
  local f="$1" missing=""
  grep -qiE "$META_RE" "$f" || missing="meta"
  grep -qiE "$CSS_RE"  "$f" || missing="${missing:+$missing+}css"
  if [ -n "$missing" ]; then
    echo "MISSING(${missing}): $f"
    return 1
  fi
  return 0
}

check_dir() {
  local dir="$1" fails=0 total=0
  if [ ! -d "$dir" ]; then
    echo "check_dashboard_color_scheme: directory not found: $dir" >&2
    return 2
  fi
  while IFS= read -r f; do
    total=$((total + 1))
    check_file "$f" || fails=$((fails + 1))
  done < <(find "$dir" -name "*.html" -type f \
             -not -path "*/site_libs/*" -not -path "*/_freeze/*" 2>/dev/null)
  if [ "$total" -eq 0 ]; then
    echo "check_dashboard_color_scheme: no HTML files under $dir — nothing to check"
    return 0
  fi
  if [ "$fails" -gt 0 ]; then
    echo ""
    echo "check_dashboard_color_scheme: $fails of $total HTML file(s) missing color-scheme signals."
    echo "Remediation (accessibility rule Part 2 Clause 0, llm#584):"
    echo '  head:  <meta name="color-scheme" content="dark" />'
    echo '  css:   :root, html, body { color-scheme: dark; }'
    echo "Without these, Chrome's Auto Dark Mode silently inverts the page."
    return 1
  fi
  echo "check_dashboard_color_scheme: OK — $total HTML file(s) declare color-scheme: dark"
  return 0
}

selftest() {
  local tmp pass=0 fail=0
  tmp=$(mktemp -d /tmp/ccs_selftest_XXXXXX)

  _case() { # name expected_rc dir
    local name="$1" want="$2" dir="$3" got=0
    check_dir "$dir" >/dev/null 2>&1 || got=$?
    if [ "$got" = "$want" ]; then
      pass=$((pass + 1)); echo "  PASS  $name"
    else
      fail=$((fail + 1)); echo "  FAIL  $name (want rc=$want got rc=$got)"
    fi
  }

  # Good: both signals, double quotes
  mkdir -p "$tmp/good"
  cat > "$tmp/good/index.html" <<'HTML'
<html><head><meta name="color-scheme" content="dark"></head>
<body><style>:root, html, body { color-scheme: dark; }</style></body></html>
HTML
  _case "both signals present → 0" 0 "$tmp/good"

  # Good: single quotes + spaced CSS
  mkdir -p "$tmp/good2"
  cat > "$tmp/good2/index.html" <<'HTML'
<html><head><meta name='color-scheme' content='dark'></head>
<body><style>html { color-scheme : dark; }</style></body></html>
HTML
  _case "single-quoted meta + spaced css → 0" 0 "$tmp/good2"

  # Bad: meta missing
  mkdir -p "$tmp/nometa"
  cat > "$tmp/nometa/index.html" <<'HTML'
<html><head></head><body><style>:root { color-scheme: dark; }</style></body></html>
HTML
  _case "meta missing → 1" 1 "$tmp/nometa"

  # Bad: css missing
  mkdir -p "$tmp/nocss"
  cat > "$tmp/nocss/index.html" <<'HTML'
<html><head><meta name="color-scheme" content="dark"></head><body></body></html>
HTML
  _case "css missing → 1" 1 "$tmp/nocss"

  # Bad: one good + one bad file in same dir
  mkdir -p "$tmp/mixed"
  cp "$tmp/good/index.html" "$tmp/mixed/a.html"
  cat > "$tmp/mixed/b.html" <<'HTML'
<html><head></head><body></body></html>
HTML
  _case "one bad file among good → 1" 1 "$tmp/mixed"

  # Neutral: site_libs excluded
  mkdir -p "$tmp/libs/site_libs/bootstrap"
  cat > "$tmp/libs/site_libs/bootstrap/junk.html" <<'HTML'
<html><head></head><body>vendored</body></html>
HTML
  _case "site_libs excluded, no other HTML → 0" 0 "$tmp/libs"

  # Neutral: empty dir
  mkdir -p "$tmp/empty"
  _case "no HTML files → 0" 0 "$tmp/empty"

  # Usage: missing dir
  _case "missing directory → 2" 2 "$tmp/does-not-exist"

  rm -rf "$tmp"
  echo ""
  echo "check_dashboard_color_scheme selftest: ${pass} pass, ${fail} fail"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest ;;
  "")         echo "usage: $(basename "$0") <output-dir> | --selftest" >&2; exit 2 ;;
  *)          check_dir "$1" ;;
esac
