# /wiki-health - Validate Knowledge Base Wiki

Run the full 7-check health report on a knowledge-base wiki and write
the report to `outputs/wiki-health-YYYY-MM-DD.md`.

## When to Run

- After compiling a batch of new wiki content (`wiki-curator` agent)
- Before commit (T2 pre-commit also runs a subset automatically)
- Weekly as a checkpoint (or via `/loop 7d /wiki-health`)
- When `> ⚠ AI-inferred:` markers exceed 30% of claims

## What It Checks

| # | Check | Severity if fails |
|---|---|---|
| 1 | Provenance — every wiki file has `## Sources` section | Error |
| 2 | Source drift — cited line ranges still match raw content | Warning |
| 3 | Orphan check — every raw/ file referenced by at least one wiki/ | Warning |
| 4 | Dead `[[wiki-link]]` — every link resolves to a wiki/*.md | Warning |
| 5 | Confidence ratio — % source-stated vs AI-inferred | Info |
| 6 | Contradiction scan — wiki articles making conflicting claims | Warning |
| 7 | INDEX sync — `wiki/INDEX.md` lists every topic | Warning |

## Steps

1. Identify the wiki directory (default: `~/docs_gh/llm/knowledge/<domain>/wiki/`)
2. Run `~/.claude/scripts/wiki_health_check.sh <wiki_dir>`
3. For checks 2 and 6 (drift + contradictions), use AI to:
   - Read each cited line range from `raw/` and verify wiki summary still matches
   - Cross-read wiki files for contradictory statements
4. Write report to `<domain>/outputs/wiki-health-$(date +%Y-%m-%d).md`
5. Report summary inline:
   - `✅ Healthy` (0 errors, 0 warnings)
   - `⚠ N warnings` (no errors)
   - `❌ N errors, M warnings` (must fix)

## Commands to Execute

```bash
# Identify wiki dir from arguments or default to current project
WIKI_DIR="${1:-./wiki}"

# Run shared script (T3 mode)
~/.claude/scripts/wiki_health_check.sh "$WIKI_DIR"

# AI-driven checks (drift + contradictions) — invoke critic agent
# (handled by Claude after the shell script)
```

## Output Format

Save to `<domain>/outputs/wiki-health-$(date +%Y-%m-%d).md`:

```markdown
# Wiki Health Report — YYYY-MM-DD

## Summary
- Files: N
- Errors: 0
- Warnings: 0
- Confidence ratio: 78% source-stated, 18% AI-inferred, 4% other

## Check Results
[per-check details]

## Recommendations
[fix list, prioritised]
```

## Related

- Skill: `knowledge-base-wiki`
- Rules: `provenance-mandatory`, `confidence-markers`, `raw-folder-readonly`
- Agents: `wiki-curator`, `critic` (wiki validation mode)
- Hook: `wiki_health_onwrite.sh` (T1 — fires on every Edit/Write)
