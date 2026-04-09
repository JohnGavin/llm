# Rule: Confidence Markers in wiki/

## When This Applies
Any markdown file inside a `wiki/` directory in a knowledge base project.

## CRITICAL: Distinguish Source-Stated From AI-Inferred

Wiki readers must be able to tell at a glance which claims are grounded in
sources and which are AI synthesis. Without this distinction, AI hallucinations
become indistinguishable from facts.

## Markers

| Marker | Meaning | When to use |
|---|---|---|
| (no marker) | Direct quote or close paraphrase from a cited source | Default — most claims should be source-stated |
| `> ⚠ AI-inferred:` | Synthesised across multiple sources, no single source statement | Bridging or summarising claims |
| `> 🔬 Hypothesis:` | Speculative, not in any source | When the AI is reasoning beyond the data |
| `> ❓ Conflicting:` | Sources disagree | Flag both sides with citations |

## Page-level consensus (frontmatter)

In addition to inline markers, every wiki page declares a page-level
`consensus_level` in its YAML frontmatter. This summarises agreement
**across cited sources**, not across AI models:

| `consensus_level` | Definition | When to use |
|---|---|---|
| `unanimous` | All cited sources state the same thing with no disagreement | Rare; genuine unanimity across independent sources |
| `strong` | Sources agree on core claims; differ on emphasis or edge cases | Most well-sourced pages |
| `split` | Sources agree on some claims, diverge substantively on others | Use alongside `> ❓ Conflicting:` markers in body |
| `divergent` | Sources reach fundamentally different conclusions | Valuable — surfaces unsettled questions |
| `direct` | Single source, summary page, or comparison file | No cross-source consensus to measure |

The frontmatter `consensus_level` and the inline markers complement each
other: `consensus_level: split` at the page level should be visible as
`> ❓ Conflicting:` blocks in the body text.

## Examples

### Source-stated (no marker needed)

```markdown
Curve carry captures the roll yield differential between front and back of
the futures curve ([transcript.md:715-720](raw/transcript.md#L715)).
```

### AI-inferred (synthesis across sources)

```markdown
> ⚠ AI-inferred: Both Faheem Osman (Macquarie) and Gerald Rushton emphasise
> hedger price-insensitivity as the structural reason curve carry persists,
> suggesting this is the consensus view at Macquarie QIS rather than one
> person's framing.
```

### Hypothesis (speculative)

```markdown
> 🔬 Hypothesis: The shift to weekly options in commodities may eventually
> follow the equity market's path to zero-DTE, though no source explicitly
> predicts this timeline.
```

### Conflicting

```markdown
> ❓ Conflicting: Source A claims the strategy has had no negative years
> ([transcript.md:707](raw/A.md#L707)), while Source B reports a 12% drawdown
> in 2022 ([report.md:45](raw/B.md#L45)). The discrepancy may reflect
> different implementations or measurement periods.
```

## Health Metric

`/wiki-health` reports the **confidence ratio**:

- Source-stated claims: %
- AI-inferred (`⚠`): %
- Hypothesis (`🔬`): %
- Conflicting (`❓`): %

Healthy wikis: >70% source-stated, <20% AI-inferred, <5% each of hypothesis/conflicting.

If AI-inferred exceeds 30%, the wiki is becoming a confabulation — the AI is
filling gaps with synthesis instead of grounding in sources.

## Enforcement

- T1 hook: counts marker ratio per file on write
- T3 `/wiki-health`: full ratio report
- `critic` agent: flags claims that LOOK like inference but lack the marker

## Why

Spisak's post mentions error compounding but offers no mechanism to detect it.
Confidence markers make the inference layer explicit and auditable.

## Related Rules

- `provenance-mandatory` — citation requirements
- `raw-folder-readonly` — source protection
