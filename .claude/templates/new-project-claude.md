# {{package-name}} — Project Config

Global config: `~/.claude/CLAUDE.md` (loaded first, all rules apply unless overridden here).

## Project Identity

| Field | Value |
|-------|-------|
| Package name | `{{package-name}}` |
| Primary domain | {{domain description}} |
| Stage | {{Active development / Maintenance / Archive}} |
| Nix shell | `/Users/johngavin/docs_gh/{{package-name}}/default.nix` |
| R version | 4.5.x (from `default.nix`) |

## Active Skills (prioritized for this project)

- {{skill-1}} — {{why relevant}}
- {{skill-2}} — {{why relevant}}

## Project-Specific Rules

### Quality Gate Threshold
Minimum score: 80 (production)

### Disabled Global Rules
- {{rule-name}}: {{reason not applicable}}

## Session Conventions
- CHANGELOG.md append at session end is mandatory (global rule)
- `.claude/CURRENT_WORK.md` is session-ephemeral (gitignored)

## roborev Configuration

<!-- Delete this section if roborev not used -->

| Status | Value |
|--------|-------|
| Hook enabled | Yes / No |
| Config file | `.roborev.toml` exists / missing |

If roborev hook is enabled:
- Ensure `.roborev.toml` exists (run `/roborev-setup`)
- Fix high-severity findings when touching affected files
- Run `roborev refine --min-severity high --max-iterations 3` at session end
- Use `/roborev-clear-backlog` for one-time backlog burn-down

## Knowledge Base

<!-- Choose ONE approach based on project complexity -->

| Project complexity | Approach |
|-------------------|----------|
| Simple (< 10 files, single concern) | CHANGELOG.md only |
| Medium (10-50 files, 2-3 concerns) | FINDINGS.md log |
| Complex (50+ files, multiple domains) | Full knowledge/ structure |

**This project uses:** {{CHANGELOG only / FINDINGS.md / full knowledge/}}

<!-- If using FINDINGS.md, create from llm/.claude/templates/FINDINGS.md -->
<!-- If using full knowledge/, create: mkdir -p knowledge/{raw,wiki} -->

## Mandatory Quarto post-render wiring (if `_quarto.yml` exists)

Every Quarto project MUST wire the GLOBAL dark-mode contrast audit into
`_quarto.yml`. The script is NEVER copied into the project. Single source
of truth: `https://github.com/JohnGavin/llm/blob/main/.claude/scripts/`.

```yaml
project:
  type: website
  output-dir: docs
  post-render:
    - <existing post-render scripts, if any>
    - /Users/johngavin/docs_gh/llm/.claude/scripts/quarto_post_render_contrast.sh
```

Verification: `quarto render` must show `=== Dark-mode contrast audit (post-render) ===`
followed by `PASS:` for every rendered HTML. See `dark-mode-completeness` rule.
