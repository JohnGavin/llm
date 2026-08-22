#!/usr/bin/env python3
"""extract_pdf_text.py — stdlib-only PDF text extraction with OCR fallback.

Context (llm#1001): the Signal braindump pipeline silently dropped PDF
attachments entirely (no text extraction, no log line). This script is the
committed, tested parser required by the reproducible-ingestion rule — it is
called as a subprocess from signal_group_filter.py, never invoked ad hoc.

Verified out-of-band (2026-08-22) against a real personal attachment that is
never committed to this repo and whose extracted content never leaves the
local-only knowledge store: no `/Font` entries anywhere in the file (no text
layer), `/DCTDecode`-encoded JPEG page scans, tesseract successfully OCRs the
carved pages. That shape (scanned document, image-only) is expected to be the
common case for this pipeline, but this script does not assume it is the
ONLY case:

  1. If the PDF has NO `/Font` anywhere, treat it as an image-only scan.
     Carve embedded JPEG images via a raw byte scan for SOI/EOI markers
     (FFD8FF...FFD9) and OCR each with tesseract (subprocess, not a Python
     import — no new Python dependency).
  2. If `/Font` IS present, attempt best-effort text-layer extraction:
     locate `stream...endstream` blocks, zlib-decompress the FlateDecode
     ones, and regex out Tj/TJ text-showing operators. This is NOT a
     general PDF text extractor — it does not handle CID/Type0 fonts,
     custom encodings, or column-aware reading order. A real general
     extractor would mean either shelling out to poppler's pdftotext
     (not on PATH on this machine) or pulling in pdfplumber (known nix
     build failures — llm#62, documented pip-venv fallback). Given a
     stdlib-only solution is sufficient for the common case this pipeline
     actually sees (simple single-byte-encoded content streams), and a
     WRONG silent transcript is worse than no transcript, this extractor
     verifies its own output: if the regex extraction yields no usable
     text despite `/Font` being present, that is reported as unsupported,
     not silently returned as an empty "success".
  3. Anything else (e.g. non-DCTDecode raster images with no font, such as
     raw FlateDecode-encoded samples) is explicitly unsupported — rasterising
     an arbitrary image stream needs real image-format handling (dimensions,
     color space, bit depth) that this script does not attempt. Reported,
     not guessed at.

Exit codes (the caller distinguishes these, mirroring the existing whisper
integration's success/failure handling):
  0  success  — extracted text on stdout, at least one usable character
  2  unsupported — nothing could be safely extracted; reason on stderr
  1  error    — something broke while trying (bad path, tesseract crash,
                unexpected exception); reason on stderr

No network access. No third-party Python imports. tesseract is invoked as an
external subprocess, resolved via PATH (overridable through TESSERACT_BIN for
tests) with a fallback to the known Homebrew location.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zlib

# Minimum extracted-text length before we trust it as "usable" rather than
# noise/empty. Chosen conservatively low (a real page of prose is hundreds of
# characters; a single stray character from a mis-decoded stream should not
# count as success).
_MIN_USABLE_CHARS = 20
_MIN_OCR_CHARS = 5

_STR_RE = re.compile(rb"\((?:[^()\\]|\\.)*\)")
_OP_RUN_RE = re.compile(
    rb"((?:[\[\]\s]|\((?:[^()\\]|\\.)*\)|-?\d+(?:\.\d+)?)+)(Tj|TJ)\b"
)
_STREAM_RE = re.compile(rb"stream\r?\n(.*?)endstream", re.DOTALL)

_OCTAL_ESCAPES = {0x6E: 10, 0x72: 13, 0x74: 9, 0x62: 8, 0x66: 12}  # n r t b f


def _unescape_pdf_string(raw):
    """Un-escape a PDF literal string token, INCLUDING its surrounding parens."""
    inner = raw[1:-1]
    out = bytearray()
    i = 0
    n = len(inner)
    while i < n:
        c = inner[i]
        if c == 0x5C and i + 1 < n:  # backslash
            nxt = inner[i + 1]
            if nxt in _OCTAL_ESCAPES:
                out.append(_OCTAL_ESCAPES[nxt])
                i += 2
                continue
            if nxt in (0x28, 0x29, 0x5C):  # ( ) backslash
                out.append(nxt)
                i += 2
                continue
            if 0x30 <= nxt <= 0x37:  # octal escape, up to 3 digits
                j = i + 1
                digits = b""
                while j < n and len(digits) < 3 and 0x30 <= inner[j] <= 0x37:
                    digits += inner[j : j + 1]
                    j += 1
                out.append(int(digits, 8) & 0xFF)
                i = j
                continue
            # Unknown escape (or line-continuation backslash-newline) — drop
            # the backslash, keep the next char literally.
            out.append(nxt)
            i += 2
            continue
        out.append(c)
        i += 1
    return out.decode("latin-1")


def carve_jpegs(data):
    """Return a list of byte-strings, each a carved JPEG (SOI..EOI)."""
    images = []
    start = 0
    while True:
        soi = data.find(b"\xff\xd8\xff", start)
        if soi == -1:
            break
        eoi = data.find(b"\xff\xd9", soi)
        if eoi == -1:
            break
        eoi += 2
        images.append(data[soi:eoi])
        start = eoi
    return images


def extract_text_layer(data):
    """Best-effort Tj/TJ text extraction from Flate-compressed content
    streams. See module docstring for the documented limitations."""
    chunks = []
    for m in _STREAM_RE.finditer(data):
        raw = m.group(1)
        try:
            dec = zlib.decompress(raw)
        except Exception:
            continue  # not Flate-compressed, or not a real content stream
        if b"Tj" not in dec and b"TJ" not in dec:
            continue
        for op_match in _OP_RUN_RE.finditer(dec):
            run = op_match.group(1)
            for s in _STR_RE.finditer(run):
                chunks.append(_unescape_pdf_string(s.group(0)))
            chunks.append(" ")
        chunks.append("\n")
    return "".join(chunks).strip()


def _resolve_tesseract():
    override = os.environ.get("TESSERACT_BIN")
    if override:
        return override
    found = shutil.which("tesseract")
    if found:
        return found
    fallback = "/opt/homebrew/bin/tesseract"
    if os.path.isfile(fallback):
        return fallback
    return None


def ocr_image(tesseract_bin, jpeg_bytes, tmp_dir, index, timeout=60):
    img_path = os.path.join(tmp_dir, f"page_{index}.jpg")
    with open(img_path, "wb") as f:
        f.write(jpeg_bytes)
    out_base = os.path.join(tmp_dir, f"page_{index}_out")
    result = subprocess.run(
        [tesseract_bin, img_path, out_base],
        capture_output=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"tesseract exited {result.returncode}: "
            f"{result.stderr.decode(errors='replace')[:200]}"
        )
    txt_path = out_base + ".txt"
    if not os.path.isfile(txt_path):
        raise RuntimeError("tesseract produced no output file")
    with open(txt_path, encoding="utf-8", errors="replace") as f:
        return f.read()


def extract(pdf_path):
    """Core extraction logic, independent of process exit-code plumbing.

    Returns (status, payload) where status is 'ok' | 'unsupported' | 'error'
    and payload is the extracted text (for 'ok') or a human-readable reason
    (for 'unsupported' / 'error').
    """
    try:
        with open(pdf_path, "rb") as f:
            data = f.read()
    except OSError as e:
        return "error", f"cannot read {pdf_path}: {e}"

    has_font = b"/Font" in data
    has_dct = b"/DCTDecode" in data

    if has_font:
        text = extract_text_layer(data)
        if len(text) >= _MIN_USABLE_CHARS:
            return "ok", text
        return "unsupported", (
            "/Font present (text layer expected) but best-effort Tj/TJ "
            "extraction yielded no usable text — likely a CID/Type0 font, "
            "non-Flate content stream, or unsupported encoding this "
            "stdlib-only extractor cannot decode"
        )

    if has_dct:
        tesseract_bin = _resolve_tesseract()
        if not tesseract_bin:
            return "unsupported", "no text layer and tesseract not found on PATH"
        images = carve_jpegs(data)
        if not images:
            return "unsupported", (
                "/DCTDecode present but no JPEG SOI/EOI markers could be carved"
            )
        tmp_dir = tempfile.mkdtemp(prefix="pdf_ocr_")
        try:
            pages = []
            any_error = []
            for idx, jpeg in enumerate(images, start=1):
                try:
                    page_text = ocr_image(tesseract_bin, jpeg, tmp_dir, idx)
                except Exception as e:  # noqa: BLE001 — report, don't crash the batch
                    any_error.append(f"page {idx}: {e}")
                    page_text = ""
                pages.append(f"--- page {idx} ---\n{page_text.strip()}")
            text = "\n\n".join(pages).strip()
        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)

        if len(text.replace("--- page", "").strip()) < _MIN_OCR_CHARS:
            reason = "OCR ran but produced no usable text on any carved image"
            if any_error:
                reason += "; errors: " + "; ".join(any_error)
            return "unsupported", reason
        return "ok", text

    return "unsupported", (
        "no /Font (no text layer) and no /DCTDecode images — PDF page "
        "images (if any) use an encoding this stdlib-only extractor cannot "
        "rasterise (e.g. raw FlateDecode samples)"
    )


def main(argv):
    if len(argv) != 2:
        print("usage: extract_pdf_text.py <pdf_path>", file=sys.stderr)
        return 1
    status, payload = extract(argv[1])
    if status == "ok":
        print(payload)
        return 0
    if status == "unsupported":
        print(payload, file=sys.stderr)
        return 2
    print(payload, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
