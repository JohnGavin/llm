#!/usr/bin/env python3
"""test_codex_analyzer.py — standalone smoke-tests for codex_self_learning_analyzer.

Run with: python3 tests/python/test_codex_analyzer.py

No external dependencies (stdlib only). Exits non-zero on any assertion failure.
"""

from __future__ import annotations

import datetime as dt
import json
import pathlib
import sys
import tempfile
import textwrap

# ---------------------------------------------------------------------------
# Ensure the scripts directory is importable
# ---------------------------------------------------------------------------
_SCRIPTS_DIR = pathlib.Path(__file__).parent.parent.parent / ".claude" / "scripts"
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from codex_self_learning_analyzer import (  # noqa: E402
    SessionInfo,
    CorrectionFinding,
    FailureFinding,
    NgramFinding,
    UnproductiveSession,
    REDACT_PATTERNS,
    CORRECTION_PATTERNS,
    detect_user_corrections,
    detect_repeated_failures,
    detect_ngrams,
    detect_unproductive_sessions,
    build_report,
    load_sessions,
    parse_jsonl_session,
    redact,
    classify_tool,
    command_family,
    REPORT_DISCLAIMER,
)


# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

_FAILURES: list[str] = []
_PASSES: int = 0


def ok(name: str, condition: bool, detail: str = "") -> None:
    global _PASSES
    if condition:
        _PASSES += 1
        print(f"  PASS  {name}")
    else:
        _FAILURES.append(f"FAIL  {name}" + (f" — {detail}" if detail else ""))
        print(f"  FAIL  {name}" + (f" — {detail}" if detail else ""))


def make_session(
    session_id: str,
    user_prompts: list[str] | None = None,
    tool_labels: list[str] | None = None,
    failures: list[dict] | None = None,
    assistant_turns: int = 1,
) -> SessionInfo:
    s = SessionInfo(session_id=session_id, path=f"/fake/{session_id}.jsonl")
    s.user_prompts = user_prompts or []
    s.assistant_turns = assistant_turns
    s.tool_calls = [{"label": lab, "name": lab, "raw": lab, "call_id": f"c{i}"}
                    for i, lab in enumerate(tool_labels or [])]
    s.tool_failures = failures or []
    return s


# ---------------------------------------------------------------------------
# Build synthetic JSONL fixture
# ---------------------------------------------------------------------------

def _make_jsonl_lines(session_id: str, user_prompts: list[str], tool_cmds: list[str],
                      fail_cmds: list[str]) -> list[str]:
    lines = []
    lines.append(json.dumps({
        "timestamp": "2026-05-22T10:00:00.000Z",
        "type": "session_meta",
        "payload": {
            "id": session_id,
            "timestamp": "2026-05-22T10:00:00.000Z",
            "cwd": "/fake",
        }
    }))
    for msg in user_prompts:
        lines.append(json.dumps({
            "timestamp": "2026-05-22T10:00:01.000Z",
            "type": "event_msg",
            "payload": {"type": "user_message", "message": msg}
        }))
    for i, cmd in enumerate(tool_cmds):
        call_id = f"call_{i}"
        lines.append(json.dumps({
            "timestamp": "2026-05-22T10:00:02.000Z",
            "type": "response_item",
            "payload": {
                "type": "function_call",
                "name": "exec_command",
                "arguments": json.dumps({"cmd": cmd}),
                "call_id": call_id,
            }
        }))
        lines.append(json.dumps({
            "timestamp": "2026-05-22T10:00:03.000Z",
            "type": "response_item",
            "payload": {
                "type": "function_call_output",
                "call_id": call_id,
                "output": "Chunk ID: abc\nProcess exited with code 0\nOutput:\nok\n"
            }
        }))
    for i, cmd in enumerate(fail_cmds):
        call_id = f"fail_{i}"
        lines.append(json.dumps({
            "timestamp": "2026-05-22T10:00:04.000Z",
            "type": "response_item",
            "payload": {
                "type": "function_call",
                "name": "exec_command",
                "arguments": json.dumps({"cmd": cmd}),
                "call_id": call_id,
            }
        }))
        lines.append(json.dumps({
            "timestamp": "2026-05-22T10:00:05.000Z",
            "type": "response_item",
            "payload": {
                "type": "function_call_output",
                "call_id": call_id,
                "output": "Chunk ID: xyz\nProcess exited with code 1\nOutput:\nError: command not found: foo\n"
            }
        }))
    return lines


def write_jsonl(tmp_dir: pathlib.Path, date_str: str, session_id: str, lines: list[str]) -> pathlib.Path:
    year, month, day = date_str.split("-")
    session_dir = tmp_dir / year / month / day
    session_dir.mkdir(parents=True, exist_ok=True)
    path = session_dir / f"rollout-{date_str}T10-00-00-{session_id}.jsonl"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


# ---------------------------------------------------------------------------
# Test: redaction
# ---------------------------------------------------------------------------

def test_redaction() -> None:
    print("\n[test_redaction]")

    ok("github_pat", "[REDACTED:github_pat]" in redact("token: ghp_" + "A" * 36))
    ok("openai_key", "[REDACTED:openai_key]" in redact("key=sk-" + "B" * 32))
    ok("aws_access", "[REDACTED:aws_access_key]" in redact("AKIA" + "C" * 16))
    ok("no_false_pos", "hello world" == redact("hello world"),
       "plain text should not be redacted")
    # Bearer token
    ok("bearer", "[REDACTED:bearer_token]" in redact("Authorization: Bearer " + "x" * 25))


# ---------------------------------------------------------------------------
# Test: correction-pattern detection
# ---------------------------------------------------------------------------

def test_correction_detection() -> None:
    print("\n[test_correction_detection]")

    sessions = [
        make_session("s1", user_prompts=["don't use sed for this", "always read AGENTS.md first"]),
        make_session("s2", user_prompts=["don't do that again", "you forgot to check the output"]),
        make_session("s3", user_prompts=["use git -C instead", "stop using rm -rf"]),
        make_session("s4", user_prompts=["stop editing default.nix directly please"]),
    ]
    findings = detect_user_corrections(sessions)

    # There should be findings
    ok("corrections_found", len(findings) > 0, f"got {len(findings)}")

    # dont_verb should appear across multiple sessions
    dont_finds = [f for f in findings if f.phrase == "dont_verb"]
    if dont_finds:
        ok("dont_verb_multi_session", dont_finds[0].session_count >= 2,
           f"session_count={dont_finds[0].session_count}")
        ok("dont_verb_count_ge2", dont_finds[0].count >= 2, f"count={dont_finds[0].count}")

    # stop_verbing
    stop_finds = [f for f in findings if f.phrase == "stop_verbing"]
    ok("stop_verbing_found", len(stop_finds) > 0, f"findings={[f.phrase for f in findings]}")

    # examples are redacted strings (no raw tokens)
    for f in findings[:3]:
        for ex in f.examples:
            ok("example_no_raw_key", "sk-" not in ex and "ghp_" not in ex,
               f"raw key in example: {ex[:60]}")


# ---------------------------------------------------------------------------
# Test: repeated failures threshold
# ---------------------------------------------------------------------------

def test_failure_detection() -> None:
    print("\n[test_failure_detection]")

    sessions = [
        make_session("s1", failures=[
            {"label": "nix-shell", "exit_code": 1, "preview": "build of derivation failed"},
            {"label": "nix-shell", "exit_code": 1, "preview": "build of derivation failed"},
        ]),
        make_session("s2", failures=[
            {"label": "nix-shell", "exit_code": 1, "preview": "build of derivation failed"},
        ]),
        make_session("s3", failures=[
            {"label": "git push", "exit_code": 128, "preview": "remote rejected"},
        ]),
    ]

    # With defaults (min_occurrences=3, min_sessions=2): nix-shell has 3 total but only 2 sessions
    findings = detect_repeated_failures(sessions, min_occurrences=3, min_sessions=2)
    ok("nix_shell_found", any(f.tool_label == "nix-shell" for f in findings),
       f"findings={[f.tool_label for f in findings]}")

    # With stricter threshold
    findings_strict = detect_repeated_failures(sessions, min_occurrences=5, min_sessions=3)
    ok("strict_threshold_empty", len(findings_strict) == 0,
       f"expected 0, got {len(findings_strict)}")

    # Single-session failure not surfaced at default
    findings_default = detect_repeated_failures(sessions, min_occurrences=3, min_sessions=2)
    git_push_finds = [f for f in findings_default if f.tool_label == "git push"]
    ok("single_session_not_surfaced", len(git_push_finds) == 0,
       "git push appeared in only 1 session, should not surface")


# ---------------------------------------------------------------------------
# Test: N-gram extraction
# ---------------------------------------------------------------------------

def test_ngrams() -> None:
    print("\n[test_ngrams]")

    # 3 sessions each with the same 2-gram: git status -> gh issue list
    sessions = [
        make_session(f"s{i}", tool_labels=["git status", "gh issue list", "sed"])
        for i in range(3)
    ]
    findings = detect_ngrams(sessions, n_values=(2,), min_sessions=3)
    ok("bigram_found", len(findings) > 0, "expected at least one bigram")
    first_ngram = findings[0].ngram if findings else ()
    ok("correct_bigram", ("git status", "gh issue list") in [f.ngram for f in findings],
       f"got {[f.ngram for f in findings[:3]]}")

    # Only 2 sessions — should not surface at min_sessions=3
    sessions_2 = [
        make_session(f"s{i}", tool_labels=["nix-shell", "Rscript"])
        for i in range(2)
    ]
    findings_2 = detect_ngrams(sessions_2, n_values=(2,), min_sessions=3)
    ok("min_sessions_respected", len(findings_2) == 0,
       f"expected 0, got {len(findings_2)}")


# ---------------------------------------------------------------------------
# Test: unproductive tail detection
# ---------------------------------------------------------------------------

def test_unproductive() -> None:
    print("\n[test_unproductive]")

    # 8 reads, 0 writes — unproductive
    s_unprod = SessionInfo(session_id="unprod", path="/fake/unprod.jsonl")
    s_unprod.tool_calls = [
        {"label": lab, "name": lab, "raw": lab, "call_id": f"c{i}"}
        for i, lab in enumerate(["git log", "git status", "cat", "ls", "find", "which", "cat", "ls"])
    ]

    # Productive: has writes
    s_prod = SessionInfo(session_id="prod", path="/fake/prod.jsonl")
    s_prod.tool_calls = [
        {"label": lab, "name": lab, "raw": lab, "call_id": f"c{i}"}
        for i, lab in enumerate(["git log", "git add", "git commit"])
    ]

    results = detect_unproductive_sessions([s_unprod, s_prod])
    ok("unprod_found", any(u.session_id == "unprod" for u in results),
       f"results={[u.session_id for u in results]}")
    ok("prod_not_found", all(u.session_id != "prod" for u in results),
       "productive session should not be in unproductive list")
    unprod_entry = next((u for u in results if u.session_id == "unprod"), None)
    if unprod_entry:
        ok("read_pct_gt_50", unprod_entry.read_pct > 0.50,
           f"read_pct={unprod_entry.read_pct}")


# ---------------------------------------------------------------------------
# Test: report contains all sections + disclaimer
# ---------------------------------------------------------------------------

def test_report_structure() -> None:
    print("\n[test_report_structure]")

    sessions = [make_session("s1")]
    report = build_report(
        window_start=dt.date(2026, 5, 22),
        window_end=dt.date(2026, 5, 29),
        sessions=sessions,
        corrections=[],
        failures=[],
        ngrams=[],
        unproductive=[],
        report_date=dt.date(2026, 5, 29),
    )

    required_sections = [
        "## 1. Analysis Window",
        "## 2. Top User-Correction Patterns",
        "## 3. Repeated Tool Failures",
        "## 4. Repeated Tool-Call N-Grams",
        "## 5. Long Unproductive Tail Sessions",
        "## 6. Candidate Learnings",
    ]
    for section in required_sections:
        ok(f"section_{section[:30]}", section in report, f"missing from report: {section}")

    ok("disclaimer_present", "NOT auto-applied" in report and "NOT Auto-Applied" not in report
       or "NOT auto-applied" in report,
       "disclaimer not found")
    ok("no_auto_edit_claim", "No config was modified" in report or "no config was modified" in report.lower())


# ---------------------------------------------------------------------------
# Test: JSONL fixture round-trip via load_sessions
# ---------------------------------------------------------------------------

def test_fixture_roundtrip() -> None:
    print("\n[test_fixture_roundtrip]")

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = pathlib.Path(tmp)
        date_str = "2026-05-22"

        lines1 = _make_jsonl_lines(
            "aaa-111",
            user_prompts=["don't use sed for this change"],
            tool_cmds=["git status", "cat README.md"],
            fail_cmds=["nix-shell ./default.nix"],
        )
        lines2 = _make_jsonl_lines(
            "bbb-222",
            user_prompts=["don't edit that file directly", "you forgot to read the file first"],
            tool_cmds=["git log", "cat file.txt", "git add ."],
            fail_cmds=["nix-shell ./default.nix", "nix-shell ./default.nix"],
        )
        lines3 = _make_jsonl_lines(
            "ccc-333",
            user_prompts=["stop editing default.nix directly"],
            tool_cmds=["git status", "cat README.md"],
            fail_cmds=[],
        )
        write_jsonl(tmp_path, date_str, "aaa-111", lines1)
        write_jsonl(tmp_path, date_str, "bbb-222", lines2)
        write_jsonl(tmp_path, date_str, "ccc-333", lines3)

        since = dt.date(2026, 5, 22)
        until = dt.date(2026, 5, 22)
        sessions = load_sessions(tmp_path, since, until)

        ok("loaded_3_sessions", len(sessions) == 3, f"got {len(sessions)}")

        corrections = detect_user_corrections(sessions)
        ok("corrections_from_fixture", len(corrections) > 0,
           f"got {len(corrections)} correction findings")

        # check failure detection: nix-shell fails in sessions s1 and s2 (3+ total, 2+ sessions)
        failures = detect_repeated_failures(sessions, min_occurrences=3, min_sessions=2)
        ok("nix_shell_detected", any("nix-shell" in f.tool_label for f in failures),
           f"failures={[f.tool_label for f in failures]}")

        # redaction should work: no raw credentials in correction examples
        for corr in corrections:
            for ex in corr.examples:
                ok("no_raw_cred_in_fixture_ex",
                   all(marker not in ex for marker in ("ghp_", "sk-", "AKIA")),
                   f"credential found: {ex[:60]}")


# ---------------------------------------------------------------------------
# Test: classify_tool
# ---------------------------------------------------------------------------

def test_classify_tool() -> None:
    print("\n[test_classify_tool]")

    ok("git_log_is_read", classify_tool("git log") == "read")
    ok("git_add_is_write", classify_tool("git add") == "write")
    ok("git_commit_is_write", classify_tool("git commit") == "write")
    ok("sed_is_write", classify_tool("sed") == "write")
    ok("cat_is_read", classify_tool("cat") == "read")
    ok("web_search_is_web", classify_tool("web_search_call") == "web")


# ---------------------------------------------------------------------------
# Test: command_family
# ---------------------------------------------------------------------------

def test_command_family() -> None:
    print("\n[test_command_family]")

    ok("git_status", command_family("git -C /repo status") == "git status")
    ok("git_commit", command_family("git commit -m 'msg'") == "git commit")
    ok("gh_issue", command_family("gh issue create --title foo") == "gh issue create")
    ok("nix_shell", command_family("nix-shell ./default.nix --run cmd") == "nix-shell")
    ok("timeout_rscript", command_family("timeout 60 Rscript -e 'x'").startswith("timeout"))


# ---------------------------------------------------------------------------
# Test: synthetic report contains redacted secret
# ---------------------------------------------------------------------------

def test_redaction_in_report() -> None:
    print("\n[test_redaction_in_report]")

    # Create two sessions so the correction pattern fires (count>=2 or session_count>=2)
    fake_key = "sk-" + "Z" * 32
    sessions = [
        make_session("sectest1", user_prompts=[
            f"don't use this token {fake_key} in the code",
        ]),
        make_session("sectest2", user_prompts=[
            f"don't embed the token {fake_key} directly",
        ]),
    ]
    corrections = detect_user_corrections(sessions)
    report = build_report(
        window_start=dt.date(2026, 5, 22),
        window_end=dt.date(2026, 5, 29),
        sessions=sessions,
        corrections=corrections,
        failures=[],
        ngrams=[],
        unproductive=[],
        report_date=dt.date(2026, 5, 29),
    )
    ok("secret_not_in_report", fake_key not in report,
       f"raw key found in report")
    ok("redacted_in_report", "[REDACTED" in report,
       "expected REDACTED marker in report")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    print("=" * 60)
    print("codex_self_learning_analyzer — smoke tests")
    print("=" * 60)

    test_redaction()
    test_correction_detection()
    test_failure_detection()
    test_ngrams()
    test_unproductive()
    test_report_structure()
    test_fixture_roundtrip()
    test_classify_tool()
    test_command_family()
    test_redaction_in_report()

    total = _PASSES + len(_FAILURES)
    print(f"\n{'=' * 60}")
    print(f"Results: {_PASSES}/{total} PASS")
    if _FAILURES:
        print("\nFailed tests:")
        for msg in _FAILURES:
            print(f"  {msg}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
