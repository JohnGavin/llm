#!/usr/bin/env bash
# mermaid_dashboard_guard.sh — PreToolUse:Edit|Write hook.
#
# Blocks edits that put a ```{mermaid} chunk inside a `::: {.panel-tabset}`
# block of a .qmd file. That combination silently fails at runtime because
# Quarto's mermaid loader fires on `window.load` when only the first tab
# is visible, leaving SVGs zero-sized.
#
# Rule: mermaid-dashboard-pattern
# Lessons: L-10, L-11 in JohnGavin/premortem knowledge_base/lessons_learnt.md
# Reference template: ~/docs_gh/llm/.claude/templates/mermaid-dashboard/
#
# Exit codes:
#   0  allowed (no .qmd, no problematic content, or escape hatch)
#   2  blocked (the violating pattern was detected)
#   3  selftest mode + a test failed
#
# Env:
#   CLAUDE_MERMAID_DASHBOARD_GUARD=0  bypass (audited to skip log)
#   CLAUDE_HOOK_SELFTEST=1            run embedded selftests and exit

set -u
set -o pipefail

LOG="${HOME}/.claude/logs/mermaid_dashboard_guard.log"
SKIP_LOG="${HOME}/.claude/logs/mermaid_dashboard_guard_skip.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

ts()  { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '%s %s\n' "$(ts)" "$*" >> "$LOG"; }

# ── Escape hatch ──────────────────────────────────────────────────────────────
if [ "${CLAUDE_MERMAID_DASHBOARD_GUARD:-1}" = "0" ]; then
  printf '%s SKIP cwd=%s\n' "$(ts)" "$PWD" >> "$SKIP_LOG"
  exit 0
fi

# ── Selftest battery ─────────────────────────────────────────────────────────
if [ "${CLAUDE_HOOK_SELFTEST:-0}" = "1" ]; then
  pass=0; fail=0; total=0
  _ok()   { total=$((total+1)); pass=$((pass+1)); printf '  PASS  %s\n' "$*"; }
  _fail() { total=$((total+1)); fail=$((fail+1)); printf '  FAIL  %s\n' "$*"; }

  # Each case feeds a JSON payload into the hook's stdin and checks exit code.
  run_case() {
    local payload="$1"
    CLAUDE_HOOK_SELFTEST=0 CLAUDE_MERMAID_DASHBOARD_GUARD=1 \
      bash "$0" <<<"$payload" >/dev/null 2>&1
    echo "$?"
  }

  # 1. .qmd with panel-tabset AND {mermaid} → BLOCK (exit 2)
  p1='{"tool":"Write","tool_input":{"file_path":"/tmp/dash.qmd","content":"# Dash\n\n::: {.panel-tabset}\n\n## Architecture\n\n```{mermaid}\ngraph TD\n  A-->B\n```\n\n:::\n"}}'
  rc=$(run_case "$p1")
  [ "$rc" = "2" ] && _ok "blocks {mermaid} inside .panel-tabset" \
                  || _fail "did not block (rc=$rc)"

  # 2. .qmd with {mermaid} but NO panel-tabset → ALLOW (exit 0)
  p2='{"tool":"Write","tool_input":{"file_path":"/tmp/flat.qmd","content":"# Flat page\n\n```{mermaid}\ngraph TD\n  A-->B\n```\n"}}'
  rc=$(run_case "$p2")
  [ "$rc" = "0" ] && _ok "allows {mermaid} on a flat page (no tabset)" \
                  || _fail "wrongly blocked flat-page (rc=$rc)"

  # 3. .qmd with panel-tabset but NO mermaid → ALLOW
  p3='{"tool":"Write","tool_input":{"file_path":"/tmp/tabs.qmd","content":"::: {.panel-tabset}\n## A\nfoo\n## B\nbar\n:::\n"}}'
  rc=$(run_case "$p3")
  [ "$rc" = "0" ] && _ok "allows .panel-tabset without {mermaid}" \
                  || _fail "wrongly blocked tabset-only (rc=$rc)"

  # 4. non-.qmd file → ALLOW (out of scope)
  p4='{"tool":"Write","tool_input":{"file_path":"/tmp/x.R","content":"```{mermaid}\ngraph TD\n  A-->B\n```\n"}}'
  rc=$(run_case "$p4")
  [ "$rc" = "0" ] && _ok "ignores non-.qmd files" \
                  || _fail "wrongly blocked non-.qmd (rc=$rc)"

  # 5. Mount-div pattern (the recommended replacement) → ALLOW
  p5='{"tool":"Write","tool_input":{"file_path":"/tmp/dash2.qmd","content":"::: {.panel-tabset}\n## Architecture\n<div id=\"arch-mount\"></div>\n:::\n"}}'
  rc=$(run_case "$p5")
  [ "$rc" = "0" ] && _ok "allows mount-div pattern in tabset" \
                  || _fail "wrongly blocked mount-div (rc=$rc)"

  # 6. Edit tool variant (not just Write) → BLOCK same payload
  p6='{"tool":"Edit","tool_input":{"file_path":"/tmp/dash.qmd","new_string":"::: {.panel-tabset}\n```{mermaid}\ngraph TD\n  A-->B\n```\n:::"}}'
  rc=$(run_case "$p6")
  [ "$rc" = "2" ] && _ok "blocks Edit (not just Write) too" \
                  || _fail "Edit not blocked (rc=$rc)"

  # 7. Escape hatch silences block
  rc=$(CLAUDE_MERMAID_DASHBOARD_GUARD=0 CLAUDE_HOOK_SELFTEST=0 \
       bash "$0" <<<"$p1" >/dev/null 2>&1; echo "$?")
  [ "$rc" = "0" ] && _ok "CLAUDE_MERMAID_DASHBOARD_GUARD=0 bypasses block" \
                  || _fail "escape hatch failed (rc=$rc)"

  printf '\nmermaid_dashboard_guard selftest: %d/%d PASS\n' "$pass" "$total"
  [ "$fail" -eq 0 ] && exit 0 || exit 3
fi

# ── Production logic ─────────────────────────────────────────────────────────
# Read the tool-call JSON from stdin.
payload="$(cat || true)"
[ -n "$payload" ] || exit 0

# Extract file_path. We support both `.tool_input.file_path` and the
# `tool_use.input` shape from older Claude harness versions.
file_path="$(
  printf '%s' "$payload" |
    grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' |
    head -1 |
    sed -E 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
)"

# Only act on .qmd files
case "$file_path" in
  *.qmd) ;;
  *) exit 0 ;;
esac

# Detect both signatures in the payload.
# Use one-char-class greps so we don't depend on the exact key the harness used
# (content / new_string / file_text / etc.).
has_tabset=0
has_mermaid_chunk=0

if printf '%s' "$payload" | grep -qE '\.panel-tabset|::: *\{[^}]*\.panel-tabset'; then
  has_tabset=1
fi
if printf '%s' "$payload" | grep -qE '`{3}\{mermaid|backticks\{mermaid'; then
  has_mermaid_chunk=1
fi
# Also catch the escaped form "```\{mermaid" or backslash-escaped braces in JSON
if [ "$has_mermaid_chunk" = "0" ] && \
   printf '%s' "$payload" | grep -qE '\\u0060\\u0060\\u0060\{mermaid'; then
  has_mermaid_chunk=1
fi

if [ "$has_tabset" = "1" ] && [ "$has_mermaid_chunk" = "1" ]; then
  log "BLOCK file=$file_path tabset+mermaid_chunk"
  cat >&2 <<EOF
[mermaid_dashboard_guard] BLOCKED — $file_path

This edit would put a \`\`\`{mermaid} chunk inside a
::: {.panel-tabset} block. That combination has a known silent failure
mode: Quarto's mermaid loader fires on window.load when only the first
tab is visible, leaving SVGs zero-sized in hidden tabs.

Use the dashboard pattern instead:
  1. Replace the {mermaid} chunk with a mount div, e.g.
     <div id="my-arch-mount" style="min-height:520px;"></div>
  2. Define the diagram in dashboard/<project>-diagrams.js
  3. Inline-load it via include-after-body in your qmd YAML.

See:
  - Rule:     ~/docs_gh/llm/.claude/rules/mermaid-dashboard-pattern.md
  - Template: ~/docs_gh/llm/.claude/templates/mermaid-dashboard/
  - Lessons:  premortem knowledge_base/lessons_learnt.md L-10/L-11

Bypass for one-off (e.g. you really mean a flat-page diagram you'll
move outside the tabset later): set CLAUDE_MERMAID_DASHBOARD_GUARD=0
for this command. Per-project exemption: add the line
  mermaid-dashboard-guard: off
to the project's .claude/CLAUDE.md.
EOF
  exit 2
fi

log "ALLOW file=$file_path"
exit 0
