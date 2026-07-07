#!/usr/bin/env bash
# log_command_use.sh — Stage slash-command invocations for command_usage
# instrumentation. Hook: UserPromptSubmit in settings.json.
#
# Card 1e (own-your-context plan, #745). skill_usage (Card 1b, #729/#744)
# captures invocations of the `Skill` tool, but Claude Code slash commands
# (/bye, /check, /cleanup, /issue-triage, ...) are NOT logged as Skill
# tool_use blocks. Investigation of real transcripts under
# ~/.claude/projects/*/*.jsonl (2026-07-07) found two distinct mechanisms:
#
#   1. Built-in commands (e.g. /model, /usage, /exit) are recorded as a
#      plain "user" turn whose `message.content` is a STRING containing
#      `<command-name>/x</command-name>` (+ optional <command-args>).
#   2. Project/user *custom* commands — the ones this card cares about,
#      e.g. /bye (~/.claude/commands/bye.md), /issue-triage,
#      /cleanup-worktrees — instead produce a top-level
#      `{"type":"attachment","attachment":{"type":"invoked_skills",
#      "skills":[{"name":"bye","path":"userSettings:bye","content":"..."}]}}`
#      record. This is the "bare tool name" signal referenced in #745: the
#      command name appears bare (not wrapped in a "Skill" tool_use block).
#      Confirmed empirically: /issue-triage (a pure custom command with no
#      built-in override) produces ONLY the invoked_skills record — no
#      <command-name> tag at all. See backfill_command_usage.R for the
#      corresponding historical parser of that record shape.
#
# Neither of those records is available at UserPromptSubmit time (Claude
# Code hasn't resolved/loaded the command file yet) — but the RAW prompt
# text the user just typed IS available then, as `/name args...`. This hook
# captures that raw text at submission time so every slash-command
# invocation is captured going forward, independent of which downstream
# transcript shape it later produces.
#
# Field-name caveat: the exact stdin field carrying the prompt text is not
# fully pinned down for this Claude Code version from static docs alone —
# a generic plugin-dev skill doc and the shipped `hookify` plugin
# (core/rule_engine.py: `input_data.get('user_prompt', '')`) both name it
# `user_prompt`, so that is tried first, with `.prompt` as a defensive
# fallback. Recommended follow-up (documented in the PR): once installed,
# invoke a real slash command and confirm a row lands in
# command_usage_staging.jsonl.
#
# CONCURRENCY: mirrors log_skill_use.sh — no duckdb CLI here (a hot loop of
# UserPromptSubmit events must not contend for the exclusive write lock on
# unified.duckdb). Append one JSON line per event to an append-only staging
# file (each printf/>> is an atomic kernel write <= PIPE_BUF).
# command_usage_staging_import.sh drains this file into the command_usage
# table on the existing roborev-metrics-etl schedule.
#
# Reads the hook payload as JSON on stdin. ALWAYS exits 0 — must never
# block prompt submission.
set -uo pipefail

_staging="$HOME/.claude/logs/command_usage_staging.jsonl"
mkdir -p "$(dirname "$_staging")" 2>/dev/null || true

_sid=""
if [ -f "$HOME/.claude/logs/.current_session" ]; then
  _sid=$(cat "$HOME/.claude/logs/.current_session" 2>/dev/null || echo "")
fi
[ -n "$_sid" ] || _sid="unknown"

_input=$(cat 2>/dev/null || echo "")   # consume stdin once

_jq() { echo "$_input" | jq -r "$1" 2>/dev/null || echo ""; }

# Detectable-failure signal (#747 review): the stdin field name carrying the
# prompt text (user_prompt / prompt) was inferred from a generic plugin doc,
# not a confirmed live payload shape. If that inference is wrong, extraction
# below silently returns empty forever with no way to notice. When a
# genuinely non-empty payload yields nothing, leave a throttled trace of its
# top-level keys so the failure is diagnosable. Override path for tests.
_debug_log="${CMD_USE_DEBUG_LOG:-$HOME/.claude/logs/command_use_debug.log}"
_log_unrecognized_payload() {
  mkdir -p "$(dirname "$_debug_log")" 2>/dev/null || true
  # Throttle to at most once per hour so a persistently-wrong field name
  # doesn't spam the log on every keystroke-driven prompt submission.
  if [ -f "$_debug_log" ] && [ -n "$(find "$_debug_log" -mmin -60 2>/dev/null)" ]; then
    return 0
  fi
  local _keys
  if command -v jq >/dev/null 2>&1; then
    _keys=$(echo "$_input" | jq -r 'keys | join(",")' 2>/dev/null || echo "")
  else
    _keys="jq-unavailable"
  fi
  printf '%s unrecognized UserPromptSubmit payload; top-level keys=[%s]\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')" "$_keys" \
    >> "$_debug_log" 2>/dev/null || true
}

if [ -n "$_input" ] && command -v jq >/dev/null 2>&1; then
  _prompt=$(_jq '.user_prompt // .prompt // empty')
else
  # Legacy fallback: crude grep extraction when jq is unavailable.
  _prompt=$(echo "$_input" | grep -o '"user_prompt":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ -n "$_prompt" ] || _prompt=$(echo "$_input" | grep -o '"prompt":"[^"]*"' | head -1 | cut -d'"' -f4)
fi

if [ -z "$_prompt" ]; then
  [ -n "$_input" ] && _log_unrecognized_payload
  exit 0   # no prompt text — nothing to inspect
fi

# Strip leading whitespace, then require the FIRST character to be '/'
# followed by a letter (excludes absolute paths like "/Users/..." typed as
# plain text, since those continue with another "/" rather than whitespace
# or end-of-string after the leading token).
_trimmed=$(printf '%s' "$_prompt" | sed -e 's/^[[:space:]]*//')
# Require the command token to be followed by whitespace or end-of-string —
# NOT another "/" — so a typed absolute path (e.g. "/Users/johngavin/...")
# is never mistaken for a slash-command invocation.
if ! printf '%s' "$_trimmed" | grep -Eq '^/[A-Za-z][A-Za-z0-9_-]*([[:space:]]|$)'; then
  exit 0
fi

_command=$(printf '%s' "$_trimmed" | grep -Eo '^/[A-Za-z][A-Za-z0-9_-]*' | sed 's#^/##')
[ -n "$_command" ] || exit 0

_proj="$(pwd)"

# False-positive guard (#747 review): the regex above matches any leading
# "/word" token, so a prompt like "/tmp needs cleaning" or "/etc is broken"
# (a typed absolute path, not a command invocation) would otherwise stage a
# bogus "tmp"/"etc" command. Require the extracted name to correspond to an
# installed command file — user-level (~/.claude/commands/) or project-level
# (<cwd>/.claude/commands/) — before staging anything. This intentionally
# narrows capture to file-backed custom commands; unrecognized names
# (including Claude Code built-ins with no .md file) are silently ignored.
if [ ! -f "$HOME/.claude/commands/${_command}.md" ] && \
   [ ! -f "$_proj/.claude/commands/${_command}.md" ]; then
  exit 0
fi

_rest=$(printf '%s' "$_trimmed" | sed -E 's#^/[A-Za-z][A-Za-z0-9_-]*##')
_args=$(printf '%s' "$_rest" | sed -E 's/^[[:space:]]+//')

_ts=$(date -u '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')

# args_hash: short non-reversible fingerprint of the args string, same
# privacy stance as log_skill_use.sh — never store the args text itself.
_args_hash=""
if [ -n "$_args" ] && command -v shasum >/dev/null 2>&1; then
  _args_hash=$(printf '%s' "$_args" | shasum -a 256 | cut -c1-16)
fi

# JSON-escape (same convention as log_skill_use.sh / log_session.sh).
_esc() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}
_command_esc=$(_esc "$_command")
_proj_esc=$(_esc "$_proj")
_sid_esc=$(_esc "$_sid")

printf '{"ts":"%s","session_id":"%s","command_name":"%s","project_path":"%s","args_hash":"%s"}\n' \
  "$_ts" "$_sid_esc" "$_command_esc" "$_proj_esc" "$_args_hash" \
  >> "$_staging" 2>/dev/null || true

exit 0
