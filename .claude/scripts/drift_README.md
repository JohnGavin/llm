# Semantic drift logger (#125 Phase 1)

Passive drift detection: at session end, embed the assistant's
output text and log a z-score against a baseline built from the
last 30 closed-no-revert commits.

## Status

**Passive log only.** No enforcement, no notification. The threshold
in `drift_check.py` (`ALERT_Z = 2.5`) marks lines but doesn't gate
on them. Need 2-3 weeks of data before deciding whether the signal
is meaningful enough to act on.

## What's wired

- `drift_check.py` — runs at session end via `session_stop.sh`
- Output: `~/.claude/logs/drift.log`
- Baseline: `~/.claude/data/drift_baseline.{npy,json}` (rebuilt
  lazily on first call, or explicitly via `drift_check.py
  --rebuild-baseline`)

## Enabling real embeddings

The script currently logs `"embedder unavailable"` because
`transformers` / `sentence_transformers` are not in the nix shell.
Two options:

### Option A — venv (recommended for prototype phase)

```bash
/usr/bin/python3 -m venv ~/.venvs/drift
~/.venvs/drift/bin/pip install sentence-transformers
```

Then point the hook at the venv's python by editing
`.claude/hooks/session_stop.sh` to call
`~/.venvs/drift/bin/python3 "$DRIFT"`.

First run downloads `intfloat/e5-small-v2` (~133MB) into
`~/.cache/huggingface/`.

### Option B — add to nix shell (commit, all sessions get it)

Add to `default.R`:

```r
py_pkgs = c("sentence-transformers", "torch")
```

Then `Rscript default.R` to regenerate `default.nix` and re-enter
the shell. Heavier change; commit only after the prototype proves
useful.

## Reading the log

```
2026-05-13T08:21:04Z  session=23e9bc85 dist=0.0421 z=+0.32 (baseline mean=0.0398 std=0.0072)
2026-05-13T22:05:18Z  session=4f1e9c30 dist=0.0918 z=+7.22 (baseline mean=0.0398 std=0.0072) ALERT
```

- `dist` — cosine distance from this session's text to the baseline centroid (0 = identical direction, 1 = orthogonal, 2 = opposite)
- `z` — number of standard deviations above/below the baseline distribution
- `ALERT` — appears when `|z| > 2.5`

## Revert

Remove the `# ── Semantic drift logger` block from
`.claude/hooks/session_stop.sh` and delete `drift_check.py`. The
log file at `~/.claude/logs/drift.log` and baseline files are
harmless to leave.

## Tracked in

#125 — the scoping decisions are recorded in this session's chat.
Embedding source = local `e5-small-v2`. Baseline = last 30
closed-no-revert commits. Cadence = session-end batch. Enforcement
= passive log only.
