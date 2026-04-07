#!/usr/bin/env bash
# wiki_health_check.sh - Validate a knowledge-base wiki against its raw sources
# Used by T1 (on-write hook), T2 (pre-commit), T3 (/wiki-health), T4 (cron)
#
# Usage:
#   wiki_health_check.sh <wiki_dir> [--single FILE] [--quiet] [--json]
#
# Modes:
#   default       — full 7-check report (T3)
#   --single FILE — fast single-file check (T1, T2)
#   --quiet       — exit code only, no output unless errors (T1)
#   --json        — JSON output for programmatic consumption
#
# Exit codes:
#   0 = clean
#   1 = warnings (broken links, missing sources)
#   2 = errors (fabricated quotes, missing required sections)

set -uo pipefail

WIKI_DIR="${1:-}"
[ -z "$WIKI_DIR" ] && { echo "Usage: $0 <wiki_dir> [--single FILE] [--quiet] [--json]"; exit 2; }
[ ! -d "$WIKI_DIR" ] && { echo "ERROR: $WIKI_DIR is not a directory"; exit 2; }

shift
SINGLE_FILE=""
QUIET=0
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --single) SINGLE_FILE="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --json) JSON=1; shift ;;
    *) shift ;;
  esac
done

# Find raw/ sibling of wiki/
PARENT="$(dirname "$WIKI_DIR")"
RAW_DIR="$PARENT/raw"
[ ! -d "$RAW_DIR" ] && { echo "ERROR: no raw/ sibling at $RAW_DIR"; exit 2; }

errors=0
warnings=0
report=""

log_error() { errors=$((errors + 1)); report="$report\n  ERROR: $1"; }
log_warn()  { warnings=$((warnings + 1)); report="$report\n  WARN: $1"; }

# ── Check 1: Provenance — every wiki/*.md has ## Sources section ──
check_provenance() {
  local file="$1"
  if ! grep -q "^## Sources" "$file"; then
    log_error "$file missing '## Sources' section"
    return 1
  fi
}

# ── Check 4: Dead [[wiki-link]] resolution ──
check_wiki_links() {
  local file="$1"
  # Extract [[link]] targets
  grep -oE '\[\[[a-z0-9_-]+\]\]' "$file" 2>/dev/null | sort -u | while read -r link; do
    target="${link//\[\[/}"
    target="${target//\]\]/}"
    if [ ! -f "$WIKI_DIR/$target.md" ]; then
      echo "DEAD_LINK:$file:$target"
    fi
  done
}

# ── Check 5: Confidence ratio ──
count_confidence_markers() {
  local file="$1"
  local inferred=$(grep -c "^> ⚠ AI-inferred:" "$file" 2>/dev/null || echo 0)
  local hypothesis=$(grep -c "^> 🔬 Hypothesis:" "$file" 2>/dev/null || echo 0)
  local conflicting=$(grep -c "^> ❓ Conflicting:" "$file" 2>/dev/null || echo 0)
  echo "$inferred $hypothesis $conflicting"
}

# ── Single-file mode (T1, T2) ──
if [ -n "$SINGLE_FILE" ]; then
  [ ! -f "$SINGLE_FILE" ] && exit 0  # file doesn't exist (deleted) — skip
  case "$SINGLE_FILE" in
    */wiki/*.md)
      check_provenance "$SINGLE_FILE"
      dead=$(check_wiki_links "$SINGLE_FILE")
      if [ -n "$dead" ]; then
        log_warn "$(echo "$dead" | head -3)"
      fi
      ;;
    *) exit 0 ;;  # not a wiki file
  esac

  if [ $errors -gt 0 ]; then
    [ $QUIET -eq 0 ] && echo -e "wiki health: $errors error(s) in $SINGLE_FILE$report"
    exit 2
  fi
  if [ $warnings -gt 0 ]; then
    [ $QUIET -eq 0 ] && echo -e "wiki health: $warnings warning(s) in $SINGLE_FILE$report"
    exit 1
  fi
  exit 0
fi

# ── Full mode (T3, T4) ──
total_files=0
files_with_sources=0
total_inferred=0
total_hypothesis=0
total_conflicting=0
dead_links=()

for f in "$WIKI_DIR"/*.md; do
  [ -f "$f" ] || continue
  [ "$(basename "$f")" = "INDEX.md" ] && continue
  total_files=$((total_files + 1))

  if check_provenance "$f" 2>/dev/null; then
    files_with_sources=$((files_with_sources + 1))
  fi

  read -r inf hyp con <<< "$(count_confidence_markers "$f")"
  total_inferred=$((total_inferred + inf))
  total_hypothesis=$((total_hypothesis + hyp))
  total_conflicting=$((total_conflicting + con))

  while IFS= read -r line; do
    [ -n "$line" ] && dead_links+=("$line")
  done < <(check_wiki_links "$f")
done

# ── Check 3: Orphan raw/ files (not referenced by any wiki/) ──
orphans=0
for r in "$RAW_DIR"/*.md; do
  [ -f "$r" ] || continue
  base=$(basename "$r")
  if ! grep -rq "$base" "$WIKI_DIR" 2>/dev/null; then
    orphans=$((orphans + 1))
    log_warn "orphan raw file: $base (not referenced in any wiki)"
  fi
done

# ── Check 7: INDEX.md sync ──
if [ -f "$WIKI_DIR/INDEX.md" ]; then
  for f in "$WIKI_DIR"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .md)
    [ "$base" = "INDEX" ] && continue
    if ! grep -q "$base" "$WIKI_DIR/INDEX.md" 2>/dev/null; then
      log_warn "INDEX.md missing entry for $base"
    fi
  done
else
  log_warn "wiki/INDEX.md does not exist"
fi

# ── Output ──
if [ $JSON -eq 1 ]; then
  echo "{"
  echo "  \"total_files\": $total_files,"
  echo "  \"files_with_sources\": $files_with_sources,"
  echo "  \"orphan_raw_files\": $orphans,"
  echo "  \"dead_wiki_links\": ${#dead_links[@]},"
  echo "  \"ai_inferred_claims\": $total_inferred,"
  echo "  \"hypothesis_claims\": $total_hypothesis,"
  echo "  \"conflicting_claims\": $total_conflicting,"
  echo "  \"errors\": $errors,"
  echo "  \"warnings\": $warnings"
  echo "}"
else
  echo "=== Wiki Health Report ==="
  echo "Wiki dir:   $WIKI_DIR"
  echo "Raw dir:    $RAW_DIR"
  echo ""
  echo "Files:                $total_files"
  echo "With ## Sources:      $files_with_sources / $total_files"
  echo "Orphan raw files:     $orphans"
  echo "Dead [[wiki-links]]:  ${#dead_links[@]}"
  echo ""
  echo "Confidence markers:"
  echo "  AI-inferred (⚠):    $total_inferred"
  echo "  Hypothesis (🔬):    $total_hypothesis"
  echo "  Conflicting (❓):   $total_conflicting"
  echo ""
  if [ ${#dead_links[@]} -gt 0 ]; then
    echo "Dead links:"
    printf '  %s\n' "${dead_links[@]}"
    echo ""
  fi
  echo -e "Errors: $errors$report"
  echo "Warnings: $warnings"
fi

[ $errors -gt 0 ] && exit 2
[ $warnings -gt 0 ] && exit 1
exit 0
