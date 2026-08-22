#!/usr/bin/env python3
"""test_extract_pdf_text.py — tests for .claude/scripts/extract_pdf_text.py
(llm#1001).

All fixtures under tests/fixtures/pdf/ are SYNTHETIC — no real Signal
attachment content, no PII. text_layer_*.pdf fixtures are hand-built minimal
PDFs (not produced by a real PDF writer) containing only placeholder
sentences; ocr_sample.jpg / dct_ocr_ok.pdf contain only the literal string
"TEST PAGE ONE" rendered as an image.

The extractor was ALSO verified once, manually, out-of-band, against a real
personal attachment (2026-08-22) — exit 0, 4 pages, 1213 words extracted.
That verification is not reproduced here: the source file lives under
~/.local/share/signal-cli/attachments/, was read but never copied, and its
extracted content was never written to disk, committed, or printed — see the
session report for the exact commands used.

Run with: python3 tests/python/test_extract_pdf_text.py
No external dependencies beyond the stdlib. Exits non-zero on any failure.
"""
from __future__ import annotations

import pathlib
import shutil
import sys

_SCRIPTS_DIR = pathlib.Path(__file__).parent.parent.parent / ".claude" / "scripts"
_FIXTURES = pathlib.Path(__file__).parent.parent / "fixtures" / "pdf"
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

import extract_pdf_text as ep  # noqa: E402

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


def test_text_layer_ok():
    print("\n-- text-layer PDF with extractable Tj text")
    status, payload = ep.extract(str(_FIXTURES / "text_layer_ok.pdf"))
    check("status is 'ok'", status == "ok", status)
    check(
        "extracted text matches fixture sentence",
        "synthetic test PDF page" in payload,
        payload,
    )


def test_text_layer_tj_array():
    print("\n-- text-layer PDF with a TJ kerning array (multi-chunk words)")
    status, payload = ep.extract(str(_FIXTURES / "text_layer_tj_array.pdf"))
    check("status is 'ok'", status == "ok", status)
    check(
        "kerned word chunks join without spurious spaces",
        "Hello World, synthetic multichunk PDF test" in payload,
        payload,
    )


def test_text_layer_unsupported():
    print("\n-- /Font present but content stream has no recoverable Tj/TJ text")
    status, payload = ep.extract(str(_FIXTURES / "text_layer_unsupported.pdf"))
    check("status is 'unsupported'", status == "unsupported", status)
    check("reason mentions no usable text", "no usable text" in payload, payload)


def test_no_font_no_dct():
    print("\n-- neither /Font nor /DCTDecode present")
    status, payload = ep.extract(str(_FIXTURES / "no_font_no_dct.pdf"))
    check("status is 'unsupported'", status == "unsupported", status)
    check(
        "reason names the missing encoding",
        "FlateDecode" in payload or "encoding" in payload,
        payload,
    )


def test_dct_ocr_ok():
    print("\n-- /DCTDecode image PDF, OCR round-trip")
    if not shutil.which("tesseract") and not pathlib.Path(
        "/opt/homebrew/bin/tesseract"
    ).is_file():
        print("  SKIP: tesseract not available on this machine")
        return
    status, payload = ep.extract(str(_FIXTURES / "dct_ocr_ok.pdf"))
    check("status is 'ok'", status == "ok", status)
    check("OCR recovered the fixture text", "TEST PAGE ONE" in payload, payload)
    check("page marker present", "--- page 1 ---" in payload, payload)


def test_carve_jpegs_empty():
    print("\n-- carve_jpegs on bytes with no JPEG markers")
    images = ep.carve_jpegs(b"no markers here at all")
    check("returns empty list", images == [], images)


def test_carve_jpegs_multiple():
    print("\n-- carve_jpegs finds two concatenated minimal JPEG-shaped blobs")
    jpeg1 = b"\xff\xd8\xff" + b"A" * 5 + b"\xff\xd9"
    jpeg2 = b"\xff\xd8\xff" + b"B" * 5 + b"\xff\xd9"
    images = ep.carve_jpegs(jpeg1 + b"junk-between" + jpeg2)
    check("found exactly two images", len(images) == 2, len(images))
    check("first image matches", images[0] == jpeg1 if images else False)
    check("second image matches", images[1] == jpeg2 if len(images) > 1 else False)


def test_missing_file():
    print("\n-- missing PDF path")
    status, payload = ep.extract(str(_FIXTURES / "does_not_exist.pdf"))
    check("status is 'error'", status == "error", status)
    check("reason mentions the path", "does_not_exist.pdf" in payload, payload)


def test_cli_exit_codes():
    print("\n-- CLI exit codes match extract() status (ok=0, unsupported=2, error=1)")
    check("main() ok -> 0", ep.main(["x", str(_FIXTURES / "text_layer_ok.pdf")]) == 0)
    check(
        "main() unsupported -> 2",
        ep.main(["x", str(_FIXTURES / "no_font_no_dct.pdf")]) == 2,
    )
    check(
        "main() error -> 1",
        ep.main(["x", str(_FIXTURES / "does_not_exist.pdf")]) == 1,
    )
    check("main() usage -> 1", ep.main(["x"]) == 1)


def main():
    test_text_layer_ok()
    test_text_layer_tj_array()
    test_text_layer_unsupported()
    test_no_font_no_dct()
    test_dct_ocr_ok()
    test_carve_jpegs_empty()
    test_carve_jpegs_multiple()
    test_missing_file()
    test_cli_exit_codes()

    print(f"\n=== Results: {PASS} passed, {FAIL} failed ===")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
