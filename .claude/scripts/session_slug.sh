#!/usr/bin/env bash
# session_slug.sh — Generate a 6-10 word slug from CURRENT_WORK.md
#
# Usage:
#   session_slug.sh [path/to/CURRENT_WORK.md]
#   BRANCH=<branch-name> session_slug.sh [path/to/CURRENT_WORK.md]
#
# Prints slug to stdout. No newlines appended by the caller — the slug IS the output.
#
# Slug rules:
#   1. Take the first non-empty, non-heading-marker line of CURRENT_WORK.md
#   2. Strip markdown formatting (**bold**, [link](url), `code`, etc.)
#   3. Lowercase
#   4. Replace non-alphanumeric with -
#   5. Collapse multiple -
#   6. Trim leading/trailing -
#   7. Truncate to first 8 words (split on -)
#   8. Truncate to 60 chars max
#   9. Empty result → "unlabeled"
#  10. Missing/unreadable file → "unlabeled-<short-branch>"
#
# Issues: JohnGavin/llm#374

set -euo pipefail

# ── Selftest ──────────────────────────────────────────────────────────────────
if [ "${CLAUDE_HOOK_SELFTEST:-0}" = "1" ]; then
  _pass=0
  _fail=0
  _tmpdir=$(mktemp -d /tmp/session_slug_test.XXXXXX)
  trap 'rm -rf "$_tmpdir"' EXIT

  _run_case() {
    local desc="$1"
    local content="$2"
    local branch="$3"
    local expected="$4"
    local _f="$_tmpdir/cw.md"
    printf '%s\n' "$content" > "$_f"
    local actual
    actual=$(CLAUDE_HOOK_SELFTEST=0 BRANCH="$branch" bash "$0" "$_f" 2>/dev/null)
    if [ "$actual" = "$expected" ]; then
      echo "PASS: $desc"
      _pass=$((_pass + 1))
    else
      echo "FAIL: $desc"
      echo "      expected: [$expected]"
      echo "      actual:   [$actual]"
      _fail=$((_fail + 1))
    fi
  }

  # Case 1: normal first line — 9 words → truncated to first 8
  _run_case \
    "normal-first-line" \
    "Wire fallback codex command into roborev primary loop" \
    "feat/issue-374-session-rename-hook" \
    "wire-fallback-codex-command-into-roborev-primary-loop"

  # Case 2: empty file
  _run_case \
    "empty-file" \
    "" \
    "feat/issue-374-session-rename-hook" \
    "unlabeled"

  # Case 3: missing file (use nonexistent path)
  _actual_missing=$(CLAUDE_HOOK_SELFTEST=0 BRANCH="feat/issue-374-session-rename-hook" bash "$0" "$_tmpdir/nonexistent.md" 2>/dev/null)
  if [ "$_actual_missing" = "unlabeled-feat-issue-374-session" ]; then
    echo "PASS: missing-file"
    _pass=$((_pass + 1))
  else
    echo "FAIL: missing-file"
    echo "      expected: [unlabeled-feat-issue-374-session]"
    echo "      actual:   [$_actual_missing]"
    _fail=$((_fail + 1))
  fi

  # Case 4: file with leading # headings — skip headings, take first content line
  _run_case \
    "leading-headings" \
    "# Session Work Log
## Status
First real content line here to process" \
    "main" \
    "first-real-content-line-here-to-process"

  # Case 5: markdown formatting stripped
  _run_case \
    "markdown-formatting-stripped" \
    "**Fix** the [roborev hook](https://example.com) and \`session_stop.sh\` file" \
    "main" \
    "fix-the-roborev-hook-and-session-stop-sh"

  echo ""
  echo "$_pass/$((_pass + _fail)) PASS"
  if [ "$_fail" -gt 0 ]; then
    exit 1
  fi
  exit 0
fi

# ── Main logic ────────────────────────────────────────────────────────────────

CURRENT_WORK_PATH="${1:-}"
BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")}"

# Short branch: slugify and take first 4 dash-components (≈ feat-issue-374-name)
_short_branch=$(printf '%s' "$BRANCH" \
  | sed 's|/|-|g' \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//')
# Limit to 4 dash-separated components for readability
_short_branch=$(printf '%s' "$_short_branch" \
  | awk -F'-' '{
    out=""
    for(i=1; i<=NF && i<=4; i++) {
      if(i==1) out=$i
      else out=out"-"$i
    }
    print out
  }')

# Fallback when file is missing or unreadable
if [ -z "$CURRENT_WORK_PATH" ] || [ ! -f "$CURRENT_WORK_PATH" ]; then
  if [ -n "$_short_branch" ] && [ "$_short_branch" != "unknown" ]; then
    printf 'unlabeled-%s' "$_short_branch"
  else
    printf 'unlabeled'
  fi
  exit 0
fi

# Extract first non-empty, non-heading line.
# The trailing newline guard (`|| [ -n "$_line" ]`) handles files that
# lack a final newline — `read` returns non-zero for the last partial line
# but still populates the variable.
_first_line=""
while IFS= read -r _line || [ -n "$_line" ]; do
  # Skip blank lines
  [ -z "$_line" ] && continue
  # Skip heading lines (lines starting with one or more #)
  case "$_line" in
    "#"*) continue ;;
  esac
  _first_line="$_line"
  break
done < "$CURRENT_WORK_PATH"

# Empty content → "unlabeled"
if [ -z "$_first_line" ]; then
  printf 'unlabeled'
  exit 0
fi

# Strip markdown formatting:
#   **bold** → bold
#   *italic* → italic
#   `code` → code
#   [text](url) → text
#   __bold__ → bold
#   _italic_ → italic
#   ~~strikethrough~~ → strikethrough
_stripped=$(printf '%s' "$_first_line" \
  | sed 's/\[\([^]]*\)\]([^)]*)/\1/g' \
  | sed 's/\*\*\([^*]*\)\*\*/\1/g' \
  | sed 's/__\([^_]*\)__/\1/g' \
  | sed 's/\*\([^*]*\)\*/\1/g' \
  | sed 's/_\([^_]*\)_/\1/g' \
  | sed 's/~~\([^~]*\)~~/\1/g' \
  | sed 's/`\([^`]*\)`/\1/g')

# Lowercase, replace non-alphanumeric with -, collapse, trim
_slug=$(printf '%s' "$_stripped" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9]/-/g' \
  | sed 's/--*/-/g' \
  | sed 's/^-//; s/-$//')

# Empty after slugification → "unlabeled"
if [ -z "$_slug" ]; then
  printf 'unlabeled'
  exit 0
fi

# Truncate to first 8 words (split on -)
_word_count=0
_truncated=""
IFS='-' read -ra _words <<< "$_slug"
for _w in "${_words[@]}"; do
  [ -z "$_w" ] && continue
  _word_count=$((_word_count + 1))
  if [ "$_word_count" -eq 1 ]; then
    _truncated="$_w"
  else
    _truncated="${_truncated}-${_w}"
  fi
  [ "$_word_count" -ge 8 ] && break
done

# Truncate to 60 chars max
_final=$(printf '%s' "$_truncated" | cut -c1-60)

# Strip trailing dash that cut may leave
_final=$(printf '%s' "$_final" | sed 's/-$//')

if [ -z "$_final" ]; then
  printf 'unlabeled'
else
  printf '%s' "$_final"
fi
