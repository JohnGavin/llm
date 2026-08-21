#!/usr/bin/env bash
# signal_braindump_handler.sh — Event-driven braindump processing
# Triggered by launchd WatchPaths on signal-cli attachments directory
# OR run periodically to catch up on any missed messages.
#
# Requires: signal-cli daemon running on localhost:7583 (com.johngavin.signal-cli-daemon)
# Requires: whisper (from Nix shell)

set -uo pipefail

# Source Nix for whisper/PyTorch — need BOTH daemon (nix-store) and user profile
for _nix_script in \
  "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" \
  "$HOME/.nix-profile/etc/profile.d/nix.sh"; do
  [ -e "$_nix_script" ] && . "$_nix_script"
done

# Shared SIGKILL-escalating timeout wrapper + stale-process guard (llm#957).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_signal_process_guard.sh
. "$SCRIPT_DIR/lib_signal_process_guard.sh"

ATTACH_DIR="$HOME/.local/share/signal-cli/attachments"
DUMP_DIR="$HOME/docs_gh/llm/knowledge/raw/braindumps"
DB="$HOME/.claude/logs/unified.duckdb"
LOG="$HOME/.claude/logs/signal_sync.log"
PROCESSED_LOG="$HOME/.claude/logs/whisper_processed.txt"
SIGNAL_HTTP="http://localhost:7583"
ACCOUNT="+447521254904"

# Find whisper: check PATH first, then known Nix store location
WHISPER_BIN=$(command -v whisper 2>/dev/null)
if [ -z "$WHISPER_BIN" ]; then
  WHISPER_BIN=$(find /nix/store -maxdepth 3 -path "*/bin/whisper" -type f 2>/dev/null | head -1)
  # Add its directory to PATH so Python subprocess can find torch etc.
  [ -n "$WHISPER_BIN" ] && export PATH="$(dirname "$WHISPER_BIN"):$PATH"
fi
WHISPER_MODEL="small"
WHISPER_PROMPT="duckplyr Nix rix dagitty targets Quarto DuckDB Parquet bslib tidyverse pkgdown Claude signal-cli whisper"

mkdir -p "$DUMP_DIR"
mkdir -p "$(dirname "$LOG")"
touch "$PROCESSED_LOG"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

# Check daemon is running (check if port is listening, not HTTP API which
# returns 404). Wrapped via _signal_daemon_listening (LSOF_BIN overridable)
# so this branch is testable without binding the real port.
if ! _signal_daemon_listening 7583; then
  # Daemon not running — fall back to direct receive.
  log "Daemon not listening on 7583, falling back to direct receive"

  # Refuse to start if a signal-cli receive is already running (stale-lock
  # guard, llm#957). We never kill it automatically — killing mid-`receive`
  # can consume-and-discard messages server-side — only refuse and log
  # loudly so it shows up in the health report's stale-process section.
  if _signal_cli_already_running "signal-cli.*receive"; then
    log "REFUSED: signal-cli receive already running — not starting a second receive (stale-process guard, llm#957)"
    exit 0
  fi

  export JAVA_HOME="/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home"
  export PATH="$JAVA_HOME/bin:/opt/homebrew/bin:$PATH"
  # Version-STABLE path (llm#937): /opt/homebrew/bin/signal-cli is the
  # symlink Homebrew repoints on upgrade. A hardcoded Cellar version
  # directory (this used to read
  # "/opt/homebrew/Cellar/signal-cli/0.14.3_1/bin/signal-cli") stops
  # existing on the next `brew upgrade` and silently degrades to the same
  # "command not found" -> empty-message-list failure mode already fixed in
  # signal_notes_sync.sh.
  SIGNAL_CLI="${SIGNAL_CLI:-/opt/homebrew/bin/signal-cli}"
  if [ ! -x "$SIGNAL_CLI" ]; then
    log "FATAL: signal-cli not executable at $SIGNAL_CLI"
    exit 1
  fi

  # Two layers of timeout guard this call (llm#957):
  #   -t 20   signal-cli's OWN internal timeout — lets it exit cleanly
  #           before the external wrapper ever needs to intervene.
  #   30/10   _bounded_kill's external timeout/kill-grace — SIGTERM at 30s,
  #           SIGKILL at 40s if still alive (see lib_signal_process_guard.sh
  #           for why bare `timeout N` cannot actually kill signal-cli).
  # llm#937/#957: distinguish "receive failed" from "no new messages" (same
  # treatment as signal_notes_sync.sh) — stderr is captured rather than
  # discarded so the reason survives into the log.
  _recv_err=$(mktemp)
  _recv_rc=0
  MESSAGES=$(_bounded_kill 30 10 "$SIGNAL_CLI" -a "$ACCOUNT" --output=json receive -t 20 2>"$_recv_err") || _recv_rc=$?
  if [ "$_recv_rc" -ne 0 ]; then
    log "RECEIVE FAILED rc=$_recv_rc: $(head -c 300 "$_recv_err" | tr '\n' ' ')"
    rm -f "$_recv_err"
    # A failed receive is NOT "no new messages" — skip the message-handling
    # block entirely so the two cases stay distinguishable in the log
    # (llm#937/#957: these used to collapse into the same empty string).
    MESSAGES=""
    _recv_ok=0
  else
    rm -f "$_recv_err"
    _recv_ok=1
  fi

  if [ "${_recv_ok:-0}" -eq 0 ]; then
    :  # already logged RECEIVE FAILED above; nothing further to do here
  elif [ -z "$MESSAGES" ]; then
    log "Direct receive: no new messages"
  else
    echo "$MESSAGES" > "/tmp/signal_messages_$$.json"
    # Fix (llm#957): this JSON used to be written to a temp file and never
    # read again — a genuine silent-drop path (text messages received while
    # the daemon was down were captured but never ingested). Parse and
    # ingest exactly as process_daemon_messages() does for the daemon path.
    echo "$MESSAGES" | python3 -c "
import sys, json, os, subprocess
from datetime import datetime

dump_dir = '$DUMP_DIR'
db_path = '$DB'
account = '$ACCOUNT'

for line in sys.stdin:
    line = line.strip()
    if not line or not line.startswith('{'):
        continue
    try:
        msg = json.loads(line)
        env = msg.get('envelope', {})
        sync = env.get('syncMessage', {})
        sent = sync.get('sentMessage', {})
        if not sent:
            continue

        dest = sent.get('destinationNumber', sent.get('destination', ''))
        if dest and dest != account:
            continue

        ts = env.get('timestamp', 0) / 1000
        dt = datetime.fromtimestamp(ts) if ts > 0 else datetime.now()

        body = sent.get('message', '')
        if body:
            filename = f\"{dump_dir}/{dt.strftime('%Y-%m-%d-%H%M%S')}-signal.md\"
            with open(filename, 'w') as f:
                f.write(f'# Signal Notes - {dt:%Y-%m-%d %H:%M}\n\n')
                f.write('Source: Signal Notes chat (direct receive fallback)\n\n')
                f.write(body + '\n')
            escaped = body.replace(\"'\", \"''\")[:500]
            subprocess.run(['duckdb', db_path, '-c',
                f\"INSERT INTO braindumps (source, raw_text, captured_at) SELECT 'signal_notes', '{escaped}', '{dt:%Y-%m-%d %H:%M:%S}'::TIMESTAMP WHERE NOT EXISTS (SELECT 1 FROM braindumps WHERE source='signal_notes' AND raw_text='{escaped}');\"],
                capture_output=True)
            print(f'Text: {filename}')

    except (json.JSONDecodeError, KeyError, ValueError):
        continue
" 2>>"$LOG" || true
    rm -f "/tmp/signal_messages_$$.json"
  fi
else
  # Daemon IS listening. Text-message collection happens below via
  # process_daemon_messages() (tails the daemon's stdout log). This `else`
  # branch existing at all closes the llm#957 gap where the daemon-up case
  # previously fell through this whole block with nothing assigned or
  # logged — a silent no-op that looked like "no new messages" forever.
  log "Daemon listening on 7583 — text messages collected via process_daemon_messages() (daemon stdout tail)"
fi

# Process any new audio attachments (voice messages)
transcribe_audio() {
  local audio_file="$1"
  local base=$(basename "$audio_file")

  # Skip if already processed
  grep -qF "$base" "$PROCESSED_LOG" 2>/dev/null && return 0

  if [ -z "$WHISPER_BIN" ]; then
    log "Whisper not found, skipping $base"
    echo "$base" >> "$PROCESSED_LOG"
    return 1
  fi

  log "Transcribing: $base"
  local txt_dir=$(mktemp -d)
  timeout 120 "$WHISPER_BIN" "$audio_file" --model "$WHISPER_MODEL" --language en \
    --output_format txt --output_dir "$txt_dir" \
    --initial_prompt "$WHISPER_PROMPT" 2>>"$LOG" || {
    log "Whisper failed on $base"
    echo "$base" >> "$PROCESSED_LOG"
    rm -rf "$txt_dir"
    return 1
  }

  local txt_file=$(find "$txt_dir" -name "*.txt" -type f | head -1)
  if [ -n "$txt_file" ] && [ -s "$txt_file" ]; then
    local text=$(cat "$txt_file")
    local now=$(date '+%Y-%m-%d-%H%M%S')
    local out="$DUMP_DIR/${now}-voice-${base%.*}.md"

    cat > "$out" <<HEREDOC
# Signal Voice Note - $(date '+%Y-%m-%d %H:%M')

Source: Signal voice message (whisper $WHISPER_MODEL)
Audio: $base

$text
HEREDOC

    # Insert to DuckDB with dedup (raw_text only — processing happens later per #88)
    local escaped=$(echo "$text" | head -c 500 | sed "s/'/''/g")
    duckdb "$DB" -c "
      INSERT INTO braindumps (source, raw_text, captured_at)
      SELECT 'signal_voice', '$escaped', current_timestamp
      WHERE NOT EXISTS (
        SELECT 1 FROM braindumps WHERE source='signal_voice' AND raw_text='$escaped'
      );" 2>/dev/null || true

    log "Transcribed: $base -> $out"
  fi

  echo "$base" >> "$PROCESSED_LOG"
  rm -rf "$txt_dir"
}

# Process text messages from daemon stdout log (if daemon is running)
#
# KNOWN GAP (llm#957): this function's correctness depends on the signal-cli
# daemon (com.johngavin.signal-cli-daemon, a local-only unversioned
# launchd plist per the queued-issues README) actually writing received
# message envelopes as JSON lines to $stdout_log. Probing the daemon's
# JSON-RPC socket on :7583 during this fix returned an empty response, so
# the exact request/response shape used by the daemon path could not be
# confirmed without invoking `receive` against the live account, which is
# out of scope for this change. Rather than guess a protocol and leave this
# looking implemented, the missing-log case below is logged loudly instead
# of silently returning, so a real gap is visible in $LOG rather than
# masquerading as "no new messages" (the exact llm#937 failure mode this
# whole family of fixes exists to prevent). Follow-up: confirm the daemon's
# actual stdout/JSON-RPC contract and either validate this path or replace
# it with a JSON-RPC client call.
process_daemon_messages() {
  local stdout_log="/tmp/signal_cli_daemon_stdout.log"
  local last_pos_file="$HOME/.claude/logs/.signal_daemon_pos"
  if [ ! -f "$stdout_log" ]; then
    log "GAP: daemon stdout log not found at $stdout_log — daemon-path message collection is unverified for this run (llm#957 follow-up needed, see comment above process_daemon_messages)"
    return
  fi

  # Track position to avoid reprocessing
  local last_pos=0
  [ -f "$last_pos_file" ] && last_pos=$(cat "$last_pos_file")
  local current_size=$(wc -c < "$stdout_log" 2>/dev/null || echo 0)
  current_size=$(echo "$current_size" | tr -d ' ')

  [ "$current_size" -le "$last_pos" ] && return

  # Read new lines since last position
  tail -c "+$((last_pos + 1))" "$stdout_log" 2>/dev/null | python3 -c "
import sys, json, os, subprocess
from datetime import datetime

dump_dir = '$DUMP_DIR'
db_path = '$DB'
account = '$ACCOUNT'

for line in sys.stdin:
    line = line.strip()
    if not line or not line.startswith('{'):
        continue
    try:
        msg = json.loads(line)
        env = msg.get('envelope', {})
        sync = env.get('syncMessage', {})
        sent = sync.get('sentMessage', {})
        if not sent:
            continue

        dest = sent.get('destinationNumber', sent.get('destination', ''))
        if dest and dest != account:
            continue

        ts = env.get('timestamp', 0) / 1000
        dt = datetime.fromtimestamp(ts) if ts > 0 else datetime.now()

        # Handle text
        body = sent.get('message', '')
        if body:
            filename = f\"{dump_dir}/{dt.strftime('%Y-%m-%d-%H%M%S')}-signal.md\"
            with open(filename, 'w') as f:
                f.write(f'# Signal Notes - {dt:%Y-%m-%d %H:%M}\n\n')
                f.write(f'Source: Signal Notes chat\n\n')
                f.write(body + '\n')
            escaped = body.replace(\"'\", \"''\")[:500]
            subprocess.run(['duckdb', db_path, '-c',
                f\"INSERT INTO braindumps (source, raw_text, captured_at) SELECT 'signal_notes', '{escaped}', '{dt:%Y-%m-%d %H:%M:%S}'::TIMESTAMP WHERE NOT EXISTS (SELECT 1 FROM braindumps WHERE source='signal_notes' AND raw_text='{escaped}');\"],
                capture_output=True)
            print(f'Text: {filename}')

    except (json.JSONDecodeError, KeyError, ValueError):
        continue
" 2>>"$LOG" || true

  # Update position
  echo "$current_size" > "$last_pos_file"
}

# --- Main ---

# 1. Process daemon stdout for text messages
process_daemon_messages

# 2. Process any new audio attachments
for aac in "$ATTACH_DIR"/*.aac "$ATTACH_DIR"/*.ogg "$ATTACH_DIR"/*.opus "$ATTACH_DIR"/*.m4a; do
  [ -f "$aac" ] || continue
  transcribe_audio "$aac"
done

exit 0
