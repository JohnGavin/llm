#!/usr/bin/env bash
# quarto_post_render_contrast.sh - Quarto post-render hook for dark-mode contrast audit
#
# Wired into a project's _quarto.yml:
#   project:
#     post-render:
#       - ${HOME}/docs_gh/llm/.claude/scripts/quarto_post_render_contrast.sh
#
# Quarto invokes post-render scripts with these env vars set:
#   QUARTO_PROJECT_DIR           - the project root
#   QUARTO_PROJECT_OUTPUT_DIR    - output directory (e.g. "docs", "_site")
#   QUARTO_PROJECT_OUTPUT_FILES  - newline-separated list of rendered files
#   QUARTO_PROJECT_RENDER_ALL    - "1" on full-site render, empty on partial
#
# What this wrapper does:
#   1. Picks every .html in $QUARTO_PROJECT_OUTPUT_FILES (the freshly-rendered set).
#   2. Calls the canonical check_dark_contrast.sh on each via file:// URL.
#   3. Aggregates results. Exits non-zero if ANY file fails — Quarto aborts the
#      render and the failure surfaces in your build.
#
# Single source of truth: this wrapper lives in the public llm repo. Projects
# reference it by absolute path; no per-project copy.
#
# Public mirror for CI:
#   https://raw.githubusercontent.com/JohnGavin/llm/main/.claude/scripts/check_dark_contrast.sh
#   https://raw.githubusercontent.com/JohnGavin/llm/main/.claude/scripts/quarto_post_render_contrast.sh

set -uo pipefail

CHECK_SCRIPT="${HOME}/docs_gh/llm/.claude/scripts/check_dark_contrast.sh"
if [ ! -x "$CHECK_SCRIPT" ]; then
  echo "post-render-contrast: $CHECK_SCRIPT not found or not executable" >&2
  exit 0  # Don't fail the render if the audit infrastructure is missing
fi

# When run by Quarto, output files are in a single env var. When run manually
# for testing, fall back to scanning $QUARTO_PROJECT_OUTPUT_DIR for *.html.
files=""
if [ -n "${QUARTO_PROJECT_OUTPUT_FILES:-}" ]; then
  files="$QUARTO_PROJECT_OUTPUT_FILES"
elif [ -n "${QUARTO_PROJECT_OUTPUT_DIR:-}" ] && [ -d "${QUARTO_PROJECT_OUTPUT_DIR}" ]; then
  files=$(find "${QUARTO_PROJECT_OUTPUT_DIR}" -name '*.html' -type f 2>/dev/null)
else
  echo "post-render-contrast: no QUARTO_PROJECT_OUTPUT_FILES or _OUTPUT_DIR set" >&2
  exit 0
fi

fail=0
total=0
echo
echo "=== Dark-mode contrast audit (post-render) ==="
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in *.html) ;; *) continue ;; esac
  [ -f "$f" ] || continue
  total=$((total + 1))
  abs=$(cd "$(dirname "$f")" && pwd)/$(basename "$f")
  rel="${abs#${QUARTO_PROJECT_DIR:-$PWD}/}"
  echo
  echo "→ $rel"
  if "$CHECK_SCRIPT" "file://$abs" 2>&1 | tail -20; then
    :
  else
    fail=$((fail + 1))
  fi
done <<< "$files"

echo
echo "=== Audit summary: $total file(s) checked, $fail with violations ==="
if [ $fail -gt 0 ]; then
  echo "FAIL: contrast violations in $fail file(s). Render is BLOCKED."
  echo "      See dark-mode-completeness rule for the fix pattern."
  exit 1
fi
exit 0
