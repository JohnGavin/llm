#!/usr/bin/env bash
# install_roborev_primary_shim.sh — idempotent installer for the roborev primary shim.
#
# Phase 1.6 of JohnGavin/llm#386 (primary-loop shim).
#
# What it does:
#   1. Creates ~/.local/bin/ if missing.
#   2. Creates a symlink: ~/.local/bin/roborev → this repo's roborev_primary_shim.sh.
#   3. Warns if ~/.local/bin/ is not in $PATH.
#   4. Warns if PATH order puts /usr/local/bin/ BEFORE ~/.local/bin/.
#
# Idempotent: re-running when the symlink already exists is safe and does nothing
# destructive (it updates the symlink target if it changed).
#
# Test mode:
#   --test    Report what would happen without making any changes.
#
# Usage:
#   ~/docs_gh/llm/.claude/scripts/install_roborev_primary_shim.sh
#   ~/docs_gh/llm/.claude/scripts/install_roborev_primary_shim.sh --test
#
# Post-install verification:
#   which roborev            # must show ~/.local/bin/roborev
#   roborev --version        # must work (execs the real binary)
#
# Tracked: JohnGavin/llm#386

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

LOCAL_BIN="${LOCAL_BIN:-${HOME}/.local/bin}"
INSTALL_TARGET="${LOCAL_BIN}/roborev"
REAL_ROBOREV="${REAL_ROBOREV:-/usr/local/bin/roborev}"

# The shim always lives at the canonical repo path, not a worktree path.
# Using the canonical path means the symlink stays valid after the worktree
# is pruned.
#
# Resolution order:
#   1. SHIM_SCRIPT env var (explicit override — for testing from a worktree)
#   2. Canonical path: ~/docs_gh/llm/.claude/scripts/roborev_primary_shim.sh
#   3. Same-directory fallback: resolve this script's own directory
#
# The same-directory fallback handles the case where this installer is run
# directly from the worktree before the PR is merged to main (e.g. manual test
# after checkout).  Post-merge the canonical path is used.
_resolve_shim_script() {
  local canonical="${HOME}/docs_gh/llm/.claude/scripts/roborev_primary_shim.sh"
  if [ -f "$canonical" ]; then
    echo "$canonical"
    return
  fi
  # Fallback: same directory as this installer (worktree test path)
  local this_dir
  this_dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null || dirname "${BASH_SOURCE[0]}")"
  echo "${this_dir}/roborev_primary_shim.sh"
}
SHIM_SCRIPT="${SHIM_SCRIPT:-$(_resolve_shim_script)}"

TEST_MODE=0

# ── Argument parsing ──────────────────────────────────────────────────────────

for arg in "$@"; do
  case "$arg" in
    --test|-t)  TEST_MODE=1 ;;
    --help|-h)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$arg'" >&2
      echo "Usage: $0 [--test]" >&2
      exit 1
      ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

_say()  { echo "install_roborev_primary_shim: $*"; }
_warn() { echo "install_roborev_primary_shim: WARNING — $*" >&2; }
_err()  { echo "install_roborev_primary_shim: ERROR — $*" >&2; exit 1; }
_dry()  { echo "  [test] would: $*"; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────

_say "shim source: $SHIM_SCRIPT"
_say "install target: $INSTALL_TARGET"
_say "real roborev: $REAL_ROBOREV"
[ "$TEST_MODE" -eq 1 ] && _say "MODE: test (no changes will be made)"
echo ""

# Verify shim source exists
if [ ! -f "$SHIM_SCRIPT" ]; then
  _err "shim script not found at $SHIM_SCRIPT — is this repo checked out at ~/docs_gh/llm?"
fi

# Verify real roborev exists
if [ ! -x "$REAL_ROBOREV" ]; then
  _warn "real roborev not found/executable at $REAL_ROBOREV"
  _warn "Install roborev first: https://github.com/your-org/roborev"
  # Continue anyway — the shim will warn at runtime too
fi

# ── Step 1: create ~/.local/bin/ ─────────────────────────────────────────────

if [ ! -d "$LOCAL_BIN" ]; then
  if [ "$TEST_MODE" -eq 1 ]; then
    _dry "mkdir -p $LOCAL_BIN"
  else
    mkdir -p "$LOCAL_BIN"
    _say "created $LOCAL_BIN"
  fi
else
  _say "$LOCAL_BIN already exists — ok"
fi

# ── Step 2: create / update symlink ──────────────────────────────────────────

_needs_link=0
if [ -L "$INSTALL_TARGET" ]; then
  # Symlink exists — check if it points to the right place
  _current_target="$(readlink "$INSTALL_TARGET")"
  if [ "$_current_target" = "$SHIM_SCRIPT" ]; then
    _say "$INSTALL_TARGET already symlinked to $SHIM_SCRIPT — nothing to do"
  else
    _warn "existing symlink at $INSTALL_TARGET points to $_current_target (expected $SHIM_SCRIPT)"
    _needs_link=1
  fi
elif [ -e "$INSTALL_TARGET" ]; then
  # A non-symlink file exists at that path
  _warn "$INSTALL_TARGET exists but is not a symlink (a real file or directory)"
  _warn "Remove it manually if you want the shim installed there, then re-run."
  exit 1
else
  _needs_link=1
fi

if [ "$_needs_link" -eq 1 ]; then
  if [ "$TEST_MODE" -eq 1 ]; then
    _dry "ln -sf $SHIM_SCRIPT $INSTALL_TARGET"
  else
    ln -sf "$SHIM_SCRIPT" "$INSTALL_TARGET"
    _say "created symlink: $INSTALL_TARGET -> $SHIM_SCRIPT"
  fi
fi

# Ensure shim is executable
if [ ! -x "$SHIM_SCRIPT" ]; then
  if [ "$TEST_MODE" -eq 1 ]; then
    _dry "chmod +x $SHIM_SCRIPT"
  else
    chmod +x "$SHIM_SCRIPT"
    _say "set executable: $SHIM_SCRIPT"
  fi
fi

# ── Step 3: PATH order checks ─────────────────────────────────────────────────

echo ""
_say "PATH order check:"

# Check ~/.local/bin/ is in PATH at all
case ":${PATH}:" in
  *":${LOCAL_BIN}:"*)
    _say "  $LOCAL_BIN is in PATH — ok"
    ;;
  *)
    _warn "  $LOCAL_BIN is NOT in PATH"
    _warn "  Add this to ~/.zshrc or ~/.bashrc:"
    _warn "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    _warn "  Then reload your shell: source ~/.zshrc"
    ;;
esac

# Check PATH order: ~/.local/bin/ must come BEFORE /usr/local/bin/
_local_pos=99999
_real_pos=99999
_idx=1
IFS=: read -ra _path_parts <<< "${PATH}"
for _part in "${_path_parts[@]}"; do
  if [ "$_part" = "$LOCAL_BIN" ]; then
    _local_pos=$_idx
  fi
  if [ "$_part" = "/usr/local/bin" ]; then
    _real_pos=$_idx
  fi
  _idx=$((_idx + 1))
done

if [ "$_local_pos" -ne 99999 ] && [ "$_real_pos" -ne 99999 ]; then
  if [ "$_local_pos" -lt "$_real_pos" ]; then
    _say "  PATH order: $LOCAL_BIN (pos $_local_pos) < /usr/local/bin (pos $_real_pos) — ok"
  else
    _warn "  PATH order: /usr/local/bin (pos $_real_pos) comes BEFORE $LOCAL_BIN (pos $_local_pos)"
    _warn "  The shim will NOT intercept roborev calls until PATH order is fixed."
    _warn "  Fix: put export PATH=\"\$HOME/.local/bin:\$PATH\" BEFORE any /usr/local/bin additions"
  fi
fi

# ── Step 4: self-test the shim ───────────────────────────────────────────────

echo ""
_say "running shim self-test..."
if ROBOREV_SHIM_SELFTEST=1 bash "$SHIM_SCRIPT"; then
  _say "shim self-test: PASS"
else
  _warn "shim self-test: FAIL — check $SHIM_SCRIPT"
  exit 1
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
if [ "$TEST_MODE" -eq 1 ]; then
  _say "Test mode complete. Run without --test to install."
else
  _say "Installation complete."
  _say ""
  _say "Verify:"
  _say "  which roborev          # must show $INSTALL_TARGET"
  _say "  roborev --help         # must work (execs real binary)"
  _say ""
  _say "If 'which roborev' still shows /usr/local/bin/roborev, reload your"
  _say "shell or run: hash -r"
fi
