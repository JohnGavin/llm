"""Extract the target path and NEW content from an Edit/Write/NotebookEdit hook
payload (llm#1387, privacy layer L1).

Usage: python3 private_term_payload.py CONTENT_OUT_FILE < payload.json
  stdout : the absolute target path (one line), or nothing when the tool is not
           one of Write, Edit, MultiEdit, NotebookEdit (caller allows).
  CONTENT_OUT_FILE : the new text (new_string / content / new_source), written
           only when a path was printed.
  exit   : 0 ok (including "not our tool"); 1 payload unreadable (caller treats
           as INDETERMINATE, never as a pass).
"""
import json
import os
import sys


def main():
    out_file = sys.argv[1]
    try:
        payload = json.loads(sys.stdin.read())
    except Exception:
        return 1
    if not isinstance(payload, dict):
        return 1
    tool = payload.get("tool_name") or ""
    ti = payload.get("tool_input") or {}
    if not isinstance(ti, dict):
        return 1
    parts = []
    if tool == "Write":
        path = ti.get("file_path") or ""
        parts.append(ti.get("content") or "")
    elif tool == "Edit":
        path = ti.get("file_path") or ""
        parts.append(ti.get("new_string") or "")
    elif tool == "MultiEdit":
        path = ti.get("file_path") or ""
        for e in ti.get("edits") or []:
            if isinstance(e, dict):
                parts.append(e.get("new_string") or "")
    elif tool == "NotebookEdit":
        path = ti.get("notebook_path") or ""
        parts.append(ti.get("new_source") or "")
    else:
        return 0
    if not path:
        return 1
    cwd = payload.get("cwd") or os.getcwd()
    path = os.path.normpath(os.path.join(cwd, os.path.expanduser(path)))
    with open(out_file, "w", encoding="utf-8", errors="replace") as fh:
        fh.write("\n".join(str(p) for p in parts))
    sys.stdout.write(path.replace("\n", " ") + "\n")
    return 0


try:
    sys.exit(main())
except SystemExit:
    raise
except Exception:
    sys.exit(1)
