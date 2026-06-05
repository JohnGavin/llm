# Rule: Cron Auto-Pull Discipline

## Source

JohnGavin/llm#510 — "every gh pr merge ships nothing": seven PRs merged
(#483, #486, #487, #501, #502, #503, #504) without any cron job picking up
their changes because the launchd-managed scripts run against the local main
checkout at `~/docs_gh/llm/` and that checkout is never automatically updated.

## When This Applies

Every `bin/*_cron.sh` wrapper script that is launched by a launchd plist and
operates on files under `${REPO_ROOT}` (or `${REPO_DIR}`). The rule applies
regardless of whether the script uses Nix, Rscript, or bash-only logic.

---

## CRITICAL: Every Cron Wrapper MUST Auto-Pull Before Running

Without the auto-pull block, the script runs against whatever commit was last
manually checked out to the local `main` branch. Merging a PR on GitHub does
NOT update the local clone. The result is that weeks of cron jobs silently run
against stale code.

### Required block placement

Insert immediately AFTER the lock-file `trap` (or, if no lock file, after
credential sourcing) and BEFORE any Step 1 work:

```bash
# ── Deploy: pull latest main before running (llm#510) ─────────────────────────
# Cron wrappers run against ${REPO_ROOT}; without this step every gh pr merge
# ships nothing — the cron uses whatever was last manually pulled to the main
# checkout. The fast-forward is silent on success and never overwrites local
# work because of --ff-only.
if [ -z "${SKIP_CRON_PULL:-}" ]; then
    git -C "${REPO_ROOT}" fetch origin main 2>/dev/null
    if git -C "${REPO_ROOT}" merge --ff-only origin/main 2>/dev/null; then
        log "deploy: ff to $(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
    else
        log "deploy WARN: ff-only failed — running against $(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
    fi
fi
log "HEAD: $(git -C "${REPO_ROOT}" rev-parse --short HEAD) $(git -C "${REPO_ROOT}" log -1 --format='%s')"
```

Adapt `${REPO_ROOT}` to whatever variable the script uses (e.g. `${REPO_DIR}`
in `roborev_weekly_rollup_cron.sh`).

### Why `--ff-only`

- **Non-destructive**: if local state cannot be fast-forwarded (local commits,
  merge conflict, or non-linear history), the pull fails silently and the cron
  continues against local state with a `WARN` log line instead of aborting
- **No rebase pollution**: `--ff-only` never rewrites history
- **No credential prompt**: `fetch` reads from `origin` using the same SSH/HTTPS
  config already set up for manual pulls

---

## `SKIP_CRON_PULL` Escape Hatch

Set `SKIP_CRON_PULL=1` in any of these situations:

| Situation | Example |
|-----------|---------|
| Testing a feature branch **before** merging | `SKIP_CRON_PULL=1 DRYRUN=1 bash bin/roborev_daily_cron.sh` |
| Debugging a script change in a worktree where `origin/main` doesn't have the change yet | Run from worktree, not main checkout |
| CI environments where no `origin` remote is configured | Set `SKIP_CRON_PULL=1` in plist `EnvironmentVariables` section |
| Intentional offline/air-gapped run | Set env var before calling the script |

**NEVER** set `SKIP_CRON_PULL=1` permanently in the launchd plist for
production cron jobs — that defeats the entire purpose of the auto-pull.

---

## HEAD breadcrumb in every log

Every cron log MUST show which commit it ran against. The auto-pull block
emits this via:

```bash
log "HEAD: $(git -C "${REPO_ROOT}" rev-parse --short HEAD) $(git -C "${REPO_ROOT}" log -1 --format='%s')"
```

This makes debugging a misbehaving cron trivial: grep the log for `HEAD:`
and compare the SHA against what was on `main` at the time.

---

## Checklist for new cron wrappers

When adding a new `bin/*_cron.sh`:

- [ ] Identify the repo-root variable (`REPO_ROOT`, `REPO_DIR`, etc.)
- [ ] Insert the auto-pull block in the required position
- [ ] Verify `SKIP_CRON_PULL` escape hatch is honoured
- [ ] Verify `HEAD:` log line appears after the block
- [ ] Test with `SKIP_CRON_PULL=1 DRYRUN=1 bash bin/<script>.sh`
- [ ] Run without skip flag; confirm log shows `deploy: ff to <sha>`

---

## Wrappers that implement this rule (as of llm#510)

| Script | Repo var |
|--------|----------|
| `bin/roborev_daily_cron.sh` | `REPO_ROOT` |
| `bin/config_digest_cron.sh` | `REPO_ROOT` |
| `bin/kb_digest_daily_cron.sh` | `REPO_ROOT` |
| `bin/stage1_findings_daily_cron.sh` | `REPO_ROOT` |
| `bin/roborev_weekly_rollup_cron.sh` | `REPO_DIR` |
| `bin/launchd_health_weekly_cron.sh` | `REPO_ROOT` |

---

## Forbidden patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| No auto-pull block in a cron wrapper | Every merge ships nothing | Add the block |
| `SKIP_CRON_PULL=1` in the launchd plist permanently | Defeats the auto-pull | Remove from plist; use only for manual testing |
| `git pull` (without `--ff-only`) | Can trigger merge commits or interactive conflict resolution, hanging the cron | Use `fetch` + `merge --ff-only` separately |
| `git reset --hard origin/main` | Destroys local state silently | Use `--ff-only` which fails gracefully |
| Using `git -C` with a relative path | Breaks when launchd cwd differs | Always absolute `${REPO_ROOT}` or `${REPO_DIR}` |

---

## Related

- llm#510 — origin issue
- `worktree-location` rule — worktrees are separate from the main checkout; auto-pull targets the main checkout only
- `agent-no-push-to-main` rule — agents commit to their own branch; the auto-pull on the main checkout is a separate, orthogonal mechanism
- `bash-safety` rule — `git -C` not `cd && git`; no compound commands
