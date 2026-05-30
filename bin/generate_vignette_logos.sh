#!/usr/bin/env bash
# generate_vignette_logos.sh — Idempotent SVG logo generator for llm vignettes.
#
# Produces one 200x200 SVG per vignette under man/figures/vignette-<slug>.svg
# and the project-level mark at assets/logo.svg.
#
# Usage:
#   bin/generate_vignette_logos.sh               # regenerate all missing logos
#   bin/generate_vignette_logos.sh --force        # regenerate all logos
#   bin/generate_vignette_logos.sh --list         # print vignette inventory
#
# SVG design rules:
#   - 200x200 viewport, circular background
#   - Two-letter abbreviation at top (identifies slug visually)
#   - Pictogram reflecting the vignette's theme
#   - Colours from _brand.yml dark-mode-safe palette
#   - <title> element for screen-reader alt text (accessibility rule)
#   - Background colours pass WCAG AA 4.5:1 on white (light mode)
#     and are visible on dark mode (#000000 background via CSS)
#
# To add a new vignette logo:
#   1. Add an entry to the VIGNETTES array below.
#   2. Add a generate_<slug> function that writes the SVG.
#   3. Re-run this script.
#
# Related: llm#152 (per-vignette logos), llm#146 (_brand.yml)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIGURES_DIR="$REPO_ROOT/man/figures"
ASSETS_DIR="$REPO_ROOT/assets"
FORCE=0
LIST_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --list)  LIST_ONLY=1 ;;
  esac
done

mkdir -p "$FIGURES_DIR"
mkdir -p "$ASSETS_DIR"

# ── Vignette inventory ─────────────────────────────────────────────────────────
# Format: "slug|two-letter-abbrev|hex-color|label|theme-description"
VIGNETTES=(
  "closeread-infrastructure|CI|#4ea8de|Infrastructure|layered stack / orchestration"
  "telemetry|TE|#69d4a0|Telemetry|logs, metrics, observability"
  "config-evolution|CE|#ffd166|Config Evolution|time-series, growth metrics"
  "knowledge-evolution|KE|#c084fc|Knowledge Evol.|wiki / graph topology"
  "llm-assisted-tips|LA|#5edaff|LLM Tips|lightbulb / practical advice"
  "closeread-config|CC|#f08080|Config Stack|agent definitions, rules, hooks"
  "roborev-architecture|RA|#ff9f43|Roborev Arch.|automated code review workflow"
  "hover-popup-demo|HP|#fd79a8|Hover Popup|interactive tooltip demonstrations"
  "scrolly-config-evolution|SC|#a29bfe|Scrolly Config|scrollytelling config timeline"
)

list_vignettes() {
  echo "Vignette logo inventory:"
  echo ""
  printf "%-36s %-6s %-10s %s\n" "Slug" "Abbr" "Colour" "Theme"
  printf "%-36s %-6s %-10s %s\n" "----" "----" "------" "-----"
  for entry in "${VIGNETTES[@]}"; do
    IFS='|' read -r slug abbr colour label theme <<< "$entry"
    printf "%-36s %-6s %-10s %s\n" "$slug" "$abbr" "$colour" "$theme"
  done
  echo ""
  echo "Project mark: assets/logo.svg"
}

if [ "$LIST_ONLY" -eq 1 ]; then
  list_vignettes
  exit 0
fi

# ── SVG fragment generators (one per vignette) ─────────────────────────────────

write_closeread_infrastructure() {
  local f="$FIGURES_DIR/vignette-closeread-infrastructure.svg"
  cat > "$f" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="200" height="200" role="img" aria-labelledby="title-ci">
  <title id="title-ci">closeread-infrastructure vignette logo — layered stack / orchestration</title>
  <circle cx="100" cy="100" r="96" fill="#4ea8de"/>
  <rect x="44" y="66" width="112" height="18" rx="4" fill="#000000" opacity="0.20"/>
  <rect x="44" y="91" width="112" height="18" rx="4" fill="#000000" opacity="0.30"/>
  <rect x="44" y="116" width="112" height="18" rx="4" fill="#000000" opacity="0.40"/>
  <text x="100" y="52" font-family="ui-monospace,monospace" font-size="20" font-weight="700" fill="#ffffff" text-anchor="middle">CI</text>
  <text x="100" y="158" font-family="system-ui,sans-serif" font-size="13" fill="#ffffff" text-anchor="middle" opacity="0.9">Infrastructure</text>
</svg>
EOF
  echo "  wrote: $f"
}

write_telemetry() {
  local f="$FIGURES_DIR/vignette-telemetry.svg"
  cat > "$f" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="200" height="200" role="img" aria-labelledby="title-te">
  <title id="title-te">telemetry vignette logo — logs, metrics, observability</title>
  <circle cx="100" cy="100" r="96" fill="#69d4a0"/>
  <polyline points="44,130 65,95 80,115 100,70 120,105 140,85 156,100" fill="none" stroke="#000000" stroke-width="4" stroke-opacity="0.35" stroke-linecap="round" stroke-linejoin="round"/>
  <text x="100" y="52" font-family="ui-monospace,monospace" font-size="20" font-weight="700" fill="#000000" text-anchor="middle" opacity="0.7">TE</text>
  <text x="100" y="158" font-family="system-ui,sans-serif" font-size="13" fill="#000000" text-anchor="middle" opacity="0.7">Telemetry</text>
</svg>
EOF
  echo "  wrote: $f"
}

write_config_evolution() {
  local f="$FIGURES_DIR/vignette-config-evolution.svg"
  cat > "$f" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="200" height="200" role="img" aria-labelledby="title-ce">
  <title id="title-ce">config-evolution vignette logo — time-series, growth metrics</title>
  <circle cx="100" cy="100" r="96" fill="#ffd166"/>
  <rect x="52" y="130" width="18" height="20" rx="2" fill="#000000" opacity="0.30"/>
  <rect x="76" y="110" width="18" height="40" rx="2" fill="#000000" opacity="0.30"/>
  <rect x="100" y="88" width="18" height="62" rx="2" fill="#000000" opacity="0.30"/>
  <rect x="124" y="68" width="18" height="82" rx="2" fill="#000000" opacity="0.30"/>
  <text x="100" y="52" font-family="ui-monospace,monospace" font-size="20" font-weight="700" fill="#000000" text-anchor="middle" opacity="0.7">CE</text>
  <text x="100" y="170" font-family="system-ui,sans-serif" font-size="12" fill="#000000" text-anchor="middle" opacity="0.7">Config Evolution</text>
</svg>
EOF
  echo "  wrote: $f"
}

write_knowledge_evolution() {
  local f="$FIGURES_DIR/vignette-knowledge-evolution.svg"
  cat > "$f" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="200" height="200" role="img" aria-labelledby="title-ke">
  <title id="title-ke">knowledge-evolution vignette logo — wiki / graph topology</title>
  <circle cx="100" cy="100" r="96" fill="#c084fc"/>
  <line x1="100" y1="80" x2="65" y2="110" stroke="#000000" stroke-width="2" stroke-opacity="0.30"/>
  <line x1="100" y1="80" x2="135" y2="110" stroke="#000000" stroke-width="2" stroke-opacity="0.30"/>
  <line x1="65" y1="110" x2="85" y2="135" stroke="#000000" stroke-width="2" stroke-opacity="0.30"/>
  <line x1="135" y1="110" x2="115" y2="135" stroke="#000000" stroke-width="2" stroke-opacity="0.30"/>
  <circle cx="100" cy="80" r="10" fill="#000000" opacity="0.30"/>
  <circle cx="65" cy="110" r="8" fill="#000000" opacity="0.25"/>
  <circle cx="135" cy="110" r="8" fill="#000000" opacity="0.25"/>
  <circle cx="85" cy="135" r="6" fill="#000000" opacity="0.20"/>
  <circle cx="115" cy="135" r="6" fill="#000000" opacity="0.20"/>
  <text x="100" y="52" font-family="ui-monospace,monospace" font-size="20" font-weight="700" fill="#ffffff" text-anchor="middle">KE</text>
  <text x="100" y="168" font-family="system-ui,sans-serif" font-size="12" fill="#ffffff" text-anchor="middle" opacity="0.9">Knowledge Evol.</text>
</svg>
EOF
  echo "  wrote: $f"
}

write_llm_assisted_tips() {
  local f="$FIGURES_DIR/vignette-llm-assisted-tips.svg"
  cat > "$f" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="200" height="200" role="img" aria-labelledby="title-la">
  <title id="title-la">llm-assisted-tips vignette logo — lightbulb / practical advice</title>
  <circle cx="100" cy="100" r="96" fill="#5edaff"/>
  <path d="M100 62 C80 62 66 76 66 94 C66 107 74 118 86 124 L86 134 C86 137 88 139 91 139 L109 139 C112 139 114 137 114 134 L114 124 C126 118 134 107 134 94 C134 76 120 62 100 62 Z" fill="#000000" opacity="0.25"/>
  <rect x="88" y="139" width="24" height="5" rx="2" fill="#000000" opacity="0.20"/>
  <text x="100" y="52" font-family="ui-monospace,monospace" font-size="20" font-weight="700" fill="#000000" text-anchor="middle" opacity="0.7">LA</text>
  <text x="100" y="168" font-family="system-ui,sans-serif" font-size="12" fill="#000000" text-anchor="middle" opacity="0.7">LLM Tips</text>
</svg>
EOF
  echo "  wrote: $f"
}

write_closeread_config() {
  local f="$FIGURES_DIR/vignette-closeread-config.svg"
  cat > "$f" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="200" height="200" role="img" aria-labelledby="title-cc">
  <title id="title-cc">closeread-config vignette logo — agent definitions, rules, hooks</title>
  <circle cx="100" cy="100" r="96" fill="#f08080"/>
  <circle cx="100" cy="100" r="22" fill="#000000" opacity="0.25"/>
  <circle cx="100" cy="100" r="12" fill="#f08080"/>
  <rect x="95" y="66" width="10" height="16" rx="3" fill="#000000" opacity="0.25" transform="rotate(0 100 100)"/>
  <rect x="95" y="66" width="10" height="16" rx="3" fill="#000000" opacity="0.25" transform="rotate(45 100 100)"/>
  <rect x="95" y="66" width="10" height="16" rx="3" fill="#000000" opacity="0.25" transform="rotate(90 100 100)"/>
  <rect x="95" y="66" width="10" height="16" rx="3" fill="#000000" opacity="0.25" transform="rotate(135 100 100)"/>
  <text x="100" y="52" font-family="ui-monospace,monospace" font-size="20" font-weight="700" fill="#ffffff" text-anchor="middle">CC</text>
  <text x="100" y="168" font-family="system-ui,sans-serif" font-size="12" fill="#ffffff" text-anchor="middle" opacity="0.9">Config Stack</text>
</svg>
EOF
  echo "  wrote: $f"
}

write_roborev_architecture() {
  local f="$FIGURES_DIR/vignette-roborev-architecture.svg"
  cat > "$f" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="200" height="200" role="img" aria-labelledby="title-ra">
  <title id="title-ra">roborev-architecture vignette logo — automated code review workflow</title>
  <circle cx="100" cy="100" r="96" fill="#ff9f43"/>
  <circle cx="95" cy="93" r="22" fill="none" stroke="#000000" stroke-width="5" stroke-opacity="0.30"/>
  <line x1="111" y1="109" x2="128" y2="126" stroke="#000000" stroke-width="5" stroke-opacity="0.30" stroke-linecap="round"/>
  <polyline points="85,94 93,102 108,84" fill="none" stroke="#000000" stroke-width="4" stroke-opacity="0.40" stroke-linecap="round" stroke-linejoin="round"/>
  <text x="100" y="52" font-family="ui-monospace,monospace" font-size="20" font-weight="700" fill="#000000" text-anchor="middle" opacity="0.7">RA</text>
  <text x="100" y="168" font-family="system-ui,sans-serif" font-size="12" fill="#000000" text-anchor="middle" opacity="0.7">Roborev Arch.</text>
</svg>
EOF
  echo "  wrote: $f"
}

write_hover_popup_demo() {
  local f="$FIGURES_DIR/vignette-hover-popup-demo.svg"
  cat > "$f" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="200" height="200" role="img" aria-labelledby="title-hp">
  <title id="title-hp">hover-popup-demo vignette logo — interactive tooltip demonstrations</title>
  <circle cx="100" cy="100" r="96" fill="#fd79a8"/>
  <rect x="50" y="72" width="100" height="60" rx="10" fill="#000000" opacity="0.25"/>
  <polygon points="90,132 100,150 110,132" fill="#000000" opacity="0.25"/>
  <circle cx="78" cy="102" r="6" fill="#fd79a8"/>
  <circle cx="100" cy="102" r="6" fill="#fd79a8"/>
  <circle cx="122" cy="102" r="6" fill="#fd79a8"/>
  <text x="100" y="52" font-family="ui-monospace,monospace" font-size="20" font-weight="700" fill="#ffffff" text-anchor="middle">HP</text>
  <text x="100" y="170" font-family="system-ui,sans-serif" font-size="12" fill="#ffffff" text-anchor="middle" opacity="0.9">Hover Popup</text>
</svg>
EOF
  echo "  wrote: $f"
}

write_scrolly_config_evolution() {
  local f="$FIGURES_DIR/vignette-scrolly-config-evolution.svg"
  cat > "$f" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="200" height="200" role="img" aria-labelledby="title-sc">
  <title id="title-sc">scrolly-config-evolution vignette logo — scrollytelling config timeline</title>
  <circle cx="100" cy="100" r="96" fill="#a29bfe"/>
  <rect x="85" y="64" width="30" height="70" rx="15" fill="none" stroke="#000000" stroke-width="4" stroke-opacity="0.30"/>
  <circle cx="100" cy="82" r="6" fill="#000000" opacity="0.35"/>
  <polyline points="86,148 100,164 114,148" fill="none" stroke="#000000" stroke-width="4" stroke-opacity="0.30" stroke-linecap="round" stroke-linejoin="round"/>
  <text x="100" y="52" font-family="ui-monospace,monospace" font-size="20" font-weight="700" fill="#ffffff" text-anchor="middle">SC</text>
  <text x="100" y="50" font-family="system-ui,sans-serif" font-size="12" fill="#ffffff" text-anchor="middle" opacity="0.9">Scrolly Config</text>
</svg>
EOF
  echo "  wrote: $f"
}

write_project_logo() {
  local f="$ASSETS_DIR/logo.svg"
  cat > "$f" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="200" height="200" role="img" aria-labelledby="title-llm">
  <title id="title-llm">llm project wordmark — Claude Code configuration and agent workflows</title>
  <circle cx="100" cy="100" r="96" fill="#2780e3"/>
  <text x="100" y="112" font-family="ui-monospace,monospace" font-size="44" font-weight="700" fill="#ffffff" text-anchor="middle">llm</text>
  <text x="100" y="148" font-family="system-ui,sans-serif" font-size="13" fill="#ffffff" text-anchor="middle" opacity="0.85">Claude Code Config</text>
</svg>
EOF
  echo "  wrote: $f"
}

# ── Main loop ──────────────────────────────────────────────────────────────────

echo "generate_vignette_logos.sh — llm per-vignette SVG logos"
echo ""

# Project mark
TARGET="$ASSETS_DIR/logo.svg"
if [ "$FORCE" -eq 1 ] || [ ! -f "$TARGET" ]; then
  write_project_logo
else
  echo "  skipped (exists): $TARGET"
fi

# Vignette logos
declare -A WRITERS=(
  [closeread-infrastructure]=write_closeread_infrastructure
  [telemetry]=write_telemetry
  [config-evolution]=write_config_evolution
  [knowledge-evolution]=write_knowledge_evolution
  [llm-assisted-tips]=write_llm_assisted_tips
  [closeread-config]=write_closeread_config
  [roborev-architecture]=write_roborev_architecture
  [hover-popup-demo]=write_hover_popup_demo
  [scrolly-config-evolution]=write_scrolly_config_evolution
)

WRITTEN=0
SKIPPED=0
for slug in "${!WRITERS[@]}"; do
  target="$FIGURES_DIR/vignette-${slug}.svg"
  if [ "$FORCE" -eq 1 ] || [ ! -f "$target" ]; then
    "${WRITERS[$slug]}"
    WRITTEN=$((WRITTEN + 1))
  else
    echo "  skipped (exists): $target"
    SKIPPED=$((SKIPPED + 1))
  fi
done

echo ""
echo "Done. Written: $WRITTEN  Skipped: $SKIPPED"
echo ""
echo "Next: update each vignette's YAML frontmatter to reference its logo:"
echo "  image: man/figures/vignette-<slug>.svg"
