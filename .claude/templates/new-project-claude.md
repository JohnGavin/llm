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
