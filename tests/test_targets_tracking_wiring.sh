#!/usr/bin/env bash
# tests/test_targets_tracking_wiring.sh
#
# llm#1295 item 3: check_targets_tracks_own_package.sh is wired into
#   (a) r_code_check.sh (the pre-commit check) — an untracked own package
#       must make it exit 1; a tracked one must not;
#   (b) session_init.sh Phase 15h — a cached FAIL/INDETERMINATE is printed,
#       a PASS is silent, and a checkout without _targets.R + DESCRIPTION
#       is skipped.
#
# (a) needs ast-grep and Rscript (run inside the llm nix shell); it reports
# SKIP, not ok, when they are missing. (b) uses a stub checker, so it needs
# neither. Falsified by removing the new r_code_check.sh section / the
# session_init phase call (see PR body).
#
# Usage: bash tests/test_targets_tracking_wiring.sh

set -uo pipefail

PASS=0
FAIL=0
SKIP=0
ok()   { echo "ok     $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL   $*"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP   $*"; SKIP=$((SKIP+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RCC="${RCC:-$REPO_ROOT/.claude/scripts/r_code_check.sh}"
HOOK="${HOOK:-$REPO_ROOT/.claude/hooks/session_init.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

# make_pkg <dir> <targets-body>: a minimal package with a _targets.R
make_pkg() {
  mkdir -p "$1/R"
  printf 'Package: mypkg\nVersion: 0.1.0\n' > "$1/DESCRIPTION"
  printf 'f <- function(x) x + 1\n' > "$1/R/f.R"
  printf '%s\n' "$2" > "$1/_targets.R"
}

make_pkg "$TMP/untracked" 'library(targets)
pkgload::load_all()
tar_option_set(packages = "mypkg")
list(tar_target(y, f(1)))'
make_pkg "$TMP/tracked" 'library(targets)
pkgload::load_all()
tar_option_set(packages = "mypkg", imports = "mypkg")
list(tar_target(y, f(1)))'

# ── (a) r_code_check.sh ──────────────────────────────────────────────────────
if ! command -v ast-grep >/dev/null 2>&1 || ! command -v Rscript >/dev/null 2>&1; then
  skip "r_code_check.sh wiring: needs ast-grep and Rscript (run in the llm nix shell)"
else
  out_u=$(bash "$RCC" "$TMP/untracked/R" 2>&1); rc_u=$?
  if [ "$rc_u" -eq 1 ] && printf '%s' "$out_u" | grep -q 'FAIL untracked-own-package'; then
    ok "r_code_check.sh exits 1 on an untracked own package"
  else
    fail "r_code_check.sh on untracked package: rc=$rc_u, FAIL line $(printf '%s' "$out_u" | grep -c 'FAIL untracked-own-package')"
  fi
  out_t=$(bash "$RCC" "$TMP/tracked/R" 2>&1); rc_t=$?
  if [ "$rc_t" -eq 0 ] && printf '%s' "$out_t" | grep -q 'PASS tracked'; then
    ok "r_code_check.sh passes a tracked own package"
  else
    fail "r_code_check.sh on tracked package: rc=$rc_t; output tail: $(printf '%s' "$out_t" | tail -3)"
  fi
fi

# ── (b) session_init.sh Phase 15h ────────────────────────────────────────────
awk '/^phase_targets_own_package\(\) \{/ {p=1} p {print} p && /^\}/ {exit}' "$HOOK" > "$TMP/phase.sh"
if ! grep -q 'phase_targets_own_package' "$TMP/phase.sh"; then
  fail "could not extract phase_targets_own_package() from $HOOK"
elif ! grep -q '^phase_targets_own_package$' "$HOOK"; then
  fail "session_init.sh defines phase_targets_own_package() but never calls it"
else
  ok "session_init.sh defines and calls phase_targets_own_package()"
  HOME_T="$TMP/home"; mkdir -p "$HOME_T/.claude/logs"
  # Stub checker: its verdict comes from $STUB_VERDICT
  cat > "$TMP/stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$STUB_VERDICT: stub verdict for $1"
EOF
  chmod +x "$TMP/stub.sh"
  for d in untracked tracked; do git -C "$TMP/$d" init -q; done
  mkdir -p "$TMP/notpkg"; git -C "$TMP/notpkg" init -q

  # run_phase <dir> <verdict>: run the phase, wait for the background refresh
  run_phase() {
    (cd "$1" && HOME="$HOME_T" CLAUDE_DIR="$TMP" TARGETS_TRACKING_SCRIPT="$TMP/stub.sh" \
      TARGETS_TRACKING_NIX="$TMP/no-such.nix" \
      STUB_VERDICT="$2" PATH="$PATH" bash -c 'source "$1"; phase_targets_own_package; wait' _ "$TMP/phase.sh" 2>&1)
  }
  wait_cache() {  # wait up to 10s for a cache file to exist
    local i; for i in $(seq 1 20); do ls "$HOME_T"/.claude/logs/session_init_targets_tracking_"$1"_* >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1
  }

  first=$(run_phase "$TMP/untracked" FAIL)
  if [ -z "$first" ] && wait_cache untracked; then
    ok "first run is silent and writes the cache in the background"
  else
    fail "first run: output='$first', cache written=$(wait_cache untracked && echo yes || echo no)"
  fi
  second=$(run_phase "$TMP/untracked" FAIL)
  if printf '%s' "$second" | grep -q '^targets-tracking: FAIL: stub verdict'; then
    ok "cached FAIL is printed with a targets-tracking: prefix"
  else
    fail "cached FAIL not printed: '$second'"
  fi

  run_phase "$TMP/tracked" PASS >/dev/null; wait_cache tracked
  pass_out=$(run_phase "$TMP/tracked" PASS)
  if [ -z "$pass_out" ]; then ok "cached PASS is silent"; else fail "PASS printed: '$pass_out'"; fi

  run_phase "$TMP/tracked" INDETERMINATE >/dev/null; sleep 1
  ind_out=$(run_phase "$TMP/tracked" INDETERMINATE)
  if printf '%s' "$ind_out" | grep -q '^targets-tracking: INDETERMINATE'; then
    ok "cached INDETERMINATE is printed (not silent)"
  else
    fail "INDETERMINATE not printed: '$ind_out'"
  fi

  np_out=$(run_phase "$TMP/notpkg" FAIL)
  if [ -z "$np_out" ] && ! ls "$HOME_T"/.claude/logs/session_init_targets_tracking_notpkg_* >/dev/null 2>&1; then
    ok "checkout without _targets.R + DESCRIPTION is skipped (no cache, no output)"
  else
    fail "non-package checkout was not skipped: output='$np_out'"
  fi
fi

echo "---"
echo "passed=$PASS failed=$FAIL skipped=$SKIP"
[ "$FAIL" -eq 0 ]
