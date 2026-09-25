#!/usr/bin/env python3
"""roborev_classify.py — shared review-output classifier for reviews.db.

WHY THIS FILE EXISTS (llm#1035)
--------------------------------
``reviews.verdict_bool = 0`` in ~/.roborev/reviews.db conflates two very
different situations: "the review ran and found nothing" and "the review
never actually ran" (the agent crashed, refused, or could not read its own
snapshot diff because roborev writes it to a gitignored path). Every
consumer that reads reviews.db and treats verdict_bool/closed alone as
"clean" or "needs triage" inherits that ambiguity.

``send_roborev_email.R`` (the daily digest) already carries the fix for one
consumer -- ``classify_unparseable_finding()`` -- which splits a review whose
severity could not be parsed into three sub-populations:

  not_reviewed   review DID NOT HAPPEN (agent-health alert)
  passed         review ran, found nothing (correct, not a backlog item)
  unclassified   genuine residual -- matches neither shape (data-quality)

This module is the SAME classification logic, ported to Python, so every
OTHER consumer of reviews.db's ``output`` text (roborev_project_backlog.sh,
and any future script) classifies a review the same way instead of each
re-deriving its own ad-hoc parse.

R and Python cannot cheaply share one implementation here (send_roborev_email.R
is deliberately left untouched -- see llm#1035 dispatch notes), so this is a
parallel, NOT a wrapped, implementation. Keep the two in sync by hand:
NOT_REVIEWED_PATTERNS, PASSED_PATTERNS, and the severity regex below MUST
match send_roborev_email.R's copies verbatim. Parity between the two is
covered by tests/test_roborev_classify.sh, which classifies the exact same
fixture strings used in tests/testthat/test-roborev-daily-email.R and checks
the answers agree.

Usage:
    from roborev_classify import classify_review, parse_max_severity_ordinal

    outcome = classify_review(output_text)
    # -> "parsed" | "not_reviewed" | "passed" | "unclassified"

STRUCTURED_OUTPUT (llm#1265, roborev v0.68.2 schema migration)
----------------------------------------------------------------
2026-09-24: roborev v0.68.2 migrated every row's review text out of
``reviews.output`` (now an empty string on all 9,863 live rows) into a new
``reviews.structured_output`` column -- JSON, keyed by ``schema_version``:

  schema_version 0  -- the ORIGINAL pre-migration text, copied verbatim into
                       ``data["legacy"]["markdown"]``. Top-level "findings"
                       and "summary" are always empty/[] for these rows --
                       the real content lives in "legacy.markdown".
  schema_version 1  -- {"schema_version":1,"summary":str,"findings":[...]}.
                       No "verdict" key. An EMPTY "findings" list here (most
                       of the live backlog: 4,021 of 7,466 schema_version-1
                       rows) means the review ran and found nothing -- there
                       is no separate "clean" signal, the empty list IS it.
  schema_version 2  -- adds a top-level "verdict": "pass"|"fail". Each
                       finding is {"severity","problem","fix","location"}
                       (severity always lowercase: critical/high/medium/low).

Rather than teach every consumer's Location:/Problem:/Severity:/Category:
regex and NOT_REVIEWED_PATTERNS/PASSED_PATTERNS substring matching a second,
JSON-shaped code path, ``review_output_text()`` below RECONSTRUCTS the same
markdown shape those regexes already expect (verbatim for schema_version 0,
synthesized from verdict/summary/findings for schema_version >= 1) and
falls back to the legacy ``output`` column when structured_output is
NULL/empty/unparseable. Every existing regex/substring consumer keeps
working unmodified against the reconstructed text -- callers only need to
select ``structured_output`` alongside ``output`` and swap in
``review_output_text(output, structured_output)`` wherever they used to
read the raw ``output`` column directly.

``classify_review_row()`` adds one NEW terminal state beyond
``classify_review()``'s four: "indeterminate" -- BOTH ``output`` and
``structured_output`` are empty/NULL/unparseable, i.e. there is no review
text to classify at all. This is the llm#1265 fix's requirement #3 ("both
columns empty/NULL" must never read as clean) made explicit and testable,
rather than relying on every caller's pre-existing fail-closed handling of
an empty string to (correctly, but implicitly) achieve the same thing.

SEVERITY IS JSON-DIRECT, NEVER REGEX-OVER-RENDERED-TEXT (PR #1269 round 3,
2026-09-25)
----------------------------------------------------------------------------
The first version of this module computed severity by calling
``parse_max_severity_ordinal()`` (a ``Severity:``/``**Severity**:`` regex)
over the text ``review_output_text()`` synthesizes from JSON findings. That
text includes each finding's own free-form ``problem``/``fix`` prose --
which can itself quote a severity marker as an EXAMPLE (e.g. a finding
recommending "Add a fixture where ... a real 'Severity: High' review").
Live proof: review ids 10523/10524 in ~/.roborev/reviews.db each have a
JSON ``findings`` list whose real max severity is "medium", but the
regex-over-rendered-text path read "high" because a lower-severity
finding's own ``problem`` text quoted "Severity: High"/"**Severity**:
High" as illustration.

``review_severity_ordinal()`` below fixes this: for a structured row with
a recognised ``schema_version`` (1 or 2) and a non-empty ``findings``
list, it reads each finding's ``severity`` JSON field DIRECTLY (via
``_findings_max_severity_ordinal()``) and takes the max ordinal --
``problem``/``fix`` prose is never consulted for severity at all, so a
quoted marker inside it cannot inflate the result. ``review_top_finding()``
extends the same JSON-direct reasoning to LOCATION/PROBLEM: it returns the
single finding whose severity is the row's max, sourced directly from its
``location``/``problem`` JSON fields, so a caller displaying "the finding
that drove this row's severity" never has to regex the rendered text
either. Schema_version 0 rows (pre-migration free text, no structured
findings to read) and any row whose only usable text is the legacy
``output`` column fall back to the regex path exactly as before -- there
is no structured JSON to read a severity/location/problem field from in
that case, so the fallback is unchanged, deliberate, and still correct.

Known gap NOT fixed here (out of scope for llm#1265, flagged 2026-09-25):
NOT_REVIEWED_PATTERNS in this file has 7 entries; send_roborev_email.R's
copy has grown 4 more since (llm#1127/#1141: "inaccessible due to
configured ignore patterns", "unable to proceed with the review", "blocked
by ignore patterns", "blocked by configured ignore patterns"). This
pre-dates the structured_output migration and is unrelated to it -- a
pre-existing sync gap between the two files, not introduced or widened by
this change. Tracked for a follow-up, not fixed in this PR.

Self-test:
    python3 roborev_classify.py --selftest
"""
import json
import re
import sys

SEVERITY_ORDINAL = {"critical": 4, "high": 3, "medium": 2, "low": 1}

# Mirrors send_roborev_email.R NOT_REVIEWED_PATTERNS (llm#1035). Keep in sync.
NOT_REVIEWED_PATTERNS = [
    "no review output generated",
    "unable to access",
    "cannot perform the requested code review",
    "unable to read the diff",
    "unable to perform the code review",
    "diff file could not be read",
    "ignored by configured ignore patterns",
]

# Mirrors send_roborev_email.R PASSED_PATTERNS (llm#1035). Keep in sync.
# "no issues were found" and "no review found for empty diff" were added to
# the R list independently (llm#972/#1035 follow-ups) without a matching
# update here -- caught 2026-09-10 via a live daily-report self-diagnostic
# (roborev review #10051 misclassified "unclassified" here, "passed" in R).
# tests/test_roborev_classify.sh's parity fixtures never covered either
# phrase, which is why the drift went undetected; both are now fixtures.
PASSED_PATTERNS = [
    "severity_threshold_met",
    "no issues found",
    "no issues were found",
    "no code changes were provided",
    "no review found for empty diff",
]

# Mirrors send_roborev_email.R parse_max_severity_ordinal()'s regex --
# \*{0,2} around "Severity" and around the colon makes bold markdown markers
# optional on EITHER side of the colon, so all of "Severity: High",
# "**Severity**: High" (bold closes before the colon), AND "**Severity:**
# High" (bold closes after the colon -- 2026-09-10, llm daily-report
# self-diagnostic, ids 9480/9652/9659/9661/9662 in the live backlog) parse.
# Matched against whitespace-normalised text (see parse_max_severity_ordinal
# below) so an embedded newline splitting "Severity" from its trailing "**:"
# (id 9617) doesn't break the match either.
_SEVERITY_RE = re.compile(
    r"\*{0,2}Severity\s*\*{0,2}\s*:\s*\*{0,2}\s*(Critical|High|Medium|Low)",
    re.IGNORECASE,
)


def normalize_ws(text):
    """Collapse all whitespace runs (including embedded newlines) to a
    single space. Stored `output` text can wrap mid-phrase (observed live:
    "No\\nissues found"), so a literal substring match on raw text silently
    misses exactly the cases this classifier exists to catch."""
    if text is None:
        return ""
    return re.sub(r"\s+", " ", text.strip())


def parse_max_severity_ordinal(text):
    """Return the highest severity ordinal (1-4) found in text, or None if
    no `Severity:` marker was found at all."""
    if not text:
        return None
    words = _SEVERITY_RE.findall(normalize_ws(text))
    if not words:
        return None
    return max(SEVERITY_ORDINAL[w.lower()] for w in words)


def _pattern_matches(text_norm, patterns):
    return any(p in text_norm for p in patterns)


def classify_unparseable_finding(text):
    """Classify a review whose severity could NOT be parsed.
    Returns one of "not_reviewed" | "passed" | "unclassified".
    "unclassified" is the deliberate residual -- matches neither known shape
    -- and MUST stay visible on its own rather than being folded into either
    named bucket, so a genuinely new failure mode doesn't disappear into a
    total."""
    norm = normalize_ws(text).lower()
    if _pattern_matches(norm, NOT_REVIEWED_PATTERNS):
        return "not_reviewed"
    if _pattern_matches(norm, PASSED_PATTERNS):
        return "passed"
    return "unclassified"


def classify_review(text):
    """Classify a review's `output` text end-to-end.
    Returns one of "parsed" | "not_reviewed" | "passed" | "unclassified".

    "parsed" means a `Severity:` marker was found -- callers that need the
    threshold-relative comparison should call parse_max_severity_ordinal()
    directly and compare against their own threshold; this function only
    tells you whether a row falls in the unparseable bucket and, if so,
    which sub-population."""
    if parse_max_severity_ordinal(text) is not None:
        return "parsed"
    return classify_unparseable_finding(text)


# ── structured_output reader (llm#1265) ────────────────────────────────────

def _parse_structured_json(structured_output):
    """Parse ``structured_output`` as JSON. Returns a dict, or None if the
    value is None/empty/not valid JSON/not a JSON object -- any of which
    means "nothing usable here, fall back to legacy output text"."""
    if not structured_output:
        return None
    try:
        data = json.loads(structured_output)
    except (ValueError, TypeError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def _legacy_markdown_from_structured(data):
    """schema_version 0 rows carry the ORIGINAL pre-migration markdown text
    verbatim under data['legacy']['markdown'] (roborev's own migration
    copied it there byte-for-byte). Returns that string, or None if absent
    or blank."""
    legacy = data.get("legacy")
    if isinstance(legacy, dict):
        md = legacy.get("markdown")
        if isinstance(md, str) and md.strip():
            return md
    return None


def _render_structured_findings_as_markdown(data):
    """Reconstruct markdown-equivalent text from a schema_version >= 1
    structured_output dict (verdict/summary/findings) so every EXISTING
    regex/substring consumer (Severity:/Location:/Problem:/Category:
    markers, NOT_REVIEWED_PATTERNS, PASSED_PATTERNS) keeps working
    unchanged against JSON-backed data -- this is the shared reader's core
    trick: synthesize equivalent text, don't rewrite every regex."""
    findings = data.get("findings")
    if not isinstance(findings, list):
        findings = []
    summary = data.get("summary") or ""
    verdict = data.get("verdict")
    schema_version = data.get("schema_version")
    # llm#1265 finding 2: only a RECOGNISED schema_version (1 or 2 today --
    # see this module's docstring) may reach the "No issues found."/
    # Summary-only paths below when findings is empty. Before this fix,
    # `elif verdict in (None, "pass")` fired for ANY empty-findings dict
    # whose verdict key happened to be absent -- which includes {} (no
    # schema_version key at all), a schema_version 0 row whose
    # legacy.markdown is blank/missing (already failed that path above,
    # before this function was even called), and an unrecognised
    # schema_version (e.g. a future 3+ this reader has never heard of) --
    # all three were silently rendered as "No issues found." and then
    # classified "passed", exactly the "both columns empty must never read
    # as clean" requirement (llm#1265 requirement #3) this reader exists to
    # satisfy. Such a row has nothing reliable to synthesize from, so it
    # must classify as INDETERMINATE instead -- returning "" here achieves
    # that via review_output_text()'s existing empty-text handling, with no
    # separate branch needed. Findings-non-empty rendering below is
    # UNAFFECTED by this gate -- a genuine finding is real signal
    # regardless of whether this function recognises its schema_version.
    known_schema = (
        isinstance(schema_version, int)
        and not isinstance(schema_version, bool)
        and schema_version in (1, 2)
    )

    lines = []
    if findings:
        lines.append("## Review Findings")
        lines.append("")
        for f in findings:
            if not isinstance(f, dict):
                continue
            sev = str(f.get("severity") or "").strip()
            lines.append("- **Severity**: {}".format(sev.capitalize()))
            loc = f.get("location")
            if loc:
                lines.append("  **Location**: {}".format(loc))
            problem = f.get("problem")
            if problem:
                lines.append("  **Problem**: {}".format(problem))
            fix = f.get("fix")
            if fix:
                lines.append("  **Fix**: {}".format(fix))
            lines.append("")
    elif not known_schema:
        return ""
    elif verdict in (None, "pass"):
        # A v1/v2 review that ran and found nothing (schema_version 1 has
        # no "verdict" key at all -- an empty findings list alone IS the
        # clean signal there; schema_version 2 makes it explicit via
        # verdict=="pass"). Synthesize the exact phrase PASSED_PATTERNS
        # already matches so every existing consumer's substring/prefix
        # check keeps working without a second code path. A verdict of
        # "fail" with an empty findings list (never observed live, but not
        # provably impossible) is a data inconsistency -- deliberately NOT
        # synthesized as clean; the render stays finding-less and
        # summary-only, which downstream classifies as "unclassified", not
        # "passed".
        lines.append("No issues found.")
        lines.append("")

    lines.append("## Summary")
    lines.append("")
    lines.append(summary)
    return "\n".join(lines).strip()


def review_output_text(output, structured_output):
    """THE shared reader (llm#1265). Returns the best available plain-text
    rendering of a review row, so every consumer's EXISTING Severity:/
    Location:/Problem:/Category: regex and NOT_REVIEWED_PATTERNS/
    PASSED_PATTERNS substring matching keeps working unchanged regardless
    of which schema the row was written under.

    Priority:
      1. structured_output, schema_version 0 -> legacy.markdown verbatim.
      2. structured_output, schema_version >= 1 -> synthesized markdown
         from verdict/summary/findings.
      3. legacy `output` column text -- used both for pre-v0.68.2 rows (no
         structured_output at all) AND, since PR #1269 round 3 (review id
         10523: "when structured_output is valid-but-unusable JSON, fall
         back to legacy output text... before returning ''"), for a row
         whose structured_output IS valid JSON but yields nothing
         renderable (`{}`, an unrecognised/missing schema_version, or
         schema_version 0 with a blank/missing legacy.markdown). Before
         this fix such a row returned "" straight from the structured
         branch and never consulted `output` at all, even when `output`
         held real text -- silently discarding a usable fallback the
         docstring above already promised as priority 3.
      4. "" when BOTH are empty/unusable -- callers MUST treat "" as
         INDETERMINATE, never as "passed"/"clean" (llm#1265 requirement
         #3). Every existing consumer already fails closed on "" (no
         Severity: marker -> unparseable -> classify_unparseable_finding("")
         -> "unclassified", never "passed"), so this is a safe drop-in even
         for callers not yet updated to check the indeterminate case
         explicitly. classify_review_row() below makes the state explicit
         for callers that want it.
    """
    data = _parse_structured_json(structured_output)
    if data is not None:
        legacy_md = _legacy_markdown_from_structured(data)
        if legacy_md is not None:
            return legacy_md
        rendered = _render_structured_findings_as_markdown(data)
        if rendered:
            return rendered
        # structured_output was valid JSON but produced nothing usable
        # (unrecognised schema, {}, or blank legacy.markdown) -- fall
        # through to the legacy `output` column rather than giving up.
    return (output or "").strip()


# ── JSON-direct severity / top-finding reader (PR #1269 round 3) ───────────
# See the module docstring's "SEVERITY IS JSON-DIRECT..." section for why
# this exists: parse_max_severity_ordinal() over review_output_text()'s
# SYNTHESIZED text is vulnerable to a finding's own problem/fix prose
# quoting a severity marker as an example. The functions below read
# `findings[].severity` (and `.location`/`.problem`) directly from the
# parsed JSON for schema_version 1/2 rows with a non-empty findings list,
# and only fall back to the regex-over-text path when there is no
# structured findings list to read from at all.


def _known_structured_schema(schema_version):
    """True iff `schema_version` is the Python int 1 or 2 (never a bool --
    `isinstance(True, int)` is True in Python, and a JSON boolean has no
    business being treated as a schema version)."""
    return (
        isinstance(schema_version, int)
        and not isinstance(schema_version, bool)
        and schema_version in (1, 2)
    )


def _structured_findings_normalized(data):
    """Return a list of dicts ``{"ordinal", "severity", "location",
    "problem"}`` read DIRECTLY from a schema_version 1/2 dict's JSON
    `findings` entries -- never via regex over rendered text. Returns None
    when there is nothing usable to read (unrecognised/missing
    schema_version, findings missing/empty, or no entry has a recognised
    `severity` value) -- callers MUST treat None as "fall back to the
    legacy regex-over-text path", NOT as "no findings" (which is
    represented by a present-but-recognised-empty findings list and is a
    genuine "passed" state, handled by the caller BEFORE this function is
    even reached in practice, but this function stays agnostic to that
    distinction and simply reports what it could read)."""
    if not _known_structured_schema(data.get("schema_version")):
        return None
    findings = data.get("findings")
    if not isinstance(findings, list) or not findings:
        return None
    out = []
    for f in findings:
        if not isinstance(f, dict):
            continue
        sev = f.get("severity")
        if not isinstance(sev, str):
            continue
        ordv = SEVERITY_ORDINAL.get(sev.strip().lower())
        if ordv is None:
            continue
        loc = f.get("location")
        problem = f.get("problem")
        out.append({
            "ordinal": ordv,
            "severity": sev.strip().lower(),
            "location": loc.strip() if isinstance(loc, str) and loc.strip() else None,
            "problem": problem.strip() if isinstance(problem, str) and problem.strip() else None,
        })
    return out if out else None


def review_structured_findings(output, structured_output):
    """Public entry: parse `structured_output` and return
    _structured_findings_normalized(data), or None if structured_output is
    not usable JSON at all (malformed, not an object, empty/NULL). None
    means "no per-finding JSON to read -- use review_output_text() with
    your own regex instead"; this is the schema_version 0 / legacy-`output`
    -only case, which never had structured findings to begin with."""
    data = _parse_structured_json(structured_output)
    if data is None:
        return None
    return _structured_findings_normalized(data)


def review_severity_ordinal(output, structured_output):
    """Max severity ordinal (1-4) for a review row, sourced from EITHER
    column. For a structured row (schema_version 1/2, non-empty findings)
    this reads each finding's `severity` JSON field DIRECTLY -- NEVER via
    regex over rendered/synthesized text -- so a finding whose own
    `problem`/`fix` prose happens to quote a severity marker (e.g.
    "Severity: High" used as an illustrative example) cannot inflate the
    row's true max severity. See the module docstring's "SEVERITY IS
    JSON-DIRECT..." section for the live incident this fixes (review ids
    10523/10524 in ~/.roborev/reviews.db: true max severity "medium",
    regex-over-text read "high").

    Returns None if the row has no severity to report at all -- either a
    recognised structured schema with empty findings ("passed": nothing to
    fall back to, by design -- see below), or the legacy regex path found
    no `Severity:` marker.

    Falls back to `parse_max_severity_ordinal(review_output_text(...))`
    (the pre-existing regex path) for: schema_version 0 rows (real
    pre-migration free text, no per-finding JSON), an unrecognised/missing
    schema_version, structured_output that is not usable JSON at all, and
    (implicitly, via review_output_text()'s own fallback) the legacy
    `output` column. A RECOGNISED schema_version with an EMPTY findings
    list is NOT included in the fallback -- an empty findings list is
    itself the "review ran, found nothing" signal (schema_version 1 has no
    separate verdict key; schema_version 2 makes it explicit via
    verdict=="pass"), so there is genuinely no severity to report, and
    falling back to `output` there would risk resurrecting stale text from
    an unrelated column on a migrated row (`output` is empty on every live
    migrated row, so this is currently a no-op in practice, but the
    distinction is deliberate, not incidental)."""
    data = _parse_structured_json(structured_output)
    if data is not None:
        schema_version = data.get("schema_version")
        legacy_md = _legacy_markdown_from_structured(data)
        if legacy_md is not None:
            return parse_max_severity_ordinal(legacy_md)
        if _known_structured_schema(schema_version):
            findings = data.get("findings")
            normalized = _structured_findings_normalized(data)
            if normalized is not None:
                return max(f["ordinal"] for f in normalized)
            if isinstance(findings, list):
                # Recognised schema, but either genuinely empty (passed)
                # or non-empty with no entry carrying a recognised
                # severity value -- either way, nothing to report and
                # nothing to fall back to (see docstring above).
                return None
        # Unrecognised/missing schema_version and no legacy.markdown --
        # fall through to the legacy `output` column below (matches
        # review_output_text()'s own PR #1269-round-3 fallback fix).
    return parse_max_severity_ordinal(review_output_text(output, structured_output))


def review_top_finding(output, structured_output):
    """Return the finding dict (``{"ordinal","severity","location",
    "problem"}``) whose severity equals the row's max, sourced DIRECTLY
    from JSON for schema_version 1/2 rows -- so a caller wanting to show
    "the finding that drove this severity" never has to regex Location:/
    Problem: markers out of rendered text either (the same corruption risk
    as severity: a lower-severity finding's problem/fix prose could
    contain those literal marker strings too). Returns None when there is
    no structured findings list to read from (falls back the same way
    review_severity_ordinal() does -- callers needing a location/problem
    for a legacy/regex-path row must still parse review_output_text()
    themselves, unchanged pre-existing behaviour)."""
    normalized = review_structured_findings(output, structured_output)
    if not normalized:
        return None
    return max(normalized, key=lambda f: f["ordinal"])


def classify_review_row(output, structured_output):
    """The shared, explicit-outcome reader (llm#1265). Classifies a review
    row from EITHER column, preferring structured_output.

    Returns one of "parsed" | "not_reviewed" | "passed" | "unclassified" |
    "indeterminate":
      "parsed"        -- a severity marker was found (call
                          review_severity_ordinal() for the ordinal).
      "not_reviewed"  -- review did not run (agent-failure text).
      "passed"        -- review ran, found nothing.
      "unclassified"  -- genuine residual, matches no known shape.
      "indeterminate" -- BOTH output and structured_output are empty/NULL/
                          unparseable -- there is no review text at all to
                          classify. NEVER a "clean"/"passed" result.
    """
    text = review_output_text(output, structured_output)
    if not text:
        return "indeterminate"
    return classify_review(text)


# ── Self-test ─────────────────────────────────────────────────────────────
def _selftest():
    passed = 0
    failed = 0

    def check(label, expected, actual):
        nonlocal passed, failed
        if expected == actual:
            passed += 1
            print(f"  PASS [{label}]")
        else:
            failed += 1
            print(f"  FAIL [{label}]: expected={expected!r} got={actual!r}")

    # Fixtures taken verbatim from tests/testthat/test-roborev-daily-email.R
    # so this module classifies the SAME live-observed text the same way.
    not_reviewed_exact = "No review output generated"
    not_reviewed_agent_failure = (
        "I am unable to access the diff file at "
        "`/private/tmp/roborev-snapshot-content.diff` because it is ignored by "
        "configured ignore patterns. Consequently, I cannot perform the requested "
        "code review."
    )
    passed_threshold_met = "SEVERITY_THRESHOLD_MET"
    passed_no_issues_linebreak = "No\nissues found"
    passed_no_issues_were_found = (
        "Summary: The code review of the provided diff is complete. No issues "
        "were found in the changes."
    )
    passed_empty_diff = "No review found for empty diff."
    unclassified_prose = (
        "This review comment matches none of the known agent-failure or "
        "pass-through shapes and should remain visible as a genuine residual."
    )
    not_reviewed_live_unable_to_read = (
        "I am unable to read the diff file "
        "`/Users/x/repo/.roborev/roborev-snapshot-1/roborev-snapshot-content.diff` "
        "because it is ignored by configured ignore patterns."
    )
    not_reviewed_live_unable_to_perform = (
        "I am unable to perform the code review because the diff file at "
        "`/Users/x/repo/.roborev/roborev-snapshot-2/roborev-snapshot-content.diff` "
        "is not readable."
    )
    not_reviewed_live_could_not_be_read = (
        "Summary: Cannot review code changes as the diff file could not be read. "
        "Review Findings: none available."
    )
    high_sev_output = "- **Severity**: High\nSomething real was found."

    check("exact 'No review output generated' -> not_reviewed",
          "not_reviewed", classify_unparseable_finding(not_reviewed_exact))
    check("agent-failure prose -> not_reviewed",
          "not_reviewed", classify_unparseable_finding(not_reviewed_agent_failure))
    check("'SEVERITY_THRESHOLD_MET' -> passed",
          "passed", classify_unparseable_finding(passed_threshold_met))
    check("'No\\nissues found' (line break) -> passed",
          "passed", classify_unparseable_finding(passed_no_issues_linebreak))
    check("'No issues were found' -> passed (2026-09-10 parity fix, id 10051)",
          "passed", classify_unparseable_finding(passed_no_issues_were_found))
    check("'No review found for empty diff' -> passed (2026-09-10 parity fix)",
          "passed", classify_unparseable_finding(passed_empty_diff))
    check("unrecognised prose -> unclassified",
          "unclassified", classify_unparseable_finding(unclassified_prose))
    check("live 'unable to read the diff' -> not_reviewed",
          "not_reviewed", classify_unparseable_finding(not_reviewed_live_unable_to_read))
    check("live 'unable to perform the code review' -> not_reviewed",
          "not_reviewed", classify_unparseable_finding(not_reviewed_live_unable_to_perform))
    check("live 'diff file could not be read' -> not_reviewed",
          "not_reviewed", classify_unparseable_finding(not_reviewed_live_could_not_be_read))
    check("bold severity marker parses (regression guard)",
          3, parse_max_severity_ordinal(high_sev_output))
    check("classify_review(): real finding -> parsed",
          "parsed", classify_review(high_sev_output))
    check("classify_review(): not-reviewed text -> not_reviewed",
          "not_reviewed", classify_review(not_reviewed_exact))
    check("classify_review(): passed text -> passed",
          "passed", classify_review(passed_threshold_met))
    check("classify_review(): unclassified text -> unclassified",
          "unclassified", classify_review(unclassified_prose))
    check("classify_review(): empty text -> unclassified",
          "unclassified", classify_review(""))
    check("classify_review(): None -> unclassified",
          "unclassified", classify_review(None))
    check("no-bold 'Severity: High' still parses",
          3, parse_max_severity_ordinal("- Severity: High\nplain form"))

    # ── structured_output reader (llm#1265) ─────────────────────────────
    v2_with_findings = (
        '{"schema_version":2,"summary":"x","verdict":"fail",'
        '"findings":[{"severity":"medium","problem":"p1","location":"a.R:1","fix":"f1"},'
        '{"severity":"high","problem":"p2","location":"b.R:2","fix":"f2"}]}'
    )
    v2_pass_no_findings = (
        '{"schema_version":2,"summary":"clean diff","verdict":"pass","findings":[]}'
    )
    v1_empty_findings_no_verdict = (
        '{"schema_version":1,"summary":"trivial gitignore change","findings":[]}'
    )
    schema0_legacy = (
        '{"legacy":{"markdown":"- **Severity**: Critical\\n  '
        '**Problem**: bad thing","recorded_verdict":false},'
        '"schema_version":0,"summary":"","findings":[]}'
    )
    malformed_json = "{not valid json"
    legacy_text_only = "- **Severity**: Low\n  **Problem**: minor thing"
    not_reviewed_structured = (
        '{"schema_version":1,"summary":"I am unable to access the diff file",'
        '"findings":[]}'
    )
    # llm#1265 finding 2: valid JSON, empty findings, but nothing reliable
    # to render from -- each of these MUST classify as indeterminate, never
    # "passed", even though the pre-fix code synthesized "No issues found."
    # for every one of them.
    empty_object = "{}"
    schema0_blank_legacy = (
        '{"legacy":{"markdown":""},"schema_version":0,"summary":"","findings":[]}'
    )
    schema0_missing_legacy = '{"schema_version":0,"summary":"","findings":[]}'
    unknown_schema_version = (
        '{"schema_version":99,"summary":"x","findings":[]}'
    )
    missing_schema_version_key = '{"summary":"x","findings":[]}'

    check("review_severity_ordinal(): v2 JSON with medium+high findings -> 3 (high)",
          3, review_severity_ordinal(None, v2_with_findings))
    check("classify_review_row(): v2 JSON with findings -> parsed",
          "parsed", classify_review_row(None, v2_with_findings))
    check("classify_review_row(): v2 verdict=pass, no findings -> passed",
          "passed", classify_review_row(None, v2_pass_no_findings))
    check("review_severity_ordinal(): v2 pass/no-findings -> None",
          None, review_severity_ordinal(None, v2_pass_no_findings))
    check("classify_review_row(): v1 empty findings, no verdict key -> passed",
          "passed", classify_review_row(None, v1_empty_findings_no_verdict))
    check("classify_review_row(): schema_version 0 legacy.markdown -> parsed (Critical)",
          "parsed", classify_review_row(None, schema0_legacy))
    check("review_severity_ordinal(): schema_version 0 legacy.markdown -> 4 (critical)",
          4, review_severity_ordinal(None, schema0_legacy))
    check("classify_review_row(): malformed JSON falls back to legacy `output` text -> parsed",
          "parsed", classify_review_row(legacy_text_only, malformed_json))
    check("review_severity_ordinal(): malformed JSON falls back to legacy `output` -> 1 (low)",
          1, review_severity_ordinal(legacy_text_only, malformed_json))
    check("classify_review_row(): BOTH output and structured_output empty -> indeterminate",
          "indeterminate", classify_review_row("", None))
    check("classify_review_row(): BOTH output and structured_output None -> indeterminate",
          "indeterminate", classify_review_row(None, None))
    check("classify_review_row(): malformed JSON AND empty output -> indeterminate",
          "indeterminate", classify_review_row("", malformed_json))
    check("classify_review_row(): structured_output not-reviewed text -> not_reviewed",
          "not_reviewed", classify_review_row(None, not_reviewed_structured))
    check("review_output_text(): structured_output takes priority over legacy output",
          True, "Critical" in review_output_text("Severity: Low", schema0_legacy))

    # llm#1265 finding 2: fixtures for the four ways a row can have valid
    # JSON, empty findings, and STILL be unusable -- every one of these
    # MUST classify as indeterminate, never "passed".
    check("classify_review_row(): {} (no schema_version, no findings key) -> indeterminate",
          "indeterminate", classify_review_row(None, empty_object))
    check("review_output_text(): {} -> ''",
          "", review_output_text(None, empty_object))
    check("classify_review_row(): schema_version 0, legacy.markdown blank -> indeterminate",
          "indeterminate", classify_review_row(None, schema0_blank_legacy))
    check("classify_review_row(): schema_version 0, legacy key entirely missing -> indeterminate",
          "indeterminate", classify_review_row(None, schema0_missing_legacy))
    check("classify_review_row(): unrecognised schema_version (99) -> indeterminate",
          "indeterminate", classify_review_row(None, unknown_schema_version))
    check("classify_review_row(): missing schema_version key -> indeterminate",
          "indeterminate", classify_review_row(None, missing_schema_version_key))

    # ── PR #1269 round 3 (llm#1265 follow-up) ───────────────────────────
    # Finding 1: review_output_text() valid-but-unusable JSON must fall
    # back to legacy `output` text before returning "" (review id 10523).
    unusable_structured_real_output = (
        legacy_text_only,  # "- **Severity**: Low\n  **Problem**: minor thing"
        empty_object,      # "{}"
    )
    check("review_output_text(): {} structured falls back to real `output` text",
          True, "Severity" in review_output_text(*unusable_structured_real_output))
    check("review_severity_ordinal(): {} structured falls back to `output` -> 1 (low)",
          1, review_severity_ordinal(*unusable_structured_real_output))
    check("classify_review_row(): {} structured falls back to `output` -> parsed",
          "parsed", classify_review_row(*unusable_structured_real_output))

    # Finding 2 (the headline bug, PR #1269 review ids 10523/10524): a v2
    # row whose real max severity is "medium" must NOT be inflated to
    # "high" just because a (lower-severity) finding's own problem/fix
    # prose quotes "Severity: High"/"**Severity**: Critical" as an
    # illustrative example. review_severity_ordinal() must read the JSON
    # `severity` fields directly and ignore prose entirely.
    v2_medium_with_quoted_high_in_problem = json.dumps({
        "schema_version": 2,
        "summary": "one real finding, quoted example text elsewhere",
        "verdict": "fail",
        "findings": [
            {
                "severity": "medium",
                "location": "a.R:1",
                "problem": (
                    "When X happens the reader mis-parses. Add a fixture "
                    "where structured_output is `{}` and `output` holds a "
                    "real 'Severity: High' review."
                ),
                "fix": (
                    "Have the caller emit **Severity**: Critical only when "
                    "genuinely critical; do not infer it from prose."
                ),
            },
        ],
    })
    check("review_severity_ordinal(): v2 medium finding, problem/fix TEXT quotes "
          "High/Critical -> 2 (medium, NOT inflated by prose)",
          2, review_severity_ordinal(None, v2_medium_with_quoted_high_in_problem))
    check("parse_max_severity_ordinal() over the OLD rendered-text path WOULD have "
          "read Critical (4, from the quoted 'fix' text) instead of the true medium "
          "-- proves the bug this fix closes, not just the fix itself",
          4, parse_max_severity_ordinal(
              review_output_text(None, v2_medium_with_quoted_high_in_problem)))
    check("classify_review_row(): same fixture -> parsed",
          "parsed", classify_review_row(None, v2_medium_with_quoted_high_in_problem))

    # review_structured_findings() / review_top_finding(): JSON-direct,
    # never regex -- and the SAME quoted-marker-in-prose case must not
    # corrupt location/problem either.
    v2_multi_with_quoted_markers = json.dumps({
        "schema_version": 2,
        "summary": "x",
        "verdict": "fail",
        "findings": [
            {"severity": "low", "location": "a.R:1",
             "problem": "mentions **Location**: b.R:99 and **Problem**: fake as an example"},
            {"severity": "high", "location": "c.R:42", "problem": "the real problem"},
        ],
    })
    check("review_severity_ordinal(): max of [low, high] -> 3 (high), not corrupted "
          "by the low finding's own quoted markers",
          3, review_severity_ordinal(None, v2_multi_with_quoted_markers))
    top = review_top_finding(None, v2_multi_with_quoted_markers)
    check("review_top_finding(): top finding severity == 'high'",
          "high", top["severity"] if top else None)
    check("review_top_finding(): top finding location read from JSON, not regex "
          "(the low finding's problem text ALSO contains a '**Location**:' marker)",
          "c.R:42", top["location"] if top else None)
    check("review_top_finding(): top finding problem read from JSON",
          "the real problem", top["problem"] if top else None)

    # A recognised schema with an EMPTY findings list is "passed" -- must
    # NOT fall back to `output`, even when `output` holds real severity
    # text (deliberate: see review_severity_ordinal()'s own docstring).
    v2_pass_with_stale_output = "**Severity**: Critical\nstale text in `output`"
    check("review_severity_ordinal(): recognised schema + empty findings does NOT "
          "fall back to `output`, even when `output` has real severity text",
          None, review_severity_ordinal(v2_pass_with_stale_output, v2_pass_no_findings))

    # review_structured_findings() returns None (not []) when there is no
    # per-finding JSON to read at all -- the "use the regex path instead"
    # signal, distinct from a recognised-but-empty findings list.
    check("review_structured_findings(): schema_version 0 -> None (no per-finding JSON)",
          None, review_structured_findings(None, schema0_legacy))
    check("review_structured_findings(): malformed JSON -> None",
          None, review_structured_findings(legacy_text_only, malformed_json))
    check("review_top_finding(): malformed JSON -> None",
          None, review_top_finding(legacy_text_only, malformed_json))

    print(f"\n{passed}/{passed + failed} PASS")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    print(__doc__)
    sys.exit(0)
