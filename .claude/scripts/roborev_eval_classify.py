#!/usr/bin/env python3
"""Classification logic for roborev_eval_run.sh (llm#1044).

Two responsibilities, kept deliberately separate so `--selftest` can
exercise classification without any live roborev/network call:

  extract   -- read a roborev `review --dirty --local --wait` raw capture
               (a JSONL event stream on stdout+stderr) and print the final
               review text (the "result" field of the terminal
               {"type":"result",...} line), or exit 1 if no such line is
               found at all.

  classify  -- given review text + an expected.json spec + whether the
               roborev process completed without error, decide
               PASS / FAIL / ERROR and print "<STATUS>|<reason>".

  selftest  -- run built-in fixtures against `classify()`/`find_severities()`
               directly (no live roborev call, no filesystem scratch repo).

ERROR must never be silently folded into FAIL or PASS (see the
checks-must-distinguish-unknown rule): a review that did not complete, or
that completed but returned an EMPTY result, is an INDETERMINATE result
about roborev/the agent -- not a positive or negative finding about the
fixture's code. That empty-result-despite-success shape is the exact
signature of the llm#1035 incident this harness exists to catch: an agent
silently failed to read the diff on 15.5% of reviews in this repo, and
nothing distinguished that from "reviewed, found nothing" until a human
hand-queried the DB.
"""
import json
import re
import sys

SEVERITY_ORDER = ["low", "medium", "high", "critical"]

# Tolerant of the markdown '**Severity**: High' form roborev's claude-code
# stream actually produces (verified live, 2026-08-27), a plain
# 'Severity: High' form, and a trailing-bold 'Severity:** High' form.
SEVERITY_PATTERN = re.compile(
    r"severity\*{0,2}\s*:\s*\*{0,2}\s*(critical|high|medium|low)",
    re.IGNORECASE,
)


def severity_rank(name):
    name = (name or "").lower()
    return SEVERITY_ORDER.index(name) if name in SEVERITY_ORDER else -1


def find_severities(text):
    """Return the lowercase severity strings found in `text`, in order."""
    if not text:
        return []
    return [m.group(1).lower() for m in SEVERITY_PATTERN.finditer(text)]


def extract_result_text(raw_path):
    """Return the `result` field of the last {"type":"result",...} JSONL
    line in raw_path, or None if no such line was found (distinct from an
    empty string, which means the line WAS found but the field was empty)."""
    result_text = None
    try:
        with open(raw_path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or '"type":"result"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("type") == "result":
                    result_text = obj.get("result", "")
    except FileNotFoundError:
        return None
    return result_text


def classify(result_text, completed_ok, expected):
    """Return (status, reason). status is one of PASS, FAIL, ERROR."""
    if not completed_ok:
        return "ERROR", "roborev review did not complete (nonzero exit or error signature)"

    if result_text is None:
        return "ERROR", "no terminal result line found in roborev output"

    if result_text.strip() == "":
        # Exit 0, but nothing came back: the silent-failure signature this
        # harness exists to catch (llm#1035/llm#1044).
        return "ERROR", "empty result text despite exit 0 -- the silent-failure signature (llm#1035)"

    exp_completion = expected.get("expect_completion", True)
    if exp_completion is False:
        return "FAIL", "expected non-completion but review completed"

    severities = find_severities(result_text)
    has_findings = len(severities) > 0

    exp_findings = expected.get("expect_findings", None)
    if exp_findings is True and not has_findings:
        return "FAIL", "expected at least one Severity finding but none were found"
    if exp_findings is False and has_findings:
        return "FAIL", f"expected no findings but found severities: {severities}"

    must_mention_any = expected.get("must_mention_any") or None
    if exp_findings is True and must_mention_any:
        lowered = result_text.lower()
        if not any(kw.lower() in lowered for kw in must_mention_any):
            return "FAIL", (
                "found a Severity marker but review text did not mention any "
                f"of the expected keywords {must_mention_any} -- possible "
                "unrelated/hallucinated finding rather than the real bug"
            )

    forbid_at_or_above = expected.get("forbid_severity_at_or_above")
    if forbid_at_or_above:
        threshold = severity_rank(forbid_at_or_above)
        offending = [s for s in severities if threshold >= 0 and severity_rank(s) >= threshold]
        if offending:
            return "FAIL", f"found severities at or above '{forbid_at_or_above}': {offending}"

    return "PASS", f"completed; severities found={severities or 'none'}"


def run_selftest():
    passed = 0
    failed = 0

    def check(name, got_status, want_status, got_reason=""):
        nonlocal passed, failed
        if got_status == want_status:
            print(f"CASE {name} PASS: got {got_status} ({got_reason})")
            passed += 1
        else:
            print(f"CASE {name} FAIL: wanted {want_status}, got {got_status} ({got_reason})")
            failed += 1

    # Case A: PASS -- findings expected + found + keyword matched (mirrors fixture 01)
    exp_a = {
        "expect_completion": True,
        "expect_findings": True,
        "must_mention_any": ["denominator", "zero"],
        "forbid_severity_at_or_above": None,
    }
    text_a = "## Review Findings\n\n- **Severity**: High\n- Problem: unguarded denominator, silent NaN.\n"
    status, reason = classify(text_a, True, exp_a)
    check("A-real-bug-found", status, "PASS", reason)

    # Case B: FAIL -- findings expected but none reported. This is the exact
    # regression an agent/model swap could introduce and is the harness's
    # core purpose (see roborev-resolution rule: run this after ANY
    # agent=/model= change before trusting it in production).
    text_b = "No issues found. The change looks fine."
    status, reason = classify(text_b, True, exp_a)
    check("B-missed-real-bug", status, "FAIL", reason)

    # Case C: FAIL -- a Severity marker was found but about something else
    # entirely (guards against a hallucinated/unrelated finding satisfying
    # the "has findings" check by accident).
    text_c = "- **Severity**: Low\n- Problem: missing roxygen @export tag.\n"
    status, reason = classify(text_c, True, exp_a)
    check("C-unrelated-finding", status, "FAIL", reason)

    # Case D: ERROR -- roborev/the agent did not complete at all (nonzero
    # exit, auth failure, model-not-found, etc.). Must be ERROR, never
    # silently folded into PASS or FAIL.
    status, reason = classify("anything", False, exp_a)
    check("D-process-did-not-complete", status, "ERROR", reason)

    # Case E: ERROR -- the llm#1035 silent-failure signature: roborev
    # reports success (exit 0) but the result text is EMPTY, meaning the
    # agent never actually engaged with the diff.
    status, reason = classify("", True, exp_a)
    check("E-empty-result-despite-success", status, "ERROR", reason)

    # Case F: PASS -- clean fixture (mirrors fixture 02): no findings
    # expected, none found.
    exp_f = {
        "expect_completion": True,
        "expect_findings": False,
        "forbid_severity_at_or_above": "high",
    }
    text_f = "No issues found. Comment-only change."
    status, reason = classify(text_f, True, exp_f)
    check("F-clean-no-findings", status, "PASS", reason)

    # Case G: FAIL -- clean fixture unexpectedly gets a High/Critical
    # finding (a reviewer regression: over-flagging trivial changes).
    text_g = "- **Severity**: High\n- Problem: hallucinated concern about a comment-only diff.\n"
    status, reason = classify(text_g, True, exp_f)
    check("G-clean-false-positive", status, "FAIL", reason)

    # Case H: parser format robustness -- find_severities() must match both
    # the markdown-bold form roborev's claude-code stream actually produces
    # (verified live, 2026-08-27) and plainer forms, without requiring one
    # single canonical format. This is what fixture 04's loose live
    # assertion defers to: format variance is real and is handled HERE
    # against known forms, not asserted against a non-deterministic live
    # LLM response.
    forms = [
        "- **Severity**: Critical\n",
        "Severity: Medium\n",
        "**Severity:** low\n",
    ]
    all_matched = all(len(find_severities(f)) == 1 for f in forms)
    check(
        "H-severity-format-variants",
        "PASS" if all_matched else "FAIL",
        "PASS",
        f"forms={forms}",
    )

    total = passed + failed
    print("")
    print(f"Selftest: {passed}/{total} PASS")
    return 0 if failed == 0 else 1


def main(argv):
    if len(argv) < 2:
        print("usage: roborev_eval_classify.py <extract|classify|selftest> ...", file=sys.stderr)
        return 2

    mode = argv[1]

    if mode == "extract":
        # roborev_eval_classify.py extract <raw_output_file>
        if len(argv) < 3:
            print("usage: roborev_eval_classify.py extract <raw_output_file>", file=sys.stderr)
            return 2
        text = extract_result_text(argv[2])
        if text is None:
            return 1
        sys.stdout.write(text)
        return 0

    if mode == "classify":
        # roborev_eval_classify.py classify <expected.json> <completed_ok 0/1> [<result_text_file>]
        if len(argv) < 4:
            print(
                "usage: roborev_eval_classify.py classify <expected.json> <completed_ok 0|1> [<result_text_file>]",
                file=sys.stderr,
            )
            return 2
        expected_path = argv[2]
        completed_ok = argv[3] == "1"
        result_text = None
        if len(argv) > 4:
            try:
                with open(argv[4], "r", encoding="utf-8", errors="replace") as fh:
                    result_text = fh.read()
            except FileNotFoundError:
                result_text = None

        with open(expected_path, "r", encoding="utf-8") as fh:
            expected = json.load(fh)

        status, reason = classify(result_text, completed_ok, expected)
        print(f"{status}|{reason}")
        return 0 if status == "PASS" else 1

    if mode == "selftest":
        return run_selftest()

    print(f"unknown mode: {mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
