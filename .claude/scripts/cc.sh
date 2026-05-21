#!/usr/bin/env bash
# cc.sh — Claude Code wrapper with permission-mode + budget-aware model selection
#         + project-name auto-set (#147) + worktree-offer on main checkout (B2)
#
# Permission mode selection:
#   /tmp, /private/tmp                       → bypassPermissions
#   git worktree (git-dir != git-common-dir) → bypassPermissions
#   anything else (main checkout, $HOME)     → default
#
# Budget-aware model selection (unless --model explicitly provided):
#   BURN >= 90%: Auto-spawn sonnet session in worktree
#   BURN >= 70%: Use sonnet model
#   BURN <  70%: Use opus model
#
# Worktree offer (B2 — approval-reduction plan):
#   When launched in a main checkout (not worktree, not /tmp), cc.sh prints a
#   one-line note and prompts the user to open a new worktree. Choosing yes (or
#   typing a branch name) creates the worktree, changes into it, and continues.
#   The worktree session will use bypassPermissions automatically.
#   Pass --no-worktree to suppress the prompt.
#
# Project name + colour (#147):
#   Session title = basename($PWD) (passed to `claude -n` so /resume + session
#   switcher show the project name). If a colour is mapped in
#   ~/.claude/project-colors.yaml, prints a one-line paste tip with
#   `/color <name>` — paste once per session, colour persists across resume.
#
# Usage:
#   alias cc='~/.claude/scripts/cc.sh'
#   cc                      # starts session with auto-selected mode + model + name
#   cc --print-mode         # prints the detected mode and exits
#   cc --model opus         # explicit model override (bypasses budget check)
#   cc --permission-mode <m> ...  # explicit permission override
#   cc -n <custom-name> ... # explicit name override (skips auto-name)
#   cc --no-worktree        # skip the worktree-offer prompt (stay in main checkout)
#
# Companion rules: permission-mode-discipline, auto-delegation, permission-discipline

set -e

# ---------------------------------------------------------------------------
# Self-test mode: CC_SH_SELFTEST=1 bash cc.sh
# Runs minimal state-detection and flag-parsing tests then exits 0/1.
# ---------------------------------------------------------------------------
if [ "${CC_SH_SELFTEST:-0}" = "1" ]; then
  PASS=0
  FAIL=0

  check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
      echo "PASS: $desc"
      PASS=$((PASS + 1))
    else
      echo "FAIL: $desc — expected '$expected' got '$actual'"
      FAIL=$((FAIL + 1))
    fi
  }

  # Test 1: is_worktree detects non-worktree (run from /tmp)
  result=$(git -C /tmp rev-parse --git-dir 2>/dev/null || echo "not-a-repo")
  check "non-repo returns not-a-repo" "not-a-repo" "$result"

  # Test 2: --no-worktree flag detection
  NO_WORKTREE=false
  for _arg in --no-worktree --model opus; do
    case "$_arg" in --no-worktree) NO_WORKTREE=true ;; esac
  done
  check "--no-worktree detected in arg list" "true" "$NO_WORKTREE"

  # Test 3: --no-worktree stripping from args
  # Input: 4 tokens (--no-worktree --model opus foo), expect 3 after stripping
  set -- --no-worktree --model opus foo
  CLEAN_ARGS=()
  for _arg in "$@"; do
    case "$_arg" in --no-worktree) ;; *) CLEAN_ARGS+=("$_arg") ;; esac
  done
  check "--no-worktree stripped, 4 args remain as 3" "3" "${#CLEAN_ARGS[@]}"

  # Test 4: branch name sanitisation (/ → -)
  raw="feat/my-task"
  sanitised="${raw//\//-}"
  check "branch / replaced with -" "feat-my-task" "$sanitised"

  # Test 5: default branch name format
  branch_ts="feat/cc-$(date +%Y%m%d-%H%M%S)"
  # Just check it starts with feat/cc-
  prefix="${branch_ts:0:8}"
  check "default branch starts with feat/cc-" "feat/cc-" "$prefix"

  # Test 6: worktree path construction from repo root + branch suffix
  _repo_root="/Users/johngavin/docs_gh/llm"
  _repo_name="$(basename "$_repo_root")"
  _branch="feat/my-feature"
  _suffix="${_branch//\//-}"
  _wt="${_repo_root}/../${_repo_name}-${_suffix}"
  check "worktree path constructed" "/Users/johngavin/docs_gh/llm/../llm-feat-my-feature" "$_wt"

  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

is_worktree() {
  local common gitdir
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  gitdir=$(git rev-parse --git-dir 2>/dev/null) || return 1
  common=$(cd "$common" 2>/dev/null && pwd) || return 1
  gitdir=$(cd "$gitdir" 2>/dev/null && pwd) || return 1
  [ "$common" != "$gitdir" ]
}

is_in_git_repo() {
  git rev-parse --git-dir >/dev/null 2>&1
}

select_mode() {
  case "$PWD" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*) echo "bypassPermissions"; return ;;
  esac
  if is_worktree; then
    echo "bypassPermissions"
  else
    echo "default"
  fi
}

get_burn_rate() {
  local script="$HOME/.claude/scripts/burn_rate_check.sh"
  if [[ -x "$script" ]]; then
    "$script" --percent-only 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# Resolve project name and colour from a given directory.
# Called once before worktree switch and again after (if switched) so that
# the launched session is always named for its actual working directory.
resolve_project_name_and_color() {
  local dir="${1:-$PWD}"
  PROJECT_NAME="$(basename "$dir")"
  PROJECT_COLOR=""
  local colors_yaml="$HOME/.claude/project-colors.yaml"
  if [ -f "$colors_yaml" ]; then
    # Use awk for literal-key lookup to avoid regex metacharacter mis-match
    # (e.g. "JohnGavin.github.io" contains dots that would be wildcards in sed).
    PROJECT_COLOR=$(awk -F': *' -v key="$PROJECT_NAME" '
      $1 == key { gsub(/[[:space:]#].*/, "", $2); print $2; exit }
    ' "$colors_yaml")
  fi
}

# offer_worktree: when in a main git checkout, prompt the user to create a
# worktree. Reads from /dev/tty so it works even when stdin is redirected.
# Sets WORKTREE_DIR to the chosen worktree path (empty if user declined).
offer_worktree() {
  # Skip if not in a git repo
  is_in_git_repo || return 0
  # Skip if already a worktree
  is_worktree && return 0
  # Skip if in /tmp
  case "$PWD" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*) return 0 ;;
  esac

  local repo_root repo_name
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  repo_name="$(basename "$repo_root")"

  echo "You're in the main checkout of $repo_name. New work should go in a worktree (lets bypassPermissions safely)."
  printf "Open a new worktree? [y / N / branch-name]: "

  local answer
  if [ -t 0 ] && [ -r /dev/tty ]; then
    if ! read -r answer </dev/tty 2>/dev/null; then
      answer="n"
    fi
  else
    # non-interactive — decline worktree, fall through to plain claude
    answer="n"
  fi

  case "$answer" in
    ""|n|N) return 0 ;;
    y|Y) answer="feat/cc-$(date +%Y%m%d-%H%M%S)" ;;
  esac

  # Sanitise branch name for use as a directory suffix (replace / with -)
  local branch="$answer"
  local suffix="${branch//\//-}"
  local wt_path="${repo_root}/../${repo_name}-${suffix}"
  wt_path="$(cd "${repo_root}/.." && pwd)/${repo_name}-${suffix}"

  if [ -d "$wt_path" ]; then
    # Safety check: confirm the existing directory really is the intended branch,
    # not a collision where a different branch mapped to the same path
    # (e.g. feat/foo and feat-foo both → feat-foo under tr '/' '-').
    local actual_branch
    actual_branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ "$actual_branch" != "$branch" ]; then
      echo "ERROR: Directory $wt_path exists but is on branch '$actual_branch', not '$branch'."
      echo "Refusing to reuse — possible branch-name collision. Use a different branch name."
      return 0
    fi
    echo "Worktree already exists: $wt_path"
    echo "Switched to worktree: $wt_path"
    cd "$wt_path"
    WORKTREE_DIR="$wt_path"
    return 0
  fi

  echo "Creating worktree $wt_path on branch $branch ..."
  if git -C "$repo_root" worktree add -b "$branch" "$wt_path" 2>/dev/null; then
    echo "Switched to worktree: $wt_path"
  elif git -C "$repo_root" worktree add "$wt_path" "$branch" 2>/dev/null; then
    # Branch already exists — attach worktree without resetting its tip.
    echo "Switched to worktree (existing branch): $wt_path"
  else
    # Branch exists AND may be checked out elsewhere, or user wants a forced reset.
    local reset_answer="n"
    printf "Branch '%s' already exists. Reset its tip to current HEAD? [y/N]: " "$branch"
    if [ -t 0 ] && [ -r /dev/tty ]; then
      if ! read -r reset_answer </dev/tty 2>/dev/null; then
        reset_answer="n"
      fi
    fi
    case "$reset_answer" in
      y|Y)
        if git -C "$repo_root" worktree add -B "$branch" "$wt_path"; then
          echo "Switched to worktree (branch tip reset): $wt_path"
        else
          echo "Could not create worktree — continuing in main checkout."
          return 0
        fi
        ;;
      *)
        echo "Could not create worktree — continuing in main checkout."
        return 0
        ;;
    esac
  fi

  cd "$wt_path"
  WORKTREE_DIR="$wt_path"
}

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------

# Check for explicit overrides and --no-worktree
HAS_MODEL_OVERRIDE=false
HAS_PERMISSION_OVERRIDE=false
HAS_NAME_OVERRIDE=false
NO_WORKTREE=false

for arg in "$@"; do
  case "$arg" in
    --model|--model=*) HAS_MODEL_OVERRIDE=true ;;
    --permission-mode|--permission-mode=*) HAS_PERMISSION_OVERRIDE=true ;;
    -n|--name|-n=*|--name=*) HAS_NAME_OVERRIDE=true ;;
    --no-worktree) NO_WORKTREE=true ;;
  esac
done

# Strip --no-worktree from the args that will be forwarded to claude
PASSTHROUGH_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --no-worktree) ;;
    *) PASSTHROUGH_ARGS+=("$arg") ;;
  esac
done

# ---------------------------------------------------------------------------
# Initial project-name + colour resolution (from current directory)
# ---------------------------------------------------------------------------
resolve_project_name_and_color "$PWD"

# ---------------------------------------------------------------------------
# Early exits
# ---------------------------------------------------------------------------

# Print mode and exit if requested
if [ "${1:-}" = "--print-mode" ]; then
  echo "Permission: $(select_mode)"
  echo "Burn rate: $(get_burn_rate)%"
  exit 0
fi

# ---------------------------------------------------------------------------
# Worktree offer (B2)
# Runs before ARGS construction so that select_mode() sees the post-cd cwd.
# ---------------------------------------------------------------------------
WORKTREE_DIR=""
if ! $NO_WORKTREE; then
  offer_worktree
fi

# If we changed directory into a worktree, re-resolve project name + colour
if [ -n "$WORKTREE_DIR" ]; then
  resolve_project_name_and_color "$WORKTREE_DIR"
fi

# ---------------------------------------------------------------------------
# Build argument list
# ---------------------------------------------------------------------------
ARGS=()

# Add permission mode unless overridden
if ! $HAS_PERMISSION_OVERRIDE; then
  MODE=$(select_mode)
  ARGS+=(--permission-mode "$MODE")
fi

# Add model unless overridden
if ! $HAS_MODEL_OVERRIDE; then
  BURN=$(get_burn_rate)

  if [[ "$BURN" -ge 90 ]]; then
    # CRITICAL: Auto-spawn worktree with sonnet
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

    if [[ -n "$REPO_ROOT" ]] && ! is_worktree; then
      REPO_NAME=$(basename "$REPO_ROOT")
      WORKTREE="${REPO_ROOT}/../${REPO_NAME}-sonnet"

      if [[ ! -d "$WORKTREE" ]]; then
        BRANCH_NAME="sonnet-$(date +%m%d)"
        echo "BURN CRITICAL ($BURN%) — creating worktree at $WORKTREE"
        git -C "$REPO_ROOT" worktree add "$WORKTREE" -b "$BRANCH_NAME" 2>/dev/null || \
          git -C "$REPO_ROOT" worktree add "$WORKTREE" "$BRANCH_NAME" 2>/dev/null || \
          git -C "$REPO_ROOT" worktree add "$WORKTREE" HEAD
      else
        echo "BURN CRITICAL ($BURN%) — using existing worktree at $WORKTREE"
      fi

      echo "Starting sonnet session in worktree..."
      echo "To return to main checkout: cd $REPO_ROOT"
      echo ""

      cd "$WORKTREE"
      # Re-resolve name/colour for the worktree directory (fixes #905: name was
      # computed for the original checkout before the cd).
      resolve_project_name_and_color "$WORKTREE"
      # Re-select mode for worktree (will be bypassPermissions)
      ARGS=(--permission-mode "$(select_mode)" --model sonnet)
    else
      echo "BURN CRITICAL ($BURN%) — using sonnet"
      ARGS+=(--model sonnet)
    fi

  elif [[ "$BURN" -ge 70 ]]; then
    echo "BURN WARNING ($BURN%) — using sonnet"
    ARGS+=(--model sonnet)
  else
    ARGS+=(--model claude-opus-4-7)
  fi
fi

# Auto-add -n <project_name> unless user already passed one
if ! $HAS_NAME_OVERRIDE; then
  ARGS+=(-n "$PROJECT_NAME")
fi

# Surface colour paste-tip (single line, easy to copy)
if [ -n "$PROJECT_COLOR" ]; then
  echo "Tip (paste once): /color $PROJECT_COLOR    [project: $PROJECT_NAME]"
fi

exec ~/.local/bin/claude "${ARGS[@]}" "${PASSTHROUGH_ARGS[@]}"
