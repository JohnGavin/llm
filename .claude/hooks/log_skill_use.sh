#!/usr/bin/env bash
# log_skill_use.sh — Stage Skill-tool invocations for skill_usage instrumentation.
# Hook: PostToolUse(Skill) in settings.json.
#
# Card 1b (own-your-context plan): skill_usage had only ~29 rows against 3,783
# sessions because the only path into the table was a nightly ETL scanning
# raw JSONL transcripts (skill_usage_etl.R/.sh) for a narrow literal-match
# pattern. This hook adds a REAL-TIME forward path so every Skill invocation
# is captured going forward, independent of that nightly batch scan.
#
# CONCURRENCY (mirrors log_session.sh's `hook` case, #710): do NOT open the
# duckdb CLI here — a busy session firing many tool calls per minute would
# contend for the exclusive write lock on unified.duckdb. Instead append one
# JSON line per event to an append-only staging file (each printf/>> is an
# atomic kernel write <= PIPE_BUF). skill_usage_staging_import.sh drains this
# file into the skill_usage table on the existing roborev-metrics-etl launchd
# schedule (see roborev_metrics_etl.sh).
#
# Reads the hook payload as JSON on stdin (modern interface). ALWAYS exits 0
# — must never block the Skill tool call.
set -uo pipefail

_staging="$HOME/.claude/logs/skill_usage_staging.jsonl"
mkdir -p "$(dirname "$_staging")" 2>/dev/null || true

_sid=""
if [ -f "$HOME/.claude/logs/.current_session" ]; then
  _sid=$(cat "$HOME/.claude/logs/.current_session" 2>/dev/null || echo "")
fi
[ -n "$_sid" ] || _sid="unknown"

_input=$(cat 2>/dev/null || echo "")   # consume stdin once

_jq() { echo "$_input" | jq -r "$1" 2>/dev/null || echo ""; }

if [ -n "$_input" ] && command -v jq >/dev/null 2>&1; then
  _skill=$(_jq '.tool_input.skill // empty')
  _args=$(_jq '.tool_input.args // empty')
else
  # Legacy fallback: crude grep extraction when jq is unavailable.
  _skill=$(echo "$_input" | grep -o '"skill":"[^"]*"' | head -1 | cut -d'"' -f4)
  _args=""
fi

[ -n "$_skill" ] || exit 0   # not a real Skill invocation (e.g. payload shape changed) — nothing to log

_proj="$(pwd)"
_ts=$(date -u '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')

# args_hash: short non-reversible fingerprint of the args string. We never
# store args content itself — only a fixed-length hash — so free-text skill
# args (which may reference private notes/paths) never land in the DB.
_args_hash=""
if [ -n "$_args" ] && command -v shasum >/dev/null 2>&1; then
  _args_hash=$(printf '%s' "$_args" | shasum -a 256 | cut -c1-16)
fi

# JSON-escape (backslash then double-quote; strip control chars that would
# break JSONL), same convention as log_session.sh's `hook` case.
_esc() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}
_skill_esc=$(_esc "$_skill")
_proj_esc=$(_esc "$_proj")
_sid_esc=$(_esc "$_sid")

printf '{"ts":"%s","session_id":"%s","skill_name":"%s","project_path":"%s","args_hash":"%s"}\n' \
  "$_ts" "$_sid_esc" "$_skill_esc" "$_proj_esc" "$_args_hash" \
  >> "$_staging" 2>/dev/null || true

exit 0
