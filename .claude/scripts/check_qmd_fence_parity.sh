#!/usr/bin/env bash
# check_qmd_fence_parity.sh — detect orphan triple-backtick fences in Quarto .qmd files
#
# An unmatched triple-backtick in a .qmd file silently breaks rendering for all
# content below it (the orphan is interpreted as opening a new fenced code block).
# Caught in JohnGavin/historical docs/avoid-worst-days.qmd:330 (2026-06-03).
# See JohnGavin/llm#465.
#
# Logic:
#   1. Scan every .qmd under the target path (file or directory).
#   2. For each file, walk lines and maintain a fence depth counter.
#      - A line of 4+ backticks (````) is a quadruple-fence used to escape content
#        containing triple-backticks in prose — these toggle fence depth by 1.
#      - A line of exactly 3 backticks (``` possibly followed by language tag or
#        whitespace) toggles fence depth by 1 ONLY when not inside a quadruple fence.
#   3. If depth != 0 at EOF → odd parity → ERROR.
#
# Usage:
#   check_qmd_fence_parity.sh [PATH] [--quiet] [--selftest]
#
#   PATH      file or directory to scan (default: current dir)
#   --quiet   parseable output only: one line per violation (for hooks)
#   --selftest  run built-in test fixtures; exits 0 if 4/4 PASS, 1 if any FAIL
#
# Exit codes:
#   0 — all .qmd files have balanced fences (or no .qmd files found)
#   1 — one or more files have unbalanced fences
#
# Called by:
#   - .claude/scripts/r_code_check.sh (on staged .qmd files at pre-commit)
#   - Manually during /check sessions

set -euo pipefail

QUIET=0
SELFTEST=0
TARGET="."

for arg in "$@"; do
  case "$arg" in
    --quiet)   QUIET=1   ;;
    --selftest) SELFTEST=1 ;;
    *)         TARGET="$arg" ;;
  esac
done

# ─── Self-test ─────────────────────────────────────────────────────────────────

run_selftest() {
  local pass=0 fail=0

  # Helper: run the parity check on a string, return exit code
  check_string() {
    local content="$1"
    local tmpfile
    tmpfile=$(mktemp /tmp/qmd_fence_test_XXXXXX.qmd)
    printf '%s\n' "$content" > "$tmpfile"
    check_file "$tmpfile" 1>/dev/null 2>/dev/null
    local rc=$?
    rm -f "$tmpfile"
    return "$rc"
  }

  # Case 1: clean file — balanced fences, exit 0
  clean_content='# Heading

Some prose.

```{r setup}
1 + 1
```

Another chunk.

```bash
echo hello
```
'
  if check_string "$clean_content"; then
    echo "CASE 1 PASS: clean file detected as OK"
    pass=$((pass+1))
  else
    echo "CASE 1 FAIL: clean file incorrectly flagged as violation"
    fail=$((fail+1))
  fi

  # Case 2: orphan opening fence — odd parity, exit 1
  orphan_open_content='# Heading

```{r chunk1}
x <- 1
```

Prose.

```{r orphan-open
y <- 2
'
  if ! check_string "$orphan_open_content"; then
    echo "CASE 2 PASS: orphan opening fence detected"
    pass=$((pass+1))
  else
    echo "CASE 2 FAIL: orphan opening fence NOT detected"
    fail=$((fail+1))
  fi

  # Case 3: orphan closing fence — odd parity, exit 1
  orphan_close_content='# Heading

```{r chunk1}
x <- 1
```

Orphan closer below:

```
'
  if ! check_string "$orphan_close_content"; then
    echo "CASE 3 PASS: orphan closing fence detected"
    pass=$((pass+1))
  else
    echo "CASE 3 FAIL: orphan closing fence NOT detected"
    fail=$((fail+1))
  fi

  # Case 4: quadruple fence (nested) — valid escape for prose containing triple-backticks
  # A `````  wraps a block that mentions ``` — this is balanced and should pass
  nested_quad_content='# Heading showing markdown syntax

Here is how to write a code fence in markdown:

````markdown
Use triple backticks like this:
```
code here
```
````

End of document.
'
  if check_string "$nested_quad_content"; then
    echo "CASE 4 PASS: nested quadruple fence accepted as balanced"
    pass=$((pass+1))
  else
    echo "CASE 4 FAIL: nested quadruple fence incorrectly flagged"
    fail=$((fail+1))
  fi

  echo ""
  echo "Selftest: $pass/4 PASS"
  [ "$fail" -eq 0 ] && return 0 || return 1
}

# ─── Fence parity checker ──────────────────────────────────────────────────────

# Check a single .qmd file.
# Outputs: nothing on success, diagnostic lines on failure.
# Returns: 0 if balanced, 1 if unbalanced.
check_file() {
  local file="$1"
  local line_num=0
  local depth=0
  local violations=()

  # We track two types of fences:
  #   quad  — lines starting with 4+ backticks (quadruple fence opener/closer)
  #   triple — lines starting with exactly 3 backticks
  # A quad-fence opens a "quad context" where triple-backticks are literal text.
  # Outside a quad context, triple-backticks toggle depth.
  local in_quad=0
  local quad_open_line=0

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # Strip leading whitespace for the fence test (indented fences are valid in Quarto)
    local stripped="${line#"${line%%[! ]*}"}"

    # Count leading backticks
    local bt_count=0
    local rest="$stripped"
    while [[ "${rest:0:1}" == '`' ]]; do
      bt_count=$((bt_count + 1))
      rest="${rest:1}"
    done

    # Only lines where ALL leading non-whitespace chars are backticks count as fences.
    # A line like `` `x` `` is inline code, not a fence.
    # A fence line is: 3+ backticks, then optionally a language tag or whitespace.
    if [ "$bt_count" -ge 4 ]; then
      # Quadruple (or more) fence
      if [ "$in_quad" -eq 0 ]; then
        in_quad=1
        quad_open_line="$line_num"
        depth=$((depth + 1))
      else
        in_quad=0
        depth=$((depth - 1))
      fi
    elif [ "$bt_count" -eq 3 ]; then
      # Triple fence
      if [ "$in_quad" -eq 0 ]; then
        # Normal context: toggle depth
        if [ "$depth" -eq 0 ]; then
          depth=1
          violations+=("  line $line_num: opening fence: $line")
        else
          depth=$((depth - 1))
          violations+=("  line $line_num: closing fence: $line")
        fi
      fi
      # Inside quad context, triple-backticks are literal text — ignore
    fi
  done < "$file"

  if [ "$depth" -ne 0 ]; then
    if [ "$QUIET" -eq 1 ]; then
      echo "FENCE_PARITY_ERROR:$file:depth=$depth"
    else
      echo "ERROR: Unbalanced code fences in $file (depth=$depth at EOF)"
      for v in "${violations[@]}"; do
        echo "$v"
      done
    fi
    return 1
  fi

  return 0
}

# ─── Main ──────────────────────────────────────────────────────────────────────

if [ "$SELFTEST" -eq 1 ]; then
  run_selftest
  exit $?
fi

# Collect .qmd files under TARGET
if [ -f "$TARGET" ]; then
  qmd_files=("$TARGET")
elif [ -d "$TARGET" ]; then
  mapfile -t qmd_files < <(find "$TARGET" -name "*.qmd" -type f 2>/dev/null | sort)
else
  echo "ERROR: Target not found: $TARGET"
  exit 1
fi

if [ "${#qmd_files[@]}" -eq 0 ]; then
  [ "$QUIET" -eq 0 ] && echo "No .qmd files found under $TARGET"
  exit 0
fi

violations_found=0

for f in "${qmd_files[@]}"; do
  if ! check_file "$f"; then
    violations_found=$((violations_found + 1))
  fi
done

if [ "$violations_found" -eq 0 ]; then
  [ "$QUIET" -eq 0 ] && echo "check_qmd_fence_parity: OK ($((${#qmd_files[@]})) files, 0 violations)"
  exit 0
else
  [ "$QUIET" -eq 0 ] && echo ""
  [ "$QUIET" -eq 0 ] && echo "check_qmd_fence_parity: FAIL ($violations_found file(s) with unbalanced fences)"
  exit 1
fi
