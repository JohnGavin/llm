#!/usr/bin/env python3
"""test_signal_group_filter.py — tests for
.claude/scripts/signal_group_filter.py (llm#1001).

Covers: groupId-vs-groupName classification (pinned on groupId, never falls
back to matching by name), direct-message exclusion, fail-closed behaviour
when the target group is unconfigured, the allowlist gate used by
signal_braindump_handler.sh's directory-glob audio catch-up loop, and PDF
attachment dispatch (ok / unsupported / missing-file cases) using the same
synthetic fixtures as test_extract_pdf_text.py.

Run with: python3 tests/python/test_signal_group_filter.py
No external dependencies beyond the stdlib. Exits non-zero on any failure.
"""
from __future__ import annotations

import pathlib
import shutil
import sys
import tempfile

_SCRIPTS_DIR = pathlib.Path(__file__).parent.parent.parent / ".claude" / "scripts"
_FIXTURES = pathlib.Path(__file__).parent.parent / "fixtures" / "pdf"
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

import signal_group_filter as sgf  # noqa: E402

PASS = 0
FAIL = 0


def check(desc, cond, detail=""):
    global PASS, FAIL
    if cond:
        print(f"  PASS: {desc}")
        PASS += 1
    else:
        print(f"  FAIL: {desc}  {detail}")
        FAIL += 1


TARGET_ID = "grp-target-abc123"


def test_classify_group_target_match():
    print("\n-- classify_group: matching groupId -> allowed")
    sent = {"groupInfo": {"groupId": TARGET_ID, "groupName": "Notes to llm"}}
    allowed, reason, name, gid = sgf.classify_group(sent, TARGET_ID)
    check("allowed is True", allowed is True, (allowed, reason))
    check("groupId echoed back", gid == TARGET_ID, gid)


def test_classify_group_wrong_group():
    print("\n-- classify_group: different groupId -> not allowed, wrong group")
    sent = {"groupInfo": {"groupId": "grp-other-xyz", "groupName": "pills"}}
    allowed, reason, name, gid = sgf.classify_group(sent, TARGET_ID)
    check("allowed is False", allowed is False)
    check("reason says wrong group", "wrong group" in reason, reason)


def test_classify_group_name_change_still_matches():
    print("\n-- classify_group: groupId unchanged but groupName renamed -> still allowed")
    # Design requirement (llm#1001): pin on groupId, never fall back to
    # matching by name — a rename must NOT break the filter.
    sent = {"groupInfo": {"groupId": TARGET_ID, "groupName": "Renamed Notes Group"}}
    allowed, reason, name, gid = sgf.classify_group(sent, TARGET_ID)
    check("still allowed after a group rename", allowed is True, (allowed, reason))


def test_classify_group_name_match_but_id_mismatch_is_rejected():
    print("\n-- classify_group: groupName happens to match but groupId differs -> rejected")
    # Proves there is no name-based fallback path at all.
    sent = {"groupInfo": {"groupId": "grp-impostor", "groupName": "Notes to llm"}}
    allowed, reason, name, gid = sgf.classify_group(sent, TARGET_ID)
    check("rejected despite matching name", allowed is False, (allowed, reason))
    check("reason says wrong group, not name-based", "wrong group" in reason, reason)


def test_classify_group_direct_message():
    print("\n-- classify_group: no groupInfo at all (direct/self-sent) -> excluded")
    sent = {"message": "note to self"}
    allowed, reason, name, gid = sgf.classify_group(sent, TARGET_ID)
    check("allowed is False", allowed is False)
    check("reason says direct message", "direct message" in reason, reason)


def test_classify_group_unconfigured_fails_closed():
    print("\n-- classify_group: target_group_id empty (unconfigured) -> fails closed, not open")
    sent = {"groupInfo": {"groupId": TARGET_ID, "groupName": "Notes to llm"}}
    allowed, reason, name, gid = sgf.classify_group(sent, "")
    check("allowed is False even for what would be the target group", allowed is False)
    check("reason says not configured", "not configured" in reason, reason)


def test_describe_message_contents():
    print("\n-- describe_message_contents")
    check(
        "text only",
        sgf.describe_message_contents({"message": "hi"}) == "text",
    )
    check(
        "text + attachment",
        sgf.describe_message_contents(
            {"message": "hi", "attachments": [{"contentType": "image/jpeg"}]}
        )
        == "text,image/jpeg",
    )
    check(
        "empty message",
        sgf.describe_message_contents({}) == "(empty)",
    )


def test_allowlist_roundtrip():
    print("\n-- allowlist_add / allowlist_contains roundtrip")
    with tempfile.TemporaryDirectory() as td:
        allowlist = str(pathlib.Path(td) / "allowlist.txt")
        check("not present before add", sgf.allowlist_contains(allowlist, "att-1") is False)
        sgf.allowlist_add(allowlist, "att-1")
        check("present after add", sgf.allowlist_contains(allowlist, "att-1") is True)
        check(
            "a different id is still absent",
            sgf.allowlist_contains(allowlist, "att-2") is False,
        )
        # idempotent — adding twice does not duplicate or break lookup
        sgf.allowlist_add(allowlist, "att-1")
        content = pathlib.Path(allowlist).read_text()
        check("no duplicate entry", content.count("att-1") == 1, content)


def test_handle_pdf_attachment_ok():
    print("\n-- handle_pdf_attachment: text-layer PDF -> note file written, DB/log called")
    with tempfile.TemporaryDirectory() as td:
        attach_dir = pathlib.Path(td) / "attachments"
        attach_dir.mkdir()
        dump_dir = pathlib.Path(td) / "dumps"
        dump_dir.mkdir()
        shutil.copy(_FIXTURES / "text_layer_ok.pdf", attach_dir / "att-pdf-1")
        log_file = str(pathlib.Path(td) / "log.txt")
        import datetime

        ctx = {
            "attach_dir": str(attach_dir),
            "dump_dir": str(dump_dir),
            "db_path": str(pathlib.Path(td) / "nonexistent.duckdb"),
            "log_file": log_file,
            "pdf_extractor": str(_SCRIPTS_DIR / "extract_pdf_text.py"),
        }
        sgf.handle_pdf_attachment(
            {"id": "att-pdf-1", "contentType": "application/pdf"},
            datetime.datetime(2026, 8, 22, 9, 45),
            ctx,
        )
        out_files = list(dump_dir.glob("*-pdf-*.md"))
        check("exactly one note file written", len(out_files) == 1, out_files)
        if out_files:
            text = out_files[0].read_text()
            check(
                "note contains extracted text",
                "synthetic test PDF page" in text,
                text,
            )
        log_text = pathlib.Path(log_file).read_text()
        check("log records 'PDF extracted'", "PDF extracted" in log_text, log_text)


def test_handle_pdf_attachment_unsupported():
    print("\n-- handle_pdf_attachment: unsupported PDF -> stub note, distinct log wording")
    with tempfile.TemporaryDirectory() as td:
        attach_dir = pathlib.Path(td) / "attachments"
        attach_dir.mkdir()
        dump_dir = pathlib.Path(td) / "dumps"
        dump_dir.mkdir()
        shutil.copy(_FIXTURES / "no_font_no_dct.pdf", attach_dir / "att-pdf-2")
        log_file = str(pathlib.Path(td) / "log.txt")
        import datetime

        ctx = {
            "attach_dir": str(attach_dir),
            "dump_dir": str(dump_dir),
            "db_path": str(pathlib.Path(td) / "nonexistent.duckdb"),
            "log_file": log_file,
            "pdf_extractor": str(_SCRIPTS_DIR / "extract_pdf_text.py"),
        }
        sgf.handle_pdf_attachment(
            {"id": "att-pdf-2", "contentType": "application/pdf"},
            datetime.datetime(2026, 8, 22, 9, 45),
            ctx,
        )
        out_files = list(dump_dir.glob("*-pdf-unsupported-*.md"))
        check("exactly one stub file written", len(out_files) == 1, out_files)
        if out_files:
            text = out_files[0].read_text()
            check("stub clearly marked UNSUPPORTED", "UNSUPPORTED" in text, text)
            check(
                "stub does NOT look like a real transcript (no extracted text)",
                "synthetic test PDF page" not in text,
                text,
            )
        log_text = pathlib.Path(log_file).read_text()
        check(
            "log wording is 'unhandled:', distinct from group-exclusion 'ignored:'",
            "unhandled: PDF extraction unsupported" in log_text,
            log_text,
        )


def test_handle_pdf_attachment_missing_file():
    print("\n-- handle_pdf_attachment: attachment referenced but file absent")
    with tempfile.TemporaryDirectory() as td:
        attach_dir = pathlib.Path(td) / "attachments"
        attach_dir.mkdir()
        dump_dir = pathlib.Path(td) / "dumps"
        dump_dir.mkdir()
        log_file = str(pathlib.Path(td) / "log.txt")
        import datetime

        ctx = {
            "attach_dir": str(attach_dir),
            "dump_dir": str(dump_dir),
            "db_path": str(pathlib.Path(td) / "nonexistent.duckdb"),
            "log_file": log_file,
            "pdf_extractor": str(_SCRIPTS_DIR / "extract_pdf_text.py"),
        }
        sgf.handle_pdf_attachment(
            {"id": "att-pdf-missing", "contentType": "application/pdf"},
            datetime.datetime(2026, 8, 22, 9, 45),
            ctx,
        )
        out_files = list(dump_dir.glob("*.md"))
        check("no note file written", len(out_files) == 0, out_files)
        log_text = pathlib.Path(log_file).read_text()
        check(
            "log records the missing-file case",
            "not found" in log_text,
            log_text,
        )


def test_process_non_audio_attachments_dispatch():
    print("\n-- process_non_audio_attachments: mixed audio/pdf/image dispatch")
    with tempfile.TemporaryDirectory() as td:
        attach_dir = pathlib.Path(td) / "attachments"
        attach_dir.mkdir()
        dump_dir = pathlib.Path(td) / "dumps"
        dump_dir.mkdir()
        shutil.copy(_FIXTURES / "text_layer_ok.pdf", attach_dir / "att-pdf.pdf")
        (attach_dir / "att-img.jpg").write_bytes(b"fake jpeg bytes")
        log_file = str(pathlib.Path(td) / "log.txt")
        allowlist = str(pathlib.Path(td) / "allowlist.txt")
        import datetime

        ctx = {
            "attach_dir": str(attach_dir),
            "dump_dir": str(dump_dir),
            "db_path": str(pathlib.Path(td) / "nonexistent.duckdb"),
            "log_file": log_file,
            "pdf_extractor": str(_SCRIPTS_DIR / "extract_pdf_text.py"),
            "allowlist_file": allowlist,
        }
        sent = {
            "attachments": [
                {"id": "att-audio", "contentType": "audio/aac"},
                {"id": "att-pdf", "contentType": "application/pdf"},
                {"id": "att-img", "contentType": "image/jpeg"},
            ]
        }
        sgf.process_non_audio_attachments(
            sent, datetime.datetime(2026, 8, 22, 9, 45), ctx
        )
        check(
            "audio attachment recorded to allowlist (not transcribed here)",
            sgf.allowlist_contains(allowlist, "att-audio"),
        )
        check(
            "pdf attachment produced a note file",
            len(list(dump_dir.glob("*-pdf-*.md"))) == 1,
        )
        log_text = pathlib.Path(log_file).read_text()
        check(
            "image attachment logged as unhandled with its content type",
            "unhandled: no processor for content type 'image/jpeg'" in log_text,
            log_text,
        )
        check(
            "audio attachment is NOT logged as unhandled",
            "unhandled: no processor for content type 'audio/aac'" not in log_text,
            log_text,
        )


def main():
    test_classify_group_target_match()
    test_classify_group_wrong_group()
    test_classify_group_name_change_still_matches()
    test_classify_group_name_match_but_id_mismatch_is_rejected()
    test_classify_group_direct_message()
    test_classify_group_unconfigured_fails_closed()
    test_describe_message_contents()
    test_allowlist_roundtrip()
    test_handle_pdf_attachment_ok()
    test_handle_pdf_attachment_unsupported()
    test_handle_pdf_attachment_missing_file()
    test_process_non_audio_attachments_dispatch()

    print(f"\n=== Results: {PASS} passed, {FAIL} failed ===")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
