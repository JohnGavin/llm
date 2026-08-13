---
description: Bitwarden Secrets Manager (BWS) is the single system of record for credentials; ~/.config/secrets.env is a derived, regenerable cache — never hand-edited, never the target of a rotation
paths:
  - "**/secrets.env"
  - "**/.zshenv"
  - "**/.zshrc"
  - ".claude/scripts/**"
  - "bin/**"
  - "**/*.plist"
---

# Rule: Secrets Single Source of Truth (BWS)

## Architecture

- **Bitwarden Secrets Manager (BWS) is the system of record.** All
  credentials live there. Rotation happens there, and only there.
- **`~/.config/secrets.env` is a derived, regenerable cache.** It is
  generated FROM BWS by `secrets_cache_regen.sh`, carries `chmod 600`,
  and starts with a `GENERATED — DO NOT EDIT` header. It exists so
  interactive shells and scripts that source it get secrets without a
  network round-trip and keep working offline.
- launchd jobs call `bws run -- <cmd>` (or read from BWS directly). They
  do not depend on the cache file.
- The cache being plaintext is safe: it is not the source of truth, it is
  fully regenerable from BWS at any time, and it carries the same
  `chmod 600` trust boundary the existing `with-secrets` design already
  relies on (see Related).

## CRITICAL: Rotate in BWS Only

Never hand-edit `~/.config/secrets.env` to rotate a credential. A hand
edit is invisible to BWS, gets silently overwritten by the next
`secrets_cache_regen.sh` run, and — worse — if `secrets_to_bws.sh` is ever
re-run against a version-drifted `secrets.env`, a hand-edited (and
possibly mistyped) value could be mistaken for the real one during
review. Rotate the value in BWS, then run
`secrets_cache_regen.sh --apply` to refresh the cache.

## CRITICAL: Never Let secrets.env Overwrite BWS

`secrets_to_bws.sh` — the one-time migration script that seeds BWS from
the legacy `secrets.env` — treats BWS as authoritative for any name that
already exists there. **It never overwrites an existing BWS secret**,
even when `secrets.env` disagrees. A name present in both is always
reported as a conflict (with a truncated sha256 comparison of each side,
so a human can see at a glance whether the two already agree) and left
untouched either way.

### The incident that motivates this

`secrets.env` held `GMAIL_APP_PASSWORD` as a 21-character value — quotes
and spaces baked in by a bad prior migration. BWS already held the
correct 16-character app password. Six cron email jobs depend on the BWS
value. Had `secrets_to_bws.sh` "helpfully" pushed the `secrets.env` value
into BWS to keep them in sync, it would have overwritten the correct
credential with a corrupted one and broken every wrapped job. The
never-overwrite rule exists so this class of accident is structurally
impossible, not merely discouraged.

## Usage

### `secrets_to_bws.sh` — one-time migration, secrets.env → BWS

```bash
.claude/scripts/secrets_to_bws.sh                 # dry-run (default)
.claude/scripts/secrets_to_bws.sh --apply          # create missing secrets in BWS
.claude/scripts/secrets_to_bws.sh --selftest       # mocked, no live bws call
```

Skips known non-secret config flags (`GEMINI_CLI_TRUST_WORKSPACE`,
`CODEX_SANDBOX` — see the script's `NON_SECRET_NAMES` list; audit it
before adding a new non-secret `export` line to `secrets.env`). Never
prints a raw value — only names, truncated sha256 hashes, and lengths.
Exits non-zero if any name already exists in BWS (conflict) or any error
occurred, so a clean (zero-conflict) run is the signal that migration is
complete for that name set.

### `secrets_cache_regen.sh` — regenerate the cache from BWS

```bash
.claude/scripts/secrets_cache_regen.sh             # dry-run (default)
.claude/scripts/secrets_cache_regen.sh --apply      # install the new cache
.claude/scripts/secrets_cache_regen.sh --selftest   # mocked, no live bws call
```

Run at login and after every rotation in BWS. Refuses to install if the
fetch failed or is empty, returned fewer keys than the current cache (a
truncated fetch must never silently shrink the cache), or contains a
malformed or double-assignment line (the exact corruption previously
caused by a missing trailing newline on an append). Backs up the previous
cache to `~/.config/secrets.env.bak-<UTC timestamp>` (mode 600) before
installing atomically.

## Related

- `.claude/launchd/SECRETS_MIGRATION.md` — the `with-secrets` per-job
  wrapper design that replaced global `launchctl setenv` (#791, #615);
  this rule's cache-file trust model builds on the same `chmod 600` +
  no-global-env-leak boundary.
- `.claude/scripts/with-secrets`, `.claude/scripts/verify_no_launchd_secret_leak.sh`
- `.claude/scripts/secrets_to_bws.sh`, `.claude/scripts/secrets_cache_regen.sh`
  — this rule's two scripts.
