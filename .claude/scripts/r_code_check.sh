#!/usr/bin/env bash
# r_code_check.sh - Run ast-grep + jarl scan on R project code
# Called by: /check command, quality-gates skill, manual invocation
#
# Requires:
#   ast-grep 0.40+ with R grammar at ~/.config/ast-grep/  (provided by nix shell)
#
# Optional (LAPTOP-LOCAL ONLY — see llm#99):
#   jarl 0.5.0+  — currently a manual install at /usr/local/bin/jarl
#   - NOT provided by nix-shell (nixpkgs only has 0.3.0, fails to build)
#   - NOT available on GitHub Actions runners — jarl checks are silently skipped in CI
#   - The script auto-detects /usr/local/bin/jarl so it works inside nix-shell
#     even though /usr/local/bin is not on PATH there.
#   - To install: download release from https://github.com/krlmlr/jarl/releases
#     and place at /usr/local/bin/jarl (chmod +x).
#   - Migration to nix tracked in llm#99.
#
# Usage:
#   r_code_check.sh [TARGET_DIR] [--json]
#   r_code_check.sh R/
#   r_code_check.sh ~/docs_gh/proj/mypackage/R/ --json
#
# Also runs check_qmd_fence_parity.sh on any *.qmd files in the project root
# vignettes/ and docs/ directories (parallel to TARGET_DIR).
# See JohnGavin/llm#465.

set -euo pipefail

# AST_GREP_DIR_OVERRIDE: testability hook only (default unchanged). Lets a
# test harness point at a scratch rules dir instead of the laptop-local,
# non-git-backed ~/.config/ast-grep — used to verify newly-staged
# .claude/ast-grep-rules/*.yml before the one-time manual deploy copy
# described in each staged rule's header.
AST_GREP_DIR="${AST_GREP_DIR_OVERRIDE:-$HOME/.config/ast-grep}"
SGCONFIG="$AST_GREP_DIR/sgconfig.yml"
TARGET_DIR="${1:-.}"
JSON_FLAG="${2:-}"

if [ ! -f "$SGCONFIG" ]; then
  echo "ERROR: sgconfig.yml not found at $SGCONFIG"
  exit 1
fi

if ! command -v ast-grep >/dev/null 2>&1; then
  echo "ERROR: ast-grep not found in PATH"
  echo "Ensure you are in a Nix shell with ast-grep available"
  exit 1
fi

# Resolve TARGET_DIR to absolute path before cd
TARGET_DIR=$(cd "$TARGET_DIR" 2>/dev/null && pwd || echo "$TARGET_DIR")

# Must cd to sgconfig.yml directory for custom language discovery
cd "$AST_GREP_DIR"

echo "=== ast-grep R Code Scan ==="
echo "Target: $TARGET_DIR"
echo "Rules:  $(ls rules/*.yml 2>/dev/null | wc -l | tr -d ' ') rules loaded"
echo ""

if [ "$JSON_FLAG" = "--json" ]; then
  ast-grep scan --json=compact "$TARGET_DIR" 2>/dev/null
  exit 0
fi

# Run scan with all rules
scan_output=$(ast-grep scan "$TARGET_DIR" 2>&1) || true
n_error=0
n_warning=0

if [ -z "$scan_output" ]; then
  echo "No ast-grep violations found."
else
  echo "$scan_output"
  echo ""
  echo "--- Summary ---"
  n_error=$(echo "$scan_output" | grep -ci "error\[" || true)
  n_warning=$(echo "$scan_output" | grep -ci "warning\[" || true)
  echo "Errors:   $n_error"
  echo "Warnings: $n_warning"
fi

# Hardcoded path check (grep-based, not ast-grep)
echo ""
echo "=== Hardcoded Path Check ==="
hardcoded=$(grep -rn '/Users/[a-zA-Z]' "$TARGET_DIR" --include='*.R' --include='*.r' 2>/dev/null || true)
if [ -n "$hardcoded" ]; then
  n_hardcoded=$(echo "$hardcoded" | wc -l | tr -d ' ')
  echo "WARNING: $n_hardcoded lines with hardcoded /Users/ paths:"
  echo "$hardcoded"
  n_warning=$((n_warning + n_hardcoded))
else
  echo "No hardcoded paths found."
fi

# ─── Domain logic outside R/ check (domain-logic-in-package rule) ──────────
# group_by()+summarise() outside R/ is the signature of aggregation logic
# written inline in a script/dashboard instead of extracted to R/, where a
# second consumer could find and reuse it. See llm#1063.
echo ""
echo "=== Domain Logic Outside R/ Check ==="
DLP_ROOT="$TARGET_DIR"
while [ "$DLP_ROOT" != "/" ] && [ ! -f "$DLP_ROOT/DESCRIPTION" ] && [ ! -d "$DLP_ROOT/.git" ]; do
  DLP_ROOT=$(dirname "$DLP_ROOT")
done
dlp_hits=""
if [ -d "$DLP_ROOT" ]; then
  dlp_hits=$(grep -rl "group_by(" "$DLP_ROOT" \
    --include='*.qmd' --include='*.R' --include='*.r' 2>/dev/null \
    | grep -v "^$DLP_ROOT/R/" \
    | while read -r f; do grep -q "summari[sz]e(" "$f" && echo "$f"; done || true)
fi
if [ -n "$dlp_hits" ]; then
  n_dlp=$(echo "$dlp_hits" | wc -l | tr -d ' ')
  echo "WARNING: $n_dlp file(s) with group_by()+summarise() outside R/ — likely domain logic that should be an exported, tested function instead:"
  echo "$dlp_hits"
  echo "See ~/docs_gh/llm/.claude/rules/domain-logic-in-package.md"
  n_warning=$((n_warning + n_dlp))
else
  echo "No aggregation logic found outside R/."
fi

# jarl R idiom linter (separate tool, different rule set from ast-grep)
# LAPTOP-LOCAL ONLY: see llm#99. Manual install at /usr/local/bin/jarl.
# Skipped silently inside CI runners (no /usr/local/bin/jarl) — that is by design
# until nixpkgs ships a working jarl >= 0.5.0.
echo ""
echo "=== jarl R Idiom Linter ==="
jarl_errors=0
JARL_BIN=""
if command -v jarl >/dev/null 2>&1; then
  JARL_BIN="jarl"
elif [ -x /usr/local/bin/jarl ]; then
  # /usr/local/bin is not on PATH inside nix-shell; reach the manual install directly
  JARL_BIN="/usr/local/bin/jarl"
fi

if [ -n "$JARL_BIN" ]; then
  jarl_output=$("$JARL_BIN" check "$TARGET_DIR" 2>&1) || true
  if [ -n "$jarl_output" ]; then
    echo "$jarl_output"
    jarl_errors=$(echo "$jarl_output" | grep -c "^error" || true)
  else
    echo "No jarl violations found."
  fi
else
  echo "jarl not found — skipping R idiom checks."
  echo "  Laptop-local manual install required (see llm#99)."
  echo "  Install: download https://github.com/krlmlr/jarl/releases >= 0.5.0"
  echo "           to /usr/local/bin/jarl (chmod +x)."
  echo "  Note: jarl is not available on GitHub Actions runners."
fi

# ─── Quarto fence parity check (llm#465) ────────────────────────────────────
# Run check_qmd_fence_parity.sh on vignettes/ and docs/ relative to TARGET_DIR
# so staged .qmd edits are caught at pre-commit time.
QMD_FENCE_SCRIPT="$(dirname "$0")/check_qmd_fence_parity.sh"
qmd_errors=0
if [ -x "$QMD_FENCE_SCRIPT" ]; then
  echo ""
  echo "=== Quarto Fence Parity Check ==="
  # Derive project root from TARGET_DIR: walk up until we find a DESCRIPTION or .git
  PROJ_ROOT="$TARGET_DIR"
  while [ "$PROJ_ROOT" != "/" ] && [ ! -f "$PROJ_ROOT/DESCRIPTION" ] && [ ! -d "$PROJ_ROOT/.git" ]; do
    PROJ_ROOT=$(dirname "$PROJ_ROOT")
  done
  qmd_exit=0
  for qmd_dir in "$PROJ_ROOT/vignettes" "$PROJ_ROOT/docs"; do
    if [ -d "$qmd_dir" ]; then
      if ! "$QMD_FENCE_SCRIPT" "$qmd_dir"; then
        qmd_exit=1
      fi
    fi
  done
  if [ "$qmd_exit" -ne 0 ]; then
    echo "Quarto fence parity: FAIL — fix orphan triple-backtick fences above"
    qmd_errors=1
  else
    echo "Quarto fence parity: OK"
  fi
else
  echo ""
  echo "=== Quarto Fence Parity Check ==="
  echo "check_qmd_fence_parity.sh not found at $QMD_FENCE_SCRIPT — skipping"
fi

# ─── Provisional Constants Check (graduated block/warn, JohnGavin/llm#792) ─
# The `provisional-constants` ast-grep rule (staged at
# .claude/ast-grep-rules/provisional-constants.yml; laptop-local deploy
# required, see that file's header) always fires at `warning` severity —
# Option C's graduated block/warn split is a function of WHICH FILE the
# match is in, which ast-grep cannot express natively. This section decides
# block-vs-warn per match based on the file's path, and re-confirms each
# match against the source text to exclude the "trailing comment on a prior
# unrelated statement" false-positive documented in that rule's header.
#
# Graduated-block paths (approximates "feeds a published output", per
# JohnGavin/llm#792's own proposed approximation — not a full dependency
# graph): R/plan_*/**, pipeline/**, scrapers/**, or the matched file's
# basename is read/sourced by a .qmd under docs/** or vignettes/**.
echo ""
echo "=== Provisional Constants Check (JohnGavin/llm#792) ==="
PC_ROOT="$TARGET_DIR"
while [ "$PC_ROOT" != "/" ] && [ ! -f "$PC_ROOT/DESCRIPTION" ] && [ ! -d "$PC_ROOT/.git" ]; do
  PC_ROOT=$(dirname "$PC_ROOT")
done
pc_block=0
pc_warn=0
pc_json=$(cd "$AST_GREP_DIR" && ast-grep scan --json=compact "$TARGET_DIR" 2>/dev/null) || true
if [ -n "$pc_json" ]; then
  pc_matches=$(echo "$pc_json" | jq -c '.[] | select(.ruleId=="provisional-constants")' 2>/dev/null) || true
  if [ -n "$pc_matches" ]; then
    while IFS= read -r match; do
      [ -z "$match" ] && continue
      m_file=$(echo "$match" | jq -r '.file')
      m_line0=$(echo "$match" | jq -r '.range.start.line')
      m_line=$((m_line0 + 1))
      # Resolve to an absolute path relative to TARGET_DIR for sed/grep.
      case "$m_file" in
        /*) m_abs="$m_file" ;;
        *) m_abs="$TARGET_DIR/$m_file" ;;
      esac
      [ -f "$m_abs" ] || continue
      prev_line=$(sed -n "$((m_line - 1))p" "$m_abs" 2>/dev/null || echo "")
      prev_stripped="${prev_line#"${prev_line%%[![:space:]]*}"}"
      case "$prev_stripped" in
        "#"*)
          # Confirmed: the line immediately above is a comment-only line
          # (excludes the trailing-comment-on-a-prior-statement bleed-through
          # documented in provisional-constants.yml's header).
          rel_path="${m_abs#"$PC_ROOT"/}"
          is_blocked=0
          case "$rel_path" in
            R/plan_*/*|pipeline/*|scrapers/*) is_blocked=1 ;;
          esac
          if [ "$is_blocked" -eq 0 ] && [ -d "$PC_ROOT/docs" -o -d "$PC_ROOT/vignettes" ]; then
            base_name=$(basename "$m_abs")
            if grep -rlq "$base_name" "$PC_ROOT/docs" "$PC_ROOT/vignettes" --include='*.qmd' 2>/dev/null; then
              is_blocked=1
            fi
          fi
          if [ "$is_blocked" -eq 1 ]; then
            echo "BLOCK [P0 graduated tier]: $m_abs:$m_line — provisional-marked literal in a file that feeds a published output"
            pc_block=$((pc_block + 1))
          else
            echo "WARN  [not graduated]: $m_abs:$m_line — provisional-marked literal; document + cite (F2) or write a parser (F1)"
            pc_warn=$((pc_warn + 1))
          fi
          ;;
        *)
          # Preceding line is not comment-only text — likely the "follows"
          # false-positive bleed-through (a trailing comment belongs to the
          # PRIOR statement, not this one). Skip.
          :
          ;;
      esac
    done <<EOF
$pc_matches
EOF
  fi
fi
if [ "$pc_block" -eq 0 ] && [ "$pc_warn" -eq 0 ]; then
  echo "No provisional-marked literals found."
else
  echo ""
  echo "Provisional constants: $pc_block blocked (graduated tier), $pc_warn warned (see .claude/rules/provisional-constants.md)"
fi

# ─── MANUAL Marker Staleness Check (JohnGavin/llm#792) ─────────────────────
# "# MANUAL: no source" markers with NO issue reference are already flagged
# unconditionally as an ast-grep `error` (manual-marker-no-issue-ref, counted
# in $n_error above). This section checks the OTHER half: a marker that DOES
# cite an issue, but the issue has since been closed — "a marker with no
# expiry becomes a lie" (JohnGavin/llm#792).
echo ""
echo "=== MANUAL Marker Staleness Check (JohnGavin/llm#792) ==="
manual_stale=0
manual_indeterminate=0
manual_hits=""
manual_grep_err=""
manual_grep_errfile=$(mktemp)
set +e
manual_hits=$(grep -rnoE '# MANUAL:.*#[0-9]+' "$TARGET_DIR" --include='*.R' --include='*.r' 2>"$manual_grep_errfile")
manual_grep_rc=$?
set -e
manual_grep_err=$(cat "$manual_grep_errfile")
rm -f "$manual_grep_errfile"
# grep exit 1 with empty stderr means "no matches" (a legitimate negative);
# exit >1, or exit 1 with non-empty stderr, means grep itself failed (e.g.
# unreadable path) — that is INDETERMINATE, not "no markers found".
if [ "$manual_grep_rc" -gt 1 ] || { [ "$manual_grep_rc" -eq 1 ] && [ -n "$manual_grep_err" ]; }; then
  echo "INDETERMINATE: grep over $TARGET_DIR failed (rc=$manual_grep_rc): $manual_grep_err"
  manual_indeterminate=$((manual_indeterminate + 1))
  manual_hits=""
fi
# Resolve owner/repo explicitly rather than relying on gh's cwd auto-detection —
# a caller may invoke this script from a cwd gh cannot map to a repo (e.g. an
# agent whose shell cwd resets between calls), which would otherwise turn every
# lookup into a false INDETERMINATE.
MC_ROOT="$TARGET_DIR"
while [ "$MC_ROOT" != "/" ] && [ ! -f "$MC_ROOT/DESCRIPTION" ] && [ ! -d "$MC_ROOT/.git" ]; do
  MC_ROOT=$(dirname "$MC_ROOT")
done
gh_repo_slug=""
if [ -d "$MC_ROOT/.git" ] || git -C "$MC_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  gh_repo_slug=$(git -C "$MC_ROOT" remote get-url origin 2>/dev/null | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##') || gh_repo_slug=""
fi
if [ -z "$manual_hits" ]; then
  echo "No cited MANUAL markers found."
elif ! command -v gh >/dev/null 2>&1; then
  echo "INDETERMINATE: gh CLI not found — cannot verify cited issues are still open."
else
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    hit_loc="${hit%%:*}"
    issue_num=$(echo "$hit" | grep -oE '#[0-9]+' | tail -1 | tr -d '#')
    [ -z "$issue_num" ] && continue
    if [ -n "$gh_repo_slug" ]; then
      issue_state=$(gh issue view "$issue_num" -R "$gh_repo_slug" --json state --jq .state 2>/dev/null) || issue_state=""
    else
      issue_state=$(gh issue view "$issue_num" --json state --jq .state 2>/dev/null) || issue_state=""
    fi
    if [ -z "$issue_state" ]; then
      echo "INDETERMINATE: $hit_loc — could not resolve state of issue #$issue_num (gh error / not authenticated / wrong repo)"
      manual_indeterminate=$((manual_indeterminate + 1))
    elif [ "$issue_state" = "CLOSED" ]; then
      echo "STALE [error]: $hit_loc — cites issue #$issue_num, which is CLOSED. Marker with no expiry becomes a lie: update the code to use the now-available source, or delete the marker."
      manual_stale=$((manual_stale + 1))
    fi
  done <<EOF
$manual_hits
EOF
  if [ "$manual_stale" -eq 0 ] && [ "$manual_indeterminate" -eq 0 ]; then
    echo "All cited MANUAL markers reference open issues."
  fi
fi

# Exit code: 1 if any errors (ast-grep, jarl, qmd fence, graduated-block
# provisional constants, or stale MANUAL markers), 0 if clean or warnings/
# indeterminates only. An INDETERMINATE result is reported but does NOT
# silently pass as clean and does NOT silently block — see
# checks-must-distinguish-unknown.
if [ "$n_error" -gt 0 ] || [ "$jarl_errors" -gt 0 ] || [ "$qmd_errors" -gt 0 ] || [ "$pc_block" -gt 0 ] || [ "$manual_stale" -gt 0 ]; then
  exit 1
else
  exit 0
fi
