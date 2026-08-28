#!/usr/bin/env python3
"""codex_overnight_learning.py - Summarise recent CLI-agent sessions into a daily digest.

Reads TWO session sources -- Codex session JSONL (plus its prompt history)
and Claude Code session JSONL under ~/.claude/projects/**/*.jsonl -- and
extracts repeated workflows, repeated user corrections, and repeated command
failures from both, then writes a combined machine-readable JSON summary and
a markdown report.

Why two sources (llm#690): this job originally read ONLY Codex sessions.
When Codex CLI is rate-limited/unavailable, ~/.codex/sessions/ is empty and
the job silently emitted an all-zero digest every morning while real work
was happening in Claude Code sessions the job never looked at -- the same
"metric reads a dead/empty source" shape as #318/#323/#676/#679. The two
sources are merged (Claude Code session ids prefixed "claude:" so they can
never collide with Codex's own ids) so the digest reflects whichever tool
was actually in use, and a loud WARN fires if BOTH sources are empty rather
than silently reporting session_count=0 as if nothing happened overnight.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import shlex
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, asdict
from typing import Any


PATH_RE = re.compile(r"/Users/[A-Za-z0-9._-]+(?:/[^\s\"']+)?")
URL_RE = re.compile(r"https?://\S+")
DATE_RE = re.compile(r"\b20\d{2}-\d{2}-\d{2}\b")
NUMBER_RE = re.compile(r"\b\d+\b")
SPACE_RE = re.compile(r"\s+")


@dataclass
class Signal:
    category: str
    title: str
    target: str
    repetition_count: int
    session_count: int
    details: str
    sources: list[str]


def parse_args() -> argparse.Namespace:
    home = pathlib.Path.home()
    default_session_root = home / ".codex" / "sessions"
    default_history = home / ".codex" / "history.jsonl"
    default_output_dir = home / ".codex" / "learning"
    default_claude_projects_root = home / ".claude" / "projects"
    parser = argparse.ArgumentParser()
    parser.add_argument("--session-root", default=str(default_session_root))
    parser.add_argument("--history-file", default=str(default_history))
    parser.add_argument("--output-dir", default=str(default_output_dir))
    parser.add_argument(
        "--claude-projects-root",
        default=str(default_claude_projects_root),
        help="Claude Code session JSONL root (llm#690) -- set to a nonexistent "
        "path to disable this source and read Codex sessions only.",
    )
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="Run against synthetic fixtures in a temp dir and exit; no real "
        "session data is read.",
    )
    parser.add_argument("--lookback-hours", type=int, default=24)
    parser.add_argument(
        "--now",
        help="Override current UTC timestamp in ISO-8601 form, e.g. 2026-05-22T07:00:00+00:00",
    )
    return parser.parse_args()


def parse_now(raw: str | None) -> dt.datetime:
    if raw:
        parsed = dt.datetime.fromisoformat(raw)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.astimezone(dt.timezone.utc)
    return dt.datetime.now(dt.timezone.utc)


def ensure_dir(path: pathlib.Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def normalize_text(text: str) -> str:
    text = URL_RE.sub("<URL>", text)
    text = PATH_RE.sub("<PATH>", text)
    text = DATE_RE.sub("<DATE>", text)
    text = NUMBER_RE.sub("<N>", text)
    text = SPACE_RE.sub(" ", text)
    return text.strip()


def strip_env_prefix(tokens: list[str]) -> list[str]:
    idx = 0
    while idx < len(tokens) and "=" in tokens[idx] and not tokens[idx].startswith("-"):
        key, _, value = tokens[idx].partition("=")
        if key and value:
            idx += 1
            continue
        break
    return tokens[idx:]


def command_family(cmd: str) -> str:
    try:
        tokens = shlex.split(cmd)
    except ValueError:
        tokens = cmd.strip().split()
    tokens = strip_env_prefix(tokens)
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

    if first == "which" and tail:
        return f"which {tail[0]}"

    if first == "echo" and tail:
        if "IN_NIX_SHELL" in " ".join(tail):
            return "echo IN_NIX_SHELL"
        return "echo"

    if first in {"sed", "rg", "sqlite3", "python3", "python", "find", "ls", "duckdb", "nix-shell"}:
        return first

    if first == "timeout":
        for tok in tail[1:]:
            if tok.startswith("-"):
                continue
            return f"timeout {os.path.basename(tok)}"
        return "timeout"

    return first


def flatten_call(name: str, arguments: str) -> list[dict[str, str]]:
    labels: list[dict[str, str]] = []
    try:
        payload = json.loads(arguments or "{}")
    except json.JSONDecodeError:
        payload = {}

    if name == "exec_command":
        cmd = str(payload.get("cmd", ""))
        labels.append({"label": command_family(cmd), "raw": cmd or "exec_command"})
        return labels

    if name == "parallel":
        for tool_use in payload.get("tool_uses", []):
            recipient = tool_use.get("recipient_name", "")
            params = tool_use.get("parameters", {})
            if recipient == "functions.exec_command":
                cmd = str(params.get("cmd", ""))
                labels.append({"label": command_family(cmd), "raw": cmd or "exec_command"})
            else:
                labels.append({"label": recipient.replace("functions.", ""), "raw": recipient})
        return labels

    labels.append({"label": name, "raw": name})
    return labels


def detect_failure(output: str) -> tuple[bool, int | None]:
    match = re.search(r"Process exited with code (\d+)", output)
    if match:
        code = int(match.group(1))
        return (code != 0, code)
    if "Error:" in output or "Traceback" in output:
        return (True, None)
    return (False, None)


def extract_failure_preview(output: str) -> str:
    body = output
    if "Output:\n" in output:
        body = output.split("Output:\n", 1)[1]
    elif "Output:" in output:
        body = output.split("Output:", 1)[1]

    for line in body.splitlines():
        preview = normalize_text(line)
        if preview:
            return preview[:160]
    return ""


def session_files(session_root: pathlib.Path, cutoff: float) -> list[pathlib.Path]:
    files = [p for p in session_root.rglob("*.jsonl") if p.is_file()]
    return sorted([p for p in files if p.stat().st_mtime >= cutoff])


def parse_sessions(paths: list[pathlib.Path]) -> dict[str, dict[str, Any]]:
    sessions: dict[str, dict[str, Any]] = {}

    for path in paths:
        info: dict[str, Any] = {
            "session_id": path.stem.split("-")[-1],
            "path": str(path),
            "command_labels": [],
            "raw_commands": [],
            "call_map": {},
            "failures": [],
            "title": path.stem,
        }
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if event.get("type") == "session_meta":
                    payload = event.get("payload", {})
                    info["session_id"] = payload.get("id", info["session_id"])
                    info["title"] = payload.get("title", info["title"])
                    continue

                if event.get("type") != "response_item":
                    continue

                payload = event.get("payload", {})
                item_type = payload.get("type")

                if item_type == "function_call":
                    call_id = payload.get("call_id", "")
                    labels = flatten_call(payload.get("name", ""), payload.get("arguments", "{}"))
                    info["call_map"][call_id] = labels
                    for label in labels:
                        info["command_labels"].append(label["label"])
                        info["raw_commands"].append(label["raw"])
                    continue

                if item_type == "function_call_output":
                    output = str(payload.get("output", ""))
                    has_failure, exit_code = detect_failure(output)
                    if has_failure:
                        preview = extract_failure_preview(output)
                        if not preview:
                            continue
                        labels = info["call_map"].get(payload.get("call_id", ""), [{"label": "tool_call", "raw": "tool_call"}])
                        for label in labels:
                            info["failures"].append(
                                {
                                    "label": label["label"],
                                    "exit_code": exit_code,
                                    "preview": preview,
                                }
                            )

        sessions[info["session_id"]] = info

    return sessions


def parse_claude_timestamp(ts: str) -> int:
    """Parse a Claude Code session's ISO-8601 'Z' timestamp to epoch seconds.

    Returns 0 (not "now") on any parse failure so a malformed/missing
    timestamp sorts before the lookback window rather than always inside it.
    """
    if not ts:
        return 0
    try:
        parsed = dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return int(parsed.timestamp())
    except ValueError:
        return 0


def extract_claude_failure_preview(content: Any) -> str:
    """Normalise a Claude Code tool_result's `content` (str or content-block
    list) into a short preview, mirroring extract_failure_preview()'s output
    shape so both sources feed detect_failures() identically."""
    if isinstance(content, list):
        texts = [
            block.get("text", "")
            for block in content
            if isinstance(block, dict) and block.get("type") == "text"
        ]
        text = " ".join(texts)
    else:
        text = str(content)

    for line in text.splitlines():
        preview = normalize_text(line)
        if preview:
            return preview[:160]
    return ""


def parse_claude_sessions(
    paths: list[pathlib.Path],
) -> tuple[dict[str, dict[str, Any]], list[dict[str, Any]]]:
    """Parse Claude Code session JSONL files (~/.claude/projects/**/*.jsonl).

    Returns (sessions, history_rows) in the same shapes parse_sessions() and
    parse_history() produce, so detect_workflows()/detect_corrections()/
    detect_failures() run over them unchanged regardless of source. Session
    ids are prefixed "claude:" so they can never collide with Codex's own
    ids when the two sources' session dicts are merged in main().

    Schema (differs entirely from Codex's response_item/function_call
    format): each JSONL line is one event with a top-level "type". A Bash
    tool call is an "assistant" event whose message.content list has a
    {"type": "tool_use", "name": "Bash", "input": {"command": ...}} block.
    Its result is a later "user" event whose message.content is a LIST of
    {"type": "tool_result", "tool_use_id": ..., "is_error": bool} blocks --
    contrast a genuine user prompt, whose message.content is a bare STRING.
    That str-vs-list distinction is what separates real prompts (read for
    detect_corrections()) from tool-result wrappers (read for failures).
    """
    sessions: dict[str, dict[str, Any]] = {}
    history_rows: list[dict[str, Any]] = []

    for path in paths:
        session_id = f"claude:{path.stem}"
        info: dict[str, Any] = {
            "session_id": session_id,
            "path": str(path),
            "command_labels": [],
            "raw_commands": [],
            "call_map": {},
            "failures": [],
            "title": path.parent.name,
        }
        saw_any_event = False

        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                saw_any_event = True

                event_type = event.get("type")
                content = event.get("message", {}).get("content")

                if event_type == "assistant" and isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict) or block.get("type") != "tool_use":
                            continue
                        if block.get("name") != "Bash":
                            continue
                        cmd = str(block.get("input", {}).get("command", ""))
                        label = command_family(cmd)
                        entry = {"label": label, "raw": cmd or "Bash"}
                        info["call_map"].setdefault(block.get("id", ""), []).append(entry)
                        info["command_labels"].append(label)
                        info["raw_commands"].append(cmd or "Bash")

                elif event_type == "user" and isinstance(content, str):
                    history_rows.append(
                        {
                            "ts": parse_claude_timestamp(event.get("timestamp", "")),
                            "text": content,
                            "session_id": session_id,
                        }
                    )

                elif event_type == "user" and isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict) or block.get("type") != "tool_result":
                            continue
                        if not block.get("is_error"):
                            continue
                        preview = extract_claude_failure_preview(block.get("content", ""))
                        if not preview:
                            continue
                        labels = info["call_map"].get(
                            block.get("tool_use_id", ""),
                            [{"label": "tool_call", "raw": "tool_call"}],
                        )
                        for label in labels:
                            info["failures"].append(
                                {"label": label["label"], "exit_code": None, "preview": preview}
                            )

        if saw_any_event:
            sessions[session_id] = info

    return sessions, history_rows


def parse_history(history_file: pathlib.Path, cutoff: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not history_file.exists():
        return rows

    with history_file.open("r", encoding="utf-8") as handle:
        for line in handle:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if int(row.get("ts", 0)) < cutoff:
                continue
            rows.append(row)
    return rows


def detect_workflows(sessions: dict[str, dict[str, Any]]) -> list[Signal]:
    buckets: dict[str, list[str]] = defaultdict(list)

    for session_id, info in sessions.items():
        families = set(info["command_labels"])
        raw_blob = " ".join(info["raw_commands"])

        if {"git status", "gh issue list", "sed"} <= families and "CHANGELOG.md" in raw_blob:
            buckets["repo triage workflow"].append(session_id)

        if "gh issue create" in families:
            buckets["github issue drafting workflow"].append(session_id)

        if any("IN_NIX_SHELL" in raw for raw in info["raw_commands"]) or "which R" in families or "nix-shell" in families:
            buckets["nix environment verification"].append(session_id)

        if ".codex/" in raw_blob and ("sqlite3" in families or "find" in families or "sed" in families):
            buckets["codex local-state inspection"].append(session_id)

    signals: list[Signal] = []
    for title, session_ids in buckets.items():
        unique_ids = sorted(set(session_ids))
        if len(unique_ids) < 2:
            continue
        target = "skill"
        if title in {"nix environment verification", "codex local-state inspection"}:
            target = "memory"
        details = f"Observed in {len(unique_ids)} recent sessions."
        signals.append(
            Signal(
                category="workflow",
                title=title,
                target=target,
                repetition_count=len(unique_ids),
                session_count=len(unique_ids),
                details=details,
                sources=unique_ids,
            )
        )

    return signals


def detect_corrections(history_rows: list[dict[str, Any]]) -> list[Signal]:
    grouped: dict[str, dict[str, Any]] = {}

    for row in history_rows:
        text = str(row.get("text", "")).strip()
        lowered = text.lower()
        if not any(marker in lowered for marker in ("don't", "do not", "never", "always", "no need", "instead", "read agents")):
            continue

        normalized = normalize_text(lowered)
        title = f"Repeated user correction: {normalized[:90]}"
        target = "memory"
        if any(marker in lowered for marker in ("don't", "do not", "never", "always")):
            target = "rule"

        if "read agents" in lowered:
            title = "Read AGENTS.md before deeper work"
            target = "memory"

        if "default.nix" in lowered and any(marker in lowered for marker in ("don't", "do not", "never")):
            title = "Do not edit default.nix directly"
            target = "rule"

        bucket = grouped.setdefault(
            title,
            {"count": 0, "sessions": set(), "details": normalized[:180], "target": target},
        )
        bucket["count"] += 1
        bucket["sessions"].add(str(row.get("session_id", "unknown")))

    signals: list[Signal] = []
    for title, bucket in grouped.items():
        session_ids = sorted(bucket["sessions"])
        if bucket["count"] < 2:
            continue
        signals.append(
            Signal(
                category="correction",
                title=title,
                target=bucket["target"],
                repetition_count=int(bucket["count"]),
                session_count=len(session_ids),
                details=f"Prompt-history correction repeated {bucket['count']} times.",
                sources=session_ids,
            )
        )

    return signals


def detect_failures(sessions: dict[str, dict[str, Any]]) -> list[Signal]:
    grouped: dict[str, dict[str, Any]] = {}

    for session_id, info in sessions.items():
        for failure in info["failures"]:
            code = failure["exit_code"]
            label = failure["label"]
            title = f"Repeated non-zero exit: {label}"
            if code is not None:
                title = f"Repeated exit {code}: {label}"
            bucket = grouped.setdefault(
                title,
                {"count": 0, "sessions": set(), "details": failure["preview"]},
            )
            bucket["count"] += 1
            bucket["sessions"].add(session_id)

    signals: list[Signal] = []
    for title, bucket in grouped.items():
        session_ids = sorted(bucket["sessions"])
        if len(session_ids) < 2:
            continue
        signals.append(
            Signal(
                category="failure",
                title=title,
                target="issue-only",
                repetition_count=int(bucket["count"]),
                session_count=len(session_ids),
                details=bucket["details"],
                sources=session_ids,
            )
        )

    return signals


def top_signals(signals: list[Signal], limit: int = 5) -> list[Signal]:
    ordered = sorted(
        signals,
        key=lambda signal: (
            {"workflow": 0, "correction": 1, "failure": 2}.get(signal.category, 9),
            -signal.session_count,
            -signal.repetition_count,
            signal.title,
        ),
    )
    return ordered[:limit]


def build_markdown(
    summary_date: str,
    window_start: str,
    window_end: str,
    sessions: dict[str, dict[str, Any]],
    signals: list[Signal],
    output_json: pathlib.Path,
    source_summary: dict[str, Any],
) -> str:
    workflow_signals = [s for s in signals if s.category == "workflow"]
    correction_signals = [s for s in signals if s.category == "correction"]
    failure_signals = [s for s in signals if s.category == "failure"]
    lines = [
        f"# Codex Overnight Learning Summary — {summary_date}",
        "",
        f"- Window: `{window_start}` to `{window_end}`",
        f"- Sessions analyzed: `{len(sessions)}`",
        f"- JSON summary: `{output_json}`",
        "",
        "## Sources (llm#690)",
        "",
        f"- Codex: `{source_summary['codex_session_root']}` — "
        f"`{source_summary['codex_sessions']}` session(s)",
        f"- Claude Code: `{source_summary['claude_projects_root']}` — "
        f"`{source_summary['claude_sessions']}` session(s)",
        "",
        "## Counts",
        "",
        f"- Workflow candidates: `{len(workflow_signals)}`",
        f"- User-correction candidates: `{len(correction_signals)}`",
        f"- Failure candidates: `{len(failure_signals)}`",
        "",
        "## Top Signals",
        "",
    ]

    for idx, signal in enumerate(top_signals(signals), start=1):
        lines.extend(
            [
                f"{idx}. **{signal.title}**",
                f"   - Category: `{signal.category}`",
                f"   - Suggested target: `{signal.target}`",
                f"   - Repetitions: `{signal.repetition_count}`",
                f"   - Sessions: `{signal.session_count}`",
                f"   - Sources: `{', '.join(signal.sources[:5])}`",
                f"   - Detail: {signal.details}",
            ]
        )

    source_ids = sorted({source for signal in signals for source in signal.sources})
    lines.extend(["", "## Session Provenance", ""])
    for session_id in source_ids:
        info = sessions.get(session_id)
        if info is None:
            continue
        lines.append(f"- `{session_id}` — `{info['title']}` — `{info['path']}`")

    omitted = len(sessions) - len(source_ids)
    if omitted > 0:
        lines.append(f"- `{omitted}` additional session(s) were analyzed but did not appear in surfaced signals.")

    return "\n".join(lines) + "\n"


def write_outputs(
    output_dir: pathlib.Path,
    now: dt.datetime,
    window_start: dt.datetime,
    sessions: dict[str, dict[str, Any]],
    signals: list[Signal],
    source_summary: dict[str, Any],
) -> tuple[pathlib.Path, pathlib.Path]:
    ensure_dir(output_dir)
    summary_date = now.date().isoformat()
    json_path = output_dir / f"{summary_date}-summary.json"
    md_path = output_dir / f"{summary_date}-summary.md"

    payload = {
        "summary_date": summary_date,
        "generated_at_utc": now.isoformat(),
        "window_start_utc": window_start.isoformat(),
        "window_end_utc": now.isoformat(),
        "session_count": len(sessions),
        "sources": source_summary,
        "counts": {
            "workflow_candidates": sum(1 for s in signals if s.category == "workflow"),
            "correction_candidates": sum(1 for s in signals if s.category == "correction"),
            "failure_candidates": sum(1 for s in signals if s.category == "failure"),
            "candidate_targets": dict(Counter(s.target for s in signals)),
        },
        "top_signals": [asdict(signal) for signal in top_signals(signals)],
        "all_signals": [asdict(signal) for signal in signals],
    }

    markdown = build_markdown(
        summary_date=summary_date,
        window_start=window_start.isoformat(),
        window_end=now.isoformat(),
        sessions=sessions,
        signals=signals,
        output_json=json_path,
        source_summary=source_summary,
    )

    json_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    md_path.write_text(markdown, encoding="utf-8")
    return json_path, md_path


def selftest() -> int:
    """Synthetic-fixture check for parse_claude_sessions() (llm#690).

    Builds one fixture session with: a successful Bash tool_use, a FAILING
    Bash tool_use whose tool_result carries is_error=true, and a real user
    prompt containing a correction marker -- then asserts each surfaces
    through the same shapes/paths a real session would.
    """
    import tempfile

    checks: list[tuple[str, bool]] = []

    with tempfile.TemporaryDirectory() as tmp:
        proj_dir = pathlib.Path(tmp) / "-fake-project"
        proj_dir.mkdir()
        session_path = proj_dir / "11111111-2222-3333-4444-555555555555.jsonl"

        events = [
            {
                "type": "user",
                "timestamp": "2026-08-28T09:00:00.000Z",
                "message": {"content": "don't ever run rm -rf without asking first"},
            },
            {
                "type": "assistant",
                "message": {
                    "content": [
                        {
                            "type": "tool_use",
                            "id": "toolu_ok",
                            "name": "Bash",
                            "input": {"command": "git status"},
                        }
                    ]
                },
            },
            {
                "type": "user",
                "message": {
                    "content": [
                        {"type": "tool_result", "tool_use_id": "toolu_ok", "content": "clean", "is_error": False}
                    ]
                },
            },
            {
                "type": "assistant",
                "message": {
                    "content": [
                        {
                            "type": "tool_use",
                            "id": "toolu_fail",
                            "name": "Bash",
                            "input": {"command": "gh pr view 999"},
                        }
                    ]
                },
            },
            {
                "type": "user",
                "message": {
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": "toolu_fail",
                            "content": "Error: pull request not found",
                            "is_error": True,
                        }
                    ]
                },
            },
        ]
        with session_path.open("w", encoding="utf-8") as handle:
            for event in events:
                handle.write(json.dumps(event) + "\n")

        sessions, history_rows = parse_claude_sessions([session_path])

        session_id = f"claude:{session_path.stem}"
        checks.append(("session captured", session_id in sessions))
        info = sessions.get(session_id, {})
        checks.append(("git status labelled", "git status" in info.get("command_labels", [])))
        checks.append(
            ("gh command labelled", any(lbl.startswith("gh ") for lbl in info.get("command_labels", [])))
        )
        checks.append(("one failure recorded", len(info.get("failures", [])) == 1))
        checks.append(
            (
                "failure preview non-empty",
                bool(info.get("failures", [{}])[0].get("preview")) if info.get("failures") else False,
            )
        )
        checks.append(("history row captured", len(history_rows) == 1))
        checks.append(
            (
                "history row text matches",
                history_rows[0]["text"] == "don't ever run rm -rf without asking first" if history_rows else False,
            )
        )
        checks.append(
            ("history row epoch parsed", history_rows[0]["ts"] > 0 if history_rows else False)
        )

        # detect_corrections() requires >= 2 occurrences before surfacing a
        # signal -- one fixture session correctly yields zero signals here.
        # The str-content-vs-list-content split (real prompt vs tool-result
        # wrapper) is what's actually under test in the "history row" checks
        # above; this just confirms the existing threshold still applies.
        detected_corrections = detect_corrections(history_rows)
        checks.append(("correction threshold (2+) still applies to 1 occurrence", len(detected_corrections) == 0))

    print("=== codex_overnight_learning.py --selftest ===")
    all_pass = True
    for label, ok in checks:
        print(f"  {'PASS' if ok else 'FAIL'}: {label}")
        all_pass = all_pass and ok

    print(f"=== {'ALL PASS' if all_pass else 'FAILURES DETECTED'} ({sum(1 for _, ok in checks if ok)}/{len(checks)}) ===")
    return 0 if all_pass else 1


def main() -> int:
    args = parse_args()
    if args.selftest:
        return selftest()
    now = parse_now(args.now)
    cutoff_dt = now - dt.timedelta(hours=args.lookback_hours)
    cutoff_ts = cutoff_dt.timestamp()

    session_root = pathlib.Path(args.session_root).expanduser()
    history_file = pathlib.Path(args.history_file).expanduser()
    output_dir = pathlib.Path(args.output_dir).expanduser()
    claude_projects_root = pathlib.Path(args.claude_projects_root).expanduser()

    codex_sessions = parse_sessions(session_files(session_root, cutoff_ts))
    claude_sessions, claude_history_rows = parse_claude_sessions(
        session_files(claude_projects_root, cutoff_ts)
    )
    sessions = {**codex_sessions, **claude_sessions}
    history_rows = parse_history(history_file, int(cutoff_ts)) + claude_history_rows

    source_summary = {
        "codex_session_root": str(session_root),
        "codex_sessions": len(codex_sessions),
        "claude_projects_root": str(claude_projects_root),
        "claude_sessions": len(claude_sessions),
    }

    workflow_signals = detect_workflows(sessions)
    correction_signals = detect_corrections(history_rows)
    failure_signals = detect_failures(sessions)
    signals = workflow_signals + correction_signals + failure_signals

    json_path, md_path = write_outputs(
        output_dir, now, cutoff_dt, sessions, signals, source_summary
    )

    digest = hashlib.sha1(json_path.read_bytes()).hexdigest()
    print(f"codex-overnight-learning: sessions={len(sessions)} signals={len(signals)} sha1={digest}")
    print(f"  codex={source_summary['codex_sessions']} claude={source_summary['claude_sessions']}")
    print(f"  json: {json_path}")
    print(f"  md:   {md_path}")

    # llm#690: a 0 across BOTH sources usually means one or both roots are
    # dead/misconfigured (e.g. Codex CLI rate-limited so ~/.codex/sessions/
    # is empty), not that no work happened overnight -- flag it loudly
    # rather than let a silent all-zero digest look like a real "quiet
    # night". Exit code stays 0 (this is a launchd job; a non-zero exit
    # would page on a state that isn't actually a script failure) but the
    # WARN line is unambiguous in the launchd log.
    if len(sessions) == 0:
        print(
            "codex-overnight-learning: WARN 0 sessions across BOTH configured "
            f"sources (codex={session_root}, claude={claude_projects_root}) -- "
            "source(s) likely dead/misconfigured, not a genuinely quiet night "
            "(llm#690)",
            file=sys.stderr,
        )

    # Stamp for cron_catchup.sh catch-up detection
    import datetime
    _stamp_dir = pathlib.Path.home() / ".claude" / "logs" / "stamps"
    _stamp_dir.mkdir(parents=True, exist_ok=True)
    (_stamp_dir / "codex-overnight.stamp").write_text(
        datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ") + "\n"
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
