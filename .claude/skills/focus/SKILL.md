---
name: focus
description: >
  A rigorous, detail-preserving summarization method for academic papers, reports, and long-form documents.
  Based on the FOCUS workflow (Lin, 2025, Nature Biotechnology). Extracts every key point with specific
  details and embedded direct quotes, organized section by section, then produces a clean final output
  with an overview/takeaway. Trigger this skill whenever the user types "/focus", says "summarize with focus",
  "FOCUS summary", "use the focus method", or asks for a thorough/exhaustive/detailed summary of a paper
  or document that should capture every key insight. Also trigger when the user wants a summary that
  preserves direct quotes and specific details (e.g., numbers, effect sizes, comparisons) rather than
  a high-level gloss.
---

# FOCUS Summarization Skill

This skill implements a two-step summarization method adapted from the FOCUS workflow
(Lin, 2025, *Nature Biotechnology*). The goal is exhaustive, detail-rich summarization
that preserves the specificity and language of the original source while remaining
well-organized and readable.

## When to use

- The user invokes `/focus` or asks for a "FOCUS summary"
- The user wants every key point extracted from a paper or document, not just the highlights
- The user wants direct quotes embedded naturally alongside summarized points
- The user needs section-by-section coverage of an academic paper or structured document

## Core principles

1. **Exhaustiveness over brevity.** Do not skip key points to save space. If a document has 30 distinct insights, list all 30.
2. **Specificity is mandatory.** Every point must include concrete details: numbers, effect sizes, sample sizes, method names, comparisons, dates. Vague paraphrases are failures.
3. **Quotes support, not duplicate.** Embed direct quotes to convey points more precisely than paraphrase alone. Do not quote something and then restate the same idea in your own words next to it.
4. **No meta-discourse.** Never write "In this section, the authors argue..." or "Below is a summary..." or "End of summary." Attribution to "the authors" or "the paper" is assumed and should be omitted.
5. **Section structure mirrors the source.** If the document has sections, organize the summary by those sections using the original section titles. Skip References, Author Information, Acknowledgments, and similar boilerplate.

## Two-step process

### Step 1: Exhaustive extraction

Read the document carefully. For each section, extract every key point or insight as a numbered list item with the following structure:

**Format for each item:**

```
N. **Heading in sentence case**
Body paragraph with specific details and naturally embedded direct quotes in *italics* within double quotation marks.
```

Rules for Step 1:

- Start each item with an Arabic numeral, period, space, then a bold heading.
- The body paragraph follows on the next line (no indentation).
- Use **bold** within the body to emphasize key terms, concepts, or phrases.
- Enclose direct quotes in double quotation marks and italicize them: *"like this"*.
- Combine redundant points rather than listing near-duplicates separately.
- Proceed section by section. Each section gets its own bold section title header before the numbered items in that section.
- Numbering restarts at 1 for each section (or continues sequentially across sections, either is fine, just be consistent).

**Example of correct style:**

> Table 1 compares six methods (no software, point-and-click, modify code chunks, Excel, teach coding and Copilot) and emphasizes that *"Copilot... is the only approach that is favorable across all [the] characteristics"*...

**Example of incorrect style (do not do this):**

> In Table 1 the authors compare six methods and emphasize that the Copilot method is the only one that is favorable across all five characteristics. They note that *"Copilot... is the only approach that is favorable across all [the] characteristics"*...

The incorrect version restates the quote's content before the quote, and inserts unnecessary attribution ("the authors," "They note that"). The correct version lets the quote carry the point directly.

### Step 2: Clean and organize

Take the Step 1 output and apply these transformations:

1. **Remove all citation markers and reference links.** Strip superscript numbers, bracketed references like [1], inline citations like (Smith et al., 2023), URLs, and DOI links.
2. **Add an overview/takeaway** at the top. This should be a concise paragraph (3-6 sentences) capturing the document's main contribution, key findings, and significance. No bullet points in the overview.
3. **Organize into logical sections** for easier reading. If the source's own section structure works well, keep it. If the extracted points would benefit from regrouping (e.g., a document without clear sections), organize them thematically. Do not remove any items from the list during reorganization.

**Only output the Step 2 result.** Do not show the Step 1 intermediate output. Do not include any preamble or closing meta-commentary.

## Handling edge cases

- **Documents without clear sections:** Organize thematically and create your own section headings that reflect the content's structure.
- **Very short documents (< 2 pages):** Still apply the full method, but the output will naturally be shorter. Do not pad.
- **Foreign-language documents:** Summarize in the language the user is writing in (default English), translating quotes as needed with the original language in parentheses if the user might want it.
- **Multiple documents:** If the user provides several documents, summarize each separately under its own heading unless the user explicitly asks for a combined synthesis.
- **Books or very long documents:** Proceed chapter by chapter or major section by major section. Maintain the same rigor throughout; do not get less detailed as the document goes on.