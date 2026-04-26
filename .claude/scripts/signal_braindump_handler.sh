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
touch "$PROCESSED_LOG"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

# Check daemon is running
if ! curl -sf "$SIGNAL_HTTP/api/v1/about" >/dev/null 2>&1; then
  # Daemon not running — fall back to direct receive
  log "Daemon not available, falling back to direct receive"
  export JAVA_HOME="/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home"
  export PATH="$JAVA_HOME/bin:/opt/homebrew/bin:$PATH"
  SIGNAL_CLI="/opt/homebrew/Cellar/signal-cli/0.14.2/libexec/bin/signal-cli"
  MESSAGES=$(timeout 30 "$SIGNAL_CLI" -a "$ACCOUNT" --output=json receive 2>/dev/null || echo "")
  if [ -z "$MESSAGES" ]; then
    # Still process any unprocessed audio files
    :
  else
    echo "$MESSAGES" > /tmp/signal_messages_$$.json
  fi
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
process_daemon_messages() {
  local stdout_log="/tmp/signal_cli_daemon_stdout.log"
  local last_pos_file="$HOME/.claude/logs/.signal_daemon_pos"
  [ -f "$stdout_log" ] || return

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
