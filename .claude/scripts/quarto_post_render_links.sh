#!/usr/bin/env bash
# quarto_post_render_links.sh — Quarto post-render hook: fail on broken internal links.
#
# Wired into a project's _quarto.yml:
#   project:
#     post-render:
#       - .claude/scripts/quarto_post_render_links.sh
#
# Quarto sets QUARTO_PROJECT_OUTPUT_DIR (e.g. "docs"). This wrapper scans the
# WHOLE output dir (not just the freshly-rendered files) because a link's target
# may be a page rendered in a previous/partial pass. It delegates to the
# canonical check_internal_links.sh and aborts the render (exit 1) if any
# internal link 404s. See JohnGavin/llm#715.
#
# Self-locating: finds check_internal_links.sh beside itself via BASH_SOURCE so
# it works both on a local machine and in CI (where $HOME/docs_gh/llm is absent).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/check_internal_links.sh"

if [ ! -x "$CHECK_SCRIPT" ]; then
  echo "post-render-links: $CHECK_SCRIPT not found or not executable" >&2
  exit 0  # Don't fail the render if the check infrastructure is missing.
fi

OUT_DIR="${QUARTO_PROJECT_OUTPUT_DIR:-docs}"
if [ ! -d "$OUT_DIR" ]; then
  echo "post-render-links: output dir not found: $OUT_DIR" >&2
  exit 0
fi

echo
echo "=== Internal-link check (post-render) ==="
if "$CHECK_SCRIPT" "$OUT_DIR"; then
  echo "OK: no broken internal links in $OUT_DIR"
  exit 0
fi
echo "FAIL: broken internal links (listed above). Render is BLOCKED (llm#715)." >&2
exit 1
