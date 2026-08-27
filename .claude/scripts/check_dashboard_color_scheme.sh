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
# Origin: issue 0027 in a private project's tracker (5 merged iterations on the wrong layer),
# llm#584. See `accessibility` rule Part 2 Clause 0 (this script checks
# only the page-level declaration; for the separate mermaid <foreignObject>
# dark-render bug see `mermaid-dashboard-pattern`'s "Dark-mode rendering
# (mermaid-specific)" section).
#
# Scope: only HTML files Quarto actually rendered are checked — i.e. an
# `*.html` file with a same-directory, same-basename `.qmd` or `.md` source
# (`page.qmd`/`page.md` -> `page.html`). A file with no such source (a
# shinylive export, a hand-built diagram page, an untracked build artifact)
# cannot carry a Quarto-injected <meta> tag, so it is skipped rather than
# failed — see llm#584 discussion for the historical-project case that
# motivated this (4 of 8 originally-failing files had no Quarto source at
# all and could never pass). Files WITH a source are held to the full
# standard — this is a scoping fix, not a loosened check.
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
# Exit codes: 0 all HTML files with a Quarto source carry both signals
#             (or none have a Quarto source, or no HTML found);
#             1 at least one file with a Quarto source is missing a signal;
#             2 usage error.

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

has_quarto_source() {
  # A page Quarto did not render cannot carry a Quarto-injected meta tag.
  # Same-directory lookup only (not recursive): this project's observed
  # layout is flat — page.qmd/page.md sits next to page.html in the same
  # output directory (verified against the historical project's docs/,
  # e.g. api-historicaldata.md + api-historicaldata.html). A recursive
  # basename search would risk pairing an html file with an unrelated
  # source of the same name in a different directory.
  local f="$1" d base
  d="$(dirname "$f")"
  base="$(basename "$f" .html)"
  [ -f "$d/$base.qmd" ] || [ -f "$d/$base.md" ]
}

check_dir() {
  local dir="$1" fails=0 total=0 checked=0 skipped=0
  if [ ! -d "$dir" ]; then
    echo "check_dashboard_color_scheme: directory not found: $dir" >&2
    return 2
  fi
  while IFS= read -r f; do
    total=$((total + 1))
    if has_quarto_source "$f"; then
      checked=$((checked + 1))
      check_file "$f" || fails=$((fails + 1))
    else
      skipped=$((skipped + 1))
      echo "SKIP(no-quarto-source): $f"
    fi
  done < <(find "$dir" -name "*.html" -type f \
             -not -path "*/site_libs/*" -not -path "*/_freeze/*" 2>/dev/null)
  if [ "$total" -eq 0 ]; then
    echo "check_dashboard_color_scheme: no HTML files under $dir — nothing to check"
    return 0
  fi
  if [ "$checked" -eq 0 ]; then
    echo "check_dashboard_color_scheme: no HTML files under $dir have a Quarto (.qmd/.md) source — nothing to check ($skipped skipped)"
    return 0
  fi
  if [ "$fails" -gt 0 ]; then
    echo ""
    echo "check_dashboard_color_scheme: $fails of $checked Quarto-rendered HTML file(s) missing color-scheme signals ($skipped skipped: no Quarto source)."
    echo "Remediation (accessibility rule Part 2 Clause 0, llm#584):"
    echo '  head:  <meta name="color-scheme" content="dark" />'
    echo '  css:   :root, html, body { color-scheme: dark; }'
    echo "Without these, Chrome's Auto Dark Mode silently inverts the page."
    return 1
  fi
  echo "check_dashboard_color_scheme: OK — $checked Quarto-rendered HTML file(s) declare color-scheme: dark ($skipped skipped: no Quarto source)"
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

  # Good: both signals, double quotes, .qmd source
  mkdir -p "$tmp/good"
  cat > "$tmp/good/index.html" <<'HTML'
<html><head><meta name="color-scheme" content="dark"></head>
<body><style>:root, html, body { color-scheme: dark; }</style></body></html>
HTML
  : > "$tmp/good/index.qmd"
  _case "both signals present, .qmd source → 0" 0 "$tmp/good"

  # Good: single quotes + spaced CSS, .md source
  mkdir -p "$tmp/good2"
  cat > "$tmp/good2/index.html" <<'HTML'
<html><head><meta name='color-scheme' content='dark'></head>
<body><style>html { color-scheme : dark; }</style></body></html>
HTML
  : > "$tmp/good2/index.md"
  _case "single-quoted meta + spaced css, .md source → 0" 0 "$tmp/good2"

  # Bad: meta missing, .qmd source present → must still fail
  mkdir -p "$tmp/nometa"
  cat > "$tmp/nometa/index.html" <<'HTML'
<html><head></head><body><style>:root { color-scheme: dark; }</style></body></html>
HTML
  : > "$tmp/nometa/index.qmd"
  _case "meta missing, .qmd source → 1" 1 "$tmp/nometa"

  # Bad: css missing, .qmd source present → must still fail
  mkdir -p "$tmp/nocss"
  cat > "$tmp/nocss/index.html" <<'HTML'
<html><head><meta name="color-scheme" content="dark"></head><body></body></html>
HTML
  : > "$tmp/nocss/index.qmd"
  _case "css missing, .qmd source → 1" 1 "$tmp/nocss"

  # Bad: css missing, .md source present → must still fail (not just .qmd)
  mkdir -p "$tmp/nocssmd"
  cat > "$tmp/nocssmd/page.html" <<'HTML'
<html><head><meta name="color-scheme" content="dark"></head><body></body></html>
HTML
  : > "$tmp/nocssmd/page.md"
  _case "css missing, .md source → 1" 1 "$tmp/nocssmd"

  # Bad: one good + one bad file in same dir, both with sources
  mkdir -p "$tmp/mixed"
  cp "$tmp/good/index.html" "$tmp/mixed/a.html"
  : > "$tmp/mixed/a.qmd"
  cat > "$tmp/mixed/b.html" <<'HTML'
<html><head></head><body></body></html>
HTML
  : > "$tmp/mixed/b.qmd"
  _case "one bad file among good, both sourced → 1" 1 "$tmp/mixed"

  # Neutral: site_libs excluded (regardless of source)
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

  # Scoping: HTML with no Quarto source, missing signals → skipped, not failed
  mkdir -p "$tmp/nosource"
  cat > "$tmp/nosource/orphan.html" <<'HTML'
<html><head></head><body>no source, no signals</body></html>
HTML
  _case "no Quarto source, signals missing → skipped, 0" 0 "$tmp/nosource"

  # Scoping: sourced file passes, sourceless file with missing signals is
  # skipped rather than dragging the whole directory to failure
  mkdir -p "$tmp/mixedskip"
  cp "$tmp/good/index.html" "$tmp/mixedskip/real.html"
  : > "$tmp/mixedskip/real.qmd"
  cat > "$tmp/mixedskip/orphan2.html" <<'HTML'
<html><head></head><body>no source, no signals</body></html>
HTML
  _case "sourced file OK + sourceless file skipped → 0" 0 "$tmp/mixedskip"

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
