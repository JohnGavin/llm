# Skill: Codex Self-Learning Analyzer (Phase 1)

**Trigger:** Use when reviewing Codex session history for repeated patterns, user corrections, or tool failures that should become durable config changes.

## Summary

`codex_self_learning_analyzer.py` scans recent Codex JSONL sessions and emits a human-readable markdown report. It detects four signal types:

1. **User correction phrases** — `don't verb`, `stop X-ing`, `you forgot to`, etc.
2. **Repeated tool failures** — same tool + error class appearing ≥3 times across ≥2 sessions.
3. **Repeated tool-call N-grams** — 2- or 3-call sequences seen in ≥3 sessions.
4. **Long unproductive tail** — sessions with >50% read calls and no writes.

The script is read-only. It never writes to `~/.claude/rules/`, `~/.claude/memory/`, or GitHub.

## Running the analyzer

```bash
# Default: last 7 days, write report to ~/.claude/logs/codex_self_learning/YYYY-MM-DD.md
python3 ~/.claude/scripts/codex_self_learning_analyzer.py

# Custom date window
python3 ~/.claude/scripts/codex_self_learning_analyzer.py --since 2026-05-01 --until 2026-05-29

# Dry-run (print report to stdout, no file written)
python3 ~/.claude/scripts/codex_self_learning_analyzer.py --dry-run

# Custom sessions directory
python3 ~/.claude/scripts/codex_self_learning_analyzer.py --sessions-dir /path/to/sessions

# Tune thresholds
python3 ~/.claude/scripts/codex_self_learning_analyzer.py \
  --min-failures 2 --min-failure-sessions 2 --min-ngram-sessions 2
```

## Reviewing the report

The report lives at `~/.claude/logs/codex_self_learning/YYYY-MM-DD.md`. Each item includes:

- **Category** (user-correction / tool-failure / ngram-workflow / unproductive-tail)
- **Count** and **session count**
- **Verbatim examples** — redacted to strip obvious credentials (GitHub PATs, OpenAI keys, AWS keys, bearer tokens)
- **Suggested action** — one of: `memory`, `rule`, `skill`, `issue-only`, `ignore`

**The suggested action is advisory.** Nothing is auto-applied.

## Stage → human review → optional manual change

```
analyzer runs
    │
    ▼
report: ~/.claude/logs/codex_self_learning/YYYY-MM-DD.md
    │
    ▼
you read the report
    │
    ├─ correction pattern → add to ~/.claude/memory/*.md or .claude/rules/*.md manually
    ├─ repeated failure → open a GitHub issue (gh issue create)
    ├─ ngram workflow → add a skill or memory entry
    └─ unproductive tail → investigate the session; add setup guidance to memory
```

No step in this pipeline writes config automatically.

## Privacy redaction list

Patterns stripped from all verbatim excerpts before appearing in the report:

- GitHub PAT (`ghp_*`), GitHub OAuth (`gho_*`), GitHub Actions PAT (`github_pat_*`)
- OpenAI key (`sk-*`), Anthropic key (`sk-ant-*`)
- AWS access key (`AKIA*`)
- Generic `token=...` and `password=...` assignments
- Bearer tokens in Authorization headers

## Tests

```bash
python3 tests/python/test_codex_analyzer.py
```

Expected: `48/48 PASS`. Run after any change to the analyzer.

## Phase 2 / Phase 3 (out of scope now)

- **Phase 2**: scheduled overnight run via launchd + startup digest banner
- **Phase 3**: scoring/confidence layer; optional DuckDB normalization (see llm#231)

These are intentionally deferred. Phase 1 is read-only and on-demand.
