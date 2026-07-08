---
name: feedback_knowledge-base-discipline
description: Lessons from Karpathy/Spisak "second brain" — the four gaps and our discipline to address them
type: feedback
---

The Karpathy/Spisak "second brain" pattern (raw/ + wiki/ + outputs/, AI compiles wiki, schema file)
is good but has 4 critical gaps the post itself glosses over:

1. **Provenance** — which raw file does each wiki claim come from? Spisak's pattern doesn't enforce citation, so wiki articles become indistinguishable from AI hallucination.
2. **Versioning** — git is mentioned but no awareness of raw/ vs wiki/ asymmetry. raw/ should be append-only.
3. **Validation** — "monthly health check" is too lax; errors compound between checks.
4. **Confidence tracking** — no distinction between source-stated claims and AI synthesis.

**HFloyd's reply to Karpathy is the most important caveat in the whole thread:**
> "When outputs get filed back, errors compound too."

This is the single biggest risk. Without provenance tracking, AI-generated wiki content becomes
"facts" that the next compilation cycle treats as ground truth. The fix is structural, not procedural.

**Why:** The "knowledge base" pattern is high-leverage but brittle. Without provenance, validation,
and confidence markers, it degrades into a confabulation engine over time. Spisak's monthly health
check catches errors after they've already propagated; T1 (on-write) catches them at the source.

**How to apply:**
- Use `knowledge-base-wiki` skill for the canonical pattern
- Use central hub at `~/docs_gh/llm/knowledge/` for cross-project knowledge (LOCAL git only, no GitHub)
- Use per-project `wiki/` for project-specific content
- Mandatory `## Sources` section in every wiki file (`provenance-mandatory` rule)
- raw/ folders are append-only (`raw-folder-readonly` rule + `file_protection.sh` hook)
- AI-inferred claims tagged with `> ⚠ AI-inferred:` (`confidence-markers` rule)
- Cross-wiki links use `[[topic]]` syntax (Obsidian-compatible, tool-agnostic)
- Multi-tier health check: T1 on-write hook, T2 pre-commit, T3 `wiki_health_check.sh` (manual full report), T4 weekly cron
- `wiki-curator` agent compiles raw → wiki with mandatory provenance
- `critic` agent in wiki validation mode does adversarial review (verifies cited content exists in raw)

**Decision rule for "central hub vs per-project":**
- Cross-project concepts → central hub (`~/docs_gh/llm/knowledge/<domain>/`)
- Project-specific → per-project (`<project>/wiki/`)
- Confidential / PHI → per-project with `.gitignore` + PHI scan

**Privacy:** Central hub is local git only, NEVER pushed to GitHub. `PRIVATE` marker file + pre-push
hook block any push attempt. Backup via Time Machine, rsync, or local NAS — never public hosting.

**What we explicitly rejected:**
- `agent-browser` CLI — unverified token-savings claims
- Obsidian plugins — locks into a tool; flat markdown + git is more durable
- Knowledge graph visualisation — out of scope; `[[wiki-link]]` is enough
- BibTeX/CSL citation library — over-engineering for transcript wikis

**The QIS strategies wiki at `~/docs_gh/llm/knowledge/qis-strategies/` is the first real-world
validation of this infrastructure.**
