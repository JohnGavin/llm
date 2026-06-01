#!/usr/bin/env bash
# check_tlang_flake_closure_rebuild.sh
#
# Detects T-lang R projects under ~/docs_gh/ (or --projects-dir) whose
# flake.nix is missing the closure-rebuild shellHook marker.
#
# The closure-rebuild block is mandated by the nix-nested-shell-isolation rule
# and re-applied after every `t update` via default.post.sh. When stripped,
# R compiled packages segfault on dyn.load. See JohnGavin/llm#303.
#
# Exit codes:
#   0 — all T-lang projects have the marker (or no T-lang projects found)
#   1 — at least one T-lang project is MISSING the marker
#
# Usage:
#   check_tlang_flake_closure_rebuild.sh [--quiet] [--projects-dir <dir>]
#   CLAUDE_HOOK_SELFTEST=1 check_tlang_flake_closure_rebuild.sh
#
# Output (one line per matched project):
#   OK      <project-path>
#   MISSING <project-path>
#   SKIP    <project-path>   (has flake.nix but no T-lang signature)
#
# With --quiet: only MISSING lines are shown.

set -euo pipefail

# ── Parse arguments ────────────────────────────────────────────────────────────
QUIET=0
PROJECTS_DIR="${HOME}/docs_gh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet)          QUIET=1; shift ;;
    --projects-dir)   PROJECTS_DIR="$2"; shift 2 ;;
    --projects-dir=*) PROJECTS_DIR="${1#--projects-dir=}"; shift ;;
    *)                shift ;;
  esac
done

# ── Self-test mode ─────────────────────────────────────────────────────────────
if [[ "${CLAUDE_HOOK_SELFTEST:-0}" == "1" ]]; then
  TMP_DIR=$(mktemp -d /tmp/tlang_test_XXXXXX)
  trap 'rm -rf "$TMP_DIR"' EXIT

  # Case A: T-lang project WITH the Closure-rebuild marker → should emit OK
  mkdir -p "$TMP_DIR/proj_ok"
  cat > "$TMP_DIR/proj_ok/tproject.toml" <<'TOML'
[project]
name = "proj_ok"
TOML
  cat > "$TMP_DIR/proj_ok/flake.nix" <<'NIX'
{
  inputs.t-lang.url = "github:b-rodrigues/tlang/v0.51.2";
  outputs = { self, t-lang }: {
    devShells.default = {
      shellHook = ''
        # Closure-rebuild: discard inherited R_LIBS_SITE
        R_LIBS_SITE=""
        export R_LIBS_SITE
      '';
    };
  };
}
NIX

  # Case B: T-lang project WITHOUT the marker → should emit MISSING
  mkdir -p "$TMP_DIR/proj_missing"
  cat > "$TMP_DIR/proj_missing/tproject.toml" <<'TOML'
[project]
name = "proj_missing"
TOML
  cat > "$TMP_DIR/proj_missing/flake.nix" <<'NIX'
{
  inputs.t-lang.url = "github:b-rodrigues/tlang/v0.51.2";
  outputs = { self, t-lang }: {
    devShells.default = {
      shellHook = ''
        echo "no closure rebuild here"
      '';
    };
  };
}
NIX

  # Case C: Directory with flake.nix but NO T-lang signature → should emit SKIP
  mkdir -p "$TMP_DIR/proj_notlang"
  cat > "$TMP_DIR/proj_notlang/flake.nix" <<'NIX'
{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }: {};
}
NIX

  # Run the check on our fixture dir (suppress QUIET for self-test output)
  SELFTEST_OUT=$(CLAUDE_HOOK_SELFTEST=0 QUIET=0 bash "$0" --projects-dir "$TMP_DIR" 2>&1 || true)

  PASS=0
  FAIL=0

  check_line() {
    local pattern="$1" label="$2"
    if echo "$SELFTEST_OUT" | grep -qE "$pattern"; then
      echo "PASS: $label"
      PASS=$((PASS + 1))
    else
      echo "FAIL: $label"
      echo "  Expected pattern: $pattern"
      echo "  Got output:"
      echo "$SELFTEST_OUT" | sed 's/^/    /'
      FAIL=$((FAIL + 1))
    fi
  }

  # Case A: proj_ok must be reported as OK
  check_line "^OK[[:space:]].*proj_ok" "proj_ok reported as OK"

  # Case B: proj_missing must be reported as MISSING
  check_line "^MISSING[[:space:]].*proj_missing" "proj_missing reported as MISSING"

  # Case C: proj_notlang must be SKIP or absent (not OK/MISSING)
  if echo "$SELFTEST_OUT" | grep -qE "^(OK|MISSING)[[:space:]].*proj_notlang"; then
    echo "FAIL: proj_notlang should be SKIP or absent, not OK/MISSING"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: proj_notlang not reported as OK/MISSING (correct — no T-lang signature)"
    PASS=$((PASS + 1))
  fi

  # Exit code: script must exit 1 when MISSING exists
  # Use a subshell with explicit exit-code capture; avoid set -e propagation
  EXIT_CODE=0
  (CLAUDE_HOOK_SELFTEST=0 bash "$0" --projects-dir "$TMP_DIR" >/dev/null 2>&1) || EXIT_CODE=$?
  if [[ "$EXIT_CODE" -eq 1 ]]; then
    echo "PASS: script exits 1 when MISSING found"
    PASS=$((PASS + 1))
  else
    echo "FAIL: expected exit 1, got $EXIT_CODE"
    FAIL=$((FAIL + 1))
  fi

  # Exit code: script must exit 0 when all OK (only OK project present)
  ONLY_OK_DIR=$(mktemp -d /tmp/tlang_ok_only_XXXXXX)
  mkdir -p "$ONLY_OK_DIR/just_ok"
  cp "$TMP_DIR/proj_ok/tproject.toml" "$ONLY_OK_DIR/just_ok/tproject.toml"
  cp "$TMP_DIR/proj_ok/flake.nix"    "$ONLY_OK_DIR/just_ok/flake.nix"
  EXIT_CODE_OK=0
  (CLAUDE_HOOK_SELFTEST=0 bash "$0" --projects-dir "$ONLY_OK_DIR" >/dev/null 2>&1) || EXIT_CODE_OK=$?
  rm -rf "$ONLY_OK_DIR"
  if [[ "$EXIT_CODE_OK" -eq 0 ]]; then
    echo "PASS: script exits 0 when all T-lang projects have the marker"
    PASS=$((PASS + 1))
  else
    echo "FAIL: expected exit 0, got $EXIT_CODE_OK"
    FAIL=$((FAIL + 1))
  fi

  TOTAL=$((PASS + FAIL))
  echo ""
  echo "${PASS}/${TOTAL} PASS"
  [[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
fi

# ── Main detection logic ───────────────────────────────────────────────────────
# The closure-rebuild marker is a comment inserted by default.post.sh.
# We look for the literal string "Closure-rebuild" (case-sensitive) which
# appears as a comment in the shellHook block added by default.post.sh.
MARKER="Closure-rebuild"

# T-lang signature: presence of tproject.toml alongside flake.nix
# (the canonical T-lang project indicator).
# Secondary check: flake.nix references tlang or t-lang in inputs.
is_tlang_project() {
  local dir="$1"
  local flake="$dir/flake.nix"

  # Must have a tproject.toml
  [[ -f "$dir/tproject.toml" ]] || return 1

  # Must have flake.nix
  [[ -f "$flake" ]] || return 1

  # flake.nix must reference t-lang or tlang in inputs (defensive double-check)
  grep -qE '(t-lang|tlang)\.' "$flake" 2>/dev/null || return 1

  return 0
}

has_marker() {
  local flake="$1"
  grep -q "$MARKER" "$flake" 2>/dev/null
}

# Expand ~ manually in case caller passed a literal tilde path
PROJECTS_DIR="${PROJECTS_DIR/#\~/$HOME}"

if [[ ! -d "$PROJECTS_DIR" ]]; then
  echo "ERROR: projects dir not found: $PROJECTS_DIR" >&2
  exit 1
fi

EXIT_CODE=0

# Scan one level deep under PROJECTS_DIR
for candidate in "$PROJECTS_DIR"/*/; do
  [[ -d "$candidate" ]] || continue

  # Strip trailing slash for cleaner output
  project="${candidate%/}"

  flake="$project/flake.nix"

  # No flake.nix → not a nix project at all; skip silently
  [[ -f "$flake" ]] || continue

  if ! is_tlang_project "$project"; then
    # Has flake.nix but no T-lang signature
    [[ "$QUIET" -eq 0 ]] && echo "SKIP    $project"
    continue
  fi

  if has_marker "$flake"; then
    [[ "$QUIET" -eq 0 ]] && echo "OK      $project"
  else
    echo "MISSING $project"
    EXIT_CODE=1
  fi
done

exit "$EXIT_CODE"
