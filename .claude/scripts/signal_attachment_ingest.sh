#!/usr/bin/env bash
# signal_attachment_ingest.sh — Ingest non-audio Signal attachments into braindumps/
#
# Closes the content-type gap in llm#1001: the Signal pipeline handled exactly
# two shapes — a text body, and an .aac/.ogg/.opus voice note — and dropped
# everything else with no log line, no error, and no record that anything had
# arrived. A scanned PDF sent on 2026-08-22 and 93 images going back to April
# vanished that way. The outage was invisible for ten weeks precisely because
# the drop was silent.
#
# The load-bearing property of this script is therefore NOT the OCR. It is that
# every file it looks at produces exactly one recorded outcome, including the
# outcomes it cannot handle. A content type this script does not know about is
# logged as UNHANDLED with its detected MIME type — visible, and actionable the
# next time the gap matters.
#
# Audio is deliberately out of scope: signal_braindump_handler.sh already
# transcribes it via whisper. This script does not scan for audio extensions at
# all, so audio is delegated rather than dropped.
#
# Usage:
#   signal_attachment_ingest.sh                    # scan attach dir, post-cutoff only
#   signal_attachment_ingest.sh --backfill         # also process pre-cutoff backlog
#   signal_attachment_ingest.sh --dry-run          # report decisions, write nothing
#   signal_attachment_ingest.sh FILE [FILE...]     # process specific files
#   signal_attachment_ingest.sh --selftest         # built-in regression test
#
# Exit codes: 0 = ran (individual file failures are logged, never fatal)
#             2 = usage or missing hard dependency
#
# Requires: ghostscript (gs), tesseract. Both already present via Homebrew —
# this adds no new dependency. qpdf is used for page counts when available and
# falls back to a gs probe when not. ImageMagick (magick) is used only by
# --selftest to build an image-only PDF fixture; its absence skips that subtest
# loudly rather than passing vacuously.
#
# llm#1001, llm#901

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration (every value overridable so --selftest never touches real state)
# ---------------------------------------------------------------------------

ATTACH_DIR="${SIGNAL_ATTACH_DIR:-$HOME/.local/share/signal-cli/attachments}"
DUMP_DIR="${SIGNAL_DUMP_DIR:-$HOME/docs_gh/llm/knowledge/raw/braindumps}"
DB="${SIGNAL_INGEST_DB:-$HOME/.claude/logs/unified.duckdb}"
LOG="${SIGNAL_INGEST_LOG:-$HOME/.claude/logs/signal_sync.log}"
PROCESSED_LOG="${SIGNAL_ATTACH_PROCESSED_LOG:-$HOME/.claude/logs/attachment_processed.txt}"

# Cutoff. Attachments older than this are recorded once as skipped-pre-cutoff
# and never looked at again unless --backfill is passed. Default is the date of
# the dropped PDF in llm#1001, so the fix starts from the incident rather than
# retro-ingesting four months of photos into an append-only store.
SINCE="${SIGNAL_INGEST_SINCE:-2026-08-22}"

# A PDF whose text layer yields fewer than this many non-whitespace characters
# is treated as image-only and sent to OCR. Real scans yield exactly zero; the
# margin covers PDFs carrying only a stray header or page number.
PDF_TEXT_MIN_CHARS="${SIGNAL_PDF_TEXT_MIN_CHARS:-40}"

# OCR output below this many non-whitespace characters is treated as "no
# readable text" — a photo rather than a screenshot. Still recorded, as a stub.
OCR_MIN_CHARS="${SIGNAL_OCR_MIN_CHARS:-20}"

# Page cap for OCR. Exceeding it is logged explicitly (never a silent truncation).
MAX_PAGES="${SIGNAL_PDF_MAX_PAGES:-20}"

OCR_DPI="${SIGNAL_OCR_DPI:-300}"
PER_PAGE_TIMEOUT="${SIGNAL_OCR_PAGE_TIMEOUT:-120}"

# raw_text is a summary column, not the archive — the .md note is the archive.
DB_TEXT_LIMIT="${SIGNAL_DB_TEXT_LIMIT:-500}"

DRY_RUN=0
BACKFILL=0

# ---------------------------------------------------------------------------
# Binaries — PATH first, then Homebrew, all overridable
# ---------------------------------------------------------------------------

_resolve_bin() {
  local var_value="$1" name="$2"
  if [ -n "$var_value" ]; then printf '%s' "$var_value"; return 0; fi
  local found
  found=$(command -v "$name" 2>/dev/null)
  if [ -n "$found" ]; then printf '%s' "$found"; return 0; fi
  if [ -x "/opt/homebrew/bin/$name" ]; then printf '%s' "/opt/homebrew/bin/$name"; return 0; fi
  return 1
}

GS_BIN=$(_resolve_bin "${GS_BIN:-}" gs) || GS_BIN=""
TESSERACT_BIN=$(_resolve_bin "${TESSERACT_BIN:-}" tesseract) || TESSERACT_BIN=""
QPDF_BIN=$(_resolve_bin "${QPDF_BIN:-}" qpdf) || QPDF_BIN=""
DUCKDB_BIN=$(_resolve_bin "${DUCKDB_BIN:-}" duckdb) || DUCKDB_BIN=""
TIMEOUT_BIN=$(_resolve_bin "${TIMEOUT_BIN:-}" timeout) || TIMEOUT_BIN=""
MAGICK_BIN=$(_resolve_bin "${MAGICK_BIN:-}" magick) || MAGICK_BIN=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '%s attachment-ingest: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"
}

usage() {
  echo "Usage: $(basename "$0") [--backfill] [--dry-run] [--since DATE] [--selftest] [FILE...]" >&2
  exit 2
}

# Run a command under a timeout when one is available; without it otherwise.
# A missing `timeout` must not turn into a skipped conversion — it only means
# the conversion is unbounded, which is logged once by the caller.
_bounded() {
  local secs="$1"; shift
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$secs" "$@"
  else
    "$@"
  fi
}

# mtime as epoch seconds. BSD stat first (macOS), GNU stat second (Nix/Linux).
_file_mtime() {
  local f="$1" m
  m=$(stat -f %m "$f" 2>/dev/null) || m=""
  if [ -z "$m" ]; then m=$(stat -c %Y "$f" 2>/dev/null) || m=""; fi
  printf '%s' "${m:-0}"
}

# Cutoff as epoch seconds. Accepts YYYY-MM-DD or a bare epoch.
#
# The time-of-day is pinned to 00:00:00 explicitly. BSD `date -j -f '%Y-%m-%d'`
# fills any field the format string does not mention from the CURRENT time, so
# `-f '%Y-%m-%d' 2026-08-22` yields 2026-08-22 at whatever o'clock it happens to
# be — a cutoff that walks forward through the day. Run at 13:00 it excluded a
# file stamped 09:50 the same morning, which is precisely the attachment this
# whole change exists to recover, and it excluded it *quietly*: the file was
# recorded as skipped-pre-cutoff and the run reported success.
_since_epoch() {
  case "$SINCE" in
    (''|*[!0-9]*)
      local e
      e=$(date -j -f '%Y-%m-%d %H:%M:%S' "$SINCE 00:00:00" '+%s' 2>/dev/null) || e=""
      if [ -z "$e" ]; then e=$(date -d "$SINCE 00:00:00" '+%s' 2>/dev/null) || e=""; fi
      printf '%s' "${e:-0}"
      ;;
    (*) printf '%s' "$SINCE" ;;
  esac
}

# Non-whitespace character count — the emptiness test that matters. A file of
# 4,000 newlines is empty for our purposes; `wc -c` would call it substantial.
_text_chars() {
  local f="$1"
  [ -f "$f" ] || { printf '0'; return 0; }
  tr -d '[:space:]' < "$f" 2>/dev/null | wc -c | tr -d ' '
}

# Detected MIME type, for the UNHANDLED log line. Extension alone is what the
# dispatcher uses; this exists so an unknown extension still reports what the
# file actually was.
_mime_type() {
  local f="$1" m
  m=$(file -b --mime-type "$f" 2>/dev/null) || m=""
  printf '%s' "${m:-unknown}"
}

_timestamp_for() {
  local f="$1" m
  m=$(_file_mtime "$f")
  if [ "$m" = "0" ]; then date '+%Y-%m-%d-%H%M%S'; return 0; fi
  date -r "$m" '+%Y-%m-%d-%H%M%S' 2>/dev/null || date '+%Y-%m-%d-%H%M%S'
}

_human_time_for() {
  local f="$1" m
  m=$(_file_mtime "$f")
  if [ "$m" = "0" ]; then date '+%Y-%m-%d %H:%M'; return 0; fi
  date -r "$m" '+%Y-%m-%d %H:%M' 2>/dev/null || date '+%Y-%m-%d %H:%M'
}

# ---------------------------------------------------------------------------
# Processed ledger — one line per file, "<basename><TAB><outcome>"
#
# Recording the outcome (not just the name) is what lets --backfill reconsider
# files that were skipped for being pre-cutoff without also re-ingesting files
# that were genuinely processed.
# ---------------------------------------------------------------------------

_processed_outcome() {
  local base="$1"
  [ -f "$PROCESSED_LOG" ] || return 0
  awk -F'\t' -v b="$base" '$1 == b { print $2 }' "$PROCESSED_LOG" 2>/dev/null | tail -1
}

_mark_processed() {
  local base="$1" outcome="$2"
  [ "$DRY_RUN" -eq 1 ] && return 0
  mkdir -p "$(dirname "$PROCESSED_LOG")" 2>/dev/null
  printf '%s\t%s\n' "$base" "$outcome" >> "$PROCESSED_LOG"
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

write_note() {
  local out="$1" title="$2" source_desc="$3" body_file="$4" extra="$5"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would write $out"
    return 0
  fi
  mkdir -p "$DUMP_DIR" 2>/dev/null
  {
    printf '# %s\n\n' "$title"
    printf 'Source: %s\n' "$source_desc"
    [ -n "$extra" ] && printf '%s\n' "$extra"
    printf '\n'
    if [ -n "$body_file" ] && [ -f "$body_file" ]; then cat "$body_file"; fi
    printf '\n'
  } > "$out"
}

# Insert a truncated summary into the braindumps table, mirroring the dedup
# pattern the text and voice paths already use. Single quotes are doubled;
# DuckDB string literals do not process backslash escapes, so that is the whole
# escaping surface. Control characters are stripped so the value survives being
# passed as an argv element.
db_insert() {
  local source="$1" body_file="$2" ts="$3"
  [ "$DRY_RUN" -eq 1 ] && { log "DRY-RUN: would insert source=$source"; return 0; }
  [ -n "$DUCKDB_BIN" ] || { log "WARN: duckdb not found — note written to disk but not indexed"; return 0; }
  [ -f "$body_file" ] || return 0
  local escaped
  escaped=$(tr -d '\000-\010\013\014\016-\037' < "$body_file" | head -c "$DB_TEXT_LIMIT" | sed "s/'/''/g")
  [ -n "$escaped" ] || return 0
  "$DUCKDB_BIN" "$DB" -c "
    INSERT INTO braindumps (source, raw_text, captured_at)
    SELECT '$source', '$escaped', '$ts'::TIMESTAMP
    WHERE NOT EXISTS (
      SELECT 1 FROM braindumps WHERE source='$source' AND raw_text='$escaped'
    );" >/dev/null 2>&1 || log "WARN: duckdb insert failed for source=$source"
}

# ---------------------------------------------------------------------------
# PDF
# ---------------------------------------------------------------------------

pdf_page_count() {
  local f="$1" n=""
  if [ -n "$QPDF_BIN" ]; then
    n=$("$QPDF_BIN" --show-npages "$f" 2>/dev/null) || n=""
  fi
  case "$n" in (''|*[!0-9]*) n="" ;; esac
  if [ -z "$n" ] && [ -n "$GS_BIN" ]; then
    n=$(_bounded 60 "$GS_BIN" -q -dNOPAUSE -dBATCH -sDEVICE=bbox "$f" 2>&1 | grep -c '^%%HiResBoundingBox') || n=""
  fi
  case "$n" in (''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# Extract the embedded text layer. Zero output here is the signal that matters:
# it means image-only, which llm#901 flags as the case a naive extractor
# reports as success. It is never treated as "done".
pdf_text_layer() {
  local f="$1" out="$2"
  [ -n "$GS_BIN" ] || return 1
  : > "$out"
  _bounded 120 "$GS_BIN" -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=txtwrite -o "$out" "$f" >/dev/null 2>&1
}

# Rasterise each page and OCR it. Page-at-a-time so one unreadable page does not
# cost the whole document.
pdf_ocr() {
  local f="$1" out="$2" pages="$3"
  [ -n "$GS_BIN" ] || return 1
  [ -n "$TESSERACT_BIN" ] || return 1
  local work
  work=$(mktemp -d) || return 1
  : > "$out"
  local last="$pages"
  if [ "$pages" -gt "$MAX_PAGES" ]; then
    last="$MAX_PAGES"
    log "CAPPED: $(basename "$f") has $pages pages, OCR limited to first $MAX_PAGES (SIGNAL_PDF_MAX_PAGES) — remaining pages NOT ingested"
  fi
  local p=1
  while [ "$p" -le "$last" ]; do
    local png="$work/page-$p.png"
    _bounded "$PER_PAGE_TIMEOUT" "$GS_BIN" -q -dNOPAUSE -dBATCH -dSAFER \
      -sDEVICE=png16m -r"$OCR_DPI" -dFirstPage="$p" -dLastPage="$p" \
      -o "$png" "$f" >/dev/null 2>&1
    if [ -s "$png" ]; then
      _bounded "$PER_PAGE_TIMEOUT" "$TESSERACT_BIN" "$png" "$work/page-$p" >/dev/null 2>&1
      if [ -f "$work/page-$p.txt" ]; then
        printf '\n## Page %s\n\n' "$p" >> "$out"
        cat "$work/page-$p.txt" >> "$out"
      else
        log "WARN: OCR produced no output for page $p of $(basename "$f")"
      fi
    else
      log "WARN: could not rasterise page $p of $(basename "$f")"
    fi
    p=$((p + 1))
  done
  rm -rf "$work"
  return 0
}

process_pdf() {
  local f="$1" base="$2"
  local stamp human
  stamp=$(_timestamp_for "$f")
  human=$(_human_time_for "$f")
  local ts_sql
  ts_sql=$(printf '%s' "$stamp" | sed 's/^\(....\)-\(..\)-\(..\)-\(..\)\(..\)\(..\)$/\1-\2-\3 \4:\5:\6/')

  local work txt
  work=$(mktemp -d) || return 1
  txt="$work/text.txt"

  local pages
  pages=$(pdf_page_count "$f")

  pdf_text_layer "$f" "$txt"
  local chars
  chars=$(_text_chars "$txt")

  if [ "$chars" -ge "$PDF_TEXT_MIN_CHARS" ]; then
    log "PDF text-layer: $base — $pages page(s), $chars chars extracted"
    write_note "$DUMP_DIR/${stamp}-pdf-${base%.*}.md" \
      "Signal PDF — $human" \
      "Signal attachment (PDF text layer, ghostscript txtwrite)" \
      "$txt" \
      "$(printf 'Attachment: %s\nPages: %s\nExtraction: text layer' "$base" "$pages")"
    db_insert signal_pdf "$txt" "$ts_sql"
    rm -rf "$work"
    printf 'pdf-text'
    return 0
  fi

  # No usable text layer. This is the llm#901 case — say so, then OCR.
  log "PDF has no text layer: $base — $pages page(s), $chars chars from txtwrite; falling back to OCR"

  local ocr="$work/ocr.txt"
  pdf_ocr "$f" "$ocr" "$pages"
  local ocr_chars
  ocr_chars=$(_text_chars "$ocr")

  if [ "$ocr_chars" -ge "$OCR_MIN_CHARS" ]; then
    log "PDF OCR: $base — $ocr_chars chars recovered from $pages page(s)"
    write_note "$DUMP_DIR/${stamp}-pdf-ocr-${base%.*}.md" \
      "Signal PDF (OCR) — $human" \
      "Signal attachment (scanned PDF, tesseract OCR of ghostscript raster at ${OCR_DPI}dpi)" \
      "$ocr" \
      "$(printf 'Attachment: %s\nPages: %s\nExtraction: OCR — text is machine-read and may contain errors' "$base" "$pages")"
    db_insert signal_pdf_ocr "$ocr" "$ts_sql"
    rm -rf "$work"
    printf 'pdf-ocr'
    return 0
  fi

  # Neither path produced anything. Loud, per llm#901: an empty result is
  # recorded as a failure to read, never as a document with no content.
  log "FAILED: $base — PDF yielded no text layer AND OCR recovered only $ocr_chars chars from $pages page(s); stub written, content NOT captured"
  local stub="$work/stub.txt"
  printf 'This PDF could not be read. Its text layer is empty and OCR of %s rasterised page(s) recovered %s characters.\n\nThe file is still on disk at the path above — it needs a human look.\n' \
    "$pages" "$ocr_chars" > "$stub"
  write_note "$DUMP_DIR/${stamp}-pdf-unreadable-${base%.*}.md" \
    "Signal PDF (unreadable) — $human" \
    "Signal attachment (PDF; no text layer, OCR recovered nothing)" \
    "$stub" \
    "$(printf 'Attachment: %s\nPath: %s\nPages: %s\nExtraction: FAILED' "$base" "$f" "$pages")"
  db_insert signal_pdf_unreadable "$stub" "$ts_sql"
  rm -rf "$work"
  printf 'pdf-unreadable'
  return 0
}

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------

process_image() {
  local f="$1" base="$2" mime="$3"
  [ -n "$TESSERACT_BIN" ] || { log "WARN: tesseract not found — cannot OCR $base"; printf 'error-no-tesseract'; return 0; }

  local stamp human
  stamp=$(_timestamp_for "$f")
  human=$(_human_time_for "$f")
  local ts_sql
  ts_sql=$(printf '%s' "$stamp" | sed 's/^\(....\)-\(..\)-\(..\)-\(..\)\(..\)\(..\)$/\1-\2-\3 \4:\5:\6/')

  local work
  work=$(mktemp -d) || return 1
  _bounded "$PER_PAGE_TIMEOUT" "$TESSERACT_BIN" "$f" "$work/ocr" >/dev/null 2>&1
  local ocr="$work/ocr.txt"
  local chars
  chars=$(_text_chars "$ocr")

  if [ "$chars" -ge "$OCR_MIN_CHARS" ]; then
    log "Image OCR: $base ($mime) — $chars chars"
    write_note "$DUMP_DIR/${stamp}-image-ocr-${base%.*}.md" \
      "Signal Image (OCR) — $human" \
      "Signal attachment ($mime, tesseract OCR)" \
      "$ocr" \
      "$(printf 'Attachment: %s\nExtraction: OCR — text is machine-read and may contain errors' "$base")"
    db_insert signal_image_ocr "$ocr" "$ts_sql"
    rm -rf "$work"
    printf 'image-ocr'
    return 0
  fi

  # A photo rather than a screenshot. Still recorded, so the arrival is not
  # invisible — that invisibility is the whole bug being fixed here.
  log "Image no readable text: $base ($mime) — OCR recovered $chars chars; stub written"
  local stub="$work/stub.txt"
  printf 'An image arrived with no machine-readable text (OCR recovered %s characters). It is most likely a photo rather than a screenshot.\n\nThe image itself is on disk at the path above.\n' \
    "$chars" > "$stub"
  write_note "$DUMP_DIR/${stamp}-image-${base%.*}.md" \
    "Signal Image — $human" \
    "Signal attachment ($mime; no readable text)" \
    "$stub" \
    "$(printf 'Attachment: %s\nPath: %s\nExtraction: OCR found no text' "$base" "$f")"
  db_insert signal_image_stub "$stub" "$ts_sql"
  rm -rf "$work"
  printf 'image-stub'
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

process_file() {
  local f="$1"
  [ -f "$f" ] || { log "WARN: not a file: $f"; return 0; }
  local base
  base=$(basename "$f")

  local prior
  prior=$(_processed_outcome "$base")
  if [ -n "$prior" ]; then
    # Only a pre-cutoff skip is reconsidered, and only under --backfill.
    if [ "$prior" = "skipped-pre-cutoff" ] && [ "$BACKFILL" -eq 1 ]; then
      :
    else
      return 0
    fi
  fi

  local ext="${base##*.}"
  ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
  local mime
  mime=$(_mime_type "$f")

  local outcome=""
  case "$ext" in
    (pdf)
      outcome=$(process_pdf "$f" "$base")
      ;;
    (jpg|jpeg|png|gif|tif|tiff|bmp|webp)
      outcome=$(process_image "$f" "$base" "$mime")
      ;;
    (aac|ogg|opus|m4a|mp3|wav)
      # Not a drop: signal_braindump_handler.sh transcribes these via whisper.
      # Recorded so the ledger accounts for every file in the directory.
      outcome="delegated-audio"
      ;;
    (*)
      # The line llm#1001 exists for. An unknown type is now visible.
      log "UNHANDLED: $base — extension '.$ext', detected type '$mime'. No processor for this type; file left on disk, nothing ingested."
      outcome="unhandled"
      ;;
  esac

  [ -n "$outcome" ] || outcome="error"
  _mark_processed "$base" "$outcome"
  printf '%s\t%s\n' "$base" "$outcome"
}

scan_dir() {
  local cutoff
  cutoff=$(_since_epoch)
  local considered=0 skipped=0

  if [ ! -d "$ATTACH_DIR" ]; then
    log "WARN: attachment directory not found: $ATTACH_DIR"
    return 0
  fi

  local f
  for f in "$ATTACH_DIR"/*; do
    [ -f "$f" ] || continue
    local base
    base=$(basename "$f")

    local prior
    prior=$(_processed_outcome "$base")
    if [ -n "$prior" ]; then
      if [ "$prior" = "skipped-pre-cutoff" ] && [ "$BACKFILL" -eq 1 ]; then
        :
      else
        continue
      fi
    fi

    if [ "$BACKFILL" -eq 0 ]; then
      local mtime
      mtime=$(_file_mtime "$f")
      if [ "$mtime" -lt "$cutoff" ]; then
        # Recorded once, with a log line, then never mentioned again. Silence
        # here would recreate the bug at a different threshold.
        log "SKIPPED pre-cutoff: $base (mtime older than $SINCE) — run with --backfill to ingest"
        _mark_processed "$base" "skipped-pre-cutoff"
        skipped=$((skipped + 1))
        continue
      fi
    fi

    process_file "$f"
    considered=$((considered + 1))
  done

  if [ "$considered" -gt 0 ] || [ "$skipped" -gt 0 ]; then
    log "scan complete: $considered processed, $skipped recorded as pre-cutoff (cutoff=$SINCE, backfill=$BACKFILL)"
  fi
}

# ---------------------------------------------------------------------------
# Self-test
#
# Builds its own fixtures with ghostscript so nothing personal is committed and
# nothing real is touched: every path is redirected into a temp tree.
# ---------------------------------------------------------------------------

selftest() {
  local tmp fail=0 pass=0
  tmp=$(mktemp -d)

  ok()   { pass=$((pass + 1)); echo "  PASS: $1"; }
  bad()  { fail=$((fail + 1)); echo "  FAIL: $1"; }
  skip() { echo "  SKIP: $1"; }

  export SIGNAL_ATTACH_DIR="$tmp/attach"
  export SIGNAL_DUMP_DIR="$tmp/dump"
  export SIGNAL_INGEST_LOG="$tmp/sync.log"
  export SIGNAL_ATTACH_PROCESSED_LOG="$tmp/processed.txt"
  export SIGNAL_INGEST_DB="$tmp/nonexistent.duckdb"
  ATTACH_DIR="$SIGNAL_ATTACH_DIR"
  DUMP_DIR="$SIGNAL_DUMP_DIR"
  LOG="$SIGNAL_INGEST_LOG"
  PROCESSED_LOG="$SIGNAL_ATTACH_PROCESSED_LOG"
  DB="$SIGNAL_INGEST_DB"
  DUCKDB_BIN=""   # never touch a real database from a test
  mkdir -p "$ATTACH_DIR" "$DUMP_DIR"

  if [ -z "$GS_BIN" ] || [ -z "$TESSERACT_BIN" ]; then
    echo "  FAIL: gs and tesseract are required for --selftest (gs='$GS_BIN' tesseract='$TESSERACT_BIN')"
    rm -rf "$tmp"
    return 1
  fi

  echo "signal_attachment_ingest.sh --selftest"

  # -- Fixture 1: a PDF with a real text layer ------------------------------
  # Three lines, deliberately well clear of PDF_TEXT_MIN_CHARS. A one-line
  # fixture sat just under the threshold and was classified image-only — the
  # test was measuring the fixture's length, not the dispatcher's logic.
  printf '%%!PS\n/Helvetica findfont 24 scalefont setfont\n72 700 moveto (HELLO SELFTEST TEXT LAYER PRESENT) show\n72 660 moveto (SECOND LINE OF EMBEDDED TEXT FOR THE FIXTURE) show\n72 620 moveto (THIRD LINE SO THE EXTRACTION CLEARS THE THRESHOLD) show\nshowpage\n' > "$tmp/fixture.ps"
  "$GS_BIN" -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -o "$ATTACH_DIR/text.pdf" "$tmp/fixture.ps" >/dev/null 2>&1

  # -- Fixture 2: the same page as an image-only PDF (the llm#901 trap) -----
  "$GS_BIN" -q -dNOPAUSE -dBATCH -sDEVICE=png16m -r150 -o "$ATTACH_DIR/scan.png" "$ATTACH_DIR/text.pdf" >/dev/null 2>&1
  local have_scan_pdf=0
  if [ -n "$MAGICK_BIN" ]; then
    "$MAGICK_BIN" "$ATTACH_DIR/scan.png" "$ATTACH_DIR/scan.pdf" >/dev/null 2>&1
    [ -s "$ATTACH_DIR/scan.pdf" ] && have_scan_pdf=1
  fi

  # -- Fixture 3: an image with no text -------------------------------------
  printf '%%!PS\n0.5 setgray 100 100 300 300 rectfill\nshowpage\n' > "$tmp/blank.ps"
  "$GS_BIN" -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -o "$tmp/blank.pdf" "$tmp/blank.ps" >/dev/null 2>&1
  "$GS_BIN" -q -dNOPAUSE -dBATCH -sDEVICE=png16m -r72 -o "$ATTACH_DIR/blank.png" "$tmp/blank.pdf" >/dev/null 2>&1

  # -- Fixture 4: an unhandled type -----------------------------------------
  printf 'BEGIN:VCARD\nVERSION:3.0\nEND:VCARD\n' > "$ATTACH_DIR/contact.vcf"

  # -- Fixture 5: audio, which belongs to the whisper path ------------------
  printf 'not really audio' > "$ATTACH_DIR/voice.aac"

  # Test 1: text-layer PDF is read via the text layer, not OCR
  local out
  out=$(process_file "$ATTACH_DIR/text.pdf")
  case "$out" in
    (*pdf-text) ok "text-layer PDF -> pdf-text" ;;
    (*) bad "text-layer PDF -> expected pdf-text, got '${out#*	}'" ;;
  esac
  if ls "$DUMP_DIR"/*-pdf-text.md >/dev/null 2>&1; then
    ok "text-layer PDF wrote a note"
  else
    bad "text-layer PDF wrote no note"
  fi
  if grep -qF "HELLO SELFTEST TEXT LAYER PRESENT" "$DUMP_DIR"/*-pdf-text.md 2>/dev/null; then
    ok "text-layer note contains the extracted text"
  else
    bad "text-layer note is missing the extracted text"
  fi

  # Test 2: image-only PDF falls through to OCR and recovers the same words.
  # This is the case a naive extractor reports as an empty success (llm#901).
  if [ "$have_scan_pdf" -eq 1 ]; then
    out=$(process_file "$ATTACH_DIR/scan.pdf")
    case "$out" in
      (*pdf-ocr) ok "image-only PDF -> pdf-ocr (did not report empty success)" ;;
      (*) bad "image-only PDF -> expected pdf-ocr, got '${out#*	}'" ;;
    esac
    if grep -qiF "SELFTEST" "$DUMP_DIR"/*-pdf-ocr-*.md 2>/dev/null; then
      ok "OCR note contains recovered text"
    else
      bad "OCR note is missing recovered text"
    fi
    if grep -q "no text layer" "$LOG"; then
      ok "missing text layer was logged, not swallowed"
    else
      bad "missing text layer produced no log line"
    fi
  else
    skip "image-only PDF subtest (ImageMagick 'magick' not found — cannot build the fixture)"
  fi

  # Test 3: image with text -> image-ocr
  out=$(process_file "$ATTACH_DIR/scan.png")
  case "$out" in
    (*image-ocr) ok "image with text -> image-ocr" ;;
    (*) bad "image with text -> expected image-ocr, got '${out#*	}'" ;;
  esac

  # Test 4: image without text -> stub, still recorded
  out=$(process_file "$ATTACH_DIR/blank.png")
  case "$out" in
    (*image-stub) ok "image without text -> image-stub (recorded, not dropped)" ;;
    (*) bad "image without text -> expected image-stub, got '${out#*	}'" ;;
  esac
  if ls "$DUMP_DIR"/*-image-blank.md >/dev/null 2>&1; then
    ok "text-free image still produced a note"
  else
    bad "text-free image produced no note"
  fi

  # Test 5: the load-bearing one — an unknown type is logged, never silent
  out=$(process_file "$ATTACH_DIR/contact.vcf")
  case "$out" in
    (*unhandled) ok "unknown type -> unhandled" ;;
    (*) bad "unknown type -> expected unhandled, got '${out#*	}'" ;;
  esac
  if grep -q "UNHANDLED: contact.vcf" "$LOG"; then
    ok "unknown type produced an UNHANDLED log line with its detected type"
  else
    bad "unknown type produced NO log line — this is the llm#1001 bug"
  fi

  # Test 6: audio is delegated to whisper, not claimed and not dropped
  out=$(process_file "$ATTACH_DIR/voice.aac")
  case "$out" in
    (*delegated-audio) ok "audio -> delegated-audio (whisper path owns it)" ;;
    (*) bad "audio -> expected delegated-audio, got '${out#*	}'" ;;
  esac

  # Test 7: the ledger prevents reprocessing
  local before after
  before=$(ls "$DUMP_DIR" | wc -l | tr -d ' ')
  process_file "$ATTACH_DIR/text.pdf" >/dev/null
  after=$(ls "$DUMP_DIR" | wc -l | tr -d ' ')
  if [ "$before" = "$after" ]; then
    ok "already-processed file is not reprocessed"
  else
    bad "already-processed file was reprocessed ($before -> $after notes)"
  fi

  # Test 8: every fixture has exactly one ledger entry — nothing unaccounted for
  local ledger_lines
  ledger_lines=$(wc -l < "$PROCESSED_LOG" | tr -d ' ')
  local expected=5
  [ "$have_scan_pdf" -eq 1 ] && expected=6
  if [ "$ledger_lines" = "$expected" ]; then
    ok "ledger has one entry per file seen ($ledger_lines)"
  else
    bad "ledger has $ledger_lines entries, expected $expected"
  fi

  # Test 9: pre-cutoff files are recorded and skipped, and --backfill picks
  # them up later. Uses a fresh dump/ledger so counts are unambiguous.
  rm -f "$PROCESSED_LOG"
  rm -rf "$DUMP_DIR"
  mkdir -p "$DUMP_DIR"
  touch -t 202601010900 "$ATTACH_DIR/text.pdf"
  SINCE="2026-08-22"
  BACKFILL=0
  scan_dir >/dev/null
  if [ "$(_processed_outcome text.pdf)" = "skipped-pre-cutoff" ]; then
    ok "pre-cutoff file recorded as skipped-pre-cutoff"
  else
    bad "pre-cutoff file outcome was '$(_processed_outcome text.pdf)', expected skipped-pre-cutoff"
  fi
  if grep -q "SKIPPED pre-cutoff: text.pdf" "$LOG"; then
    ok "pre-cutoff skip was logged"
  else
    bad "pre-cutoff skip was NOT logged"
  fi
  BACKFILL=1
  process_file "$ATTACH_DIR/text.pdf" >/dev/null
  if [ "$(_processed_outcome text.pdf)" = "pdf-text" ]; then
    ok "--backfill reconsiders a pre-cutoff file"
  else
    bad "--backfill did not reconsider a pre-cutoff file (outcome '$(_processed_outcome text.pdf)')"
  fi
  BACKFILL=0

  # Test 9b: the cutoff must resolve to midnight, not to the current
  # time-of-day. Test 9 above passed with the bug present because its fixture
  # was months old, so drift within a single day never showed. Both halves are
  # checked: the resolved instant directly, and the behaviour of a file stamped
  # early on the cutoff date itself.
  SINCE="2026-08-22"
  local resolved resolved_clock
  resolved=$(_since_epoch)
  resolved_clock=$(date -r "$resolved" '+%H:%M:%S' 2>/dev/null)
  if [ "$resolved_clock" = "00:00:00" ]; then
    ok "cutoff resolves to midnight, not the current time-of-day"
  else
    bad "cutoff resolved to $resolved_clock — it drifts with wall-clock time"
  fi

  rm -f "$PROCESSED_LOG"
  rm -rf "$DUMP_DIR"
  mkdir -p "$DUMP_DIR"
  touch -t 202608220030 "$ATTACH_DIR/text.pdf"
  scan_dir >/dev/null
  if [ "$(_processed_outcome text.pdf)" = "pdf-text" ]; then
    ok "a file stamped 00:30 on the cutoff date is processed, not skipped"
  else
    bad "a file stamped 00:30 on the cutoff date was '$(_processed_outcome text.pdf)' — the cutoff excluded a same-day file"
  fi

  # Test 10: --dry-run writes nothing
  rm -f "$PROCESSED_LOG"
  rm -rf "$DUMP_DIR"
  mkdir -p "$DUMP_DIR"
  DRY_RUN=1
  process_file "$ATTACH_DIR/scan.png" >/dev/null
  DRY_RUN=0
  if [ -z "$(ls -A "$DUMP_DIR" 2>/dev/null)" ] && [ ! -s "$PROCESSED_LOG" ]; then
    ok "--dry-run wrote no note and no ledger entry"
  else
    bad "--dry-run wrote state"
  fi

  echo "  $pass passed, $fail failed"
  rm -rf "$tmp"
  [ "$fail" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    (--selftest)  selftest; exit $? ;;
    (--backfill)  BACKFILL=1; shift ;;
    (--dry-run)   DRY_RUN=1; shift ;;
    (--since)     SINCE="${2:-}"; shift 2 ;;
    (-h|--help)   usage ;;
    (-*)          echo "Unknown option: $1" >&2; usage ;;
    (*)           FILES+=("$1"); shift ;;
  esac
done

if [ -z "$GS_BIN" ] && [ -z "$TESSERACT_BIN" ]; then
  log "FATAL: neither ghostscript nor tesseract found — cannot process attachments"
  exit 2
fi
[ -n "$GS_BIN" ] || log "WARN: ghostscript not found — PDF handling degraded"
[ -n "$TESSERACT_BIN" ] || log "WARN: tesseract not found — OCR unavailable"
[ -n "$TIMEOUT_BIN" ] || log "WARN: timeout not found — conversions run unbounded"

if [ "${#FILES[@]}" -gt 0 ]; then
  for f in "${FILES[@]}"; do
    process_file "$f"
  done
else
  scan_dir
fi

exit 0
