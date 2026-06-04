#!/usr/bin/env bash
# verify_mermaid_dashboard.sh — post-render verifier for mermaid dashboards.
#
# Scans a rendered .html file (or a directory of them) for the failure modes
# documented in the mermaid-dashboard-pattern rule. Returns non-zero if any
# finding is detected.
#
# Rule:     mermaid-dashboard-pattern
# Template: ~/docs_gh/llm/.claude/templates/mermaid-dashboard/
# Selftest: verify_mermaid_dashboard.sh --selftest
#
# Findings flagged:
#   F1 — <pre class="mermaid mermaid-js"> co-occurs with class="tab-pane".
#        Quarto's mermaid loader fires on window.load when only the active tab
#        is visible; SVGs in hidden tabs come back zero-sized.
#   F2 — <div id="*-mount"> is empty. Template was adopted but the inline
#        diagrams module never reached the page (no SVG was injected).
#   F3 — Literal "Syntax error in text" near a "mermaid version" string.
#        Mermaid emits this when its parser throws — diagram silently fails.
#   F4 — fill:#f1c84e (banned yellow palette colour from L-10).
#        Replace with #a14ef1 purple + white text for AA contrast.
#   F5 — <script type="module" src="local.js"> with a relative URL. Chrome
#        blocks local module imports on file:// origin; inline the module.
#
# Exit codes:
#   0  no findings
#   1  one or more findings (locations printed to stderr)
#   2  bad invocation

set -u
set -o pipefail

LOG="${HOME}/.claude/logs/verify_mermaid_dashboard.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

ts()  { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '%s %s\n' "$(ts)" "$*" >> "$LOG"; }

# ── Scan a single HTML file. Prints findings to stderr; returns count to
#    stdout. NO shared state, NO subshell traps.
scan_file() {
  local f="$1"
  local hits=0

  # Build a `stripped` view of the file with HTML comments and <pre>/<code>
  # bodies removed. We scan THIS for prose-context-sensitive findings (F5)
  # so that documentation snippets inside <!-- ... --> or <pre> don't fire.
  local stripped=""
  if command -v perl >/dev/null 2>&1; then
    stripped=$(perl -0777 -ne '
      s{<!--.*?-->}{}sg;
      s{<pre\b[^>]*>.*?</pre>}{}sgi;
      s{<code\b[^>]*>.*?</code>}{}sgi;
      print;
    ' "$f" 2>/dev/null)
  fi

  # F1: tab-pane + mermaid pre in same file → flag.
  if grep -q 'class="tab-pane' "$f" 2>/dev/null && \
     grep -q 'class="mermaid mermaid-js"' "$f" 2>/dev/null; then
    printf '  [F1] %s — <pre class="mermaid mermaid-js"> + class="tab-pane" (dashboard fail mode)\n' "$f" >&2
    hits=$((hits + 1))
  fi

  # F2: empty mount div WITHOUT any inline module wiring on the page.
  #
  # At static-HTML time, mount divs are EXPECTED to be empty — they're
  # populated by an inline mermaid module at runtime. We only flag the div
  # as a real failure when there is NO inline `<script type="module">`
  # block anywhere on the page (i.e., the template was adopted but the
  # loader never reached the page).
  if command -v perl >/dev/null 2>&1; then
    local has_inline_module="0"
    if grep -qE '<script[[:space:]]+type="module"[[:space:]]*>' "$f" 2>/dev/null; then
      has_inline_module="1"
    fi

    if [ "$has_inline_module" = "0" ]; then
      local empty
      empty=$(perl -0777 -ne '
        while (m{<div\b[^>]*\bid="([^"]*-mount)"[^>]*>(.*?)</div>}sg) {
          my ($id, $body) = ($1, $2);
          if ($body !~ /<svg|<pre|<p\b|<text|<g\b/) { print "$id\n"; }
        }
      ' "$f" 2>/dev/null)
      if [ -n "$empty" ]; then
        while IFS= read -r id; do
          printf '  [F2] %s — <div id="%s"> is empty AND no inline <script type="module"> on page\n' "$f" "$id" >&2
          hits=$((hits + 1))
        done <<<"$empty"
      fi
    fi
  fi

  # F3: mermaid parser error (real prose ≠ runtime error → require both
  # signals).
  if grep -q 'Syntax error in text' "$f" 2>/dev/null && \
     grep -q 'mermaid version' "$f" 2>/dev/null; then
    printf '  [F3] %s — "Syntax error in text" + mermaid version (parser threw)\n' "$f" >&2
    hits=$((hits + 1))
  fi

  # F4: banned yellow fill (L-10 lesson). Scan the stripped view too so
  # documentation snippets showing the banned colour don't fire.
  if [ -n "$stripped" ]; then
    if printf '%s' "$stripped" | grep -qE 'fill:#f1c84e|background:#f1c84e|background-color:#f1c84e'; then
      printf '  [F4] %s — banned yellow #f1c84e (use #a14ef1 purple + white text)\n' "$f" >&2
      hits=$((hits + 1))
    fi
  else
    if grep -qE 'fill:#f1c84e|background:#f1c84e|background-color:#f1c84e' "$f" 2>/dev/null; then
      printf '  [F4] %s — banned yellow #f1c84e (use #a14ef1 purple + white text)\n' "$f" >&2
      hits=$((hits + 1))
    fi
  fi

  # F5: local module src — Chrome blocks on file://. Use the stripped view
  # so HTML-comment / <pre> documentation of the bad pattern doesn't fire.
  if [ -n "$stripped" ]; then
    local has_bad
    has_bad=$(printf '%s' "$stripped" | perl -ne '
      if (m{<script\s+type="module"\s+src="([^"]+\.js)"}) {
        my $u = $1;
        print "$u\n" unless $u =~ m{^https?://};
      }
    ' 2>/dev/null)
    if [ -n "$has_bad" ]; then
      while IFS= read -r u; do
        printf '  [F5] %s — <script type="module" src="%s"> (Chrome blocks on file://; inline the module)\n' "$f" "$u" >&2
        hits=$((hits + 1))
      done <<<"$has_bad"
    fi
  fi

  printf '%d' "$hits"
}

# ── Selftest ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  tmp=$(mktemp -d -t verify_mermaid_selftest.XXXX)
  trap 'rm -rf "$tmp"' EXIT
  pass=0; fail=0; total=0
  _ok()   { total=$((total+1)); pass=$((pass+1)); printf '  PASS  %s\n' "$*"; }
  _fail() { total=$((total+1)); fail=$((fail+1)); printf '  FAIL  %s\n' "$*"; }

  # F1
  cat > "$tmp/f1.html" <<'HTML'
<html><body>
<div class="tab-pane" role="tabpanel">
<pre class="mermaid mermaid-js">graph TD
  A-->B</pre>
</div></body></html>
HTML
  n=$(scan_file "$tmp/f1.html" 2>/dev/null)
  [ "$n" -ge 1 ] && _ok "F1 flagged (mermaid pre + tab-pane)" \
                || _fail "F1 not flagged (n=$n)"

  # F2: empty mount div
  cat > "$tmp/f2.html" <<'HTML'
<html><body>
<div id="arch-mount" style="min-height:520px;"></div>
</body></html>
HTML
  n=$(scan_file "$tmp/f2.html" 2>/dev/null)
  [ "$n" -ge 1 ] && _ok "F2 flagged (empty mount div)" \
                || _fail "F2 not flagged (n=$n)"

  # F2 negative: filled mount div
  cat > "$tmp/f2ok.html" <<'HTML'
<html><body>
<div id="arch-mount"><svg class="mermaid-js"><g></g></svg></div>
</body></html>
HTML
  n=$(scan_file "$tmp/f2ok.html" 2>/dev/null)
  [ "$n" -eq 0 ] && _ok "F2 negative (filled mount div)" \
                || _fail "F2 false-positive (n=$n)"

  # F2 negative: empty mount div + inline module on page → ALLOW
  # (matches real-world dashboards where module populates at runtime)
  cat > "$tmp/f2ok2.html" <<'HTML'
<html><body>
<div id="arch-mount" style="min-height:520px;"></div>
<script type="module">
import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
mermaid.run();
</script>
</body></html>
HTML
  n=$(scan_file "$tmp/f2ok2.html" 2>/dev/null)
  [ "$n" -eq 0 ] && _ok "F2 negative (empty mount + inline module)" \
                || _fail "F2 false-positive on inline-module page (n=$n)"

  # F3
  cat > "$tmp/f3.html" <<'HTML'
<html><body><div>Syntax error in text<br>mermaid version 11.6.0</div></body></html>
HTML
  n=$(scan_file "$tmp/f3.html" 2>/dev/null)
  [ "$n" -ge 1 ] && _ok "F3 flagged (parse error + mermaid version)" \
                || _fail "F3 not flagged (n=$n)"

  # F4
  cat > "$tmp/f4.html" <<'HTML'
<html><body><svg><rect style="fill:#f1c84e;"/></svg></body></html>
HTML
  n=$(scan_file "$tmp/f4.html" 2>/dev/null)
  [ "$n" -ge 1 ] && _ok "F4 flagged (yellow #f1c84e)" \
                || _fail "F4 not flagged (n=$n)"

  # F5
  cat > "$tmp/f5.html" <<'HTML'
<html><body><script type="module" src="diagrams.js"></script></body></html>
HTML
  n=$(scan_file "$tmp/f5.html" 2>/dev/null)
  [ "$n" -ge 1 ] && _ok "F5 flagged (local module src)" \
                || _fail "F5 not flagged (n=$n)"

  # F5 negative: inline module
  cat > "$tmp/f5ok.html" <<'HTML'
<html><body><script type="module">
import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
</script></body></html>
HTML
  n=$(scan_file "$tmp/f5ok.html" 2>/dev/null)
  [ "$n" -eq 0 ] && _ok "F5 negative (inline module + CDN)" \
                || _fail "F5 false-positive (n=$n)"

  # F5 negative: http(s) src is fine
  cat > "$tmp/f5cdn.html" <<'HTML'
<html><body><script type="module" src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs"></script></body></html>
HTML
  n=$(scan_file "$tmp/f5cdn.html" 2>/dev/null)
  [ "$n" -eq 0 ] && _ok "F5 negative (http CDN module src)" \
                || _fail "F5 false-positive on CDN (n=$n)"

  # F5 negative: local module src appears inside HTML comment → ALLOW
  cat > "$tmp/f5comment.html" <<'HTML'
<html><body>
<!-- Doc: do not use <script type="module" src="local.js"> from file:// -->
<script type="module">/* inline */</script>
</body></html>
HTML
  n=$(scan_file "$tmp/f5comment.html" 2>/dev/null)
  [ "$n" -eq 0 ] && _ok "F5 negative (local src inside HTML comment)" \
                || _fail "F5 false-positive on comment (n=$n)"

  # F5 negative: local module src appears inside <pre> block → ALLOW
  cat > "$tmp/f5pre.html" <<'HTML'
<html><body>
<pre><code>&lt;script type="module" src="diagrams.js"&gt;&lt;/script&gt;</code></pre>
<script type="module" src="diagrams.js"></script>
</body></html>
HTML
  # This one has BOTH a documented bad pattern in <pre> AND a real one
  # outside. We should flag the real one (1 finding, not 2).
  n=$(scan_file "$tmp/f5pre.html" 2>/dev/null)
  [ "$n" -eq 1 ] && _ok "F5 mixed (pre-block ignored, real script flagged)" \
                || _fail "F5 mixed wrong count (n=$n, expected 1)"

  # F4 negative: yellow fill appears inside <pre> documentation → ALLOW
  cat > "$tmp/f4pre.html" <<'HTML'
<html><body><pre>style="fill:#f1c84e"</pre><p>actual page content</p></body></html>
HTML
  n=$(scan_file "$tmp/f4pre.html" 2>/dev/null)
  [ "$n" -eq 0 ] && _ok "F4 negative (yellow inside <pre>)" \
                || _fail "F4 false-positive on pre (n=$n)"

  # Clean page
  cat > "$tmp/clean.html" <<'HTML'
<html><body><p>Hello</p></body></html>
HTML
  n=$(scan_file "$tmp/clean.html" 2>/dev/null)
  [ "$n" -eq 0 ] && _ok "clean page → 0 findings" \
                || _fail "clean page failed (n=$n)"

  # End-to-end: full invocation on the clean page returns 0
  bash "$0" "$tmp/clean.html" >/dev/null 2>&1
  [ "$?" -eq 0 ] && _ok "end-to-end: clean page exits 0" \
                 || _fail "end-to-end: clean page non-zero"

  # End-to-end: full invocation on a finding page returns 1
  bash "$0" "$tmp/f1.html" >/dev/null 2>&1
  [ "$?" -eq 1 ] && _ok "end-to-end: F1 page exits 1" \
                 || _fail "end-to-end: F1 page wrong exit"

  printf '\nverify_mermaid_dashboard selftest: %d/%d PASS\n' "$pass" "$total"
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi

# ── Production ───────────────────────────────────────────────────────────────
target="${1:-}"
if [ -z "$target" ]; then
  printf 'usage: %s <html-or-dir> | --selftest\n' "$0" >&2
  exit 2
fi
if [ ! -e "$target" ]; then
  printf 'verify_mermaid_dashboard: not found: %s\n' "$target" >&2
  exit 2
fi

if [ -d "$target" ]; then
  files=$(find "$target" -type f -name '*.html' 2>/dev/null)
else
  files="$target"
fi

total=0
for f in $files; do
  [ -f "$f" ] || continue
  n=$(scan_file "$f")
  total=$((total + n))
done

if [ "$total" -gt 0 ]; then
  printf 'verify_mermaid_dashboard: %d finding(s) — see above\n' "$total" >&2
  log "FINDINGS n=$total target=$target"
  exit 1
fi

log "OK target=$target"
exit 0
