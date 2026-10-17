#!/usr/bin/env bash
# phi_scan.sh - Scan files for potential PHI/secrets before commit
# Usage: phi_scan.sh [-h|--help] [--] [file...]   (defaults to git staged files)
#
# Exit codes (exit-code-conventions):
#   0 = clean (every requested file was read, no findings)
#   1 = findings (rule/severity/file/line printed; a finding wins over 3)
#   2 = usage error (unknown flag)
#   3 = INDETERMINATE (a file could not be read, git unavailable or not a
#       repo when scanning staged files). "Could not scan" is never "clean".
#
# Output is REDACTED by design: a finding prints rule name, severity, file and
# line number ONLY. The matched text and the surrounding line are never
# printed, so terminal scrollback, logs and CI output cannot themselves
# become a copy of the PHI the scan was meant to keep out.
#
# Two detection layers:
#   1. Regex: Known PHI patterns (NHS numbers, phones, emails, postcodes, dates of birth)
#   2. Statistical: High-entropy strings that may be encoded PHI, API keys, or tokens
#
# Pre-commit-style tool: it is NOT wired into any hook, CI job or schedule.
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no empty-array expansion.
#
# Inspired by simonw/research/string-redaction-library

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

FINDINGS=0
INDETERMINATE=0

usage() {
  echo "Usage: phi_scan.sh [-h|--help] [--] [file...]"
  echo "  Scans files (default: git staged files) for PHI-shaped strings."
  echo "  Prints rule, severity, file:line only; never the matched value."
  echo "  Exit: 0 clean, 1 findings, 2 usage error, 3 indeterminate."
}

# ── Arguments ─────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "phi_scan.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done

# ── Files to scan ─────────────────────────────────────────────────────
FILES=()
if [ $# -gt 0 ]; then
  for a in "$@"; do FILES+=("$a"); done
else
  if ! command -v git >/dev/null 2>&1; then
    echo "phi_scan.sh: INDETERMINATE: git not available, cannot list staged files." >&2
    exit 3
  fi
  if ! TOP=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "phi_scan.sh: INDETERMINATE: not inside a git repository, cannot list staged files." >&2
    exit 3
  fi
  if ! STAGED=$(git -C "$TOP" diff --cached --name-only --diff-filter=ACM 2>/dev/null); then
    echo "phi_scan.sh: INDETERMINATE: 'git diff --cached' failed." >&2
    exit 3
  fi
  # Staged paths are relative to the repo top level.
  cd "$TOP"
  while IFS= read -r sf; do
    if [ -n "$sf" ]; then FILES+=("$sf"); fi
  done <<< "$STAGED"
fi

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No files to scan."
  exit 0
fi

# Skip binary and non-text files; an unreadable requested file is INDETERMINATE
TEXT_FILES=()
for f in "${FILES[@]}"; do
  case "$f" in
    *.rds|*.rda|*.RData|*.png|*.jpg|*.pdf|*.gz|*.zip|*.duckdb|*.parquet) continue ;;
  esac
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    echo "phi_scan.sh: INDETERMINATE: cannot read '$f' (missing, not a regular file, or unreadable)." >&2
    INDETERMINATE=1
    continue
  fi
  TEXT_FILES+=("$f")
done

if [ ${#TEXT_FILES[@]} -eq 0 ]; then
  if [ "$INDETERMINATE" -eq 1 ]; then
    echo "PHI Scan: INDETERMINATE (no requested file could be read)."
    exit 3
  fi
  echo "No text files to scan."
  exit 0
fi

echo "PHI Scan: checking ${#TEXT_FILES[@]} file(s)..."
echo ""

# ── Layer 1: Regex patterns ──────────────────────────────────────────
# Redacted: no matched text, no line excerpt.
report() {
  local severity="$1" file="$2" line="$3" pattern="$4"
  if [ "$severity" = "HIGH" ]; then
    printf "${RED}[%s]${NC} %s:%s — %s (value redacted)\n" "$severity" "$file" "$line" "$pattern"
  else
    printf "${YELLOW}[%s]${NC} %s:%s — %s (value redacted)\n" "$severity" "$file" "$line" "$pattern"
  fi
  FINDINGS=$((FINDINGS + 1))
}

# Portable regex: use [[:space:]] not \s, no \b (unsupported in nix grep ERE)
is_code_line() { grep -qE '(gsub|grep|regex|pattern|\\b|\\d|example\.com|noreply|anthropic)' <<< "$1" 2>/dev/null; }

# has_match FLAGS REGEX LINE: here-string, no pipe, so no SIGPIPE/pipefail surprises
has_match() { grep -q"$1" -e "$2" <<< "$3" 2>/dev/null; }

for f in "${TEXT_FILES[@]}"; do
  line_num=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_num=$((line_num + 1))

    # Skip comments
    case "$line" in \#*|//*|"  #"*) continue ;; esac
    # Skip code pattern definitions
    if is_code_line "$line"; then continue; fi

    # NHS Number: 3-3-4 digit pattern
    if has_match E '[0-9]{3}[[:space:]]+[0-9]{3}[[:space:]]+[0-9]{4}' "$line"; then
      report "HIGH" "$f" "$line_num" "NHS Number"
    fi

    # UK Phone: starts with 0, grouped digits
    if has_match E '0[0-9]{2,4}[[:space:]]*[0-9]{3,4}[[:space:]]*[0-9]{3,4}' "$line"; then
      report "HIGH" "$f" "$line_num" "UK Phone"
    fi

    # Email addresses
    if has_match iE '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' "$line"; then
      report "MEDIUM" "$f" "$line_num" "Email"
    fi

    # UK Postcode (full): outward code, optional space, inward code
    if has_match E '[A-Z]{1,2}[0-9][0-9A-Z]?[[:space:]]*[0-9][A-Z]{2}' "$line"; then
      report "MEDIUM" "$f" "$line_num" "UK Postcode"
    fi

    # Date of birth: DD/MM/YYYY or DD-MM-YYYY
    if has_match E '[0-3][0-9][/-][01][0-9][/-](19|20)[0-9]{2}' "$line"; then
      report "HIGH" "$f" "$line_num" "Date of birth"
    fi

    # Patient name: "Mr/Mrs/Dr Firstname Lastname"
    if has_match E '(Mr|Mrs|Ms|Miss|Dr|Prof)[[:space:]]+[A-Z][a-z]+[[:space:]]+[A-Z][a-z]+' "$line"; then
      report "MEDIUM" "$f" "$line_num" "Possible name"
    fi

  done < "$f"
done

# ── Layer 2: Statistical high-entropy detection ──────────────────────
# Inspired by Willison's string-redaction-library: flag tokens with
# abnormal vowel ratios + mixed digits (likely API keys, encoded PHI)
ENTROPY_HITS=$(mktemp)
trap 'rm -f "$ENTROPY_HITS"' EXIT
for f in "${TEXT_FILES[@]}"; do
  # '|| true' on the head of the pipeline: under pipefail a file with no
  # 13+ char token makes grep exit 1 and would abort the whole scan.
  { grep -oE '[a-zA-Z0-9_]{13,}' "$f" 2>/dev/null || true; } | sort -u | while read -r token; do
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
      line_num=$({ grep -nF -e "$token" "$f" 2>/dev/null || true; } | head -1 | cut -d: -f1)
      line_num="${line_num:-?}"
      # Token deliberately NOT printed (redacted).
      printf "[LOW] %s:%s — High-entropy string (score=%s, value redacted)\n" "$f" "$line_num" "$score" >> "$ENTROPY_HITS"
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

# ── Summary ──────────────────────────────────────────────────────────
echo ""
if [ "$FINDINGS" -gt 0 ]; then
  echo -e "${RED}PHI Scan: $FINDINGS finding(s). Review before committing.${NC}"
  if [ "$INDETERMINATE" -eq 1 ]; then
    echo "PHI Scan: some requested files could not be read (see stderr); scan incomplete."
  fi
  exit 1
elif [ "$INDETERMINATE" -eq 1 ]; then
  echo "PHI Scan: INDETERMINATE (0 findings in readable files, but some requested files could not be read)."
  exit 3
else
  echo "PHI Scan: clean (0 findings)."
  exit 0
fi
