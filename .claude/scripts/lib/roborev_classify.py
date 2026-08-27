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

Self-test:
    python3 roborev_classify.py --selftest
"""
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
PASSED_PATTERNS = [
    "severity_threshold_met",
    "no issues found",
    "no code changes were provided",
]

# Mirrors send_roborev_email.R parse_max_severity_ordinal()'s regex --
# \*{0,2} on both sides of "Severity" makes bold markdown markers optional so
# both "- Severity: High" and "- **Severity**: High" parse.
_SEVERITY_RE = re.compile(
    r"\*{0,2}Severity\*{0,2}:\s*(Critical|High|Medium|Low)", re.IGNORECASE
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
    words = _SEVERITY_RE.findall(text)
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

    print(f"\n{passed}/{passed + failed} PASS")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    print(__doc__)
    sys.exit(0)
