#!/usr/bin/env bash
# phi_scan.sh - Scan files for potential PHI/secrets before commit
# Usage: phi_scan.sh [file...]   (defaults to git staged files)
# Exit 0 = clean, Exit 1 = findings
#
# Two detection layers:
#   1. Regex: Known PHI patterns (NHS numbers, phones, emails, postcodes, dates of birth)
#   2. Statistical: High-entropy strings that may be encoded PHI, API keys, or tokens
#
# Inspired by simonw/research/string-redaction-library

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

FINDINGS=0

# ── Files to scan ─────────────────────────────────────────────────────
if [ $# -gt 0 ]; then
  FILES=("$@")
else
  mapfile -t FILES < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
fi

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No files to scan."
  exit 0
fi

# Skip binary and non-text files
TEXT_FILES=()
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.rds|*.rda|*.RData|*.png|*.jpg|*.pdf|*.gz|*.zip|*.duckdb|*.parquet) continue ;;
  esac
  TEXT_FILES+=("$f")
done

if [ ${#TEXT_FILES[@]} -eq 0 ]; then
  echo "No text files to scan."
  exit 0
fi

echo "PHI Scan: checking ${#TEXT_FILES[@]} file(s)..."
echo ""

# ── Layer 1: Regex patterns ──────────────────────────────────────────
report() {
  local severity="$1" file="$2" line="$3" pattern="$4" match="$5"
  if [ "$severity" = "HIGH" ]; then
    printf "${RED}[%s]${NC} %s:%s — %s: %s\n" "$severity" "$file" "$line" "$pattern" "$match"
  else
    printf "${YELLOW}[%s]${NC} %s:%s — %s: %s\n" "$severity" "$file" "$line" "$pattern" "$match"
  fi
  FINDINGS=$((FINDINGS + 1))
}

# Portable regex: use [[:space:]] not \s, no \b (unsupported in nix grep ERE)
is_code_line() { echo "$1" | grep -qE '(gsub|grep|regex|pattern|\\b|\\d|example\.com|noreply|anthropic)' 2>/dev/null; }

for f in "${TEXT_FILES[@]}"; do
  line_num=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_num=$((line_num + 1))

    # Skip comments
    case "$line" in \#*|//*|"  #"*) continue ;; esac
    # Skip code pattern definitions
    is_code_line "$line" && continue

    # NHS Number: 3-3-4 digit pattern
    if match=$(echo "$line" | grep -oE '[0-9]{3}[[:space:]]+[0-9]{3}[[:space:]]+[0-9]{4}' | head -1) && [ -n "$match" ]; then
      report "HIGH" "$f" "$line_num" "NHS Number" "$match"
    fi

    # UK Phone: starts with 0, grouped digits
    if match=$(echo "$line" | grep -oE '0[0-9]{2,4}[[:space:]]*[0-9]{3,4}[[:space:]]*[0-9]{3,4}' | head -1) && [ -n "$match" ]; then
      report "HIGH" "$f" "$line_num" "UK Phone" "$match"
    fi

    # Email addresses
    if match=$(echo "$line" | grep -oiE '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' | head -1) && [ -n "$match" ]; then
      report "MEDIUM" "$f" "$line_num" "Email" "$match"
    fi

    # UK Postcode (full): e.g. SW1A 2AA
    if match=$(echo "$line" | grep -oE '[A-Z]{1,2}[0-9][0-9A-Z]?[[:space:]]*[0-9][A-Z]{2}' | head -1) && [ -n "$match" ]; then
      report "MEDIUM" "$f" "$line_num" "UK Postcode" "$match"
    fi

    # Date of birth: DD/MM/YYYY or DD-MM-YYYY
    if match=$(echo "$line" | grep -oE '[0-3][0-9][/-][01][0-9][/-](19|20)[0-9]{2}' | head -1) && [ -n "$match" ]; then
      report "HIGH" "$f" "$line_num" "Date of birth" "$match"
    fi

    # Patient name: "Mr/Mrs/Dr Firstname Lastname"
    if match=$(echo "$line" | grep -oE '(Mr|Mrs|Ms|Miss|Dr|Prof)[[:space:]]+[A-Z][a-z]+[[:space:]]+[A-Z][a-z]+' | head -1) && [ -n "$match" ]; then
      report "MEDIUM" "$f" "$line_num" "Possible name" "$match"
    fi

  done < "$f"
done

# ── Layer 2: Statistical high-entropy detection ──────────────────────
# Inspired by Willison's string-redaction-library: flag tokens with
# abnormal vowel ratios + mixed digits (likely API keys, encoded PHI)
ENTROPY_HITS=$(mktemp)
for f in "${TEXT_FILES[@]}"; do
  grep -oE '[a-zA-Z0-9_]{13,}' "$f" 2>/dev/null | sort -u | while read -r token; do
    # Skip common code patterns
    case "$token" in
      *test*|*Test*|*function*|*package*|*library*|*install*|*target*|*vignette*) continue ;;
      *DESCRIPTION*|*NAMESPACE*|*README*|*github*|*pkgdown*) continue ;;
    esac

    # Strip underscores for analysis
    clean=$(echo "$token" | tr -d '_')
    len=${#clean}
    [ "$len" -lt 12 ] && continue

    # Count character types
    vowels=$(echo "$clean" | tr -cd 'aeiouAEIOU' | wc -c | tr -d ' ')
    digits=$(echo "$clean" | tr -cd '0-9' | wc -c | tr -d ' ')
    uppers=$(echo "$clean" | tr -cd 'A-Z' | wc -c | tr -d ' ')
    lowers=$(echo "$clean" | tr -cd 'a-z' | wc -c | tr -d ' ')

    # Pure digits or pure alpha = skip
    [ "$digits" -eq "$len" ] && continue
    [ "$digits" -eq 0 ] && [ "$uppers" -eq 0 ] && continue  # all lowercase = word
    [ "$digits" -eq 0 ] && [ "$lowers" -eq 0 ] && continue  # all UPPERCASE = constant

    # Vowel ratio
    vowel_pct=$((vowels * 100 / len))

    # Score accumulator (Willison algorithm, simplified)
    score=0

    # Very low vowels (<15%) = likely random
    [ "$vowel_pct" -lt 15 ] && score=$((score + 2))
    # Low vowels (15-25%)
    [ "$vowel_pct" -ge 15 ] && [ "$vowel_pct" -lt 25 ] && score=$((score + 1))

    # Mixed digits with letters (10-90% digit ratio)
    digit_pct=$((digits * 100 / len))
    [ "$digit_pct" -gt 10 ] && [ "$digit_pct" -lt 90 ] && score=$((score + 2))

    # Mixed case + digits
    [ "$uppers" -gt 0 ] && [ "$lowers" -gt 0 ] && [ "$digits" -gt 0 ] && score=$((score + 1))

    # CamelCase reduction (legitimate code pattern)
    if echo "$clean" | grep -qE '[a-z][A-Z]' 2>/dev/null && [ "$digits" -eq 0 ]; then
      score=$((score - 2))
    fi

    # English suffix reduction
    if echo "$clean" | grep -qiE '(tion|sion|ment|ness|able|ible|ful|less|ing|ous|ive)$' 2>/dev/null; then
      score=$((score - 2))
    fi

    # Flag if score >= 3 (stricter than Willison's 2 to reduce noise)
    if [ "$score" -ge 3 ]; then
      line_num=$(grep -n "$token" "$f" 2>/dev/null | head -1 | cut -d: -f1)
      line_num="${line_num:-?}"
      printf "[LOW] %s:%s — High-entropy string (score=%s): %s\n" "$f" "$line_num" "$score" "$token" >> "$ENTROPY_HITS"
    fi
  done
done

# Report entropy hits (from subshell via temp file)
if [ -s "$ENTROPY_HITS" ]; then
  while IFS= read -r hit; do
    echo -e "${YELLOW}${hit}${NC}"
    FINDINGS=$((FINDINGS + 1))
  done < "$ENTROPY_HITS"
fi
rm -f "$ENTROPY_HITS"

# ── Summary ──────────────────────────────────────────────────────────
echo ""
if [ "$FINDINGS" -gt 0 ]; then
  echo -e "${RED}PHI Scan: $FINDINGS finding(s). Review before committing.${NC}"
  exit 1
else
  echo "PHI Scan: clean (0 findings)."
  exit 0
fi
