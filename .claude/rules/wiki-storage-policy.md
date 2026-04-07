# Rule: Wiki Storage Policy

## When This Applies
Any time a new knowledge base, wiki, or transcript collection is created.

## Decision: Central Hub vs Per-Project

| Knowledge type | Goes to |
|---|---|
| Cross-project concepts (QIS strategies, R patterns, statistical methods, financial theory) | **Central hub** at `~/docs_gh/llm/knowledge/<domain>/` |
| Project-specific decisions (this app's auth flow, this pipeline's quirks) | **Per-project** `<project>/wiki/` |
| Personal cross-cutting notes | **Central hub** under `personal/` |
| Confidential client data, PHI | **Per-project** with `.gitignore` and PHI scan hook |

## Central Hub Location

`~/docs_gh/llm/knowledge/`

### Structure

```
~/docs_gh/llm/knowledge/
├── .git/                  ← LOCAL git only, NO GitHub remote
├── .git/hooks/pre-push    ← blocks all push attempts
├── PRIVATE                ← marker file (presence = pre-push blocks)
├── CLAUDE.md              ← hub schema
├── INDEX.md               ← cross-domain index
├── <domain>/
│   ├── raw/               ← APPEND-ONLY
│   ├── wiki/              ← AI-maintained
│   ├── outputs/           ← ephemeral
│   └── CLAUDE.md          ← optional domain schema
```

## Privacy Policy: NEVER Push to GitHub

The central hub is **local-only**. Reasons:

- `raw/` may contain copyrighted transcripts, articles, books
- `raw/` may contain PHI or confidential client data
- `wiki/` may contain proprietary analysis derived from non-public sources
- The cost of an accidental public push is asymmetric — recovery is impossible

### Enforcement layers

| Layer | Mechanism |
|---|---|
| 1 | `PRIVATE` marker file in hub root |
| 2 | `.git/hooks/pre-push` checks for `PRIVATE` and blocks |
| 3 | `.gitignore` patterns for `*.pdf`, `PRIVATE_*`, etc. |
| 4 | No `git remote` configured by default |

### Backup (NOT GitHub)

- Time Machine (macOS)
- `rsync` to local NAS
- Encrypted backup (`borg`, `restic`) to external drive
- Private git server (Gitea, local) — never public hosting

## Adding a New Domain

```bash
cd ~/docs_gh/llm/knowledge
mkdir -p <domain>/{raw,wiki,outputs}
echo "# <Domain> Schema" > <domain>/CLAUDE.md
# Update INDEX.md with the new domain row
git add <domain>
git commit -m "Add <domain> to knowledge hub"
```

## When to Promote Per-Project → Central

If a project's wiki contains content that other projects could reuse, promote it:

1. Copy the relevant `wiki/*.md` files to `~/docs_gh/llm/knowledge/<domain>/wiki/`
2. Copy the corresponding `raw/*.md` files to `~/docs_gh/llm/knowledge/<domain>/raw/`
3. Update provenance citations to point to the new locations
4. Run `/wiki-health` on both locations

## Related Rules

- `raw-folder-readonly` — append-only enforcement
- `provenance-mandatory` — citation format
- `confidence-markers` — AI-inferred tagging
- `safe-deletion` — confirmation for >1MB deletes

## Related Skills

- `knowledge-base-wiki` — full pattern documentation
