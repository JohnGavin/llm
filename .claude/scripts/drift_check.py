#!/usr/bin/env python3
"""drift_check.py — passive semantic-drift logger (#125 Phase 1)

Reads the current session's JSONL transcript, extracts assistant text,
embeds it via local `intfloat/e5-small-v2`, compares against a baseline
centroid built from the last N closed-no-revert commit messages, and
appends a z-score line to `~/.claude/logs/drift.log`.

Passive only. No enforcement, no notification — the log line is the
record. We need 2-3 weeks of data before deciding whether the signal
is meaningful enough to gate on.

Graceful fallback: if `transformers` or `sentence_transformers` is not
importable, log a single "embedder unavailable" line and exit 0. The
rest of the framework (baseline rebuild, log rotation) still works.

Usage:
  drift_check.py                       # current session
  drift_check.py --rebuild-baseline    # rebuild baseline from git log
  drift_check.py <session_id>          # specific session
"""
import json
import os
import sys
import subprocess
import datetime
import pathlib

# ── Config ─────────────────────────────────────────────────────────────
REPO_ROOT = pathlib.Path.home() / "docs_gh" / "llm"
JSONL_DIR = pathlib.Path.home() / ".claude" / "projects" / "-Users-johngavin-docs-gh-llm"
LOG_PATH = pathlib.Path.home() / ".claude" / "logs" / "drift.log"
BASELINE_NPY = pathlib.Path.home() / ".claude" / "data" / "drift_baseline.npy"
BASELINE_META = pathlib.Path.home() / ".claude" / "data" / "drift_baseline.json"
BASELINE_N = 30                 # last N closed-no-revert commits
MODEL_NAME = "intfloat/e5-small-v2"
ALERT_Z = 2.5                   # currently log-only; threshold for future gate

LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
BASELINE_NPY.parent.mkdir(parents=True, exist_ok=True)


# ── Logging ────────────────────────────────────────────────────────────
def log(msg: str) -> None:
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(LOG_PATH, "a") as f:
        f.write(f"{ts}  {msg}\n")


# ── Embedder (graceful fallback) ───────────────────────────────────────
def get_embedder():
    """Return a callable embedder(text)->np.ndarray, or None if libs absent."""
    try:
        import numpy as np  # noqa: F401
    except ImportError:
        log("ERROR: numpy not available — skipping")
        return None

    try:
        from sentence_transformers import SentenceTransformer
        model = SentenceTransformer(MODEL_NAME)

        def embed(text: str):
            # e5 expects "query: ..." or "passage: ..." prefixes; we are
            # comparing similar-domain content, so use "passage:" uniformly.
            return model.encode(f"passage: {text}", normalize_embeddings=True)
        return embed
    except ImportError:
        pass

    # Fallback: raw transformers + manual mean-pool
    try:
        from transformers import AutoTokenizer, AutoModel
        import torch
        tok = AutoTokenizer.from_pretrained(MODEL_NAME)
        mod = AutoModel.from_pretrained(MODEL_NAME)
        mod.eval()

        def embed(text: str):
            inp = tok(f"passage: {text}", return_tensors="pt",
                      truncation=True, max_length=512)
            with torch.no_grad():
                out = mod(**inp)
            mask = inp["attention_mask"].unsqueeze(-1).float()
            v = (out.last_hidden_state * mask).sum(1) / mask.sum(1)
            v = v / v.norm(dim=-1, keepdim=True)
            return v[0].numpy()
        return embed
    except ImportError:
        return None


# ── Baseline corpus ────────────────────────────────────────────────────
def last_closed_no_revert_commits(n: int):
    """Return the subject lines of the last n commits that aren't reverts
    and weren't reverted by a later commit. Heuristic, not perfect."""
    out = subprocess.check_output(
        ["git", "-C", str(REPO_ROOT), "log", "--format=%H\t%s", "-n", str(n * 3)],
        text=True,
    )
    lines = [line.split("\t", 1) for line in out.strip().splitlines() if "\t" in line]
    reverted_shas = {
        m.group(1)
        for s in lines
        for m in [__import__("re").search(r"This reverts commit ([a-f0-9]+)", s[1])]
        if m
    }
    out = []
    for sha, subject in lines:
        if subject.lower().startswith("revert "):
            continue
        if sha in reverted_shas:
            continue
        # Skip noise: merge commits, version bumps
        if subject.startswith("Merge "):
            continue
        out.append(subject)
        if len(out) >= n:
            break
    return out


def rebuild_baseline(embed) -> None:
    import numpy as np
    subjects = last_closed_no_revert_commits(BASELINE_N)
    if not subjects:
        log("ERROR: no commits found for baseline")
        return
    vecs = np.stack([embed(s) for s in subjects])
    centroid = vecs.mean(axis=0)
    # Distance of each baseline item to the centroid → distribution
    dists = 1.0 - vecs @ centroid           # cosine distance for unit vectors
    np.save(BASELINE_NPY, centroid)
    meta = {
        "n": len(subjects),
        "model": MODEL_NAME,
        "rebuilt_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "dist_mean": float(dists.mean()),
        "dist_std": float(dists.std(ddof=1)) if len(dists) > 1 else 0.0,
        "subjects": subjects,
    }
    with open(BASELINE_META, "w") as f:
        json.dump(meta, f, indent=2)
    log(f"baseline rebuilt n={len(subjects)} mean={meta['dist_mean']:.4f} std={meta['dist_std']:.4f}")


def load_baseline():
    import numpy as np
    if not BASELINE_NPY.exists() or not BASELINE_META.exists():
        return None, None
    centroid = np.load(BASELINE_NPY)
    with open(BASELINE_META) as f:
        meta = json.load(f)
    return centroid, meta


# ── Session text extraction ────────────────────────────────────────────
def session_assistant_text(session_id: str) -> str:
    """Concatenate all assistant message text in this session's JSONL."""
    path = JSONL_DIR / f"{session_id}.jsonl"
    if not path.exists():
        return ""
    parts = []
    with open(path) as f:
        for line in f:
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            # Try a few schema variants — JSONL format has shifted over time
            msg = ev.get("message") or {}
            if msg.get("role") == "assistant":
                content = msg.get("content")
                if isinstance(content, str):
                    parts.append(content)
                elif isinstance(content, list):
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "text":
                            parts.append(c.get("text", ""))
    return "\n".join(parts)


# ── Main ───────────────────────────────────────────────────────────────
def main() -> int:
    args = sys.argv[1:]
    rebuild = "--rebuild-baseline" in args
    args = [a for a in args if a != "--rebuild-baseline"]
    session_id = args[0] if args else os.environ.get("CLAUDE_CODE_SESSION_ID", "")

    embed = get_embedder()
    if embed is None:
        log("embedder unavailable (transformers/sentence_transformers not importable) — install in a venv to enable")
        return 0

    if rebuild or not BASELINE_NPY.exists():
        rebuild_baseline(embed)

    if not session_id:
        log("no session id — set CLAUDE_CODE_SESSION_ID or pass as arg")
        return 0

    centroid, meta = load_baseline()
    if centroid is None:
        log("no baseline — try --rebuild-baseline")
        return 0

    text = session_assistant_text(session_id)
    if not text.strip():
        log(f"session={session_id[:8]} empty transcript")
        return 0

    # Truncate to reduce embedding cost; e5 max is 512 tokens anyway.
    # Take last 4000 chars — most-recent context.
    text = text[-4000:]
    v = embed(text)
    import numpy as np
    dist = float(1.0 - np.dot(v, centroid))
    if meta["dist_std"] > 0:
        z = (dist - meta["dist_mean"]) / meta["dist_std"]
    else:
        z = 0.0
    alert = " ALERT" if abs(z) > ALERT_Z else ""
    log(f"session={session_id[:8]} dist={dist:.4f} z={z:+.2f} (baseline mean={meta['dist_mean']:.4f} std={meta['dist_std']:.4f}){alert}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
