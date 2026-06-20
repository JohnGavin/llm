#!/usr/bin/env bash
# export_and_deploy_data.sh — Export local telemetry data and push to trigger deploy
# Called from session_stop.sh hook or manually
# Exports data that only exists locally (predictions, unified.duckdb, cmonitor-rs)
# then commits to llmtelemetry repo and pushes (CI deploys automatically)
#
# Issue #287 hardening (2026-06-05):
#   - Sub-bug A: bail before rebase/push when no SEMANTIC JSON change exists
#     (parquet bytes diff even when content is identical — header timestamps).
#   - Sub-bug A: on rebase conflict, log conflicted files + record stranded run
#     to ~/.claude/logs/telemetry_stranded_runs.log so session_init.sh can surface.
#   - Sub-bug B: wrap Rscript invocation in nix-shell when Rscript is not on PATH
#     (Sub-bug B was silently producing stale state when PATH was bare).
#   - Selftest: CLAUDE_HOOK_SELFTEST=1 bash export_and_deploy_data.sh
#
# Issue #311 fix (2026-06-20):
#   - Quote git-add pathspecs so git expands globs relative to $TELEMETRY_REPO,
#     not the caller's cwd. Also stage inst/extdata/*.json (cross-check snapshots,
#     llmtelemetry#312) which were detected by semantic_jsons_changed but never
#     staged.

set -uo pipefail

TELEMETRY_REPO="$HOME/docs_gh/llmtelemetry"
DATA_DIR="$TELEMETRY_REPO/vignettes/data"
EXPORT_SCRIPT="$TELEMETRY_REPO/inst/scripts/export_dashboard_data.R"
ROLLUP_SCRIPT="$TELEMETRY_REPO/inst/scripts/run_rollup.R"
STRANDED_LOG="$HOME/.claude/logs/telemetry_stranded_runs.log"

# ─── Helpers (used by both main path and selftest) ────────────────────────────

# semantic_jsons_changed REPO → echoes "JSON_CHANGED JSON_NEW"
# Counts only JSON files in vignettes/data/ and inst/extdata/, because parquets
# in inst/extdata/telemetry/v1/ regenerate to byte-different output even when
# the underlying data is identical (parquet header timestamps).
semantic_jsons_changed() {
  local repo="$1"
  local jc jn
  jc=$(git -C "$repo" diff --name-only -- 'vignettes/data/*.json' 'inst/extdata/*.json' 2>/dev/null | wc -l | tr -d ' ')
  jn=$(git -C "$repo" ls-files --others --exclude-standard -- 'vignettes/data/*.json' 'inst/extdata/*.json' 2>/dev/null | wc -l | tr -d ' ')
  echo "$jc $jn"
}

# discard_noisy_parquets REPO → unstage + revert v1 parquets so working tree is clean
discard_noisy_parquets() {
  local repo="$1"
  git -C "$repo" reset HEAD -- 'inst/extdata/telemetry/v1/' >/dev/null 2>&1 || true
  git -C "$repo" checkout -- 'inst/extdata/telemetry/v1/' >/dev/null 2>&1 || true
}

# record_stranded_run REPO CONFLICTED_FILES_NEWLINE_SEPARATED
record_stranded_run() {
  local repo="$1"
  local conflicts="$2"
  local n
  n=$(printf '%s\n' "$conflicts" | grep -c . || true)
  mkdir -p "$(dirname "$STRANDED_LOG")"
  {
    printf '%s repo=%s conflicts=%s files=[' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$repo" "$n"
    printf '%s' "$conflicts" | tr '\n' ' '
    printf ']\n'
  } >> "$STRANDED_LOG"
}

# run_rscript_with_nix REPO SCRIPT TIMEOUT
# Runs Rscript SCRIPT in REPO. If Rscript is not on PATH, wraps via nix-shell
# REPO/default.nix (same pattern as the rollup step). Returns Rscript's exit code.
run_rscript_with_nix() {
  local repo="$1" script="$2" t="$3"
  if command -v Rscript >/dev/null 2>&1; then
    (cd "$repo" && timeout "$t" Rscript "$script" 2>&1) | tail -5
    return "${PIPESTATUS[0]}"
  fi
  if [ -f "$repo/default.nix" ] && command -v nix-shell >/dev/null 2>&1; then
    (cd "$repo" && timeout "$t" nix-shell "$repo/default.nix" --run "Rscript '$script'" 2>&1) | tail -5
    return "${PIPESTATUS[0]}"
  fi
  echo "TELEMETRY: ERROR — Rscript not on PATH and no usable default.nix; cannot run $script" >&2
  return 127
}

# ─── Selftest ────────────────────────────────────────────────────────────────

if [ "${CLAUDE_HOOK_SELFTEST:-0}" = "1" ]; then
  set -e
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  git init -q "$TMP"
  git -C "$TMP" config user.email selftest@local
  git -C "$TMP" config user.name selftest
  mkdir -p "$TMP/vignettes/data" "$TMP/inst/extdata/telemetry/v1"
  echo '[]' > "$TMP/vignettes/data/sample.json"
  printf 'BASELINE-PARQUET-BYTES' > "$TMP/inst/extdata/telemetry/v1/sample.parquet"
  git -C "$TMP" add -A
  git -C "$TMP" commit -q -m baseline

  # Case 1: noisy parquet change, zero JSON change → should report 0 0
  printf 'CHANGED-PARQUET-BYTES' > "$TMP/inst/extdata/telemetry/v1/sample.parquet"
  git -C "$TMP" add 'inst/extdata/telemetry/v1/sample.parquet'
  read -r jc jn <<< "$(semantic_jsons_changed "$TMP")"
  if [ "$jc" -ne 0 ] || [ "$jn" -ne 0 ]; then
    echo "FAIL case 1: expected jc=0 jn=0, got jc=$jc jn=$jn" >&2; exit 1
  fi
  discard_noisy_parquets "$TMP"
  if ! git -C "$TMP" diff --quiet HEAD; then
    echo "FAIL case 1: working tree not clean after discard_noisy_parquets" >&2
    git -C "$TMP" status --short >&2
    exit 1
  fi
  echo "PASS case 1: noisy parquet alone yields jc=0 jn=0 and discard cleans tree"

  # Case 2: JSON content change → jc=1
  echo '[{"k":1}]' > "$TMP/vignettes/data/sample.json"
  read -r jc jn <<< "$(semantic_jsons_changed "$TMP")"
  if [ "$jc" -ne 1 ] || [ "$jn" -ne 0 ]; then
    echo "FAIL case 2: expected jc=1 jn=0, got jc=$jc jn=$jn" >&2; exit 1
  fi
  echo "PASS case 2: JSON content change yields jc=1 jn=0"
  git -C "$TMP" checkout -- 'vignettes/data/sample.json'

  # Case 3: new untracked JSON → jn=1
  echo '[]' > "$TMP/vignettes/data/new.json"
  read -r jc jn <<< "$(semantic_jsons_changed "$TMP")"
  if [ "$jc" -ne 0 ] || [ "$jn" -ne 1 ]; then
    echo "FAIL case 3: expected jc=0 jn=1, got jc=$jc jn=$jn" >&2; exit 1
  fi
  echo "PASS case 3: new JSON file yields jc=0 jn=1"
  rm -f "$TMP/vignettes/data/new.json"

  # Case 4: stranded-run logger writes a line with the expected shape
  STRANDED_LOG=$(mktemp)
  record_stranded_run "$TMP" $'a.json\nb.json'
  if ! grep -qE 'repo=.* conflicts=2 files=\[a\.json b\.json ?\]' "$STRANDED_LOG"; then
    echo "FAIL case 4: stranded-run log line malformed:" >&2
    cat "$STRANDED_LOG" >&2
    exit 1
  fi
  echo "PASS case 4: stranded-run logger writes well-formed line"
  rm -f "$STRANDED_LOG"

  # Case 5: quoted pathspec git-add stages JSON from a repo regardless of cwd (#311)
  TMP2=$(mktemp -d)
  trap 'rm -rf "$TMP" "$TMP2"' EXIT
  git init -q "$TMP2"
  git -C "$TMP2" config user.email selftest@local
  git -C "$TMP2" config user.name selftest
  mkdir -p "$TMP2/vignettes/data" "$TMP2/inst/extdata"
  git -C "$TMP2" commit -q --allow-empty -m baseline
  echo '[]' > "$TMP2/vignettes/data/unified_costs.json"
  echo '{}' > "$TMP2/inst/extdata/cmonitor_xcheck_daily.json"
  # Run add with quoted pathspecs from an unrelated cwd (/tmp)
  (cd /tmp && git -C "$TMP2" add -- 'vignettes/data/*.json' 'inst/extdata/*.json')
  staged=$(git -C "$TMP2" diff --cached --name-only | wc -l | tr -d ' ')
  if [ "$staged" -ne 2 ]; then
    echo "FAIL case 5: expected 2 staged files, got $staged" >&2
    git -C "$TMP2" diff --cached --name-only >&2
    exit 1
  fi
  echo "PASS case 5: quoted pathspec stages both JSON globs from unrelated cwd"

  echo "SELFTEST: 5/5 PASS"
  exit 0
fi

# ─── Main path ───────────────────────────────────────────────────────────────

# Quick check: is the repo available?
if [ ! -d "$TELEMETRY_REPO/.git" ]; then
  echo "TELEMETRY: repo not found at $TELEMETRY_REPO"
  exit 0
fi

# Check if export script exists
if [ ! -f "$EXPORT_SCRIPT" ]; then
  echo "TELEMETRY: export script not found"
  exit 0
fi

# Refresh config_staleness view in unified.duckdb (llm#630) — non-fatal
SKILL_ETL="$HOME/.claude/scripts/skill_usage_etl.R"
if [ -f "$SKILL_ETL" ] && [ -f "$HOME/.claude/logs/unified.duckdb" ]; then
  echo "TELEMETRY: refreshing config_staleness (skill_usage_etl.R --apply)..."
  timeout 60 Rscript "$SKILL_ETL" --apply 2>&1 | tail -3 || \
    echo "TELEMETRY: skill_usage_etl.R failed (non-fatal) — config_staleness may be stale"
fi

# Run export (from repo root so here::here() works). Sub-bug B fix:
# wrap via nix-shell when Rscript is not on PATH (was silently degrading).
echo "TELEMETRY: exporting dashboard data..."
if ! run_rscript_with_nix "$TELEMETRY_REPO" "$EXPORT_SCRIPT" 600; then
  echo "TELEMETRY: export step failed — aborting; not pushing"
  exit 1
fi

# Regenerate v1 parquets from the just-written JSON + drain staging (#210, #83)
# Non-fatal: log on failure so the existing export/commit still proceeds.
if [ -f "$ROLLUP_SCRIPT" ]; then
  echo "TELEMETRY: regenerating v1 parquets (run_rollup.R)..."
  if (cd "$TELEMETRY_REPO" && nix-shell "$TELEMETRY_REPO/default.nix" --run "Rscript '$ROLLUP_SCRIPT'" 2>&1) | tail -3; then
    # Stage regenerated parquets so they are included in the commit below
    git -C "$TELEMETRY_REPO" add inst/extdata/telemetry/v1/*.parquet 2>/dev/null || true
  else
    echo "TELEMETRY: run_rollup.R failed (non-fatal) — parquets not updated"
  fi
else
  echo "TELEMETRY: run_rollup.R not found — skipping parquet regeneration"
fi

# Sub-bug A fix: SEMANTIC change check (JSON only). Parquets regenerate to
# byte-different output even with identical data — we must not push when the
# only "change" is parquet header noise (was the race trigger for #287).
read -r JSON_CHANGED JSON_NEW <<< "$(semantic_jsons_changed "$TELEMETRY_REPO")"
CHANGED=$(git -C "$TELEMETRY_REPO" diff --name-only -- vignettes/data/ inst/extdata/telemetry/v1/ 2>/dev/null | wc -l | tr -d ' ')
UNTRACKED=$(git -C "$TELEMETRY_REPO" ls-files --others --exclude-standard -- vignettes/data/ inst/extdata/telemetry/v1/ 2>/dev/null | wc -l | tr -d ' ')
STAGED=$(git -C "$TELEMETRY_REPO" diff --cached --name-only -- inst/extdata/telemetry/v1/ 2>/dev/null | wc -l | tr -d ' ')

if [ "$JSON_CHANGED" -eq 0 ] && [ "$JSON_NEW" -eq 0 ]; then
  echo "TELEMETRY: 0 semantic JSON changes (CHANGED=$CHANGED UNTRACKED=$UNTRACKED STAGED=$STAGED) — discarding noisy parquet diffs and exiting"
  discard_noisy_parquets "$TELEMETRY_REPO"
  exit 0
fi

echo "TELEMETRY: $CHANGED changed, $UNTRACKED new data files, $STAGED staged parquets (JSON: $JSON_CHANGED changed, $JSON_NEW new)"

# ── Pull-rebase before push (JohnGavin/llmtelemetry#262) ──
echo "TELEMETRY: rebasing onto origin/main before push..."
if ! git -C "$TELEMETRY_REPO" fetch origin main 2>&1 | tail -3; then
  echo "TELEMETRY: fetch failed — skipping push (data committed locally)"
  exit 0
fi
if ! git -C "$TELEMETRY_REPO" pull --rebase --autostash origin main 2>&1 | tail -3; then
  echo "TELEMETRY: rebase conflict — aborting; bailing out without pushing"
  # #287 acceptance: log conflicted files + record stranded run for visibility
  CONFLICTS=$(git -C "$TELEMETRY_REPO" diff --name-only --diff-filter=U 2>/dev/null || true)
  if [ -n "$CONFLICTS" ]; then
    echo "TELEMETRY: conflicted files:"
    printf '  %s\n' $CONFLICTS
  fi
  record_stranded_run "$TELEMETRY_REPO" "$CONFLICTS"
  git -C "$TELEMETRY_REPO" rebase --abort 2>/dev/null || true
  exit 0
fi

# Commit data-only changes.
# Quote pathspecs so git expands globs relative to $TELEMETRY_REPO, not the
# caller's cwd. Also stages inst/extdata/*.json (e.g. cmonitor_xcheck_daily.json
# from llmtelemetry#312) which semantic_jsons_changed detected but was never staged
# before this fix (#311).
git -C "$TELEMETRY_REPO" add -- 'vignettes/data/*.json' 'inst/extdata/*.json'
git -C "$TELEMETRY_REPO" commit -m "data: update telemetry data $(date +%Y-%m-%d)

Auto-exported from local sources (predictions, unified.duckdb, cmonitor-rs).
v1 parquets regenerated by run_rollup.R (#210).
Triggered by session-end hook." --no-verify 2>/dev/null

if [ $? -eq 0 ]; then
  # Push (triggers CI deploy)
  git -C "$TELEMETRY_REPO" push 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "TELEMETRY: data pushed, CI will deploy"
  else
    echo "TELEMETRY: push failed (network?), data committed locally"
  fi
else
  echo "TELEMETRY: nothing to commit"
fi
