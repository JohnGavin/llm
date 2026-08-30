#!/usr/bin/env python3
# content_shingles.py — shared word-shingle fingerprinting for the
# external-code-zero-trust Layer 3 defence (llm#194, 2026-08-30).
#
# WHY THIS FILE EXISTS
# ---------------------
# Both external_content_fingerprint.sh (PostToolUse:WebFetch — captures a
# fingerprint of quarantined fetch content) and edit_write_similarity_guard.sh
# (PreToolUse:Edit|Write — compares new file content against recent
# fingerprints) need to compute the EXACT SAME fingerprint shape from text,
# or a genuine verbatim copy would hash to two different signatures and the
# comparison would silently never match. One logical thing, one file — same
# rationale as lib/cred_patterns.py (llm#960 Part 3) and
# lib/domain_allowlist.sh.
#
# WHAT THIS IS NOT
# -----------------
# This is NOT a cryptographic or academically-rigorous similarity measure.
# It is a deliberately simple word-shingle (n-gram) hash set with a Jaccard
# overlap comparator — good enough to flag "this new file content overlaps
# heavily with recently-fetched content from an untrusted domain" as a WARN
# signal, not good enough (and not intended) to be a hard BLOCK gate. See
# edit_write_similarity_guard.sh's header for why this layer warns instead
# of blocking, and external-code-zero-trust.md's Layer Map entry for Layer 3.
#
# IMPORT-SAFE: importing this module has no side effects — it only defines
# pure functions.

import hashlib
import re

# Words per shingle. 8 is long enough that ordinary short paraphrases (a
# re-implemented function using different names, same overall shape) score
# LOW overlap, while a genuine copy-paste of a paragraph or more scores HIGH
# overlap. Too short (e.g. 2-3 words) would flag any two files that share
# common code idioms ("import json", "return None") as similar.
SHINGLE_SIZE = 8

# Cap on the number of shingles kept per fingerprint, to bound file size and
# comparison cost. When a text produces more than this many shingles, keep a
# deterministic evenly-spaced sample rather than truncating to the first N —
# truncating would only ever compare the START of long content, missing a
# copy that lands in the middle or end of a large fetched page.
MAX_SHINGLES = 400


def normalize_text(text):
    """Lowercase, collapse all whitespace runs to single spaces, strip code
    fence markers and markdown punctuation that would otherwise make a
    reformatted (but otherwise identical) copy score as dissimilar.
    """
    if not text:
        return ""
    t = text.lower()
    # Strip markdown/code-fence noise that reformatting commonly changes.
    t = re.sub(r"```[a-zA-Z0-9_+-]*", " ", t)
    t = re.sub(r"[`*_#>|]", " ", t)
    t = re.sub(r"\s+", " ", t)
    return t.strip()


def _word_tokens(normalized_text):
    return normalized_text.split(" ") if normalized_text else []


def shingle_hashes(text, shingle_size=SHINGLE_SIZE, max_shingles=MAX_SHINGLES):
    """Return a sorted list of distinct integer hashes, one per word-shingle
    of `shingle_size` consecutive words in the normalized text. Deterministic
    across processes (uses sha1, not Python's randomized `hash()`).

    Returns an empty list for text shorter than one shingle — callers must
    treat an empty list as "no signal", never as "identical to everything"
    or "identical to nothing" (an empty-vs-empty Jaccard comparison is
    defined as 0.0 overlap by jaccard_overlap() below, precisely to avoid
    that trap).
    """
    tokens = _word_tokens(normalize_text(text))
    if len(tokens) < shingle_size:
        return []
    shingles = set()
    for i in range(len(tokens) - shingle_size + 1):
        shingle = " ".join(tokens[i : i + shingle_size])
        h = int(hashlib.sha1(shingle.encode("utf-8")).hexdigest()[:16], 16)
        shingles.add(h)
    result = sorted(shingles)
    if len(result) > max_shingles:
        # Deterministic evenly-spaced sample across the full sorted range —
        # not the first N — so a match landing anywhere in long content is
        # still representable in the capped set.
        step = len(result) / float(max_shingles)
        result = [result[int(i * step)] for i in range(max_shingles)]
    return result


def jaccard_overlap(hashes_a, hashes_b):
    """Jaccard similarity of two shingle-hash lists/sets: |A n B| / |A u B|.
    Returns 0.0 if either set is empty (no signal, not "identical" and not
    "opposite" — an empty intersection-over-union is mathematically 0/0,
    which this function defines as 0.0 rather than raising, so a caller
    comparing against a content-free fingerprint record never mistakes
    "nothing to compare" for "definitely different" in a way that would
    matter — it simply never triggers a WARN).
    """
    set_a = set(hashes_a)
    set_b = set(hashes_b)
    if not set_a or not set_b:
        return 0.0
    intersection = len(set_a & set_b)
    union = len(set_a | set_b)
    if union == 0:
        return 0.0
    return intersection / float(union)
