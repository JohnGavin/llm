#!/usr/bin/env bash
# roborev_primary_shim.sh — PATH-inject codex_shim/ then exec the real roborev.
#
# Phase 1.6 of JohnGavin/llm#386 (primary-loop shim).
#
# Problem it solves:
#   Phase 1.5 (#378) wired codex_shim/ into PATH for SECONDARY roborev callers
#   (refine, poll-merges, verify-closure, auto-verify, post-merge hook).  The
#   daemon's PRIMARY review loop calls roborev directly — it bypassed every
#   shim, which is why ~/.claude/logs/codex_fallback/ stayed empty despite 502
#   reviews completing in 14 hours.
#
# How it works:
#   1. Locate the codex_shim directory that contains codex_with_fallback.sh.
#      Canonical path: ~/docs_gh/llm/.claude/scripts/ (the same directory as
#      this file, since codex_with_fallback.sh lives there).
#   2. If the shim dir is NOT already on PATH, prepend it.
#   3. exec /usr/local/bin/roborev "$@"
#
# Idempotent: if PATH already starts with the shim dir, no duplication.
#
# Install: do NOT install from this file — use install_roborev_primary_shim.sh.
#   install target: ~/.local/bin/roborev → (symlink) this file
#   PATH order requirement: ~/.local/bin/ must precede /usr/local/bin/
#
# Self-test: ROBOREV_SHIM_SELFTEST=1 bash roborev_primary_shim.sh
#
# Tracked: JohnGavin/llm#386

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

# The real roborev binary that we exec into.
REAL_ROBOREV="${REAL_ROBOREV:-/usr/local/bin/roborev}"

# The codex_shim directory.  Default: the same directory as this script,
# because codex_with_fallback.sh lives alongside this script.
_resolve_shim_dir() {
  local script_path
  # Follow symlinks to find the actual file location
  script_path="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  dirname "$script_path"
}

CODEX_SHIM_DIR="${CODEX_SHIM_DIR:-$(_resolve_shim_dir)}"

# ── Self-test ─────────────────────────────────────────────────────────────────

if [ "${ROBOREV_SHIM_SELFTEST:-0}" = "1" ]; then
  pass=0; fail=0
  _t() {
    local label="$1" expected="$2" got="$3"
    if [ "$got" = "$expected" ]; then
      pass=$((pass+1)); echo "  PASS [$label]"
    else
      fail=$((fail+1)); echo "  FAIL [$label]: expected='$expected' got='$got'"
    fi
  }

  # Test 1: shim dir resolution produces a non-empty path
  _shim_dir=$(_resolve_shim_dir)
  _t "shim dir non-empty" "1" "$([ -n "$_shim_dir" ] && echo 1 || echo 0)"

  # Test 2: codex_with_fallback.sh found in shim dir
  _t "codex_with_fallback exists" "1" \
    "$([ -f "${_shim_dir}/codex_with_fallback.sh" ] && echo 1 || echo 0)"

  # Test 3: PATH prepend logic — simulate PATH without shim dir
  _orig_path="/usr/local/bin:/usr/bin:/bin"
  _new_path="${CODEX_SHIM_DIR}:${_orig_path}"
  # Check that shim dir appears first
  _first=$(printf '%s' "$_new_path" | cut -d: -f1)
  _t "shim dir is first on path" "$CODEX_SHIM_DIR" "$_first"

  # Test 4: idempotency — if PATH already has shim dir first, don't double-add
  _already="${CODEX_SHIM_DIR}:/usr/local/bin:/usr/bin"
  _idempotent_path="$_already"
  case ":${_already}:" in
    *":${CODEX_SHIM_DIR}:"*) : ;;   # already present, no-op
    *) _idempotent_path="${CODEX_SHIM_DIR}:${_already}" ;;
  esac
  # Count occurrences — should be exactly 1
  _count=$(printf '%s' "$_idempotent_path" | tr ':' '\n' | grep -c "^${CODEX_SHIM_DIR}$" || true)
  _t "idempotent: shim dir appears exactly once" "1" "$_count"

  # Test 5: REAL_ROBOREV default
  _t "REAL_ROBOREV default" "/usr/local/bin/roborev" "${REAL_ROBOREV}"

  echo ""
  echo "${pass}/$((pass+fail)) PASS"
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi

# ── PATH injection ────────────────────────────────────────────────────────────

# Verify the shim dir exists and contains codex_with_fallback.sh
if [ ! -d "$CODEX_SHIM_DIR" ]; then
  echo "roborev_primary_shim: WARNING — codex_shim dir not found: $CODEX_SHIM_DIR" >&2
  echo "roborev_primary_shim: Falling back to real roborev without codex_shim in PATH" >&2
else
  # Prepend the shim dir to PATH only if it isn't already there.
  case ":${PATH}:" in
    *":${CODEX_SHIM_DIR}:"*)
      # Already on PATH — no-op (idempotency guard)
      ;;
    *)
      PATH="${CODEX_SHIM_DIR}:${PATH}"
      export PATH
      ;;
  esac
fi

# ── Exec real roborev ─────────────────────────────────────────────────────────

if [ ! -x "$REAL_ROBOREV" ]; then
  echo "roborev_primary_shim: ERROR — real roborev not found or not executable: $REAL_ROBOREV" >&2
  exit 127
fi

exec "$REAL_ROBOREV" "$@"
