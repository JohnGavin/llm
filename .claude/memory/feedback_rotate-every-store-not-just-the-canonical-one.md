---
name: feedback_rotate-every-store-not-just-the-canonical-one
description: Rotating a credential in its canonical store while copies live elsewhere breaks those copies silently — enumerate every store before revoking, and verify where the credential is consumed
metadata:
  type: feedback
---

A credential lives in every place it was ever copied to. Revoking the old value
breaks all of them at once, but they fail on their own schedules — a nightly job
at 04:00, a weekly job on Sunday, a dormant repo not at all. Rotating the
canonical store and stopping there feels complete and is not.

**Before revoking anything, enumerate every store.** For this setup that means
`~/.config/secrets.env`, **GitHub Actions repo secrets**, and launchd plists
holding the value in memory. The enumeration must be a command, not recall:

```bash
for r in $(gh repo list JohnGavin --limit 200 --json name --jq '.[].name'); do
  gh secret list --repo "JohnGavin/$r" 2>/dev/null | grep -q '^VARNAME' && echo "$r"
done
```

**Worked case (llm#1013, 2026-08).** `CACHIX_AUTH_TOKEN` was rotated after the
2026-08-11 leak: new token minted, `secrets.env` updated, old token revoked —
exactly as the runbook said. Three repos kept serving the dead value to CI.
`tlang` failed nightly for 11 consecutive days; `irishbuoys` weekly; nobody
noticed until the notification emails were read.

The runbook *did* contain "confirm the dependent jobs still run … and any nix
push (`CACHIX_AUTH_TOKEN`)". It failed anyway, three ways worth copying down:

- **Prose, not a command** — nothing to run, so nothing was run.
- **Named the wrong surface** — "any nix push" framed the risk as the push. The
  break was the *pull*: `cachix use` on a **public** cache, needing no
  credential, failed because a revoked token sat in the environment. The
  consequence was larger than the sentence described.
- **Verified in the wrong context** — `gh auth status` passing on a laptop says
  nothing about a GitHub Actions runner.

**Why:** the check and the thing checked shared a context, so the check could
not observe the failure. Same family as
[[health-check-inherits-a-different-path]] (caller's PATH vs daemon's),
[[probe-must-not-share-writer-path]] (probe on the writer's own code path), and
llm#1012 (gate resolving a tool from a nonexistent path, printing PASS).

**How to apply:**

- Enumerate stores **before** revoking. After revocation the list is unchanged
  but you are racing broken CI.
- Verify each consuming surface **by running it**, not by reasoning about it.
  Trigger the workflow; watch it go green.
- **A dormant consumer looks identical to a fixed one.** `randomwalk` held the
  dead token with no run since 2026-07-12 — not failing, not repaired. Set the
  new value everywhere the enumeration lists it, not only where something is red.
- Prefer a credential that fails *narrowly*. The same incident showed a job-level
  `env:` turning a dead push credential into a dead build; scoping the secret to
  the one step that needs it means a bad credential costs that step alone.

Related: [[exec-zsh-does-not-clear-env]] (a revoked value surviving in a live
environment), [[feedback_default-permit-is-fail-open]] (the enumeration-based
control that silently omits what nobody classified).
