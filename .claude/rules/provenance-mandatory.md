---
paths: ["**/wiki/**"]
---

# Rule: Provenance Mandatory in wiki/

## When This Applies
Any markdown file inside a `wiki/` directory in a knowledge base project.

## CRITICAL: Every Wiki File MUST Cite Its Sources

Every non-trivial claim in a `wiki/*.md` file must trace back to a file in `raw/`.
This makes the wiki **auditable** and prevents AI hallucinations from becoming "facts".

## Required Format

### 1. Inline citation (preferred for short claims)

```markdown
The strategy works because hedgers are price-insensitive
([transcript.md:450](raw/flirting-with-models-faheem-osman.md#L450)).
```

### 2. Block quote (for verbatim statements)

```markdown
> "producers and consumers have to continue to hedge in the same way"
> — [transcript.md:797-803](raw/flirting-with-models-faheem-osman.md)
```

### 3. Footnote (for dense passages)

```markdown
Curve carry captures the difference in roll yield between front and back
of the futures curve.[^1]

[^1]: raw/flirting-with-models-faheem-osman.md, lines 715-795
```

## Mandatory `## Sources` Section

Every `wiki/*.md` file MUST end with:

```markdown
## Sources

- [flirting-with-models-faheem-osman.md](../raw/flirting-with-models-faheem-osman.md) — lines 715-795 (curve carry mechanism)
- [top-traders-unplugged-osman.md](../raw/top-traders-unplugged-osman.md) — lines 120-180 (sustainability argument)
```

## AI-Inferred Claims

If a claim synthesises across sources or has no direct source statement,
mark it with the `confidence-markers` rule:

```markdown
> ⚠ AI-inferred: Both Faheem and Gerald emphasise the same point about
> hedger price-insensitivity, suggesting this is the consensus view at Macquarie QIS.
```

## Cross-Wiki Links

Use double-bracket syntax for links between wiki files:

```markdown
See also [[congestion]] and [[commodity-vol-carry]] for related strategies.
```

## Forbidden Patterns

| Wrong | Right |
|---|---|
| Quoting text without a source line range | Always include `file.md#L<line>` or `lines N-M` |
| Making claims with no `## Sources` section | Every wiki file ends with `## Sources` |
| Fabricated quotes (text not in any raw file) | Verify with `critic` agent before commit |
| Mixing AI inference with source claims unmarked | Tag inference with `> ⚠ AI-inferred:` |

## Enforcement

- T1 (on-write): `wiki_health_onwrite.sh` hook checks for `## Sources` section
- T2 (pre-commit): full provenance + line-range validation
- T3 (`/wiki-health`): all 7 checks including drift detection
- `critic` agent in wiki validation mode verifies cited content exists in raw

## Why

Spisak's post identifies this as a critical gap: without provenance, the wiki
becomes indistinguishable from AI hallucination. Provenance is the difference
between a knowledge base and a confabulation engine.

## Related Rules

- `raw-folder-readonly` — protects the source-of-truth
- `confidence-markers` — tags AI-inferred content
- `wiki-storage-policy` — central hub vs per-project decisions
