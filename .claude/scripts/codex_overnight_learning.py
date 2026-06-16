#!/usr/bin/env python3
"""codex_overnight_learning.py - Summarise recent Codex sessions into a daily digest.

Reads Codex session JSONL plus prompt history, extracts repeated workflows,
repeated user corrections, and repeated command failures, then writes both a
machine-readable JSON summary and a markdown report.
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
    parser = argparse.ArgumentParser()
    parser.add_argument("--session-root", default=str(default_session_root))
    parser.add_argument("--history-file", default=str(default_history))
    parser.add_argument("--output-dir", default=str(default_output_dir))
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
    )

    json_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    md_path.write_text(markdown, encoding="utf-8")
    return json_path, md_path


def main() -> int:
    args = parse_args()
    now = parse_now(args.now)
    cutoff_dt = now - dt.timedelta(hours=args.lookback_hours)
    cutoff_ts = cutoff_dt.timestamp()

    session_root = pathlib.Path(args.session_root).expanduser()
    history_file = pathlib.Path(args.history_file).expanduser()
    output_dir = pathlib.Path(args.output_dir).expanduser()

    sessions = parse_sessions(session_files(session_root, cutoff_ts))
    history_rows = parse_history(history_file, int(cutoff_ts))

    workflow_signals = detect_workflows(sessions)
    correction_signals = detect_corrections(history_rows)
    failure_signals = detect_failures(sessions)
    signals = workflow_signals + correction_signals + failure_signals

    json_path, md_path = write_outputs(output_dir, now, cutoff_dt, sessions, signals)

    digest = hashlib.sha1(json_path.read_bytes()).hexdigest()
    print(f"codex-overnight-learning: sessions={len(sessions)} signals={len(signals)} sha1={digest}")
    print(f"  json: {json_path}")
    print(f"  md:   {md_path}")

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
