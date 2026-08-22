#!/usr/bin/env bash
# check_grep_portability.sh — Flag shell scripts that pass \b / \< / \> word
# boundaries to an UNPINNED `grep`.
#
# Why this exists
# ---------------
# `grep` on this machine resolves to ugrep, which does NOT honour \b, \< or \>
# in -E mode. A check written with them silently never matches: no error, no
# non-zero exit, just a guard that always reports "clean". That is the worst
# possible failure mode for a security or privacy check.
#
# Discovered 2026-08-18 while wiring phi-scan-hook.sh: all seven of its PHI
# patterns used \b, so the hook could never block anything. It had also never
# been wired into settings.json, so nothing surfaced the defect. Three further
# call sites were found by the audit this script automates.
#
# What counts as SAFE (and is therefore skipped):
#   * the regex is owned by python/perl (heredoc), whose \b works fine
#   * the grep call is already routed through a pinned "$GREP" / /usr/bin/grep
#   * the \b appears in a comment
#   * the pattern searches for the LITERAL two-character string \b (written \\b)
#
# Exit codes: 0 = clean, 1 = findings. Never blocks anything by itself.
#
# Usage:
#   check_grep_portability.sh [path ...]      # default: .claude/hooks .claude/scripts
#   check_grep_portability.sh --selftest

set -uo pipefail

# This script must itself be immune to the bug it detects.
GREP="${GREP:-/usr/bin/grep}"
[ -x "$GREP" ] || GREP="grep"

_audit_file() {
  local f="$1" findings=0 line lnum
  # Only lines that pipe into a bare `grep` (not "$GREP", not /usr/bin/grep)
  # AND carry a single-backslash word-boundary escape.
  while IFS= read -r line; do
    lnum="${line%%:*}"
    local body="${line#*:}"

    # Skip comments.
    case "$(printf '%s' "$body" | /usr/bin/sed -E 's/^[[:space:]]+//')" in \#*) continue ;; esac

    # Skip already-pinned invocations.
    printf '%s' "$body" | $GREP -qE '"\$GREP"|/usr/bin/grep|\$\{GREP' && continue

    # Skip a literal \\b search (two chars), which behaves the same everywhere.
    printf '%s' "$body" | $GREP -qE '\\\\b' && continue

    printf '  %s:%s\n' "$f" "$lnum"
    printf '      %s\n' "$(printf '%s' "$body" | cut -c1-100)"
    findings=$((findings + 1))
  done < <($GREP -nE '\| *grep [^|]*\\(b|<|>)' "$f" 2>/dev/null)
  return "$findings"
}

_has_python_owner() {
  # A file whose regexes live in a python heredoc is not at risk; python's re
  # honours \b. Cheap heuristic, deliberately conservative: we only skip when
  # the file has NO bare-grep-with-boundary lines left after the checks above.
  $GREP -qE 'python3 -c|<<.?PYEOF|<<.?PY' "$1" 2>/dev/null
}

main() {
  local paths=("$@")
  if [ "${#paths[@]}" -eq 0 ]; then
    paths=(".claude/hooks" ".claude/scripts")
  fi

  local total=0 files=0
  echo "grep-portability audit (\\b / \\< / \\> passed to an unpinned grep)"
  echo

  local f
  while IFS= read -r f; do
    # Skip this script: its selftest fixtures are deliberate literal examples
    # of the bad pattern, not live call sites.
    case "$f" in *check_grep_portability.sh) continue ;; esac
    files=$((files + 1))
    local out
    out="$(_audit_file "$f")"
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      total=$((total + $(printf '%s\n' "$out" | $GREP -c '^  \.' || echo 0)))
    fi
  done < <(find "${paths[@]}" -type f -name '*.sh' 2>/dev/null | sort)

  echo
  if [ "$total" -eq 0 ]; then
    echo "clean — $files files scanned, 0 unpinned word-boundary greps"
    return 0
  fi
  echo "$total finding(s) across $files files scanned"
  echo
  echo "Fix: add near the top of each file —"
  echo '  GREP="${GREP:-/usr/bin/grep}"'
  echo '  [ -x "$GREP" ] || GREP="grep"'
  echo 'then route the call:  ... | "$GREP" -qE ...'
  return 1
}

if [ "${1:-}" = "--selftest" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/.claude/scripts"

  cat > "$tmp/.claude/scripts/bad.sh" <<'EOF'
#!/usr/bin/env bash
echo "x" | grep -qE '\bfoo\b'
EOF
  cat > "$tmp/.claude/scripts/pinned.sh" <<'EOF'
#!/usr/bin/env bash
GREP="${GREP:-/usr/bin/grep}"
echo "x" | "$GREP" -qE '\bfoo\b'
EOF
  cat > "$tmp/.claude/scripts/comment.sh" <<'EOF'
#!/usr/bin/env bash
# echo "x" | grep -qE '\bfoo\b'   <- documented, not executed
EOF
  cat > "$tmp/.claude/scripts/literal.sh" <<'EOF'
#!/usr/bin/env bash
echo "x" | grep -qE '(regex|\\b|\\d)'
EOF
  cat > "$tmp/.claude/scripts/clean.sh" <<'EOF'
#!/usr/bin/env bash
echo "x" | grep -qE '[[:digit:]]+'
EOF

  pass=0; fail=0
  _one() { # name, file, expect_flagged(0/1)
    local out; out="$(cd "$tmp" && bash "$OLDPWD/.claude/scripts/check_grep_portability.sh" ".claude/scripts" 2>/dev/null)"
    if printf '%s' "$out" | $GREP -q "$2"; then local got=1; else local got=0; fi
    if [ "$got" = "$3" ]; then pass=$((pass+1)); echo "  PASS $1"
    else fail=$((fail+1)); echo "  FAIL $1 (flagged=$got want=$3)"; fi
  }
  echo "check_grep_portability selftest:"
  _one "flags unpinned \\b grep"        "bad.sh"     1
  _one "skips pinned \$GREP"            "pinned.sh"  0
  _one "skips commented-out line"       "comment.sh" 0
  _one "skips literal \\\\b search"     "literal.sh" 0
  _one "skips portable pattern"         "clean.sh"   0
  echo "  ---"
  echo "  $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

main "$@"
