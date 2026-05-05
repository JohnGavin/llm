---
name: prod-staging-context-guard
description: Projects declare their environment (research/dev/prod/mixed) in .claude/CLAUDE.md so agents have a signal to calibrate destructive-op messaging and surface prod context at session start
type: rule
---

# Rule: Production / Staging Context Guard

## Source

PocketOS / Cursor / Railway incident 2026-04-25
([thread](https://x.com/lifeof_jer/status/2048103471019434248)):
the agent "guessed" that the target was staging-isolated. It was not.
Without an explicit environment declaration the agent had no signal to
refuse or escalate. The fix is a per-project declaration that propagates
through session start and the destructive-API hook.

## The Convention

Every project's `.claude/CLAUDE.md` SHOULD declare an `Environment:` field:

```markdown
| Field       | Value   |
|-------------|---------|
| Environment | prod    |
```

or in plain form:

```
Environment: prod
```

### Valid values

| Value      | Meaning |
|------------|---------|
| `research` | Exploratory / data-science project; no live users depend on it |
| `dev`      | Tooling, config, CLIs, or package development (not user-facing) |
| `prod`     | Live service, published website, or data pipeline whose outputs are consumed by users |
| `mixed`    | Contains both prod and non-prod surfaces (e.g. a package with a public pkgdown site AND an internal API) |

### Default if unspecified

`research` — lowest friction; the destructive-API hook still blocks, but
without the extra prod warning text.

### Production endpoints (optional, recommended for `prod`)

```markdown
Production endpoints:
- https://johngavin.github.io/   # live user site
- https://telemetry.example.com/ # data dashboard
```

Listing endpoints makes it obvious to an agent what "prod" means and which
URLs would be affected by a destructive op.

## How session_init surfaces the environment (Phase 1c)

`session_init.sh` Phase 1c reads `$PWD/.claude/CLAUDE.md` for an
`Environment:` line. It reports:

- `Environment: <value>` for any declared value
- `Environment: unspecified (defaulting to research)` if not found
- For `prod`: an additional WARN marker so it surfaces in the warnings block

The value is also appended to the compact summary line as `env-class:<value>`.

## How the destructive-API hook uses the environment

`destructive_api_guard.sh` reads the project's `Environment:` value when
it blocks a command. The block message always includes
`(environment: <value>)`. For `prod`, an extra line is added:

```
⚠ This is a PROD-tagged project. Verify the target carefully.
  To run this manually, exit Claude Code and run from a regular shell.
```

This is **informational escalation only** — the block fires in all
environments. v1 has no behavioural override. See follow-up below.

## Project audit table

| Project | Recommended | Rationale |
|---------|-------------|-----------|
| `JohnGavin.github.io` | `prod` | Live user-facing website; any deletion affects public visitors |
| `llmtelemetry` | `prod` | Publishes a data dashboard consumed externally |
| `llm` | `dev` | Claude Code tooling, hooks, config — no live user surface |
| `rix.setup` | `dev` | Nix shell config and generation scripts |
| `randomwalk` | `research` | Simulation research package |
| `irishbuoys` | `research` | Ocean data analysis |
| `mycare` | `research` | Personal health data analysis (local only) |
| `footbet` | `research` | Sports analytics research |
| `urban_planning` | `research` | Urban analysis vignettes |
| `acd_area_climate_design` | `research` | Climate/area design research |
| `proj` | `research` | Project-level data and scripts |

## Forbidden Patterns

| Pattern | Why wrong |
|---------|-----------|
| No `Environment:` in a project that has a live URL or publishes data | Agent cannot distinguish prod from scratch |
| `Environment: prod` without listing at least one endpoint | Makes it impossible to verify what "prod" means |
| Declaring `research` for a project used by external users | Understates risk; hook messaging will be too soft |

## Follow-up (not in v1)

- Behavioural override mechanism: an env var or flag that allows legitimate
  prod destructive ops (e.g. `ALLOW_PROD_DESTRUCTIVE=APPROVED-<target>`).
  Tracked in issue #104 closing comment.
- Per-project adoption: edit `.claude/CLAUDE.md` for each project per the
  audit table — separate task because most repos are clean.

## Related

- `permission-mode-discipline` — binds `--permission-mode` to workspace type
- `destructive-api-calls` — hook-level blocking; this rule adds env-aware messaging
- `two-key-irreversible-ops` — human confirmation layer; env class informs the confirmation class (Class A for prod, Class B for dev)
