#!/usr/bin/env python3
"""signal_group_filter.py — shared group-filtering + attachment-dispatch
helpers for the Signal braindump pipeline (llm#1001).

Both signal_notes_sync.sh and signal_braindump_handler.sh embed small Python
blocks (three call sites total: signal_notes_sync.sh's direct-receive parse,
signal_braindump_handler.sh's direct-receive fallback parse, and
signal_braindump_handler.sh's daemon-stdout-tail parse) that turn
`envelope.syncMessage.sentMessage` JSON lines from signal-cli into braindump
files. Before llm#1001 none of them applied any group filtering — every
group's (and every direct/self-sent) message was captured — and none of them
logged anything for an attachment whose contentType wasn't audio/*: an
image/jpeg or application/pdf attachment simply vanished, no log line at
all. This module is the ONE place that decides, per message, which group it
belongs to and whether that's the configured target; it is imported (not
re-copy-pasted three times) by all three call sites so that decision logic
cannot drift between them.

Design decision — groupId, not groupName (llm#1001):
  Signal group names are user-editable at any time (Settings > Group Name).
  groupId is the stable, server-assigned identifier that survives a rename.
  Pinning the filter on the display name would silently stop matching the
  day the group is renamed — exactly the "silently drops messages" failure
  mode this issue exists to fix, not a new way to reintroduce it. groupName
  is used ONLY for human-readable logging, never for matching.

Design decision — direct (non-group) messages are excluded:
  The user's own reading, stated explicitly in the issue: "only messages
  from Notes to llm processed; everything else ignored" — that includes
  direct/self-sent notes (no groupInfo at all), which the pipeline used to
  capture unconditionally. A direct message is treated the same as "wrong
  group": ignored, logged, not captured.

Design decision — reuse the EXISTING group-id config file:
  braindump_respond.sh already reads
  ~/.claude/config/signal_notes_group_id.txt (populated by hand from
  `signal-cli listGroups`) to know which group to send status replies to.
  That is the same group this filter should listen to — the group we reply
  in and the group we listen to are the same "Notes to llm" group — so this
  module reads the SAME file rather than inventing a second, easily-
  divergent group-id config.

Design decision — fail closed when unconfigured:
  If the group-id file is missing or empty, EVERY message is treated as not
  belonging to the target group (nothing is captured) rather than falling
  back to "capture everything". Given the whole point of this filter is a
  privacy boundary (llm#1001's `pills` jpeg example), fail-open would be
  exactly backwards. The ignored-reason distinguishes this case
  ("target group not configured") from an ordinary wrong-group message so
  a genuinely unconfigured deployment is loud, not just quiet.

Deliberately NOT this module's responsibility: reading signal-cli's raw JSON
stream, daemon-stdout byte-offset tracking, exception-envelope detection, or
the RECEIVE FAILED / GAP / FALLBACK log wording — those stay in the calling
bash scripts, unchanged, so this change does not touch already-tested
control flow it doesn't need to.
"""
import os
import subprocess
import sys
from datetime import datetime

_AUDIO_EXTS = ("", ".aac", ".ogg", ".opus", ".m4a")
_OTHER_EXTS = (".jpg", ".jpeg", ".pdf", ".png")


def read_target_group_id(group_id_file):
    """Read the configured target group ID, or '' if unconfigured."""
    try:
        with open(group_id_file, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def classify_group(sent, target_group_id):
    """Return (allowed, reason, group_name, group_id) for one sentMessage.

    allowed is True only when sentMessage carries a groupInfo.groupId that
    equals target_group_id (a non-empty, configured value).
    """
    group_info = sent.get("groupInfo") or {}
    group_id = group_info.get("groupId") or ""
    group_name = group_info.get("groupName") or ""

    if not target_group_id:
        return False, "target group not configured", group_name, group_id
    if not group_id:
        return False, "direct message (no group)", group_name, group_id
    if group_id != target_group_id:
        label = group_name if group_name else "(name unknown)"
        return (
            False,
            f"wrong group (name={label!r}, id={group_id})",
            group_name,
            group_id,
        )
    return True, "target group", group_name, group_id


def describe_message_contents(sent):
    """Human-readable summary of what a message carries, for the ignored-log
    line — e.g. 'text' or 'image/jpeg' or 'text,image/jpeg' or '(empty)'."""
    kinds = []
    if sent.get("message"):
        kinds.append("text")
    for att in sent.get("attachments") or []:
        kinds.append(att.get("contentType") or "unknown")
    return ",".join(kinds) if kinds else "(empty)"


def log_line(log_file, msg):
    with open(log_file, "a", encoding="utf-8") as f:
        f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}\n")


def log_ignored(log_file, sent, reason):
    kinds = describe_message_contents(sent)
    log_line(log_file, f"ignored: {reason} — content dropped (types: {kinds})")


def save_to_file(filename, title, source_desc, body):
    with open(filename, "w", encoding="utf-8") as f:
        f.write(f"# {title}\n\n")
        f.write(f"Source: {source_desc}\n\n")
        f.write(body + "\n")


def insert_braindump(db_path, source, text, dt):
    escaped = text.replace("'", "''")[:500]
    sql = (
        "INSERT INTO braindumps (source, raw_text, captured_at) "
        f"SELECT '{source}', '{escaped}', '{dt:%Y-%m-%d %H:%M:%S}'::TIMESTAMP "
        "WHERE NOT EXISTS (SELECT 1 FROM braindumps "
        f"WHERE source='{source}' AND raw_text='{escaped}');"
    )
    subprocess.run(["duckdb", db_path, "-c", sql], capture_output=True)


def find_attachment_path(attach_dir, att_id):
    if not att_id:
        return None
    for ext in _AUDIO_EXTS + _OTHER_EXTS:
        candidate = os.path.join(attach_dir, att_id + ext)
        if os.path.isfile(candidate):
            return candidate
    try:
        for f in os.listdir(attach_dir):
            if att_id in f:
                return os.path.join(attach_dir, f)
    except OSError:
        pass
    return None


def allowlist_add(allowlist_file, att_id):
    """Record that att_id is known to belong to a target-group message.

    Used by signal_braindump_handler.sh's directory-glob audio catch-up loop
    (which has no per-message context of its own) to avoid transcribing an
    attachment that arrived via a group this pipeline is not supposed to
    capture (llm#1001).
    """
    if not att_id:
        return
    try:
        existing = set()
        if os.path.isfile(allowlist_file):
            with open(allowlist_file, encoding="utf-8") as f:
                existing = {line.strip() for line in f}
        if att_id not in existing:
            os.makedirs(os.path.dirname(allowlist_file), exist_ok=True)
            with open(allowlist_file, "a", encoding="utf-8") as f:
                f.write(att_id + "\n")
    except OSError:
        pass


def allowlist_contains(allowlist_file, att_id):
    if not att_id or not os.path.isfile(allowlist_file):
        return False
    try:
        with open(allowlist_file, encoding="utf-8") as f:
            return att_id in {line.strip() for line in f}
    except OSError:
        return False


def extract_pdf(pdf_path, extractor_script, timeout=180):
    """Run extract_pdf_text.py as a subprocess. Returns (status, payload):
    status is 'ok' | 'unsupported' | 'error'; payload is extracted text (ok)
    or a human-readable reason (unsupported/error)."""
    if not extractor_script or not os.path.isfile(extractor_script):
        return "error", f"extractor script not found: {extractor_script}"
    try:
        result = subprocess.run(
            [sys.executable, extractor_script, pdf_path],
            capture_output=True,
            timeout=timeout,
            text=True,
        )
    except subprocess.TimeoutExpired:
        return "error", "extraction timed out"
    except OSError as e:
        return "error", f"could not run extractor: {e}"
    if result.returncode == 0:
        return "ok", result.stdout
    if result.returncode == 2:
        return "unsupported", (result.stderr or "").strip()
    return "error", (result.stderr or "").strip()


def handle_pdf_attachment(att, dt, ctx):
    """Process one application/pdf attachment: extract, save, log.

    ctx keys: attach_dir, dump_dir, db_path, log_file, pdf_extractor
    """
    att_id = att.get("id") or ""
    path = find_attachment_path(ctx["attach_dir"], att_id)
    base = os.path.basename(path) if path else (att_id or "(unknown)")

    if not path:
        log_line(
            ctx["log_file"],
            f"unhandled: PDF attachment {att_id or base} referenced in a "
            f"target-group message but not found in {ctx['attach_dir']}",
        )
        return

    status, payload = extract_pdf(path, ctx.get("pdf_extractor"))
    stem = os.path.splitext(base)[0]

    if status == "ok" and payload.strip():
        out = os.path.join(ctx["dump_dir"], f"{dt:%Y-%m-%d-%H%M%S}-pdf-{stem}.md")
        save_to_file(
            out,
            f"Signal PDF Attachment - {dt:%Y-%m-%d %H:%M}",
            f"Signal PDF attachment ({base}, text/OCR extraction)",
            payload.strip(),
        )
        insert_braindump(ctx["db_path"], "signal_pdf", payload.strip(), dt)
        log_line(ctx["log_file"], f"PDF extracted: {base} -> {out}")
        return

    if status == "unsupported":
        out = os.path.join(
            ctx["dump_dir"], f"{dt:%Y-%m-%d-%H%M%S}-pdf-unsupported-{stem}.md"
        )
        save_to_file(
            out,
            "Signal PDF Attachment - EXTRACTION UNSUPPORTED",
            f"Signal PDF attachment ({base})",
            "PDF EXTRACTION UNSUPPORTED\n\n"
            f"Reason: {payload}\n\n"
            "No text was extracted. This file is a placeholder recording "
            "that a PDF attachment arrived and could not be processed "
            "automatically — it deliberately does not look like a real "
            "transcript (llm#1001: an empty note indistinguishable from a "
            "real one is the failure mode this pipeline exists to avoid).",
        )
        log_line(
            ctx["log_file"], f"unhandled: PDF extraction unsupported for {base}: {payload}"
        )
        return

    # status == 'error' — the extractor itself broke (bad path, tesseract
    # crashed, timed out). Distinct from 'unsupported' (a recognised,
    # expected case) — this is a bug/environment problem worth surfacing
    # differently, mirroring how RECEIVE FAILED is kept distinct from "no
    # new messages" elsewhere in this pipeline.
    log_line(ctx["log_file"], f"error: PDF extraction failed for {base}: {payload}")


def process_non_audio_attachments(sent, dt, ctx):
    """Loop a target-group message's attachments, dispatching everything
    that ISN'T audio/* (audio stays in each call site's existing, working
    whisper-transcription code — this function deliberately does not touch
    it, only records audio attachment IDs to the allowlist so the
    directory-glob catch-up loop in signal_braindump_handler.sh can tell
    they belong to an allowed message).

    ctx keys: attach_dir, dump_dir, db_path, log_file, pdf_extractor,
              allowlist_file (optional)
    """
    for att in sent.get("attachments") or []:
        content_type = att.get("contentType") or ""
        att_id = att.get("id") or ""

        if content_type.startswith("audio/"):
            if ctx.get("allowlist_file"):
                allowlist_add(ctx["allowlist_file"], att_id)
            continue

        if content_type == "application/pdf":
            handle_pdf_attachment(att, dt, ctx)
            continue

        path = find_attachment_path(ctx["attach_dir"], att_id)
        base = os.path.basename(path) if path else (att_id or "(unknown)")
        log_line(
            ctx["log_file"],
            f"unhandled: no processor for content type '{content_type}' "
            f"(attachment {base})",
        )
