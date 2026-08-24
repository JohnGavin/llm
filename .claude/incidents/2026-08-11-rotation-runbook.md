# Credential rotation runbook — 2026-08-11 leak

All 14 variables below were published to a public GitHub comment on 2026-08-11.
**Every one must be treated as compromised**, including those a provider has
already revoked — revocation stops the old value working, it does not restore
the service that depended on it.

Ordering is by *blast radius × exploitability*, not by provider convenience.

> **Never paste a value into a terminal you do not control, into a commit, or
> into an issue.** Edit `~/.config/secrets.env` directly with an editor.
> After editing, `exec zsh` to reload, and restart launchd jobs that hold the
> old value in memory.

---

## Step 0 — Enumerate every STORE before revoking anything

**Do this first, for each credential, and write the list down.**

`~/.config/secrets.env` is one store among several. A credential also lives
anywhere it was *copied to*, and revoking the old value breaks every copy at
once. The copies do not announce themselves — they fail on their own schedule,
which may be days later.

Known store classes:

| store | how to enumerate | notes |
|---|---|---|
| `~/.config/secrets.env` | `grep -c '^export' ~/.config/secrets.env` | the only one the original runbook covered |
| **GitHub Actions repo secrets** | command below | **this is the one that was missed in 2026-08** |
| launchd plists / job env | `grep -rl '<VARNAME>' ~/Library/LaunchAgents/` | holds values in memory until restarted |
| CI provider secrets other than GitHub | manual | none currently |

Enumerate the GitHub Actions copies — replace `VARNAME`:

```bash
for r in $(gh repo list JohnGavin --limit 200 --json name --jq '.[].name'); do
  gh secret list --repo "JohnGavin/$r" 2>/dev/null \
    | grep -q '^VARNAME' && echo "JohnGavin/$r"
done
```

Run it **before** revoking. After revocation the same list is still correct, but
you are now working against a clock with CI already broken.

> A repo that is **dormant** looks identical to a repo that is **fixed**. In the
> 2026-08 incident `randomwalk` held the dead token and had not run a workflow
> since 2026-07-12 — it was not failing, and it was not repaired either. Set the
> new value everywhere the enumeration lists it, not just where something is
> visibly red.

---

## Group 1 — Write access to code (do first)

Compromise here means an attacker can modify source, publish releases, or
poison the build. These grant the ability to *cause further compromise*, which
is why they rank above billable API keys.

| # | Variable | Provider action | Where to rotate |
|---|---|---|---|
| 1 | `GH_TOKEN` | **Auto-revoked** by GitHub | github.com → Settings → Developer settings → Personal access tokens |
| 2 | `GITHUB_PAT` | **Auto-revoked** by GitHub | same as above |
| 3 | `CACHIX_AUTH_TOKEN` | **Still live** | app.cachix.org → Personal auth tokens → revoke old, create new |

**Steps (1 and 2 together — they are the same class):**
1. Revoke any surviving old tokens explicitly; do not rely on the auto-revoke.
2. Create one new fine-grained PAT. Scope it to the minimum: `repo` (contents,
   issues, pull requests) and nothing else. Do not grant `admin` or `delete_repo`.
3. Set an expiry — 90 days maximum. An expiring token bounds the next incident.
4. Update both `GH_TOKEN` and `GITHUB_PAT` in `~/.config/secrets.env`.
5. Verify: `gh auth status` reports a valid token.
6. This unblocks all queued `gh` work, including deleting the leaked comment.

**Steps (3):** create the new Cachix token first, update `secrets.env` **and
every GitHub Actions repo secret from the Step 0 enumeration**, then revoke the
old one — this ordering avoids breaking an in-flight nix push.

```bash
# per repo from the Step 0 list; reads the value from stdin, never argv,
# so it does not land in shell history or `ps` output
gh secret set CACHIX_AUTH_TOKEN --repo JohnGavin/<repo>
```

> **This is the step that was missing in 2026-08 and it cost 11 days of broken
> CI.** The local `secrets.env` was updated correctly and the old token revoked;
> three repos (`tlang`, `irishbuoys`, `randomwalk`) kept serving the dead value
> to GitHub Actions. Nothing surfaced it — the failures were nightly and weekly
> jobs nobody was watching. See JohnGavin/llm#1013.

## Group 2 — Billable API keys (do second)

Compromise here means someone else spends your money. Several are already dead;
rotate anyway so the services work again.

| # | Variable | Provider action | Where to rotate |
|---|---|---|---|
| 4 | `OPENAI_API_KEY` | **Auto-disabled** by OpenAI | platform.openai.com → API keys |
| 5 | `GOOGLE_API_KEY` | **Auto-deleted** by Google Cloud | console.cloud.google.com → APIs & Services → Credentials |
| 6 | `GEMINI_API_KEY` | **Still live** | aistudio.google.com → Get API key |
| 7 | `ELEVENLABS_API_KEY` | **Still live** | elevenlabs.io → Profile → API key |

**Steps, each:** create the replacement, update `~/.config/secrets.env`, then
revoke the old one. Then **check the billing/usage page for anomalous spend
between 2026-08-11 and the rotation time** — this is the step people skip, and
it is the only way to detect whether the key was actually used.

`GEMINI_API_KEY` additionally gates roborev's review agent; after rotating,
restart the roborev daemon so it picks up the new value.

## Group 3 — Data-platform tokens (do third)

Three variables, one underlying credential family — HuggingFace. Rotating the
account token invalidates all three, so treat them as a single unit.

| # | Variable | Provider action |
|---|---|---|
| 8 | `HF_TOKEN` | **Auto-expired** by HuggingFace |
| 9 | `HUGGING_FACE_HUB_TOKEN` | same underlying token |
| 10 | `HUGGINGFACE_API_TOKEN` | same underlying token |

**Steps:** huggingface.co → Settings → Access Tokens. Create one token with
`write` only if you actually push datasets; otherwise `read`. Update all three
variables to the same new value.

**Follow-up worth doing:** three names for one credential is a latent bug —
whichever name a script happens to read decides whether it works. Consolidate
to `HF_TOKEN` and have the other two reference it, or delete them.

## Group 4 — Low-blast-radius keys (do last)

Free or read-only tiers. Rotate for completeness; nothing catastrophic follows
from delay.

| # | Variable | Where to rotate |
|---|---|---|
| 11 | `FRED_API_KEY` | fred.stlouisfed.org → My Account → API Keys |
| 12 | `AlphaVantage_API_KEY` | alphavantage.co → request a new free key |
| 13 | `GUARDIAN_API` | open-platform.theguardian.com |

## Group 5 — Not a credential

| Variable | Note |
|---|---|
| `GMAIL_APP_PASSWORD` | **This IS a credential and is high severity** — see below |
| `GEMINI_CLI_TRUST_WORKSPACE` | Boolean flag, not a secret. No action. |

### `GMAIL_APP_PASSWORD` — reclassify to Group 1 priority

Listed separately because it is easy to misjudge. A Gmail app password grants
**full IMAP/SMTP access to the mailbox** — read every message, send mail as
you. Mailboxes typically contain password-reset links for every other service,
which makes this a credential that can regenerate all the others.

**It was not auto-revoked**, because Google's scanners do not detect app
passwords in text.

**Steps:** myaccount.google.com → Security → 2-Step Verification → App
passwords → revoke the old entry → generate a new one → update
`~/.config/secrets.env`. Then review **Recent security activity** and **active
sessions** for unfamiliar access since 2026-08-11.

---

## Completion check

### Local store

```
grep -c '^export' ~/.config/secrets.env      # expect 13
gh auth status                                # expect valid
```

### Every OTHER store — verified where the credential is consumed

**A check that runs on this laptop cannot observe a credential failing in CI.**
Both surfaces must be verified, and the CI one must be verified *by running CI*,
not by reasoning about it.

For each repo from the Step 0 enumeration, trigger the workflow and confirm it
goes green:

```bash
gh workflow run "<workflow>" --repo JohnGavin/<repo>
gh run list --repo JohnGavin/<repo> --limit 1   # wait, then confirm success
```

For repos with **no manually-triggerable workflow**, note the next scheduled run
and check it. Do not mark the rotation complete until that run has been observed.

### Rotation is complete only when this table is filled in

| credential | `secrets.env` | GH Actions repos | consuming job observed green |
|---|---|---|---|
| `GMAIL_APP_PASSWORD` | | | 06:30 digest email |
| `GH_TOKEN` / `GITHUB_PAT` | | | `gh auth status` + one `gh` write |
| `CACHIX_AUTH_TOKEN` | | `tlang`, `irishbuoys`, `randomwalk` | one nix build per repo |
| `GEMINI_API_KEY` | | | roborev review |

### Why this section was rewritten

The original read: *"Then confirm the dependent jobs still run: … and any nix
push (`CACHIX_AUTH_TOKEN`)."*

That sentence was present, was correct, and did not work. Three reasons, all
worth avoiding in future runbooks:

1. **It was prose, not a command.** Nothing to run, so nothing was run.
2. **It named the wrong surface.** "any nix push" framed the risk as the *push*.
   The actual breakage was the *pull* — `cachix use` on a **public** cache,
   which needs no credential at all, failed because a revoked token was in the
   environment. The consequence was strictly larger than the sentence described.
3. **It had no owner and no deadline.** A nightly job that starts failing at
   04:00 is invisible until someone reads a notification email.

This is the same shape as JohnGavin/llm#1012 and #746: **the check and the
thing being checked shared a context**, so the check could not observe the
failure. `gh auth status` passing on a laptop says nothing about a GitHub
Actions runner.

## Priority summary

| Order | Group | Why this rank |
|---|---|---|
| 1 | `GMAIL_APP_PASSWORD` | Mailbox access can reset every other credential |
| 2 | GitHub tokens (2) | Code write access; also unblocks all queued work |
| 3 | `CACHIX_AUTH_TOKEN` | Build-cache poisoning |
| 4 | Billable API keys (4) | Direct financial loss |
| 5 | HuggingFace (3 names, 1 token) | Data platform write |
| 6 | Free-tier keys (3) | Negligible impact |
