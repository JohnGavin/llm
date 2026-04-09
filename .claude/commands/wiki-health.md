# /wiki-health - Validate Knowledge Base Wiki

Run the full health report on a knowledge-base wiki: structural checks
via shell script + AI-driven gap suggestions, drift verification, and
contradiction scan. Writes the report to `outputs/wiki-health-YYYY-MM-DD.md`.

## When to Run

- After compiling a batch of new wiki content (`wiki-curator` agent)
- Before commit (T2 pre-commit also runs a subset automatically)
- Weekly as a checkpoint (or via `/loop 7d /wiki-health`)
- When `> ⚠ AI-inferred:` markers exceed 30% of claims
- When any wiki file's `fresh_until` date approaches

## Structural Checks (shell script)

| # | Check | Severity |
|---|---|---|
| 1 | Provenance — `## Sources` section present | Error |
| 2 | Frontmatter — YAML frontmatter with required fields | Error |
| 3 | Staleness — `fresh_until` date vs today | Warning |
| 4 | Lifecycle — `status` value valid | Error |
| 5 | Orphan check — every raw/ file referenced by at least one wiki | Warning |
| 6 | Dead `[[wiki-link]]` — every link resolves | Warning |
| 7 | INDEX sync — `INDEX.md` lists every topic | Warning |
| 8 | LOG.md present | Info |

## AI-Driven Checks (Claude reads the wiki)

After the shell script runs, Claude performs these checks that require
reading the wiki content:

| # | Check | Output |
|---|---|---|
| A | **Source drift** — cited line ranges in raw/ still match wiki claims | Per-file report |
| B | **Contradictions** — wiki articles making conflicting claims | List with evidence |
| C | **Gap suggestions** — concepts mentioned but lacking their own page | List with proposed filenames |
| D | **Missing sources** — claims that would benefit from citing more raw/ files | Per-claim list |
| E | **Proposed new questions** — follow-ups the wiki doesn't yet answer | Ordered by value |

## Steps

1. **Identify the wiki directory** (default: `~/docs_gh/llm/knowledge/<domain>/wiki/`)
2. **Run structural check**: `~/.claude/scripts/wiki_health_check.sh <wiki_dir>`
3. **AI drift check**: for each wiki file with recent `compiled_on`, sample
   one cited line range from each source and verify the wiki summary still
   matches. Flag any discrepancies.
4. **AI contradiction scan**: cross-read the wiki for pairs of pages making
   conflicting claims. Contradictions across `> ⚠ AI-inferred:` markers
   are expected; contradictions across source-stated claims are errors.
5. **AI gap suggestions**: read `INDEX.md` and the full wiki; ask:
   - What concepts are mentioned across multiple pages but lack their own page?
   - What natural follow-up questions are the current pages begging?
   - What orphan `raw/` files have content that should be in a wiki page?
6. **Write report** to `<domain>/outputs/wiki-health-$(date +%Y-%m-%d).md`
7. **Append log entry** to `<domain>/wiki/LOG.md`:
   `## [YYYY-MM-DD] lint | /wiki-health`
8. **Report summary** inline:
   - `✅ Healthy` (0 errors, 0 warnings, no gaps)
   - `⚠ N warnings` (no errors)
   - `❌ N errors, M warnings` (must fix)

## Commands to Execute

```bash
WIKI_DIR="${1:-./wiki}"
~/.claude/scripts/wiki_health_check.sh "$WIKI_DIR"
# AI-driven checks follow in the Claude response
```

## Output Format

Save to `<domain>/outputs/wiki-health-$(date +%Y-%m-%d).md`:

```markdown
# Wiki Health Report — YYYY-MM-DD

## Summary
- Files: N
- Errors: 0
- Warnings: 0
- Stale pages: 0
- Confidence: 78% source-stated, 18% AI-inferred, 4% other
- Consensus breakdown: strong 12, split 2, direct 3

## Structural Checks
[shell script output]

## AI Drift Check
[per-file verification results]

## Contradictions
[cross-page conflict list with citations]

## Gap Suggestions
[new pages proposed + rationale]

## Recommendations
[fix list, prioritised]
```

## Related

- Skill: `knowledge-base-wiki`
- Rules: `provenance-mandatory`, `wiki-frontmatter`, `confidence-markers`
- Agents: `wiki-curator`, `critic` (wiki validation mode)
- Command: `/wiki-promote` (promote outputs/ to wiki/)
- Hook: `wiki_health_onwrite.sh` (T1)
