#!/usr/bin/env bash
# wiki_health_check.sh - Validate a knowledge-base wiki against its raw sources
# Used by T1 (on-write hook), T2 (pre-commit), T3 (manual full report), T4 (cron)
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
# Checks:
#   1. Provenance — ## Sources section present
#   2. Frontmatter — YAML frontmatter with required fields
#   3. Dead [[wiki-links]] — every link resolves
#   4. Orphan raw files — every raw/ referenced by at least one wiki
#   5. Staleness — fresh_until date vs today
#   6. Lifecycle status — active / stale / superseded
#   7. INDEX sync — wiki/INDEX.md lists every topic
#
# Exit codes:
#   0 = clean
#   1 = warnings (stale pages, orphan raw files, missing optional fields)
#   2 = errors (missing frontmatter, missing ## Sources, fabricated quotes)
#       or usage error (bad args, raw/.orphan-ignore entry without a reason)
#   3 = INDETERMINATE (raw/ or wiki/ unreadable; orphan check could not run)
#
# Known mismatch with the 0/1/2/3 convention (checks-must-distinguish-unknown):
# exit 2 still covers both "content errors" and "usage errors". Callers
# (cron_catchup.sh, launchd_run_record.sh, wiki_health_onwrite.sh) treat any
# nonzero as failure/ignore, so only 3 and the allow-list 2 were added (#1397).
#
# Orphan check (4): recursive over raw/, all file types; excludes sidecars
# (*.meta.yml, *.provenance), dotfiles, "_"-prefixed folders, and entries of
# raw/.orphan-ignore ("<rel path or dir/>  # reason"; reason mandatory).

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

PARENT="$(dirname "$WIKI_DIR")"
RAW_DIR="$PARENT/raw"
[ ! -d "$RAW_DIR" ] && { echo "ERROR: no raw/ sibling at $RAW_DIR"; exit 2; }

TODAY=$(date +%Y-%m-%d)

errors=0
warnings=0
report=""

log_error() { errors=$((errors + 1)); report="$report\n  ERROR: $1"; }
log_warn()  { warnings=$((warnings + 1)); report="$report\n  WARN: $1"; }

# ── Frontmatter schema (llm#759 Phase 1) ──
# Required fields, status enum, and consensus_level enum are derived from
# .claude/schema/wiki-frontmatter.schema.json (single source of truth) via
# jq. If jq or the schema file is unavailable, fail open: fall back to the
# pre-schema hardcoded lists and skip consensus_level enum validation
# (matches historical behaviour exactly — do not fail the hook on machines
# without jq).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SCHEMA_FILE="$SCRIPT_DIR/../schema/wiki-frontmatter.schema.json"

SCHEMA_OK=0
if command -v jq >/dev/null 2>&1 && [ -f "$SCHEMA_FILE" ]; then
  if mapfile -t REQUIRED_FIELDS < <(jq -r '.required[]' "$SCHEMA_FILE" 2>/dev/null) \
     && [ "${#REQUIRED_FIELDS[@]}" -gt 0 ] \
     && mapfile -t STATUS_ENUM < <(jq -r '.properties.status.enum[]' "$SCHEMA_FILE" 2>/dev/null) \
     && [ "${#STATUS_ENUM[@]}" -gt 0 ] \
     && mapfile -t CONSENSUS_ENUM < <(jq -r '.properties.consensus_level.enum[]' "$SCHEMA_FILE" 2>/dev/null) \
     && [ "${#CONSENSUS_ENUM[@]}" -gt 0 ]; then
    SCHEMA_OK=1
  fi
fi

if [ "$SCHEMA_OK" -eq 0 ]; then
  echo "WARN: jq or $SCHEMA_FILE unavailable — falling back to built-in frontmatter lists (no consensus_level enum validation)" >&2
  REQUIRED_FIELDS=(title canonical_question status fresh_until consensus_level sources)
  STATUS_ENUM=(active stale superseded)
  CONSENSUS_ENUM=(unanimous strong split divergent direct)
fi

# ── Frontmatter extraction ──
# Extract a single field from YAML frontmatter. Usage: get_fm FILE FIELD
get_fm() {
  local file="$1"
  local field="$2"
  awk -v field="$field" '
    /^---$/ { fm = !fm; next }
    fm && $0 ~ "^" field ":" {
      sub("^" field ":[[:space:]]*", "")
      sub("^\"", ""); sub("\"$", "")
      print
      exit
    }
  ' "$file"
}

# Check frontmatter presence and required fields
check_frontmatter() {
  local file="$1"
  if ! head -1 "$file" 2>/dev/null | grep -q "^---$"; then
    log_error "$file missing YAML frontmatter (must start with '---')"
    return 1
  fi

  for field in "${REQUIRED_FIELDS[@]}"; do
    if [ -z "$(get_fm "$file" "$field")" ]; then
      # sources is a list; check differently
      if [ "$field" = "sources" ]; then
        if ! awk '/^---$/{fm=!fm;next} fm && /^sources:/{getline; if ($0 ~ /^[[:space:]]*-/) print "yes"; exit}' "$file" | grep -q yes; then
          log_error "$file missing '$field' in frontmatter"
        fi
      else
        log_error "$file missing '$field' in frontmatter"
      fi
    fi
  done
}

# Check staleness: fresh_until vs today
check_staleness() {
  local file="$1"
  local fresh_until
  fresh_until=$(get_fm "$file" "fresh_until")
  [ -z "$fresh_until" ] && return 0

  # ISO date comparison via string comparison (works for YYYY-MM-DD)
  if [ "$fresh_until" \< "$TODAY" ]; then
    local status
    status=$(get_fm "$file" "status")
    if [ "$status" = "active" ]; then
      log_warn "$file: fresh_until=$fresh_until has passed (today=$TODAY) but status=active — should be 'stale'"
    fi
  fi
}

# Check lifecycle status
check_lifecycle() {
  local file="$1"
  local status
  status=$(get_fm "$file" "status")
  [ -z "$status" ] && return 0  # handled by check_frontmatter
  local ok=0
  for v in "${STATUS_ENUM[@]}"; do
    [ "$status" = "$v" ] && { ok=1; break; }
  done
  [ "$ok" -eq 0 ] && log_error "$file: invalid status '$status' (must be one of: ${STATUS_ENUM[*]})"
}

# Check consensus_level against schema enum (llm#759 Phase 1 — previously
# unvalidated). No-op in fallback mode (SCHEMA_OK=0) since the fallback
# vocabulary is display-only, matching pre-schema behaviour exactly.
check_consensus() {
  [ "$SCHEMA_OK" -eq 0 ] && return 0
  local file="$1"
  local consensus
  consensus=$(get_fm "$file" "consensus_level")
  [ -z "$consensus" ] && return 0  # handled by check_frontmatter
  local ok=0
  for v in "${CONSENSUS_ENUM[@]}"; do
    [ "$consensus" = "$v" ] && { ok=1; break; }
  done
  [ "$ok" -eq 0 ] && log_error "$file: invalid consensus_level '$consensus' (must be one of: ${CONSENSUS_ENUM[*]})"
}

# Exempt hub/worksheet pages (llm#759 Phase 2) — a page whose first line is
# exactly "<!-- wiki:exempt -->" is not source-compiled content (e.g. a hub,
# index, or worksheet page) and is skipped for frontmatter, provenance,
# staleness, and lifecycle checks. It still runs the dead-[[wiki-link]] check.
is_exempt() {
  local file="$1"
  local first_line
  first_line=$(head -1 "$file" 2>/dev/null)
  [ "$first_line" = "<!-- wiki:exempt -->" ]
}

# Check 1: Provenance — every wiki/*.md has ## Sources section
check_provenance() {
  local file="$1"
  if ! grep -q "^## Sources" "$file"; then
    log_error "$file missing '## Sources' section"
    return 1
  fi
}

# Check 3: Dead [[wiki-link]] resolution
check_wiki_links() {
  local file="$1"
  grep -oE '\[\[[a-z0-9_-]+\]\]' "$file" 2>/dev/null | sort -u | while read -r link; do
    target="${link//\[\[/}"
    target="${target//\]\]/}"
    if [ ! -f "$WIKI_DIR/$target.md" ]; then
      echo "DEAD_LINK:$file:$target"
    fi
  done
}

# Count confidence markers
count_confidence_markers() {
  local file="$1"
  local inferred hypothesis conflicting
  inferred=$(grep -c "^> ⚠ AI-inferred:" "$file" 2>/dev/null) || true
  inferred=${inferred:-0}
  hypothesis=$(grep -c "^> 🔬 Hypothesis:" "$file" 2>/dev/null) || true
  hypothesis=${hypothesis:-0}
  conflicting=$(grep -c "^> ❓ Conflicting:" "$file" 2>/dev/null) || true
  conflicting=${conflicting:-0}
  echo "$inferred $hypothesis $conflicting"
}

# ── Single-file mode (T1, T2) ──
if [ -n "$SINGLE_FILE" ]; then
  [ ! -f "$SINGLE_FILE" ] && exit 0
  case "$SINGLE_FILE" in
    */wiki/*.md)
      base=$(basename "$SINGLE_FILE")
      # INDEX.md, LOG.md, and wiki:exempt pages don't need frontmatter or provenance
      if [ "$base" != "INDEX.md" ] && [ "$base" != "LOG.md" ] && ! is_exempt "$SINGLE_FILE"; then
        check_frontmatter "$SINGLE_FILE"
        check_provenance "$SINGLE_FILE"
        check_staleness "$SINGLE_FILE"
        check_lifecycle "$SINGLE_FILE"
        check_consensus "$SINGLE_FILE"
      fi
      dead=$(check_wiki_links "$SINGLE_FILE")
      if [ -n "$dead" ]; then
        while IFS= read -r d; do
          [ -n "$d" ] && log_warn "$d"
        done <<< "$dead"
      fi
      ;;
    *) exit 0 ;;
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
files_with_frontmatter=0
stale_pages=0
superseded_pages=0
total_inferred=0
total_hypothesis=0
total_conflicting=0
exempt_pages=0
dead_links=()
declare -A consensus_counts=()

for f in "$WIKI_DIR"/*.md; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  [ "$base" = "INDEX.md" ] && continue
  [ "$base" = "LOG.md" ] && continue

  # wiki:exempt pages (hub/index/worksheet, not source-compiled content):
  # skip frontmatter/provenance/staleness/lifecycle checks and exclude from
  # the frontmatter/sources denominators, but still check dead wiki links.
  if is_exempt "$f"; then
    exempt_pages=$((exempt_pages + 1))
    while IFS= read -r line; do
      [ -n "$line" ] && dead_links+=("$line")
    done < <(check_wiki_links "$f")
    continue
  fi

  total_files=$((total_files + 1))

  # Frontmatter check
  if head -1 "$f" 2>/dev/null | grep -q "^---$"; then
    files_with_frontmatter=$((files_with_frontmatter + 1))
    check_frontmatter "$f" 2>/dev/null
    check_consensus "$f" 2>/dev/null

    status=$(get_fm "$f" "status")
    [ "$status" = "stale" ] && stale_pages=$((stale_pages + 1))
    [ "$status" = "superseded" ] && superseded_pages=$((superseded_pages + 1))

    consensus=$(get_fm "$f" "consensus_level")
    [ -n "$consensus" ] && consensus_counts[$consensus]=$((${consensus_counts[$consensus]:-0} + 1))

    # Staleness check
    fresh_until=$(get_fm "$f" "fresh_until")
    if [ -n "$fresh_until" ] && [ "$fresh_until" \< "$TODAY" ] && [ "$status" = "active" ]; then
      log_warn "$base: fresh_until=$fresh_until has passed (today=$TODAY) but status=active"
    fi
  else
    log_error "$base missing YAML frontmatter"
  fi

  # Provenance check
  if check_provenance "$f" 2>/dev/null; then
    files_with_sources=$((files_with_sources + 1))
  fi

  # Confidence markers
  read -r inf hyp con <<< "$(count_confidence_markers "$f")"
  total_inferred=$((total_inferred + inf))
  total_hypothesis=$((total_hypothesis + hyp))
  total_conflicting=$((total_conflicting + con))

  # Dead wiki links
  while IFS= read -r line; do
    [ -n "$line" ] && dead_links+=("$line")
  done < <(check_wiki_links "$f")
done

# Check 4: Orphan raw files (llm#1397)
# Recurses raw/ over every source file type. Excluded: sidecars (*.meta.yml,
# *.provenance), dotfiles (incl. the allow-list itself), any path under a
# "_"-prefixed folder, and entries of raw/.orphan-ignore. An orphan is a raw
# path (relative to raw/) not cited as "raw/<relative path>" in any wiki note.
orphans=0

# Allow-list: one entry per line, "<rel path or dir/>  # reason". The reason is
# mandatory; an entry without one is a usage error (exit 2).
ignore_entries=()
IGNORE_FILE="$RAW_DIR/.orphan-ignore"
if [ -f "$IGNORE_FILE" ]; then
  ignore_lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    ignore_lineno=$((ignore_lineno + 1))
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [ -z "$trimmed" ] && continue
    case "$trimmed" in "#"*) continue ;; esac
    entry="${trimmed%%#*}"
    reason=""
    case "$trimmed" in *"#"*) reason="${trimmed#*#}" ;; esac
    entry="${entry%"${entry##*[![:space:]]}"}"
    if [ -z "${reason//[[:space:]]/}" ] || [ -z "$entry" ]; then
      echo "ERROR: $IGNORE_FILE line $ignore_lineno: entry needs a '# reason' (usage error)" >&2
      exit 2
    fi
    ignore_entries+=("$entry")
  done < "$IGNORE_FILE"
fi

is_ignored() { # rel path
  local rel="$1" e
  for e in "${ignore_entries[@]+"${ignore_entries[@]}"}"; do
    case "$e" in
      */) case "$rel" in "$e"*) return 0 ;; esac ;;
      *)  [ "$rel" = "$e" ] && return 0 ;;
    esac
  done
  return 1
}

# Unreadable raw/ or wiki/ is INDETERMINATE (exit 3), never "0 orphans".
raw_list=$(mktemp)
wiki_corpus=$(mktemp)
trap 'rm -f "$raw_list" "$wiki_corpus"' EXIT
if ! find "$RAW_DIR" -mindepth 1 -name '_*' -prune -o -type f \
     ! -name '.*' ! -name '*.meta.yml' ! -name '*.provenance' -print > "$raw_list" 2>/dev/null; then
  echo "INDETERMINATE: cannot fully read $RAW_DIR; orphan-raw check could not run" >&2
  exit 3
fi
if ! find "$WIKI_DIR" -type f -name '*.md' -exec cat {} + > "$wiki_corpus" 2>/dev/null; then
  echo "INDETERMINATE: cannot fully read $WIKI_DIR; orphan-raw check could not run" >&2
  exit 3
fi

while IFS= read -r r; do
  [ -n "$r" ] || continue
  rel="${r#"$RAW_DIR"/}"
  is_ignored "$rel" && continue
  if ! grep -qF -- "raw/$rel" "$wiki_corpus"; then
    orphans=$((orphans + 1))
    log_warn "orphan raw file: $rel (not referenced in any wiki)"
  fi
done < "$raw_list"

# Check 7: INDEX sync
if [ -f "$WIKI_DIR/INDEX.md" ]; then
  for f in "$WIKI_DIR"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .md)
    [ "$base" = "INDEX" ] && continue
    [ "$base" = "LOG" ] && continue
    if ! grep -qE "(\[|\[\[|\()$base(\]|\.|\))" "$WIKI_DIR/INDEX.md" 2>/dev/null; then
      log_warn "INDEX.md missing entry for $base"
    fi
  done
else
  log_warn "wiki/INDEX.md does not exist"
fi

# LOG.md recommended (warn, don't error)
if [ ! -f "$WIKI_DIR/LOG.md" ]; then
  log_warn "wiki/LOG.md does not exist (recommended for audit trail)"
fi

# ── Output ──
if [ $JSON -eq 1 ]; then
  echo "{"
  echo "  \"total_files\": $total_files,"
  echo "  \"exempt_pages\": $exempt_pages,"
  echo "  \"files_with_frontmatter\": $files_with_frontmatter,"
  echo "  \"files_with_sources\": $files_with_sources,"
  echo "  \"stale_pages\": $stale_pages,"
  echo "  \"superseded_pages\": $superseded_pages,"
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
  echo "Today:      $TODAY"
  echo ""
  echo "Files:                $total_files"
  echo "Exempt pages:         $exempt_pages"
  echo "With frontmatter:     $files_with_frontmatter / $total_files"
  echo "With ## Sources:      $files_with_sources / $total_files"
  echo "Stale pages:          $stale_pages"
  echo "Superseded pages:     $superseded_pages"
  echo "Orphan raw files:     $orphans"
  echo "Dead [[wiki-links]]:  ${#dead_links[@]}"
  echo ""
  echo "Confidence markers (inline):"
  echo "  AI-inferred (⚠):    $total_inferred"
  echo "  Hypothesis (🔬):    $total_hypothesis"
  echo "  Conflicting (❓):   $total_conflicting"
  if [ "${#consensus_counts[@]}" -gt 0 ]; then
    echo ""
    echo "Consensus levels (frontmatter):"
    for level in "${CONSENSUS_ENUM[@]}"; do
      count="${consensus_counts[$level]:-0}"
      [ "$count" -gt 0 ] && echo "  $level: $count"
    done
  fi
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

# Stamp for cron_catchup.sh catch-up detection
mkdir -p "${HOME}/.claude/logs/stamps"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.claude/logs/stamps/wiki-health-pulse.stamp"

exit 0
