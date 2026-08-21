#!/usr/bin/env bash
# signal_notes_sync.sh — Pull messages from Signal "Notes" chat into braindumps/
# Handles both text messages and voice messages (via whisper transcription)
# Runs via launchd every 5 minutes: com.johngavin.signal-notes-sync.plist
set -euo pipefail

export JAVA_HOME="/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home"
# Include Nix profile for whisper + its Python/PyTorch dependencies
if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
  . "$HOME/.nix-profile/etc/profile.d/nix.sh"
elif [ -e "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" ]; then
  . "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
fi
export PATH="$JAVA_HOME/bin:/opt/homebrew/bin:$PATH"

# Shared SIGKILL-escalating timeout wrapper + stale-process guard (llm#957).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_signal_process_guard.sh
. "$SCRIPT_DIR/lib_signal_process_guard.sh"

# Version-STABLE path (llm#937). This was pinned to the 0.14.2 Cellar directory;
# Homebrew upgraded signal-cli to 0.14.3_1 on 2026-05-10 12:03 and that directory
# ceased to exist. The `receive` below is wrapped in `2>/dev/null || echo ""`, so
# "command not found" became an empty message list — indistinguishable from "no
# new messages". Capture stopped silently at 11:54 the same morning; the job kept
# exiting 0 for three months.
# Never pin a Cellar version here: /opt/homebrew/bin/signal-cli is the symlink
# Homebrew repoints on upgrade.
SIGNAL_CLI="${SIGNAL_CLI:-/opt/homebrew/bin/signal-cli}"
if [ ! -x "$SIGNAL_CLI" ]; then
  mkdir -p "$HOME/.claude/logs"
  echo "$(date '+%Y-%m-%d %H:%M:%S') FATAL: signal-cli not executable at $SIGNAL_CLI" >> "$HOME/.claude/logs/signal_sync.log"
  exit 1
fi
ACCOUNT="+447521254904"
DUMP_DIR="$HOME/docs_gh/llm/knowledge/raw/braindumps"
ATTACH_DIR="$HOME/.local/share/signal-cli/attachments"
DB="$HOME/.claude/logs/unified.duckdb"
LOG="$HOME/.claude/logs/signal_sync.log"
PROCESSED_LOG="$HOME/.claude/logs/whisper_processed.txt"

# Whisper config
WHISPER_BIN=$(command -v whisper 2>/dev/null || find /nix/store -maxdepth 2 -name "whisper" -type f 2>/dev/null | head -1)
WHISPER_MODEL="small"
WHISPER_PROMPT="duckplyr Nix rix dagitty targets Quarto DuckDB Parquet bslib tidyverse pkgdown Claude signal-cli whisper"

mkdir -p "$DUMP_DIR"
mkdir -p "$(dirname "$LOG")"
touch "$PROCESSED_LOG"

# Skip the direct-receive call entirely when the daemon already holds the
# signal-cli config lock (llm#989). The pre-flight stale-process guard below
# only catches an in-flight `receive`; it does NOT catch a healthy,
# long-running daemon holding the lock permanently — which is exactly why a
# direct `receive` here collided with the daemon roughly every 5.5 minutes
# ("Config file is in use by another instance", rc=124 — see
# signal_sync.log entries 2026-08-21 18:54-20:22, immediately preceding the
# daemon coming up). This is a deliberate, expected skip, not a failure —
# logged as SKIP (not RECEIVE FAILED/FATAL) so it doesn't read like an error
# in the health report. The voice-attachment backlog scan below still runs
# even when skipped: it only reads files already on disk under ATTACH_DIR
# and never touches the signal-cli lock, so it stays safe and useful
# regardless of daemon state.
MESSAGES=""
if _signal_daemon_listening 7583; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') SKIP: daemon listening on 7583 — direct receive skipped, daemon path (signal_braindump_handler.sh) handles message collection" >> "$LOG"
else
  # Refuse to start if a signal-cli receive is already running (stale-lock
  # guard, llm#957). A prior run's `receive` that outlived its timeout wrapper
  # holds the signal-cli config lock, so a second `receive` here would simply
  # block behind it. We never kill the existing process automatically —
  # killing mid-`receive` can consume-and-discard messages server-side —
  # we only refuse and log loudly so the stale process is visible in the
  # health report (see launchd_health_report.R's stale-process section).
  if _signal_cli_already_running "signal-cli.*receive"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') REFUSED: signal-cli receive already running — not starting a second receive (stale-process guard, llm#957)" >> "$LOG"
    exit 0
  fi

  # Receive messages. Two layers of timeout now guard this call (llm#957):
  #   -t 20   signal-cli's OWN internal timeout — lets it exit cleanly before
  #           the external wrapper ever needs to intervene.
  #   30/10   _bounded_kill's external timeout/kill-grace — SIGTERM at 30s,
  #           SIGKILL at 40s if the process is still alive (signal-cli is known
  #           to log receipt of SIGTERM and then not actually exit — see
  #           lib_signal_process_guard.sh for the full incident writeup).
  # llm#937: distinguish "receive failed" from "no new messages". These were
  # previously the same empty string, which is how a dead binary path masqueraded
  # as three months of silence. stderr is captured rather than discarded so the
  # reason survives into the log.
  _recv_err=$(mktemp)
  MESSAGES=$(_bounded_kill 30 10 "$SIGNAL_CLI" -a "$ACCOUNT" --output=json receive -t 20 2>"$_recv_err") || _recv_rc=$?
  _recv_rc=${_recv_rc:-0}
  if [ "$_recv_rc" -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') RECEIVE FAILED rc=$_recv_rc: $(head -c 300 "$_recv_err" | tr '\n' ' ')" >> "$LOG"
    rm -f "$_recv_err"
    exit "$_recv_rc"
  fi
  rm -f "$_recv_err"
fi

if [ -z "$MESSAGES" ]; then
  # Even with no new messages, check for unprocessed voice attachments
  # (from messages received before whisper was wired up)
  if [ -n "$WHISPER_BIN" ]; then
    for aac in "$ATTACH_DIR"/*.aac "$ATTACH_DIR"/*.ogg "$ATTACH_DIR"/*.opus; do
      [ -f "$aac" ] || continue
      _base=$(basename "$aac")
      grep -qF "$_base" "$PROCESSED_LOG" 2>/dev/null && continue

      echo "$(date '+%Y-%m-%d %H:%M:%S') Transcribing backlog: $_base" >> "$LOG"
      _txt_dir=$(mktemp -d)
      timeout 120 "$WHISPER_BIN" "$aac" --model "$WHISPER_MODEL" --language en \
        --output_format txt --output_dir "$_txt_dir" \
        --initial_prompt "$WHISPER_PROMPT" 2>>"$LOG" || { echo "$_base" >> "$PROCESSED_LOG"; continue; }

      _txt_file=$(find "$_txt_dir" -name "*.txt" -type f | head -1)
      if [ -n "$_txt_file" ] && [ -s "$_txt_file" ]; then
        _text=$(cat "$_txt_file")
        _now=$(date '+%Y-%m-%d-%H%M%S')
        _out="$DUMP_DIR/${_now}-voice-${_base%.*}.md"
        {
          echo "# Signal Voice Note - $(date '+%Y-%m-%d %H:%M')"
          echo ""
          echo "Source: Signal voice message (whisper $WHISPER_MODEL)"
          echo "Audio: $_base"
          echo ""
          echo "$_text"
        } > "$_out"

        _escaped=$(echo "$_text" | head -c 500 | sed "s/'/''/g")
        duckdb "$DB" -c "INSERT INTO braindumps (source, raw_text, captured_at) VALUES ('signal_voice', '$_escaped', current_timestamp);" 2>/dev/null || true
        echo "$(date '+%Y-%m-%d %H:%M:%S') Backlog transcribed: $_base -> $_out" >> "$LOG"
      fi
      echo "$_base" >> "$PROCESSED_LOG"
      rm -rf "$_txt_dir"
    done
  fi
  exit 0
fi

# Process messages: extract text AND voice attachments from self-sent messages
echo "$MESSAGES" | python3 -c "
import sys, json, os, subprocess
from datetime import datetime

dump_dir = '$DUMP_DIR'
db_path = '$DB'
account = '$ACCOUNT'
attach_dir = '$ATTACH_DIR'
whisper_bin = '$WHISPER_BIN'
whisper_model = '$WHISPER_MODEL'
whisper_prompt = '$WHISPER_PROMPT'
processed_log = '$PROCESSED_LOG'
log_file = '$LOG'
saved = 0

def log(msg):
    with open(log_file, 'a') as f:
        f.write(f'{datetime.now():%Y-%m-%d %H:%M:%S} {msg}\n')

def insert_braindump(source, text, dt):
    escaped = text.replace(\"'\", \"''\")[:500]
    sql = f\"INSERT INTO braindumps (source, raw_text, captured_at) VALUES ('{source}', '{escaped}', '{dt:%Y-%m-%d %H:%M:%S}'::TIMESTAMP);\"
    subprocess.run(['duckdb', db_path, '-c', sql], capture_output=True)

def save_to_file(filename, title, source_desc, body):
    with open(filename, 'w') as f:
        f.write(f'# {title}\n\n')
        f.write(f'Source: {source_desc}\n\n')
        f.write(body + '\n')

def transcribe_audio(audio_path):
    \"\"\"Transcribe audio file with whisper. Returns text or None.\"\"\"
    if not whisper_bin or not os.path.isfile(audio_path):
        return None
    import tempfile
    txt_dir = tempfile.mkdtemp()
    try:
        result = subprocess.run(
            [whisper_bin, audio_path, '--model', whisper_model, '--language', 'en',
             '--output_format', 'txt', '--output_dir', txt_dir,
             '--initial_prompt', whisper_prompt],
            capture_output=True, timeout=120
        )
        # Find output .txt file
        for f in os.listdir(txt_dir):
            if f.endswith('.txt'):
                with open(os.path.join(txt_dir, f)) as tf:
                    return tf.read().strip()
    except (subprocess.TimeoutExpired, Exception) as e:
        log(f'Whisper failed on {audio_path}: {e}')
    finally:
        import shutil
        shutil.rmtree(txt_dir, ignore_errors=True)
    return None

# Track processed attachments
processed = set()
if os.path.isfile(processed_log):
    with open(processed_log) as f:
        processed = set(line.strip() for line in f)

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

        # Handle text body
        body = sent.get('message', '')
        if body:
            filename = f\"{dump_dir}/{dt.strftime('%Y-%m-%d-%H%M')}-signal.md\"
            save_to_file(filename, f'Signal Notes - {dt:%Y-%m-%d %H:%M}',
                        'Signal Notes chat', body)
            insert_braindump('signal_notes', body, dt)
            saved += 1
            log(f'Text saved: {filename}')

        # Handle voice/audio attachments
        attachments = sent.get('attachments', [])
        for att in attachments:
            content_type = att.get('contentType', '')
            att_id = att.get('id', '')
            att_filename = att.get('filename', '')

            if not content_type.startswith('audio/'):
                continue

            # Find the attachment file
            audio_path = None
            for ext in ['', '.aac', '.ogg', '.opus', '.m4a']:
                candidate = os.path.join(attach_dir, att_id + ext)
                if os.path.isfile(candidate):
                    audio_path = candidate
                    break
            # Also check without extension (signal-cli may use bare ID)
            if not audio_path:
                for f in os.listdir(attach_dir):
                    if att_id in f:
                        audio_path = os.path.join(attach_dir, f)
                        break

            if not audio_path:
                log(f'Audio attachment not found: {att_id} ({content_type})')
                continue

            base = os.path.basename(audio_path)
            if base in processed:
                continue

            log(f'Transcribing: {base} ({content_type})')
            text = transcribe_audio(audio_path)

            if text:
                filename = f\"{dump_dir}/{dt.strftime('%Y-%m-%d-%H%M%S')}-voice-{base}.md\"
                save_to_file(filename,
                            f'Signal Voice Note - {dt:%Y-%m-%d %H:%M}',
                            f'Signal voice message (whisper {whisper_model})',
                            text)
                insert_braindump('signal_voice', text, dt)
                saved += 1
                log(f'Voice transcribed: {base} -> {filename}')
            else:
                log(f'Transcription failed: {base}')

            # Mark as processed
            with open(processed_log, 'a') as f:
                f.write(base + '\n')

    except (json.JSONDecodeError, KeyError, ValueError) as e:
        continue

if saved > 0:
    print(f'Total saved: {saved}')
" 2>>"$LOG" || true
