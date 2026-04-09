# /wiki-promote - Promote an Output into the Wiki

Convert a valuable `outputs/` answer into a proper `wiki/` page with
full frontmatter, `## Sources` section, and cross-links. This closes
the loop Karpathy identifies: query answers should compound into the
knowledge base, not disappear into chat history.

## When to Run

- After an output file contains synthesis worth preserving
- When a comparison or analysis you generated deserves a permanent home
- When a query answer references sources the wiki should track
- After an ad-hoc deep-dive that produced material for a new topic page

## What Makes an Output "Promotable"

| Criterion | Explanation |
|---|---|
| **Grounded in raw sources** | The output cites specific `raw/` files (not just reasoning) |
| **Non-obvious synthesis** | Answers a question the existing wiki doesn't cover |
| **Stable claim** | Won't need updating next week — factual or structural, not news |
| **Cross-cuts existing pages** | Brings together claims from multiple wiki pages |

Not everything in `outputs/` should be promoted. Ephemeral comparisons,
one-off briefings, or session-specific summaries stay in `outputs/`.

## Steps

1. **Identify the output file** to promote (e.g. `outputs/carry-vs-congestion-correlation-2026-04-09.md`)
2. **Determine the target wiki file**:
   - If it's a new topic: `wiki/<new-topic>.md`
   - If it expands an existing page: modify the existing `wiki/<existing>.md`
3. **Extract claims and sources**:
   - List every claim in the output
   - Map each claim to a raw/ file + line range (citing the same sources
     that were used to generate the output)
   - Mark AI-inferred claims with `> ⚠ AI-inferred:`
4. **Write frontmatter** with all required fields
5. **Write body** with inline citations and cross-links to existing wiki pages
6. **Add `## Sources`** section listing all raw/ files
7. **Update `INDEX.md`** with the new topic
8. **Append to `LOG.md`**:
   `## [YYYY-MM-DD] promote | outputs/<file> → wiki/<file>`
9. **Run `/wiki-health`** to validate
10. **Move or delete the original output file** — prefer delete; if keeping,
    add a line at the top of the output: `> Promoted to [[new-topic]] YYYY-MM-DD`

## Claude's Workflow

```
INPUT: outputs/<file>.md containing a query answer

1. Read the output file and identify its thesis
2. Decide: new wiki page OR expansion of existing page
3. For each factual claim in the output:
   a. Identify which raw/ file supports it
   b. Find the line range
   c. Write a citation in provenance format
4. For each AI-inferred synthesis:
   a. Tag with > ⚠ AI-inferred:
   b. Note which raw/ files were synthesised
5. Compose YAML frontmatter:
   - canonical_question = the question the output was answering
   - consensus_level = direct (single-source output) or strong/split/etc
   - fresh_until = 90 days out (default) or content-appropriate
6. Compose the wiki page body with inline citations
7. Append ## Sources section
8. Update INDEX.md entry
9. Append LOG.md entry
10. Run /wiki-health to verify
11. Delete the original output file (or mark it promoted)
```

## Example

Given `outputs/curve-carry-vs-congestion-correlation-2026-04-09.md`
containing an answer to "how correlated are curve carry and congestion
during backwardation regimes?":

1. Target: **expand existing `congestion.md`** with a new section
2. Extract the correlation claim → Gerald Rushton transcript lines 947-961
3. Add new section to `congestion.md`:
   ```markdown
   ## Correlation with curve carry in backwardation

   Gerald Rushton explicitly warns [...] (gerald-rushton.md:947-961)
   ```
4. Update frontmatter: bump `compiled_on` date; increment `fresh_until`
5. Append LOG.md: `## [2026-04-09] promote | outputs/curve-carry-vs-congestion-correlation-2026-04-09.md → wiki/congestion.md`
6. Delete the original output file

## Related

- Skill: `knowledge-base-wiki`
- Rules: `provenance-mandatory`, `wiki-frontmatter`, `confidence-markers`
- Command: `/wiki-health` (always run after promotion)
- Agent: `wiki-curator` (for complex multi-page promotions)
