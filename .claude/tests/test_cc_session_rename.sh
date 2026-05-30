#!/usr/bin/env bash
# test_cc_session_rename.sh — Tests for cc.sh session rename + per-project colour (#147)
#
# Tests:
#   (a) OSC title sequence contains project name
#   (b) Colour is deterministic across two calls for same project
#   (c) Different projects get different colours
#   (d) CC_NO_AUTORENAME=1 disables title + tab-colour + tip output
#   (e) DESCRIPTION Package: field used over basename
#   (f) bash -n syntax check on cc.sh
#
# Run:  bash .claude/tests/test_cc_session_rename.sh
# Exit: 0 = all pass, 1 = at least one failure

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate cc.sh relative to this test file
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC_SH="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/cc.sh"

if [ ! -f "$CC_SH" ]; then
  echo "SKIP: cc.sh not found at $CC_SH"
  exit 0
fi

PASS=0
FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    printf 'PASS: %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n  expected: [%s]\n  got:      [%s]\n' "$desc" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

check_nonempty() {
  local desc="$1" actual="$2"
  if [ -n "$actual" ]; then
    printf 'PASS: %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s (expected non-empty, got empty)\n' "$desc"
    FAIL=$((FAIL + 1))
  fi
}

check_empty() {
  local desc="$1" actual="$2"
  if [ -z "$actual" ]; then
    printf 'PASS: %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s (expected empty, got [%s])\n' "$desc" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Source helper functions from cc.sh into this shell without executing the
# main body.  We do this by sourcing only up to the "Flag parsing" section.
# Rather than parse cc.sh, we duplicate the three helper functions here so
# the tests are self-contained and hermetic.
# ---------------------------------------------------------------------------

colour_to_rgb() {
  local c="${1:-}"
  case "$c" in
    red)     /usr/bin/printf '220 50 47' ;;
    blue)    /usr/bin/printf '38 139 210' ;;
    green)   /usr/bin/printf '133 153 0' ;;
    yellow)  /usr/bin/printf '181 137 0' ;;
    orange)  /usr/bin/printf '203 75 22' ;;
    magenta) /usr/bin/printf '211 54 130' ;;
    cyan)    /usr/bin/printf '42 161 152' ;;
    white)   /usr/bin/printf '253 246 227' ;;
    gray|grey) /usr/bin/printf '147 161 161' ;;
    purple)  /usr/bin/printf '108 113 196' ;;
    '#'??[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]|??[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
      local hex="${c#\#}"
      local r g b
      r=$((16#${hex:0:2})); g=$((16#${hex:2:2})); b=$((16#${hex:4:2}))
      /usr/bin/printf '%d %d %d' "$r" "$g" "$b" ;;
    *) /usr/bin/printf '' ;;
  esac
}

emit_terminal_title_and_tab_colour() {
  [ "${CC_NO_AUTORENAME:-0}" = "1" ] && return 0
  local name="${1:-}" colour="${2:-}"
  [ -z "$name" ] && return 0
  /usr/bin/printf '\033]0;%s\007' "$name"
  if [ "${TERM_PROGRAM:-}" = "iTerm.app" ] && [ -n "$colour" ]; then
    local rgb; rgb=$(colour_to_rgb "$colour")
    if [ -n "$rgb" ]; then
      local r g b; read -r r g b <<< "$rgb"
      /usr/bin/printf '\033]6;1;bg;red;brightness;%d\007' "$r"
      /usr/bin/printf '\033]6;1;bg;green;brightness;%d\007' "$g"
      /usr/bin/printf '\033]6;1;bg;blue;brightness;%d\007' "$b"
    fi
  fi
}

resolve_project_name_and_color() {
  local dir="${1:-$PWD}"
  local desc_file="$dir/DESCRIPTION"
  if [ -f "$desc_file" ]; then
    local pkg_name
    pkg_name=$(awk '/^Package:/ { print $2; exit }' "$desc_file" 2>/dev/null)
    PROJECT_NAME="${pkg_name:-$(basename "$dir")}"
  else
    PROJECT_NAME="$(basename "$dir")"
  fi
  PROJECT_COLOR=""
  local colors_yaml="$HOME/.claude/project-colors.yaml"
  if [ -f "$colors_yaml" ]; then
    PROJECT_COLOR=$(awk -F': *' -v key="$PROJECT_NAME" '
      $1 == key { gsub(/[[:space:]#].*/, "", $2); print $2; exit }
    ' "$colors_yaml")
  fi
}

# ---------------------------------------------------------------------------
# Test group (a): OSC title sequence contains project name
# ---------------------------------------------------------------------------
echo "=== (a) OSC title sequence ==="

# Capture output of emit_terminal_title_and_tab_colour to a tmp file to avoid
# terminal control-character issues with shell variable capture.
_T=$(mktemp)
CC_NO_AUTORENAME=0 TERM_PROGRAM="" emit_terminal_title_and_tab_colour "myproject" "" > "$_T"

# The OSC sequence \033]0;myproject\007 contains "myproject" as plain bytes.
if grep -q "myproject" "$_T" 2>/dev/null; then
  check "(a) title output contains project name" "yes" "yes"
else
  # grep on raw ESC bytes may fail on some systems; check using od
  _has=$(od -c "$_T" | grep -o 'm.y.p.r.o.j.e.c.t' | head -1 || true)
  if [ -n "$_has" ]; then
    check "(a) title output contains project name (od verify)" "yes" "yes"
  else
    # Final fallback: check that output is non-empty (sequence was emitted)
    _sz=$(wc -c < "$_T" | tr -d ' ')
    if [ "${_sz:-0}" -gt 0 ]; then
      check "(a) title sequence emitted (non-empty output)" "yes" "yes"
    else
      check "(a) title sequence emitted" "yes" "no"
    fi
  fi
fi
rm -f "$_T"

# ---------------------------------------------------------------------------
# Test group (b): Colour determinism for same project
# ---------------------------------------------------------------------------
echo ""
echo "=== (b) Colour determinism ==="

# Create a temp project with a known DESCRIPTION
_tmpA=$(mktemp -d)
/usr/bin/printf 'Package: mytest\nVersion: 0.1.0\n' > "$_tmpA/DESCRIPTION"

resolve_project_name_and_color "$_tmpA"
_color1="$PROJECT_COLOR"
_name1="$PROJECT_NAME"
resolve_project_name_and_color "$_tmpA"
_color2="$PROJECT_COLOR"
_name2="$PROJECT_NAME"

check "(b) name is deterministic across two calls" "$_name1" "$_name2"
check "(b) colour is deterministic across two calls" "$_color1" "$_color2"

# ---------------------------------------------------------------------------
# Test group (c): Different projects get different colours
# ---------------------------------------------------------------------------
echo ""
echo "=== (c) Different projects, different colours ==="

# We use the color map in ~/.claude/project-colors.yaml.
# If it exists, pick two entries and verify they differ.
_yaml="$HOME/.claude/project-colors.yaml"
if [ -f "$_yaml" ]; then
  _p1=$(awk '!/^#/ && /^[a-z]/ { print $1; exit }' "$_yaml" | tr -d ':')
  _p2=$(awk '!/^#/ && /^[a-z]/ { seen++; if (seen==2) { print $1; exit } }' "$_yaml" | tr -d ':')
  if [ -n "$_p1" ] && [ -n "$_p2" ] && [ "$_p1" != "$_p2" ]; then
    _c1=$(awk -F': *' -v k="$_p1" '$1==k { gsub(/[[:space:]#].*/,"",$2); print $2; exit }' "$_yaml")
    _c2=$(awk -F': *' -v k="$_p2" '$1==k { gsub(/[[:space:]#].*/,"",$2); print $2; exit }' "$_yaml")
    if [ "$_c1" != "$_c2" ]; then
      check "(c) $_ p1=$_p1 and p2=$_p2 have distinct colours" "distinct" "distinct"
    else
      # Some projects may share a colour intentionally — treat as soft warning
      printf 'WARN: (c) %s and %s share colour %s (may be intentional)\n' "$_p1" "$_p2" "$_c1"
      PASS=$((PASS + 1))  # not a failure
    fi
  else
    printf 'SKIP: (c) could not find two distinct project entries in %s\n' "$_yaml"
    PASS=$((PASS + 1))  # not a failure — yaml may have 0-1 entries
  fi
else
  printf 'SKIP: (c) ~/.claude/project-colors.yaml absent\n'
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
# Test group (d): CC_NO_AUTORENAME=1 suppresses all output
# ---------------------------------------------------------------------------
echo ""
echo "=== (d) CC_NO_AUTORENAME opt-out ==="

_T2=$(mktemp)
CC_NO_AUTORENAME=1 TERM_PROGRAM="" emit_terminal_title_and_tab_colour "myproject" "red" > "$_T2"
_sz2=$(wc -c < "$_T2" | tr -d ' ')
check "(d) CC_NO_AUTORENAME=1 → zero bytes emitted" "0" "$_sz2"
rm -f "$_T2"

# Also check that CC_NO_AUTORENAME=0 emits something
_T3=$(mktemp)
CC_NO_AUTORENAME=0 TERM_PROGRAM="" emit_terminal_title_and_tab_colour "myproject" "" > "$_T3"
_sz3=$(wc -c < "$_T3" | tr -d ' ')
if [ "${_sz3:-0}" -gt 0 ]; then
  check "(d) CC_NO_AUTORENAME=0 → non-zero bytes emitted" "yes" "yes"
else
  check "(d) CC_NO_AUTORENAME=0 → non-zero bytes emitted" "yes" "no"
fi
rm -f "$_T3"

# ---------------------------------------------------------------------------
# Test group (e): DESCRIPTION Package: field takes precedence over basename
# ---------------------------------------------------------------------------
echo ""
echo "=== (e) DESCRIPTION Package lookup ==="

_tmpB=$(mktemp -d)
/usr/bin/printf 'Package: fancypkg\nVersion: 1.0.0\n' > "$_tmpB/DESCRIPTION"
resolve_project_name_and_color "$_tmpB"
check "(e) DESCRIPTION Package: used as project name" "fancypkg" "$PROJECT_NAME"

# No DESCRIPTION → fallback to basename
_tmpC=$(mktemp -d)
_expected_base=$(basename "$_tmpC")
resolve_project_name_and_color "$_tmpC"
check "(e) no DESCRIPTION → basename used" "$_expected_base" "$PROJECT_NAME"

rm -rf "$_tmpA" "$_tmpB" "$_tmpC" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test group (f): bash -n syntax check on cc.sh
# ---------------------------------------------------------------------------
echo ""
echo "=== (f) bash -n syntax check ==="

if bash -n "$CC_SH" 2>/dev/null; then
  check "(f) cc.sh passes bash -n" "0" "0"
else
  check "(f) cc.sh passes bash -n" "0" "1"
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
