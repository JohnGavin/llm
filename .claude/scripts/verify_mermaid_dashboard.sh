#!/usr/bin/env bash
# verify_mermaid_dashboard.sh — post-render verifier for mermaid dashboards.
#
# Scans a rendered .html file (or a directory of them) for the failure modes
# documented in the mermaid-dashboard-pattern rule. Returns non-zero if any
# finding is detected.
#
# Rule:     mermaid-dashboard-pattern
# Selftest: verify_mermaid_dashboard.sh --selftest
#
# History: removed 2026-07-13 (PR #773, commit ab14383f) as believed-unused;
# restored 2026-09-24 (llm#1067) after a downstream project's Quarto
# post-render.sh was found still calling it by absolute path — its Mermaid
# diagrams mount into empty divs at browser runtime via an external JS
# loader, so a broken mount is invisible in the static HTML without this
# check (silent-by-construction failure mode). See the "Tombstone" section
# of the mermaid-dashboard-pattern rule for the full incident.
#
# Two loader patterns are recognised:
#   1. CDN ESM import:  <script type="module"> importing mermaid from a URL.
#   2. Vendored UMD:     a classic (non-module) <script> block containing the
#      whole mermaid UMD bundle (exposes window.mermaid), followed by another
#      classic <script> calling mermaid.initialize()/.run()/.render(). This
#      pattern exists because Chrome and Brave block cross-origin ES-module
#      imports from file:// pages (CORS); a vendored UMD bundle loaded via a
#      classic <script> tag works from file:// in every browser. The UMD
#      bundle's own minified source contains the literal strings "Syntax
#      error in text" and "mermaid version" as part of ITS OWN error-message
#      templates — that text must not be mistaken for a real runtime parser
#      failure (see F3 below).
#
# Findings flagged:
#   F1 — <pre class="mermaid mermaid-js"> co-occurs with class="tab-pane".
#        Quarto's mermaid loader fires on window.load when only the active tab
#        is visible; SVGs in hidden tabs come back zero-sized.
#   F2 — <div id="*-mount"> is empty AND no evidence of a wired loader exists
#        anywhere on the page (neither an inline `<script type="module">`
#        block, nor a classic <script> that calls mermaid.initialize()/
#        .run()/.render() or references window.mermaid/globalThis.mermaid).
#        A mount div with NO loader evidence means the template was adopted
#        but the loader never reached the page — flag it. A mount div that
#        IS backed by loader evidence is expected to be empty in the static
#        HTML (it fills in at browser runtime) and is NOT flagged.
#   F3 — Literal "Syntax error in text" near a "mermaid version" string,
#        found OUTSIDE any <script> body (i.e. in the page's visible markup,
#        not inside a vendored library's own source). Text found only inside
#        a <script> block is the UMD bundle's own message template, not a
#        real parser failure, and is NOT flagged.
#   F4 — fill:#f1c84e (banned yellow palette colour from L-10).
#        Replace with #a14ef1 purple + white text for AA contrast.
#   F5 — <script type="module" src="local.js"> with a relative URL. Chrome
#        blocks local module imports on file:// origin; inline the module.
#
# Exit codes (checks-must-distinguish-unknown):
#   0  PASS          — no findings
#   1  FAIL          — one or more findings (locations printed to stderr)
#   2  usage error   — bad invocation (no target, or target not found)
#   3  INDETERMINATE — required dependency (perl) is missing; the checks
#                      that depend on it cannot run, so this is NOT a pass

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

  # `stripped_docs` — HTML comments and <pre>/<code> bodies removed (kept:
  # <script> tags AND their content). Used wherever we need to see real
  # <script> content (loader-detection, F5's tag inspection) but must
  # ignore documentation examples inside comments/<pre>/<code>.
  local stripped_docs=""
  if command -v perl >/dev/null 2>&1; then
    stripped_docs=$(perl -0777 -ne '
      s{<!--.*?-->}{}sg;
      s{<pre\b[^>]*>.*?</pre>}{}sgi;
      s{<code\b[^>]*>.*?</code>}{}sgi;
      print;
    ' "$f" 2>/dev/null)
  fi

  # `stripped_full` — stripped_docs, PLUS every <script>...</script> BODY
  # emptied (opening/closing tags are kept, so F5's tag-attribute inspection
  # is unaffected). Used for F3/F4 content matching so a vendored library's
  # own minified source text is never mistaken for real page content.
  local stripped_full=""
  if [ -n "$stripped_docs" ] && command -v perl >/dev/null 2>&1; then
    stripped_full=$(printf '%s' "$stripped_docs" | perl -0777 -pe '
      s{(<script\b[^>]*>)(.*?)(</script>)}{$1$3}sgi;
    ' 2>/dev/null)
  fi

  # F1: tab-pane + mermaid pre in same file → flag.
  if grep -q 'class="tab-pane' "$f" 2>/dev/null && \
     grep -q 'class="mermaid mermaid-js"' "$f" 2>/dev/null; then
    printf '  [F1] %s — <pre class="mermaid mermaid-js"> + class="tab-pane" (dashboard fail mode)\n' "$f" >&2
    hits=$((hits + 1))
  fi

  # F2: empty mount div WITHOUT any evidence a mermaid loader was wired.
  #
  # At static-HTML time, mount divs are EXPECTED to be empty — they're
  # populated by an inline mermaid loader at runtime. We only flag the div
  # as a real failure when there is NO loader evidence anywhere on the page
  # (i.e. the template was adopted but the loader never reached the page,
  # OR was reached but never wired up).
  #
  # Loader evidence recognised (either pattern satisfies this):
  #   - CDN ESM:  <script type="module"> block anywhere on the page.
  #   - Vendored UMD: a classic <script> whose content calls
  #     mermaid.initialize(/.run(/.render(, or references
  #     window.mermaid/globalThis.mermaid.
  if command -v perl >/dev/null 2>&1; then
    local has_loader="0"
    if grep -qE '<script[[:space:]]+type="module"[[:space:]]*>' "$f" 2>/dev/null; then
      has_loader="1"
    fi
    if [ "$has_loader" = "0" ] && [ -n "$stripped_docs" ]; then
      if printf '%s' "$stripped_docs" | grep -qE 'mermaid\.(initialize|run|render)[[:space:]]*\(' 2>/dev/null; then
        has_loader="1"
      elif printf '%s' "$stripped_docs" | grep -qE '(window|globalThis)\.mermaid\b' 2>/dev/null; then
        has_loader="1"
      fi
    fi

    if [ "$has_loader" = "0" ]; then
      local empty
      empty=$(perl -0777 -ne '
        while (m{<div\b[^>]*\bid="([^"]*-mount)"[^>]*>(.*?)</div>}sg) {
          my ($id, $body) = ($1, $2);
          if ($body !~ /<svg|<pre|<p\b|<text|<g\b/) { print "$id\n"; }
        }
      ' "$f" 2>/dev/null)
      if [ -n "$empty" ]; then
        while IFS= read -r id; do
          printf '  [F2] %s — <div id="%s"> is empty AND no mermaid loader evidence on page\n' "$f" "$id" >&2
          hits=$((hits + 1))
        done <<<"$empty"
      fi
    fi
  fi

  # F3: mermaid parser error (real prose ≠ runtime error → require both
  # signals). Matched against stripped_full so a vendored UMD bundle's own
  # error-message template text (which lives inside a <script> body) is
  # never mistaken for a real, page-visible parser failure.
  if [ -n "$stripped_full" ]; then
    if printf '%s' "$stripped_full" | grep -q 'Syntax error in text' && \
       printf '%s' "$stripped_full" | grep -q 'mermaid version'; then
      printf '  [F3] %s — "Syntax error in text" + mermaid version (parser threw)\n' "$f" >&2
      hits=$((hits + 1))
    fi
  elif command -v perl >/dev/null 2>&1; then
    : # stripped_full computed but empty on an effectively-empty file; skip.
  else
    # No perl at all should never reach here (guarded by the caller), but
    # fall back to the raw-file check rather than silently skipping.
    if grep -q 'Syntax error in text' "$f" 2>/dev/null && \
       grep -q 'mermaid version' "$f" 2>/dev/null; then
      printf '  [F3] %s — "Syntax error in text" + mermaid version (parser threw)\n' "$f" >&2
      hits=$((hits + 1))
    fi
  fi

  # F4: banned yellow fill (L-10 lesson). Scan stripped_full so vendored
  # library source and documentation snippets don't fire.
  if [ -n "$stripped_full" ]; then
    if printf '%s' "$stripped_full" | grep -qE 'fill:#f1c84e|background:#f1c84e|background-color:#f1c84e'; then
      printf '  [F4] %s — banned yellow #f1c84e (use #a14ef1 purple + white text)\n' "$f" >&2
      hits=$((hits + 1))
    fi
  else
    if grep -qE 'fill:#f1c84e|background:#f1c84e|background-color:#f1c84e' "$f" 2>/dev/null; then
      printf '  [F4] %s — banned yellow #f1c84e (use #a14ef1 purple + white text)\n' "$f" >&2
      hits=$((hits + 1))
    fi
  fi

  # F5: local module src — Chrome blocks on file://. Use stripped_docs (tags
  # + content kept, only comments/<pre>/<code> removed) so HTML-comment /
  # <pre> documentation of the bad pattern doesn't fire.
  if [ -n "$stripped_docs" ]; then
    local has_bad
    has_bad=$(printf '%s' "$stripped_docs" | perl -ne '
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

  # F2: empty mount div, no loader evidence at all
  cat > "$tmp/f2.html" <<'HTML'
<html><body>
<div id="arch-mount" style="min-height:520px;"></div>
</body></html>
HTML
  n=$(scan_file "$tmp/f2.html" 2>/dev/null)
  [ "$n" -ge 1 ] && _ok "F2 flagged (empty mount div, no loader)" \
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

  # F2 negative: empty mount div + inline ESM module on page → ALLOW
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
  [ "$n" -eq 0 ] && _ok "F2 negative (empty mount + inline ESM module)" \
                || _fail "F2 false-positive on ESM-module page (n=$n)"

  # F2 negative + F3 negative: vendored-UMD-inlined pattern (llm#1067).
  # Two classic (non-module) <script> tags: the first stands in for a
  # vendored mermaid UMD bundle whose own minified source happens to
  # contain "Syntax error in text" and "mermaid version" as part of ITS
  # OWN error-message templates; the second is the application script that
  # actually wires up rendering via mermaid.initialize()/.render(). Mount
  # divs are empty (real mounting happens at browser runtime) and must NOT
  # be flagged, and the library's own message-template text must NOT be
  # mistaken for a real parser failure.
  cat > "$tmp/umd.html" <<'HTML'
<html><body>
<div id="arch-mount" style="min-height:520px;"></div>
<div id="assump-mount" style="min-height:520px;"></div>
<script>
/* ---- stand-in for a vendored mermaid UMD bundle ---- */
var fakeUmdMessages={a:"Syntax error in text",b:"mermaid version 10.9.1"};
window.mermaid={initialize:function(){},render:function(){}};
</script>
<script>
/* ---- application script ---- */
mermaid.initialize({startOnLoad:false,securityLevel:"loose",theme:"base"});
var mount=document.getElementById("arch-mount");
mermaid.render("mmd-arch", "graph TD\nA-->B").then(function(out){
  mount.innerHTML = out.svg;
});
</script>
</body></html>
HTML
  n=$(scan_file "$tmp/umd.html" 2>/dev/null)
  [ "$n" -eq 0 ] && _ok "UMD-inlined pattern: empty mounts + library's own error text → 0 findings" \
                || _fail "UMD-inlined pattern false-positive (n=$n)"

  # F2 positive: UMD bundle present but loader never actually wired (no
  # mermaid.initialize/.run/.render call, no window.mermaid reference in
  # the SECOND script) — the div-mount template was adopted but the
  # application never calls into mermaid. Must still be flagged.
  cat > "$tmp/umd_unwired.html" <<'HTML'
<html><body>
<div id="arch-mount" style="min-height:520px;"></div>
<script>
console.log("some other classic script, nothing to do with mermaid");
</script>
</body></html>
HTML
  n=$(scan_file "$tmp/umd_unwired.html" 2>/dev/null)
  [ "$n" -ge 1 ] && _ok "F2 flagged (classic script present but never wires mermaid)" \
                || _fail "F2 not flagged for unwired classic script (n=$n)"

  # F3: real parser error baked into visible page markup (outside any
  # <script> body) — e.g. a native Quarto {mermaid} chunk that mermaid-cli
  # rendered to an error message at build time. Must still be flagged.
  cat > "$tmp/f3.html" <<'HTML'
<html><body><div>Syntax error in text<br>mermaid version 11.6.0</div></body></html>
HTML
  n=$(scan_file "$tmp/f3.html" 2>/dev/null)
  [ "$n" -ge 1 ] && _ok "F3 flagged (parse error + mermaid version, in page body)" \
                || _fail "F3 not flagged (n=$n)"

  # F4
  cat > "$tmp/f4.html" <<'HTML'
<html><body><svg><rect style="fill:#f1c84e;"/></svg></body></html>
HTML
  n=$(scan_file "$tmp/f4.html" 2>/dev/null)
  [ "$n" -ge 1 ] && _ok "F4 flagged (yellow #f1c84e)" \
                || _fail "F4 not flagged (n=$n)"

  # F4 negative: yellow fill only inside a <script> body (e.g. a vendored
  # library's own default-theme palette) → ALLOW
  cat > "$tmp/f4script.html" <<'HTML'
<html><body>
<script>var libDefaultColor="fill:#f1c84e";</script>
<p>actual page content</p>
</body></html>
HTML
  n=$(scan_file "$tmp/f4script.html" 2>/dev/null)
  [ "$n" -eq 0 ] && _ok "F4 negative (yellow color literal only inside <script>)" \
                || _fail "F4 false-positive on script body (n=$n)"

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

  # End-to-end: the UMD-inlined regression fixture exits 0 (llm#1067)
  bash "$0" "$tmp/umd.html" >/dev/null 2>&1
  [ "$?" -eq 0 ] && _ok "end-to-end: UMD-inlined page exits 0 (llm#1067 fix)" \
                 || _fail "end-to-end: UMD-inlined page wrong exit"

  # End-to-end: missing dependency (perl) → exit 3, INDETERMINATE, never a
  # silent pass and never conflated with a real finding (exit 1).
  fakebin="$tmp/fakebin"
  mkdir -p "$fakebin"
  for tool in bash sh grep cat date mkdir dirname printf env; do
    tool_path="$(command -v "$tool" 2>/dev/null)"
    [ -n "$tool_path" ] && ln -sf "$tool_path" "$fakebin/$tool"
  done
  PATH="$fakebin" bash "$0" "$tmp/clean.html" >/tmp/verify_mermaid_deptest.$$.out 2>&1
  rc=$?
  if [ "$rc" -eq 3 ] && grep -q 'INDETERMINATE' /tmp/verify_mermaid_deptest.$$.out; then
    _ok "end-to-end: perl missing → exit 3 INDETERMINATE (not a silent pass)"
  else
    _fail "end-to-end: perl missing → expected exit 3 INDETERMINATE, got rc=$rc out='$(cat /tmp/verify_mermaid_deptest.$$.out)'"
  fi
  rm -f /tmp/verify_mermaid_deptest.$$.out

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

if ! command -v perl >/dev/null 2>&1; then
  printf 'verify_mermaid_dashboard: INDETERMINATE — required dependency missing: perl\n' >&2
  log "INDETERMINATE missing-dependency=perl target=$target"
  exit 3
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
