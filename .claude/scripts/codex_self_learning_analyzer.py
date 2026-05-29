#!/usr/bin/env python3
"""codex_self_learning_analyzer.py — Phase 1 self-learning analyzer for Codex JSONL sessions.

Reads ~/.codex/sessions/**/*.jsonl (and optionally state_5.sqlite metadata) within
a date window, detects patterns, and emits a markdown report for HUMAN REVIEW.

This script:
  - Never writes to ~/.claude/rules/, ~/.claude/memory/, ~/.claude/skills/
  - Never modifies GitHub state
  - Never auto-applies any learnings
  - Redacts obvious credentials/PII from verbatim excerpts

Usage:
    python3 codex_self_learning_analyzer.py [--since YYYY-MM-DD] [--out PATH] [--dry-run]
                                             [--sessions-dir PATH]
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import shlex
import sqlite3
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field, asdict
from typing import Any

# ---------------------------------------------------------------------------
# Privacy redaction
# ---------------------------------------------------------------------------

# Patterns to redact from any verbatim text before it appears in the report.
# Each tuple: (name, compiled_regex, replacement)
REDACT_PATTERNS: list[tuple[str, re.Pattern[str], str]] = [
    ("github_pat",     re.compile(r"ghp_[A-Za-z0-9]{36,}"),          "[REDACTED:github_pat]"),
    ("github_oauth",   re.compile(r"gho_[A-Za-z0-9]{36,}"),          "[REDACTED:github_oauth]"),
    ("github_actions", re.compile(r"github_pat_[A-Za-z0-9_]{36,}"),  "[REDACTED:github_actions]"),
    ("openai_key",     re.compile(r"sk-[A-Za-z0-9]{32,}"),           "[REDACTED:openai_key]"),
    ("anthropic_key",  re.compile(r"sk-ant-[A-Za-z0-9\-_]{32,}"),   "[REDACTED:anthropic_key]"),
    ("aws_access_key", re.compile(r"AKIA[0-9A-Z]{16}"),              "[REDACTED:aws_access_key]"),
    ("aws_secret_key", re.compile(r"[A-Za-z0-9/+]{40}"),            "[REDACTED:potential_aws_secret]"),
    ("generic_token",  re.compile(r"token[=\s:]['\"]?[A-Za-z0-9_\-\.]{20,}['\"]?", re.IGNORECASE),
                                                                      "[REDACTED:token]"),
    ("password",       re.compile(r"password[=\s:]['\"]?\S+['\"]?", re.IGNORECASE),
                                                                      "[REDACTED:password]"),
    ("bearer_token",   re.compile(r"Bearer\s+[A-Za-z0-9\-\._~\+/]{20,}=*", re.IGNORECASE),
                                                                      "[REDACTED:bearer_token]"),
]


def redact(text: str) -> str:
    """Apply all redaction patterns to text."""
    for _, pattern, replacement in REDACT_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


# ---------------------------------------------------------------------------
# User-correction phrase detection
# Documented regex list — each entry is (label, compiled_regex).
# Adjust thresholds or add patterns here.
# ---------------------------------------------------------------------------

CORRECTION_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("dont_verb",         re.compile(r"\bdon'?t\s+\w+", re.IGNORECASE)),
    ("do_not_verb",       re.compile(r"\bdo\s+not\s+\w+", re.IGNORECASE)),
    ("never_verb",        re.compile(r"\bnever\s+\w+", re.IGNORECASE)),
    ("stop_verbing",      re.compile(r"\bstop\s+\w+ing\b", re.IGNORECASE)),
    ("read_X_first",      re.compile(r"\bread\s+\S+\s+first\b", re.IGNORECASE)),
    ("use_X_instead",     re.compile(r"\buse\s+\S+\s+instead\b", re.IGNORECASE)),
    ("you_forgot_to",     re.compile(r"\byou\s+forgot\s+to\b", re.IGNORECASE)),
    ("you_should_have",   re.compile(r"\byou\s+should\s+have\b", re.IGNORECASE)),
    ("should_have_used",  re.compile(r"\bshould\s+have\s+used\b", re.IGNORECASE)),
    ("always_verb",       re.compile(r"\balways\s+\w+", re.IGNORECASE)),
    ("instead_of",        re.compile(r"\binstead\s+of\b", re.IGNORECASE)),
    ("not_X_but_Y",       re.compile(r"\bnot\s+\S+\s+but\b", re.IGNORECASE)),
    ("wrong_approach",    re.compile(r"\bwrong\s+(approach|way|method|tool)\b", re.IGNORECASE)),
    ("should_use",        re.compile(r"\bshould\s+use\b", re.IGNORECASE)),
    ("no_need",           re.compile(r"\bno\s+need\s+to\b", re.IGNORECASE)),
]

# Session-level tool output exit-code patterns
EXIT_CODE_RE = re.compile(r"Process exited with code (\d+)")
OUTPUT_SECTION_RE = re.compile(r"Output:\s*\n(.*?)(?:\n\n|\Z)", re.DOTALL)


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class SessionInfo:
    session_id: str
    path: str
    cwd: str = ""
    user_prompts: list[str] = field(default_factory=list)
    assistant_turns: int = 0
    tool_calls: list[dict[str, Any]] = field(default_factory=list)  # {name, label, raw, call_id}
    tool_failures: list[dict[str, Any]] = field(default_factory=list)  # {label, exit_code, preview}
    agent_commentary: list[str] = field(default_factory=list)


@dataclass
class CorrectionFinding:
    phrase: str
    pattern_label: str
    count: int  # total across all sessions
    session_count: int
    examples: list[str]  # up to 3 verbatim (redacted) excerpts


@dataclass
class FailureFinding:
    tool_label: str
    error_preview: str  # normalized/redacted
    total_occurrences: int
    session_count: int
    session_ids: list[str]


@dataclass
class NgramFinding:
    ngram: tuple[str, ...]
    count: int
    session_count: int
    session_ids: list[str]


@dataclass
class UnproductiveSession:
    session_id: str
    path: str
    total_calls: int
    read_calls: int
    write_calls: int
    read_pct: float


# ---------------------------------------------------------------------------
# Tool-call classification
# ---------------------------------------------------------------------------

READ_TOOLS = {"read_file", "view", "cat", "ls", "find", "grep", "rg", "stat", "head", "tail",
              "git log", "git status", "git show", "git diff", "gh issue list", "gh pr list",
              "gh issue view", "gh pr view", "sqlite3", "which", "echo", "python3", "python",
              "Rscript", "timeout Rscript", "timeout python3"}
WRITE_TOOLS = {"write_file", "edit_file", "str_replace_editor", "patch",
               "git add", "git commit", "git push", "gh issue create", "gh pr create",
               "sed", "tee", "mv", "cp", "touch", "mkdir"}


def classify_tool(label: str) -> str:
    if label in READ_TOOLS:
        return "read"
    if label in WRITE_TOOLS:
        return "write"
    if label.startswith("exec_command") or label in {"shell", "bash"}:
        return "shell"
    if "web_search" in label or "fetch" in label or "curl" in label:
        return "web"
    return "other"


def command_family(cmd: str) -> str:
    """Collapse a shell command to a short canonical family label."""
    try:
        tokens = shlex.split(cmd)
    except ValueError:
        tokens = cmd.strip().split()

    # strip leading KEY=value env vars
    while tokens and "=" in tokens[0] and not tokens[0].startswith("-"):
        tokens = tokens[1:]
    if not tokens:
        return "shell"

    first = os.path.basename(tokens[0])
    tail = tokens[1:]

    if first == "git":
        i = 0
        while i < len(tail):
            tok = tail[i]
            if tok == "-C":
                i += 2
                continue
            if tok.startswith("-"):
                i += 1
                continue
            return f"git {tok}"
        return "git"

    if first == "gh":
        parts = ["gh"]
        for tok in tail:
            if tok.startswith("-"):
                continue
            parts.append(tok)
            if len(parts) == 3:
                break
        return " ".join(parts)

    if first == "timeout" and tail:
        inner = [t for t in tail if not t.startswith("-")][1:] if len(tail) > 1 else []
        if inner:
            return f"timeout {os.path.basename(inner[0])}"
        return "timeout"

    if first in {"sed", "rg", "sqlite3", "python3", "python", "find", "ls",
                 "duckdb", "nix-shell", "Rscript", "curl", "cat", "head", "tail",
                 "grep", "stat", "which", "echo", "mv", "cp", "touch", "mkdir", "tee"}:
        return first

    return first


def extract_tool_calls(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Extract tool call records from a function_call payload."""
    name = payload.get("name", "")
    arguments_raw = payload.get("arguments", "{}")
    call_id = payload.get("call_id", "")

    try:
        args = json.loads(arguments_raw or "{}")
    except json.JSONDecodeError:
        args = {}

    calls = []
    if name == "exec_command":
        cmd = str(args.get("cmd", ""))
        label = command_family(cmd)
        calls.append({"name": name, "label": label, "raw": cmd or "exec_command", "call_id": call_id})

    elif name == "parallel":
        for tool_use in args.get("tool_uses", []):
            recipient = tool_use.get("recipient_name", "")
            params = tool_use.get("parameters", {})
            if recipient == "functions.exec_command":
                cmd = str(params.get("cmd", ""))
                label = command_family(cmd)
                calls.append({"name": "exec_command", "label": label, "raw": cmd, "call_id": call_id})
            else:
                short = recipient.replace("functions.", "")
                calls.append({"name": short, "label": short, "raw": short, "call_id": call_id})

    else:
        calls.append({"name": name, "label": name, "raw": name, "call_id": call_id})

    return calls


def detect_failure_in_output(output: str) -> tuple[bool, int | None, str]:
    """Return (is_failure, exit_code, preview)."""
    match = EXIT_CODE_RE.search(output)
    exit_code = None
    if match:
        exit_code = int(match.group(1))
        if exit_code == 0:
            return False, 0, ""

    is_failure = (exit_code is not None and exit_code != 0) or \
                 ("Error:" in output) or ("Traceback" in output) or \
                 ("command not found" in output) or ("No such file" in output)
    if not is_failure:
        return False, exit_code, ""

    # Extract a short preview from the Output: section
    raw_preview = ""
    # Try to find Output: section
    body = output
    if "Output:\n" in output:
        body = output.split("Output:\n", 1)[1]
    elif "Output:" in output:
        body = output.split("Output:", 1)[1]

    for line in body.splitlines():
        stripped = line.strip()
        if stripped:
            raw_preview = stripped[:200]
            break

    return True, exit_code, redact(raw_preview)


# ---------------------------------------------------------------------------
# Session parsing
# ---------------------------------------------------------------------------

def parse_jsonl_session(path: pathlib.Path) -> SessionInfo:
    info = SessionInfo(
        session_id=path.stem,
        path=str(path),
    )
    call_map: dict[str, list[dict[str, Any]]] = {}

    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for raw_line in fh:
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                event = json.loads(raw_line)
            except json.JSONDecodeError:
                continue

            ev_type = event.get("type", "")
            payload = event.get("payload", {})

            if ev_type == "session_meta":
                info.session_id = payload.get("id", info.session_id)
                info.cwd = payload.get("cwd", "")
                continue

            if ev_type == "event_msg":
                msg_type = payload.get("type", "")
                if msg_type == "user_message":
                    msg_text = str(payload.get("message", ""))
                    if msg_text.strip():
                        info.user_prompts.append(msg_text)
                elif msg_type == "agent_message":
                    commentary = str(payload.get("message", ""))
                    if commentary.strip():
                        info.agent_commentary.append(commentary)
                continue

            if ev_type == "response_item":
                item_type = payload.get("type", "")

                if item_type in ("message", "reasoning"):
                    if payload.get("role") in ("assistant", None):
                        info.assistant_turns += 1
                    continue

                if item_type == "function_call":
                    calls = extract_tool_calls(payload)
                    call_id = payload.get("call_id", "")
                    call_map[call_id] = calls
                    info.tool_calls.extend(calls)
                    continue

                if item_type == "function_call_output":
                    output = str(payload.get("output", ""))
                    call_id = payload.get("call_id", "")
                    is_fail, exit_code, preview = detect_failure_in_output(output)
                    if is_fail and preview:
                        parent_calls = call_map.get(call_id, [{"label": "tool_call"}])
                        for pc in parent_calls:
                            info.tool_failures.append({
                                "label": pc["label"],
                                "exit_code": exit_code,
                                "preview": preview,
                            })
                    continue

    return info


def load_sessions(sessions_dir: pathlib.Path, since: dt.date, until: dt.date) -> list[SessionInfo]:
    """Load all JSONL sessions whose files fall within [since, until]."""
    sessions: list[SessionInfo] = []
    if not sessions_dir.exists():
        return sessions

    for jsonl_path in sorted(sessions_dir.rglob("*.jsonl")):
        # Parse date from path: sessions/YYYY/MM/DD/...
        parts = jsonl_path.parts
        try:
            # find YYYY/MM/DD triple in path parts
            for i, p in enumerate(parts):
                if len(p) == 4 and p.isdigit():
                    year, month, day = int(p), int(parts[i + 1]), int(parts[i + 2])
                    file_date = dt.date(year, month, day)
                    break
            else:
                continue
        except (IndexError, ValueError):
            continue

        if not (since <= file_date <= until):
            continue

        sessions.append(parse_jsonl_session(jsonl_path))

    return sessions


def load_sqlite_metadata(db_path: pathlib.Path) -> dict[str, dict[str, Any]]:
    """Load threads table keyed by session id."""
    result: dict[str, dict[str, Any]] = {}
    if not db_path.exists():
        return result
    try:
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM threads")
        for row in cursor.fetchall():
            row_dict = dict(row)
            sid = row_dict.get("id", "")
            result[sid] = row_dict
        conn.close()
    except Exception:
        pass
    return result


# ---------------------------------------------------------------------------
# Detectors
# ---------------------------------------------------------------------------

def detect_user_corrections(sessions: list[SessionInfo]) -> list[CorrectionFinding]:
    """Detect user correction phrases across sessions.

    Returns findings where a phrase appears ≥2 times across ≥2 sessions
    (or ≥3 total occurrences in a single session).
    """
    # phrase_label -> {count: int, session_ids: set, examples: list}
    buckets: dict[str, dict[str, Any]] = {}

    for session in sessions:
        for prompt in session.user_prompts:
            for label, pattern in CORRECTION_PATTERNS:
                matches = pattern.findall(prompt)
                if not matches:
                    continue
                bucket = buckets.setdefault(label, {
                    "phrase": label, "count": 0, "session_ids": set(), "examples": []
                })
                bucket["count"] += len(matches)
                bucket["session_ids"].add(session.session_id)
                for m in matches[:2]:
                    excerpt = redact(str(m).strip())
                    if excerpt and len(bucket["examples"]) < 3:
                        # include surrounding context (up to 100 chars)
                        ctx = redact(prompt.strip())
                        start = ctx.lower().find(m.lower())
                        if start >= 0:
                            excerpt = ctx[max(0, start - 20): start + len(m) + 60].strip()
                        bucket["examples"].append(excerpt[:140])

    findings: list[CorrectionFinding] = []
    for label, b in buckets.items():
        session_ids = b["session_ids"]
        if b["count"] >= 2 or len(session_ids) >= 2:
            findings.append(CorrectionFinding(
                phrase=label,
                pattern_label=label,
                count=b["count"],
                session_count=len(session_ids),
                examples=b["examples"],
            ))

    return sorted(findings, key=lambda f: (-f.count, -f.session_count))


def detect_repeated_failures(
    sessions: list[SessionInfo],
    min_occurrences: int = 3,
    min_sessions: int = 2,
) -> list[FailureFinding]:
    """Detect tool+error combinations appearing ≥min_occurrences times across ≥min_sessions."""
    # key: (tool_label, normalized_preview) -> {count, session_ids}
    buckets: dict[tuple[str, str], dict[str, Any]] = {}

    for session in sessions:
        for failure in session.tool_failures:
            label = failure["label"]
            preview = failure["preview"]
            # normalize: collapse numbers and paths for grouping
            norm = re.sub(r"\b\d+\b", "<N>", preview)
            norm = re.sub(r"/[^\s]+", "<PATH>", norm)
            norm = norm[:100]
            key = (label, norm)
            b = buckets.setdefault(key, {"count": 0, "session_ids": set(), "preview": preview})
            b["count"] += 1
            b["session_ids"].add(session.session_id)

    findings: list[FailureFinding] = []
    for (label, norm), b in buckets.items():
        if b["count"] >= min_occurrences and len(b["session_ids"]) >= min_sessions:
            findings.append(FailureFinding(
                tool_label=label,
                error_preview=b["preview"],
                total_occurrences=b["count"],
                session_count=len(b["session_ids"]),
                session_ids=sorted(b["session_ids"])[:5],
            ))

    return sorted(findings, key=lambda f: (-f.total_occurrences, -f.session_count))


def detect_ngrams(
    sessions: list[SessionInfo],
    n_values: tuple[int, ...] = (2, 3),
    min_sessions: int = 3,
) -> list[NgramFinding]:
    """Detect tool-call N-grams appearing in ≥min_sessions sessions."""
    # ngram -> {session_ids: set, count}
    buckets: dict[tuple[str, ...], dict[str, Any]] = {}

    for session in sessions:
        labels = [tc["label"] for tc in session.tool_calls]
        for n in n_values:
            seen_in_session: set[tuple[str, ...]] = set()
            for i in range(len(labels) - n + 1):
                gram = tuple(labels[i: i + n])
                if gram in seen_in_session:
                    continue
                seen_in_session.add(gram)
                b = buckets.setdefault(gram, {"count": 0, "session_ids": set()})
                b["count"] += 1
                b["session_ids"].add(session.session_id)

    findings: list[NgramFinding] = []
    for gram, b in buckets.items():
        if len(b["session_ids"]) >= min_sessions:
            findings.append(NgramFinding(
                ngram=gram,
                count=b["count"],
                session_count=len(b["session_ids"]),
                session_ids=sorted(b["session_ids"])[:5],
            ))

    return sorted(findings, key=lambda f: (-f.session_count, -f.count))


def detect_unproductive_sessions(
    sessions: list[SessionInfo],
    read_pct_threshold: float = 0.50,
    min_calls: int = 5,
) -> list[UnproductiveSession]:
    """Sessions where >read_pct_threshold of calls are reads with no writes."""
    results: list[UnproductiveSession] = []
    for session in sessions:
        calls = session.tool_calls
        if len(calls) < min_calls:
            continue
        read_n = sum(1 for c in calls if classify_tool(c["label"]) == "read")
        write_n = sum(1 for c in calls if classify_tool(c["label"]) == "write")
        if write_n > 0:
            continue
        pct = read_n / len(calls)
        if pct > read_pct_threshold:
            results.append(UnproductiveSession(
                session_id=session.session_id,
                path=session.path,
                total_calls=len(calls),
                read_calls=read_n,
                write_calls=write_n,
                read_pct=pct,
            ))

    return sorted(results, key=lambda u: -u.read_pct)


# ---------------------------------------------------------------------------
# Report building
# ---------------------------------------------------------------------------

REPORT_DISCLAIMER = """\
> **Candidate learnings — NOT auto-applied.**
> This report is generated by `codex_self_learning_analyzer.py` for HUMAN REVIEW ONLY.
> No rules, memories, skills, or GitHub state have been modified.
> Review each item, decide whether it warrants a change, and apply it manually.
"""


def _fmt_examples(examples: list[str]) -> str:
    if not examples:
        return ""
    lines = []
    for ex in examples[:3]:
        lines.append(f"  - `{ex}`")
    return "\n".join(lines)


def build_report(
    window_start: dt.date,
    window_end: dt.date,
    sessions: list[SessionInfo],
    corrections: list[CorrectionFinding],
    failures: list[FailureFinding],
    ngrams: list[NgramFinding],
    unproductive: list[UnproductiveSession],
    report_date: dt.date,
) -> str:
    lines: list[str] = []
    lines.append(f"# Codex Self-Learning Analyzer — {report_date.isoformat()}")
    lines.append("")
    lines.append(REPORT_DISCLAIMER)
    lines.append("")

    # 1. Window + totals
    lines.append("## 1. Analysis Window")
    lines.append("")
    lines.append(f"- **Window:** `{window_start}` to `{window_end}`")
    lines.append(f"- **Sessions analyzed:** {len(sessions)}")
    total_prompts = sum(len(s.user_prompts) for s in sessions)
    total_tool_calls = sum(len(s.tool_calls) for s in sessions)
    total_failures = sum(len(s.tool_failures) for s in sessions)
    lines.append(f"- **Total user prompts:** {total_prompts}")
    lines.append(f"- **Total tool calls:** {total_tool_calls}")
    lines.append(f"- **Total tool failures:** {total_failures}")
    lines.append("")

    # 2. User-correction patterns
    lines.append("## 2. Top User-Correction Patterns")
    lines.append("")
    lines.append("Phrases detected in user prompts matching curated correction patterns.")
    lines.append("Each pattern targets a class of user feedback (e.g. `don't verb`, `use X instead`).")
    lines.append("")
    if not corrections:
        lines.append("_No correction patterns detected in this window._")
    else:
        for i, c in enumerate(corrections[:10], 1):
            lines.append(f"### {i}. `{c.phrase}` — {c.count} occurrence(s) across {c.session_count} session(s)")
            if c.examples:
                lines.append("")
                lines.append("**Verbatim examples (redacted):**")
                lines.append("")
                for ex in c.examples[:3]:
                    lines.append(f"> {ex}")
                lines.append("")
    lines.append("")

    # 3. Repeated tool failures
    lines.append("## 3. Repeated Tool Failures")
    lines.append("")
    lines.append(
        f"Tool+error combinations appearing ≥3 times across ≥2 distinct sessions."
    )
    lines.append("")
    if not failures:
        lines.append("_No repeated failure patterns detected in this window._")
    else:
        for i, f_ in enumerate(failures[:10], 1):
            lines.append(f"### {i}. `{f_.tool_label}` — {f_.total_occurrences} failure(s), {f_.session_count} session(s)")
            lines.append(f"- **Error preview:** `{f_.error_preview}`")
            lines.append(f"- **Sessions:** {', '.join(f_.session_ids[:5])}")
            lines.append("")
    lines.append("")

    # 4. Repeated N-grams
    lines.append("## 4. Repeated Tool-Call N-Grams")
    lines.append("")
    lines.append("Recurring 2- and 3-call sequences seen in ≥3 distinct sessions.")
    lines.append("")
    if not ngrams:
        lines.append("_No repeated N-gram workflows detected in this window._")
    else:
        for i, ng in enumerate(ngrams[:10], 1):
            gram_str = " → ".join(ng.ngram)
            lines.append(f"### {i}. `{gram_str}` — {ng.count} occurrence(s), {ng.session_count} session(s)")
            lines.append(f"- Sessions: {', '.join(ng.session_ids[:5])}")
            lines.append("")
    lines.append("")

    # 5. Long unproductive tail
    lines.append("## 5. Long Unproductive Tail Sessions")
    lines.append("")
    lines.append(
        "Sessions where >50% of tool calls are reads with no write calls. "
        "May indicate: stuck exploration, missing context, or repeated environment checks."
    )
    lines.append("")
    if not unproductive:
        lines.append("_No unproductive-tail sessions detected in this window._")
    else:
        for u in unproductive[:10]:
            lines.append(
                f"- `{u.session_id}` — {u.total_calls} calls total, "
                f"{u.read_calls} reads ({u.read_pct:.0%}), 0 writes"
            )
            lines.append(f"  - Path: `{u.path}`")
        lines.append("")
    lines.append("")

    # 6. Candidate learnings (summary table)
    lines.append("## 6. Candidate Learnings — NOT Auto-Applied")
    lines.append("")
    lines.append(REPORT_DISCLAIMER)
    lines.append("")
    lines.append(
        "Below is a summary table. Each item requires a human decision. "
        "Suggested next steps are provided but are NOT executed automatically."
    )
    lines.append("")
    lines.append("| # | Category | Finding | Count | Suggested action |")
    lines.append("|---|----------|---------|-------|-----------------|")

    row_num = 1
    for c in corrections[:5]:
        lines.append(
            f"| {row_num} | user-correction | `{c.phrase}` | {c.count} | "
            f"Consider adding to `memory` or `rule` — review pattern manually |"
        )
        row_num += 1
    for f_ in failures[:5]:
        lines.append(
            f"| {row_num} | tool-failure | `{f_.tool_label}`: {f_.error_preview[:50]}... | "
            f"{f_.total_occurrences} | Consider `issue-only` — file a bug if recurrent |"
        )
        row_num += 1
    for ng in ngrams[:3]:
        gram_str = " → ".join(ng.ngram)
        lines.append(
            f"| {row_num} | ngram-workflow | `{gram_str}` | {ng.session_count} sessions | "
            f"Consider a `skill` if this workflow benefits from a template |"
        )
        row_num += 1
    for u in unproductive[:2]:
        lines.append(
            f"| {row_num} | unproductive-tail | `{u.session_id}` ({u.read_pct:.0%} reads) | 1 | "
            f"Investigate what was blocking progress — `memory` or `rule` update |"
        )
        row_num += 1

    if row_num == 1:
        lines.append("| — | — | No candidates found in this window | — | — |")

    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append(
        "_Generated by `codex_self_learning_analyzer.py`. "
        "This file is a read-only report. No config was modified._"
    )
    lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    today = dt.date.today()
    default_since = (today - dt.timedelta(days=7)).isoformat()
    default_out = (
        pathlib.Path.home()
        / ".claude"
        / "logs"
        / "codex_self_learning"
        / f"{today.isoformat()}.md"
    )
    default_sessions = pathlib.Path.home() / ".codex" / "sessions"
    default_sqlite = pathlib.Path.home() / ".codex" / "state_5.sqlite"

    p = argparse.ArgumentParser(
        description="Codex JSONL self-learning analyzer — Phase 1 (manual review only)"
    )
    p.add_argument("--since", default=default_since, metavar="YYYY-MM-DD",
                   help="Start date (inclusive). Default: 7 days ago.")
    p.add_argument("--until", default=today.isoformat(), metavar="YYYY-MM-DD",
                   help="End date (inclusive). Default: today.")
    p.add_argument("--out", default=str(default_out), metavar="PATH",
                   help="Output .md report path.")
    p.add_argument("--dry-run", action="store_true",
                   help="Compute report but do not write it to disk.")
    p.add_argument("--sessions-dir", default=str(default_sessions), metavar="PATH",
                   help="Root directory of Codex session JSONL files.")
    p.add_argument("--sqlite", default=str(default_sqlite), metavar="PATH",
                   help="Path to state_5.sqlite for metadata enrichment.")
    p.add_argument("--min-failures", type=int, default=3,
                   help="Minimum occurrences for a tool failure to be surfaced.")
    p.add_argument("--min-failure-sessions", type=int, default=2,
                   help="Minimum distinct sessions for a failure finding.")
    p.add_argument("--min-ngram-sessions", type=int, default=3,
                   help="Minimum distinct sessions for an N-gram finding.")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    try:
        since = dt.date.fromisoformat(args.since)
        until = dt.date.fromisoformat(args.until)
    except ValueError as e:
        print(f"ERROR: bad date format — {e}", file=sys.stderr)
        return 1

    sessions_dir = pathlib.Path(args.sessions_dir).expanduser()
    sqlite_path = pathlib.Path(args.sqlite).expanduser()

    print(f"codex_self_learning_analyzer: loading sessions from {sessions_dir}", file=sys.stderr)
    print(f"  window: {since} to {until}", file=sys.stderr)

    sessions = load_sessions(sessions_dir, since, until)
    print(f"  sessions loaded: {len(sessions)}", file=sys.stderr)

    # Optionally enrich with sqlite metadata (session title etc.)
    _ = load_sqlite_metadata(sqlite_path)  # available for future enrichment

    corrections = detect_user_corrections(sessions)
    failures = detect_repeated_failures(
        sessions,
        min_occurrences=args.min_failures,
        min_sessions=args.min_failure_sessions,
    )
    ngrams = detect_ngrams(sessions, min_sessions=args.min_ngram_sessions)
    unproductive = detect_unproductive_sessions(sessions)

    report = build_report(
        window_start=since,
        window_end=until,
        sessions=sessions,
        corrections=corrections,
        failures=failures,
        ngrams=ngrams,
        unproductive=unproductive,
        report_date=dt.date.today(),
    )

    if args.dry_run:
        print(report)
        print(
            f"\n[dry-run] Report NOT written. Would write to: {args.out}",
            file=sys.stderr,
        )
        return 0

    out_path = pathlib.Path(args.out).expanduser()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(report, encoding="utf-8")
    print(f"Report written: {out_path}")

    # Print section headings for quick smoke check
    for line in report.splitlines():
        if line.startswith("## ") or line.startswith("# "):
            print(line)

    return 0


if __name__ == "__main__":
    sys.exit(main())
