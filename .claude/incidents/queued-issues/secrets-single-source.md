# [P0] Credential sprawl: make `~/.config/secrets.env` the single source of truth

**Labels:** security, config, P0
**Origin:** fallout from the 2026-08-11 credential leak — see
`.claude/incidents/2026-08-11-credential-leak.md`.

## Problem

Credentials are defined in multiple, disagreeing places. Rotation therefore
partially applies and fails silently: you change the copy you know about, the
consumer reads a different one, and the symptom appears later somewhere
unrelated.

### Evidence at the time of filing (2026-08-13)

Measured with `secret_map.sh` — variable names and file:line only, never values.

| Credential | Locations |
|---|---|
| `GMAIL_APP_PASSWORD` | `secrets.env`, `~/.claude/env/overnight_self_review.env`, `~/.claude/env/kb_digest.env`, `~/.claude/env/roborev_email.env`, Bitwarden Secrets Manager, `~/.zshenv` plaintext comment — **6** |
| `GH_TOKEN` | `secrets.env`, `~/.zshrc`, `~/.config/positron/nix_env.sh` — **3** |
| `CACHIX_AUTH_TOKEN` | `secrets.env`, `~/.zshrc`, `~/.config/positron/nix_env.sh` — **3** |
| HuggingFace token | `HF_TOKEN` + `HUGGING_FACE_HUB_TOKEN` + `HUGGINGFACE_API_TOKEN`, each in 2 files — **6 entries, 1 secret** |
| `openai_secret_key` | `~/.zshenv` — a *fourth* OpenAI-ish name, outside `secrets.env` |
| `DOCKER_PSWD` | `~/.zshenv` — outside `secrets.env` |

Three concrete failures this caused:

1. **Wrong file wins.** `~/.zshenv:2` sources `secrets.env`; `~/.zshrc` then
   re-exports `GH_TOKEN` and `CACHIX_AUTH_TOKEN`. `.zshrc` loads later, so it
   **overrides**. Editing `secrets.env` appeared to do nothing.
2. **Corruption.** `secrets.env` had no trailing newline, so an appending
   migration concatenated two assignments onto one line — `GMAIL_APP_PASSWORD`
   ended up holding the password *plus* the literal text `FRED_API_KEY=…`.
3. **Plaintext in comments.** The migration commented out the originals rather
   than deleting them, leaving three live values readable in `~/.zshenv`.

## Progress so far

- [x] Repair the concatenated line; add trailing newline
- [x] Remove duplicate `GH_TOKEN` / `CACHIX_AUTH_TOKEN` from `~/.zshrc`
- [x] Move `openai_secret_key`, `DOCKER_PSWD`, `CODEX_SANDBOX` into `secrets.env`
- [x] Delete the 3 plaintext values from `~/.zshenv` comments
      (`strip_plaintext.sh --apply`, backup `~/.zshenv.bak-*_strip-plaintext`)

## Remaining

### 1. Collapse the three `~/.claude/env/*.env` files — BLOCKED, do at rotation

The three files are **byte-identical** (sha `0a880782c00ab677`), each holding
`GMAIL_USERNAME`, `GMAIL_APP_PASSWORD`, `REPORT_RECIPIENT`,
`ROBOREV_DASHBOARD_URL`. Six cron wrappers read them:
`overnight_self_review_email_cron.sh`, `kb_digest_daily_cron.sh`,
`roborev_daily_cron.sh`, `roborev_weekly_rollup_cron.sh`,
`config_digest_cron.sh`, `stage1_findings_daily_cron.sh`.

**Do not collapse yet.** `GMAIL_APP_PASSWORD` **differs** between stores:

| Store | length | note |
|---|---|---|
| `secrets.env` | 21 | quoted, spaces retained |
| `~/.claude/env/*.env` | 16 | canonical Gmail app-password form |

Collapsing today would switch all six jobs onto a different value and could
break SMTP auth. Since the password must be rotated anyway (it was in the
leak), sequence it as:

1. Rotate the Gmail app password
2. Write the new **16-character, unquoted, unspaced** value into `secrets.env` only
3. Add `GMAIL_USERNAME`, `REPORT_RECIPIENT`, `ROBOREV_DASHBOARD_URL` to `secrets.env` (currently absent)
4. Replace each of the three files with a single `. "$HOME/.config/secrets.env"` line — no change to the six wrappers, fully reversible
5. Dry-run one job: `EMAIL_DRY_RUN=1 bash bin/overnight_self_review_email_cron.sh`
6. Once green, delete the three files and drop the fallback branch from the wrappers

### 2. `~/.config/positron/nix_env.sh`

A full environment snapshot written to disk, containing live values for
`CACHIX_AUTH_TOKEN`, `ELEVENLABS_API_KEY`, `GEMINI_API_KEY`, `GH_TOKEN`,
`GITHUB_PAT`, `GOOGLE_API_KEY`, `GUARDIAN_API`, `HF_TOKEN`,
`HUGGINGFACE_API_TOKEN`, `HUGGING_FACE_HUB_TOKEN`, `OPENAI_API_KEY`.

Find what writes it. A tool that snapshots the environment to a file
re-creates the sprawl after every consolidation, so this is the highest-value
remaining item.

### 3. Bitwarden Secrets Manager

Decide: either BWS is the single source and `secrets.env` is generated from
it, or BWS is retired. Two "single sources" is not a single source.

### 4. Collapse the three HuggingFace names to `HF_TOKEN`

Whichever name a script happens to read decides whether it works.

### 5. Backup files

`~/.zshenv.bak-*` and `~/.config/secrets.env.bak-*` contain old live values.
Delete once rotation is complete.

## Acceptance

A check script, run in CI or session-init, asserting:

- every credential-shaped name is defined in **exactly one** file
- `secrets.env` has one assignment per line and a trailing newline
- no file outside `secrets.env` assigns a credential-shaped name
- no plaintext credential appears in a comment anywhere

This is the deterministic control. The sprawl is not fixed until something
other than a human is checking for it — the same conclusion as the incident
that produced this issue.
