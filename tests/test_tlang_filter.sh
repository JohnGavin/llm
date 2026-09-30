#!/usr/bin/env bash
# tests/test_tlang_filter.sh
#
# Tests for the locally patched Quarto/pandoc Lua filter
#   _extensions/tlang/tlang.lua
# (local patches listed in _extensions/tlang/VENDORED.md; roborev job 13831).
#
# The filter is run through `pandoc --lua-filter` (Quarto runs the same Lua
# API), with a deterministic stub standing in for the `t` CLI via TLANG_BIN.
# The stub understands just enough T: `print("X")` emits `X ` (the real CLI
# prints a string plus a trailing space -- verified against t-lang 0.51.2),
# `boom()` exits 2 with a message on stderr, `varmissing()` exits 1 after
# printing "variable not found" to stderr.
#
# Cases:
#   1. two printing chunks: the first chunk's output appears exactly ONCE
#      (unpatched filter re-emits it in the second chunk -> 2).
#   2. a failed `include: false` chunk is reported on stderr, and does not
#      poison later chunks.
#   3. TLANG_BIN containing `..` inside a file name (t..old) is accepted;
#      a real `../` segment is still rejected.
#   4. a missing binary is labelled as such; a non-zero exit from a T program
#      that says "variable not found" is NOT labelled a missing binary.
#
# Exit codes: 0 all pass, 1 any failure, 3 INDETERMINATE (pandoc missing --
# cannot run the filter at all; checks-must-distinguish-unknown).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${SCRIPT_DIR}/../_extensions/tlang/tlang.lua"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

PANDOC="$(command -v pandoc || true)"
if [ -z "${PANDOC}" ]; then
  echo "INDETERMINATE: pandoc not found on PATH; cannot run the filter"
  exit 3
fi
if [ ! -f "${FILTER}" ]; then
  echo "FAIL: filter not found at ${FILTER}"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ---- stub t -----------------------------------------------------------------
STUB="${WORK}/stub-t"
cat > "${STUB}" <<'EOF'
#!/usr/bin/env bash
# args: --mode strict --unsafe run <file>
file="${@: -1}"
re='^print\("(.*)"\)$'
while IFS= read -r line || [ -n "${line}" ]; do
  if [[ "${line}" =~ ${re} ]]; then
    printf '%s \n' "${BASH_REMATCH[1]}"
  elif [ "${line}" = "boom()" ]; then
    echo "boom: stub failure" >&2; exit 2
  elif [ "${line}" = "varmissing()" ]; then
    echo "variable not found" >&2; exit 1
  fi
done < "${file}"
EOF
chmod +x "${STUB}"

# run_filter <qmd> -> HTML on stdout, stderr in ${WORK}/stderr
run_filter() {
  TLANG_BIN="${TLANG_BIN_OVERRIDE:-${STUB}}" "${PANDOC}" -f markdown -t html \
    --lua-filter "${FILTER}" "$1" 2> "${WORK}/stderr"
}

count_of() { grep -o -- "$2" <<<"$1" | wc -l | tr -d ' '; }

# ---- 1. no repeated output --------------------------------------------------
cat > "${WORK}/one.md" <<'EOF'
```t
#| echo: false
print("ALPHA-ONE")
```

```t
#| echo: false
print("BETA-TWO")
```

```t
#| echo: false
print("GAMMA-THREE")
```
EOF
html="$(run_filter "${WORK}/one.md")"
a="$(count_of "${html}" 'ALPHA-ONE')"
b="$(count_of "${html}" 'BETA-TWO')"
c="$(count_of "${html}" 'GAMMA-THREE')"
if [ "${a}" = 1 ] && [ "${b}" = 1 ] && [ "${c}" = 1 ]; then
  pass "each chunk's output appears exactly once (alpha=${a} beta=${b} gamma=${c})"
else
  fail "chunk output repeated (alpha=${a} beta=${b} gamma=${c}, expected 1/1/1)"
fi
if grep -q '@@tlang' <<<"${html}"; then
  fail "internal chunk sentinel leaked into the rendered output"
else
  pass "no chunk sentinel leaked into the rendered output"
fi

# ---- 2. failed include:false chunk is surfaced, state not poisoned ----------
cat > "${WORK}/two.md" <<'EOF'
```t
#| echo: false
#| include: false
boom()
```

```t
#| echo: false
print("AFTER-FAIL")
```
EOF
html="$(run_filter "${WORK}/two.md")"
if grep -q '^\[tlang\] chunk failed' "${WORK}/stderr"; then
  pass "failed include:false chunk is logged to stderr"
else
  fail "failed include:false chunk was silent (stderr: $(cat "${WORK}/stderr"))"
fi
if [ "$(count_of "${html}" 'AFTER-FAIL')" = 1 ]; then
  pass "a later chunk still renders after a failed hidden chunk"
else
  fail "later chunk did not render exactly once after a failed hidden chunk"
fi

# ---- 3. '..' inside a file name vs as a path segment ------------------------
mkdir -p "${WORK}/bin"
cp "${STUB}" "${WORK}/bin/t..old"
TLANG_BIN_OVERRIDE="${WORK}/bin/t..old"
html="$(run_filter "${WORK}/one.md")"
if [ "$(count_of "${html}" 'ALPHA-ONE')" = 1 ]; then
  pass "TLANG_BIN with '..' inside a file name (t..old) is accepted"
else
  fail "TLANG_BIN=t..old rejected: $(grep -o 'T execution failed[^<]*' <<<"${html}" | head -1)"
fi
TLANG_BIN_OVERRIDE="${WORK}/bin/../bin/t..old"
html="$(run_filter "${WORK}/one.md")"
if grep -q 'parent-directory' <<<"${html}"; then
  pass "TLANG_BIN with a '../' path segment is still rejected"
else
  fail "TLANG_BIN with a '../' segment was not rejected"
fi
unset TLANG_BIN_OVERRIDE

# ---- 4. missing binary vs runtime error -------------------------------------
cat > "${WORK}/four.md" <<'EOF'
```t
print("x")
```
EOF
html="$(env -u TLANG_BIN PATH=/usr/bin:/bin "${PANDOC}" -f markdown -t html \
  --lua-filter "${FILTER}" "${WORK}/four.md" 2>/dev/null)"
if grep -q 'Could not run' <<<"${html}"; then
  pass "a genuinely missing binary is labelled as missing"
else
  fail "missing binary not labelled (html: ${html})"
fi

cat > "${WORK}/five.md" <<'EOF'
```t
varmissing()
```
EOF
html="$(run_filter "${WORK}/five.md")"
if grep -q 'Could not run' <<<"${html}"; then
  fail "'variable not found' from a T program was mislabelled as a missing binary"
elif grep -q 'T execution failed' <<<"${html}"; then
  pass "'variable not found' from a T program is reported as an execution failure"
else
  fail "no error rendered for a failing T program"
fi

echo "---"
echo "passed: ${PASS}, failed: ${FAIL}"
[ "${FAIL}" -eq 0 ]
