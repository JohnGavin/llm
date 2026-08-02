---
name: feedback_ast-grep-lessons
description: 7 lessons from ast-grep code sweep — rules need enforcement, agent violates own rules, verify counts
type: feedback
---

7 lessons from first ast-grep code sweep (2026-03-30):

1. **Rules need structural enforcement.** grep-based `qa_no_raw_sql` missed `dbGetQuery` that ast-grep found. Text grep has false negatives (comments, strings) and false positives. ast-grep searches the AST.

2. **Old code doesn't auto-update.** `stop()` survived in sync_wiki.R and ccusage.R because they were written before the cli::cli_abort style standard. Schedule periodic sweeps.

3. **The agent violates its own rules.** I wrote `data.frame()` in 3 files this session while the style guide says `tibble()`. I then justified it as "lightweight utilities" instead of fixing it. Speed must not silence standards.

4. **Silent tryCatch is the suppressWarnings of control flow.** 12 `tryCatch(error = function(e) NULL)` in plan_vignette_outputs.R meant errors were invisible. Changed to `cli::cli_warn()` + NULL.

5. **Line count ≠ call count.** ast-grep default output reported 349 lines for 28 tryCatch calls (12x inflation from multi-line matches). Use `--json=compact` + `nrow()` for accurate counts.

6. **Never accept "expected" or "lightweight" as justification.** I said "349 tryCatch — expected for targets" without checking. Reality: 289 lines were in ONE file, all silent error swallowing.

7. **Periodic code sweeps are necessary.** Rules only prevent NEW violations. Old code predating the rule persists until someone sweeps. `/check` now includes ast-grep sweep.

**How to apply:** Run `/check` which includes ast-grep sweep. When reporting counts, use --json. When justifying a violation, cite the documented exception or fix it.

---

## 8. R rules need `-c sgconfig.yml` — a bare `--rule` invocation LOOKS broken (2026-08-02)

R is a **custom grammar** registered in `~/.config/ast-grep/sgconfig.yml`, not a built-in
language. Scanning a rule standalone bypasses that registration and fails at parse time
with an error that reads like the rule file itself is malformed:

```
Error: Cannot parse rule .../r-no-system2-getenv-splice.yml
╰▻ Fail to parse yaml as RuleConfig
╰▻ data did not match any variant of untagged enum SgLang at line 28 column 1
```

`line 28` is the `language: r` line. The rule is fine; ast-grep simply does not know
what `r` is without the config.

```bash
# WRONG — reads as "your rule is broken"
ast-grep scan --rule ~/.config/ast-grep/rules/<rule>.yml target.R

# RIGHT
ast-grep scan -c ~/.config/ast-grep/sgconfig.yml --rule ~/.config/ast-grep/rules/<rule>.yml target.R
```

`ast-grep` is provided by the nix shell — not on the bare PATH, and neither is `sg`.
Run it via `nix-shell /Users/johngavin/docs_gh/llm/default.nix --run "ast-grep ..."`.

**Why this cost time:** I read the parse error as evidence that a just-merged rule was
defective and nearly reverted it. The rule was correct. Diagnose "invalid rule" errors by
first re-running WITH `-c` before doubting the rule.

**Second trap, same session:** rules live ONLY at `~/.config/ast-grep/rules/` — laptop-local,
not git-backed. A rule merged into `.claude/ast-grep-rules/` in the repo is **not active**
until copied across. Merging is not deploying. See [[deploy-gap-stale-main-checkout]].

**Third trap:** bare `$$$` multi-metavars degrade to literal R extract-operator tokens in
some syntactic positions under this grammar, so a pattern like
`system2($$$, env = c($$$, Sys.getenv($$$), $$$), $$$)` parses but never matches anything.
Verify with `--debug-query=pattern`; prefer composite `has`/`field`/`stopBy: end` rules over
multi-`$$$` patterns. A lint that never fires is worse than no lint — always prove it fires
on a bad fixture AND stays silent on a good one before trusting it.

**How to apply:** always `-c sgconfig.yml`; always run inside the nix shell; always copy new
rules to `~/.config/ast-grep/rules/` after merge; always prove a new rule fires before
claiming coverage.
