#!/usr/bin/env bash
# check_rule_scoping.sh — audit .claude/rules/ for rule-loading defects.
#
# Rules WITHOUT a `paths:` frontmatter key load into EVERY session and EVERY
# subagent context. Only the mandatory core may do so. Unscoped rules inflate
# subagent base context — the "Prompt is too long" failures in llm#590.
# Convention: AGENTS.md "Rule loading is enforced via paths: frontmatter".
#
# The mandatory list is a SINGLE source of truth: it is parsed from the
# "**Mandatory rules**" line in the repo's `.claude/CLAUDE.md` (checked
# first) or `AGENTS.md` (checked second — this is where the line actually
# lives in the llm repo, since `~/.claude/CLAUDE.md` is a symlink to
# `AGENTS.md`). A hardcoded duplicate list is guaranteed to drift from that
# policy line — it already had (llm#590 follow-up): three rules declared
# mandatory in AGENTS.md were not actually loading unconditionally, and the
# checker's own hardcoded ALLOW list silently disagreed with AGENTS.md and
# never caught it. Falls back to a hardcoded list ONLY if neither doc file
# can be parsed, with a WARN — the fallback existing at all is itself a
# smell; fix the doc source instead of relying on it.
#
# A second, PARALLEL tier — safety-critical (llm#943) — is parsed the same
# way from a "**Safety-critical rules**" line. It carries the identical
# "must never be scoped" contract as mandatory, but is named separately
# because its content is a specific credential/trust/destructive-ops
# posture rather than a general session discipline; keeping the two lines
# distinct in AGENTS.md keeps each list short and readable rather than
# merging unrelated rules into one giant "mandatory" bucket. Both tiers are
# still ONE source of truth each (one prose line in AGENTS.md, mechanically
# parsed) — this is not a second hand-maintained copy of the mandatory list,
# it is a second, independently-sourced list using the same parsing
# mechanism. The origin incident (2026-08-11 credential leak) happened
# because `credential-management.md`'s `paths:` scope excluded every file
# where secrets are actually handled — see
# `.claude/incidents/2026-08-11-credential-leak.md`.
#
# Four checks, two directions:
#   A. Context-bloat direction: a rule in NEITHER tier with no `paths:`
#      frontmatter loads into every session/subagent unconditionally. This
#      now INCLUDES `.claude/rules/_companions/**` (llm#1140 follow-up): a
#      companion doc with no `paths:` also loads unconditionally despite its
#      own header text claiming "loaded on demand" — see the origin incident
#      in `rule-scoping-guard.md`. Companions can never land in check B/C:
#      the mandatory/safety-critical tiers are name-matched against the
#      basenames declared in AGENTS.md's tier lines, and no companion
#      basename appears there, so an unscoped companion always resolves to
#      check A (exit 1, non-blocking), never check B/C (exit 3, blocking).
#   B. Safety direction: a MANDATORY or SAFETY-CRITICAL rule that DOES carry
#      `paths:` frontmatter — so despite being declared "always loads" it
#      silently only fires for matching files.
#   C. Safety direction: a MANDATORY or SAFETY-CRITICAL rule name with no
#      corresponding rule file at all — the declared policy names something
#      that doesn't exist.
#   D. Advisory only, never affects exit code: a rule in NEITHER tier whose
#      content is dense with credential/destruction keywords (>= threshold)
#      and that carries no `scoping-justification:` frontmatter field
#      explaining why it is deliberately still scoped. Printed as ADVISORY
#      lines. Intentionally non-blocking — see the `content_heuristic`
#      function's own header for why a hard block here would be premature.
#
# A fifth check, E (`--budget`), is a separate mode with its own exit codes:
# it measures the combined always-loaded instruction size per session type
# against Claude Code's startup limit — see the `budget_report` header below.
#
# Usage: check_rule_scoping.sh [rules-dir]
#        check_rule_scoping.sh --budget [--only DIR]
#        check_rule_scoping.sh --selftest
#
# Exit codes (checks A-D; --budget codes are documented at budget_report):
#   0 = clean (check D advisories, if any, do not change this)
#   1 = check-A failures only (context bloat)
#   2 = rules dir not found / usage error
#   3 = check-B and/or check-C failures present (safety — a mandatory or
#       safety-critical rule is not actually loading as declared). Takes
#       priority over 1 when both classes fail on the same run.
set -euo pipefail

# Fallback list, used ONLY when the "**Mandatory rules**" line cannot be
# parsed from .claude/CLAUDE.md or AGENTS.md. Do not rely on this staying in
# sync — that is precisely the drift this script exists to catch.
FALLBACK_ALLOW="bash-safety btw-timeouts nix-agent-shell-protocol worktree-location \
agent-identity-and-task-scopes human-in-the-loop-decision-points \
auto-delegation pivot-signal"

# Fallback list for the safety-critical tier, used ONLY when the
# "**Safety-critical rules**" line cannot be parsed. Same caveat as above.
FALLBACK_SAFETY_CRITICAL="credential-management external-code-zero-trust \
permission-discipline destructive-ops-guard"

# Content-heuristic threshold (check D). Calibrated 2026-08-21 against the
# 79 rule files existing at the time: the three already-hook-enforced
# secret-handling rules (secret-exposure-scanning, secrets-single-source,
# secret-leak-prevention) score 48-71 and carry `scoping-justification:`;
# the highest UNJUSTIFIED non-tier rule at threshold-setting time
# (long-running-process-supervision) scored 14. Set above that gap. Expect
# to retune as new rules are added — this is a starting point, not a law.
CONTENT_HEURISTIC_THRESHOLD=15
CONTENT_HEURISTIC_PATTERN='credential|secret|token|password|api[_ -]?key|rm -rf|force-push|DROP TABLE|delete repo|destroy|irreversible|force_delete|--force'

has_paths() {
    awk '/^---$/{n++; next} n==1 && /^paths:/{found=1} n>=2{exit} END{exit !found}' "$1"
}

# Does the rule file carry a `scoping-justification:` frontmatter key? Used
# by check D as the documented escape hatch: a rule may score above the
# content-heuristic threshold and still legitimately stay scoped, provided
# it says why (e.g. "enforced by a PreToolUse hook, not advisory-dependent").
has_scoping_justification() {
    awk '/^---$/{n++; next} n==1 && /^scoping-justification:/{found=1} n>=2{exit} END{exit !found}' "$1"
}

# Extract the space-separated list of backtick-quoted rule names from the
# first line matching $2 (a grep -m1 pattern, e.g. '\*\*Mandatory rules') in
# $1. Prints nothing (and returns 1) if the file doesn't exist or has no
# such line.
parse_tier_line() {
    local doc="$1" pattern="$2" line names
    [ -f "$doc" ] || return 1
    line="$(grep -m1 "$pattern" "$doc" || true)"
    [ -n "$line" ] || return 1
    names="$(echo "$line" | grep -oE '`[a-zA-Z0-9_-]+`' | tr -d '`' | tr '\n' ' ')"
    [ -n "$names" ] || return 1
    echo "$names"
}

# Resolve the mandatory-rule-name list for a given rules dir: try
# <repo_root>/.claude/CLAUDE.md, then <repo_root>/AGENTS.md, then fall back
# with a WARN to stderr. The mandatory tier is REQUIRED — if no doc source
# can be parsed at all, silently returning an empty list would mean every
# mandatory-rule check is skipped, so the fallback (a stale but non-empty
# snapshot) is safer than nothing.
resolve_mandatory_list() {
    local rules_dir="$1" repo_root doc out
    repo_root="$(cd "$rules_dir" && cd ../.. && pwd)"
    for doc in "$repo_root/.claude/CLAUDE.md" "$repo_root/AGENTS.md"; do
        out="$(parse_tier_line "$doc" '\*\*Mandatory rules' || true)"
        if [ -n "$out" ]; then
            echo "$out"
            return 0
        fi
    done
    echo "WARN: could not parse a **Mandatory rules** line from .claude/CLAUDE.md or AGENTS.md under $repo_root — falling back to hardcoded list (this can drift; fix the doc source)" >&2
    echo "$FALLBACK_ALLOW"
}

# Resolve the safety-critical-rule-name list (llm#943), same doc search
# order as resolve_mandatory_list. UNLIKE the mandatory tier, an absent
# "**Safety-critical rules**" line is a legitimate state — this tier is
# additive/optional (a repo that hasn't adopted the convention yet has none
# of it), so when a doc source EXISTS but simply has no such line, this
# returns an empty list silently, no WARN, no fallback. The hardcoded
# fallback fires only in the more severe case: neither doc source can even
# be found, which mirrors resolve_mandatory_list's own trigger condition.
#
# KNOWN RESIDUAL GAP (found by mutation-testing this exact function while
# landing llm#943, 2026-08-21 — recorded here rather than silently fixed
# because closing it fully would require either coupling the fallback names
# to a fixed file set, which is its own foot-gun, or threading extra state
# through every --selftest fixture; deferred as a documented trade-off, not
# an oversight): if AGENTS.md's "**Safety-critical rules**" line is deleted
# (but the file itself still exists), the 4 tier rules silently fall out of
# checks B/C entirely and are re-evaluated as ordinary rules under check A
# — since they correctly carry no `paths:`, they get flagged UNSCOPED
# (non-blocking, exit 1) rather than SAFETY-CRITICAL-BUT-ABSENT (blocking,
# exit 3). The identical gap exists for the mandatory tier if a single name
# is dropped from the "**Mandatory rules**" line while its file stays
# unscoped (also demotes silently to check A) — mandatory's fallback only
# protects against the WHOLE line vanishing, not one entry disappearing.
# Net effect: the checker still emits *some* signal (UNSCOPED) either way,
# never total silence, but the signal downgrades from blocking to advisory.
resolve_safety_critical_list() {
    local rules_dir="$1" repo_root doc out any_doc_exists=0
    repo_root="$(cd "$rules_dir" && cd ../.. && pwd)"
    for doc in "$repo_root/.claude/CLAUDE.md" "$repo_root/AGENTS.md"; do
        [ -f "$doc" ] || continue
        any_doc_exists=1
        out="$(parse_tier_line "$doc" '\*\*Safety-critical rules' || true)"
        if [ -n "$out" ]; then
            echo "$out"
            return 0
        fi
    done
    if [ "$any_doc_exists" -eq 1 ]; then
        return 0
    fi
    echo "WARN: could not find .claude/CLAUDE.md or AGENTS.md under $repo_root to parse a **Safety-critical rules** line — falling back to hardcoded list (this can drift; fix the doc source)" >&2
    echo "$FALLBACK_SAFETY_CRITICAL"
}

# Check D (advisory ONLY — never contributes to the exit code). A rule
# outside both the mandatory and safety-critical tiers whose content is
# dense with credential/destruction keywords, and that carries no
# `scoping-justification:` frontmatter explaining why it is deliberately
# still scoped. llm#943 item 3 asks for this heuristic to be "enforced";
# it is implemented here as a printed ADVISORY line rather than a blocking
# failure, a deliberate choice: check B/C (the safety direction) is a
# precise, zero-false-positive signal (a named rule either carries `paths:`
# or it doesn't), but a keyword-density threshold is inherently approximate
# — three already-hook-enforced secret-handling rules
# (secret-exposure-scanning, secrets-single-source, secret-leak-prevention)
# score 48-71 on this heuristic while being correctly scoped (their actual
# enforcement is a PreToolUse hook, not the LLM recalling the rule text at
# the right moment). Blocking commits on an approximate signal is exactly
# the failure mode `rule-scoping-guard.md` already warns about for check A:
# "a guard that blocks on noise gets --no-verify'd or deleted within a day".
# Promote to blocking only after this has run long enough to show a
# near-zero false-positive rate.
content_heuristic_check() {
    local f="$1" name="$2" hits
    hits="$(grep -ciE "$CONTENT_HEURISTIC_PATTERN" "$f" 2>/dev/null || true)"
    [ -n "$hits" ] || hits=0
    if [ "$hits" -ge "$CONTENT_HEURISTIC_THRESHOLD" ] && ! has_scoping_justification "$f"; then
        echo "ADVISORY-HIGH-RISK-UNJUSTIFIED: $name ($hits credential/destruction keyword hits) — not in the mandatory/safety-critical tier and carries no scoping-justification: frontmatter field explaining why it is deliberately still scoped (see llm#943 item 3)"
    fi
}

# Runs checks A, B, C, D against $1 (a rules dir). Prints one finding line
# per defect. Returns 0 clean / 1 check-A-only / 3 check-B-or-C-present.
# Check D never changes the return code (see content_heuristic_check above).
audit() {
    local dir="$1" mandatory safety_critical f rel name has_p m s tier
    local fail_a=0 fail_bc=0
    mandatory="$(resolve_mandatory_list "$dir")"
    safety_critical="$(resolve_safety_critical_list "$dir")"

    while IFS= read -r f; do
        rel="${f#"$dir"/}"
        name="$(basename "$f" .md)"
        if has_paths "$f"; then has_p=1; else has_p=0; fi

        tier=""
        case " $mandatory " in
            *" $name "*) tier="MANDATORY" ;;
        esac
        if [ -z "$tier" ]; then
            case " $safety_critical " in
                *" $name "*) tier="SAFETY-CRITICAL" ;;
            esac
        fi

        if [ -n "$tier" ]; then
            if [ "$has_p" -eq 1 ]; then
                echo "$tier-BUT-SCOPED: $name — declared $tier in CLAUDE.md/AGENTS.md but carries paths:, so it only loads for matching files"
                fail_bc=1
            fi
            continue
        fi

        if [ "$has_p" -eq 0 ]; then
            echo "UNSCOPED: $rel ($(wc -c < "$f" | tr -d ' ') bytes) — add paths: frontmatter (see llm#590)"
            fail_a=1
        fi

        content_heuristic_check "$f" "$name"
    # Companion documents under _companions/ are INCLUDED here (llm#1140
    # follow-up) — a companion with no paths: frontmatter loads into every
    # session/subagent exactly like a top-level rule; "loaded on demand" in
    # its own header text is not itself an enforcement mechanism. 32 of 34
    # companions were found unscoped in this repo before that follow-up.
    done < <(find "$dir" -name '*.md' -type f | sort)

    for m in $mandatory; do
        if [ ! -f "$dir/$m.md" ]; then
            echo "MANDATORY-BUT-ABSENT: $m — declared mandatory in CLAUDE.md/AGENTS.md but no rule file exists"
            fail_bc=1
        fi
    done
    for s in $safety_critical; do
        if [ ! -f "$dir/$s.md" ]; then
            echo "SAFETY-CRITICAL-BUT-ABSENT: $s — declared safety-critical in CLAUDE.md/AGENTS.md but no rule file exists"
            fail_bc=1
        fi
    done

    if [ "$fail_bc" -eq 1 ]; then
        return 3
    elif [ "$fail_a" -eq 1 ]; then
        return 1
    fi
    return 0
}

# Check E (--budget): always-loaded instruction budget (llm startup-limit guard).
#
# Claude Code warns at startup when the combined size of instruction files
# that load into EVERY session (each CLAUDE.md, each rules file without
# `paths:` or with `paths: ["**"]`, each resolvable @import, the first 25KB of
# the project's MEMORY.md) passes a limit (observed: 150.0k chars). This mode
# measures that per session type so the number cannot creep back unseen.
#
# Session types measured:
#   GLOBAL          ~/.claude/CLAUDE.md (symlink resolved) + every unscoped
#                   file under ~/.claude/rules/**
#   <project>       GLOBAL + that project's CLAUDE.md, .claude/CLAUDE.md,
#                   unscoped .claude/rules/** and project MEMORY.md. Files are
#                   de-duplicated by realpath, so the llm main checkout (whose
#                   rules ARE the global rules via symlink) is not double
#                   counted. Main checkouts only: worktrees and
#                   .claude/worktrees are skipped by discovery.
#   llm worktree    GLOBAL + the llm project's own files counted AGAIN (a
#                   worktree's copies have different paths, so they are not
#                   deduplicated), UNLESS `claudeMdExcludes` in
#                   ~/.claude/settings.json matches them. APPROXIMATION: the
#                   worktree is modelled at <docs>/worktrees/<llm>/feat/budget-probe/
#                   and patterns are matched with Python fnmatch (where `*`
#                   also matches `/`), not Claude Code's real glob engine.
#                   Worktree memory (a different slug) is not counted.
#
# Thresholds (chars): WARN > RULE_BUDGET_WARN (default 120000),
#                     OVER > RULE_BUDGET_LIMIT (default 150000).
# Output: `RULE-BUDGET-{OK|WARN|OVER}: <name> <chars> chars ...` — GLOBAL
# always, any other session type only when over WARN — then one
# `RULE-BUDGET-SUMMARY:` line.
#
# Exit codes (budget mode only; the A-D checks keep their own contract):
#   0 = every session type <= WARN
#   1 = at least one WARN, none over the limit
#   3 = INDETERMINATE (~/.claude/CLAUDE.md, ~/.claude/rules, python3 or
#       settings.json unreadable) — never reported as 0
#   4 = at least one session type over the limit (distinct from 2/3)
# `--only DIR` restricts the verdict to the session for DIR (plus GLOBAL and
# the llm-worktree row only when DIR is the checkout that owns the global
# rules/AGENTS.md), for use by the pre-commit gate.
# Env: RULE_BUDGET_HOME (default $HOME), RULE_BUDGET_DOCS (default $HOME/docs_gh).
budget_report() { # budget_report [--only DIR]
    local only=""
    if [ "${1:-}" = "--only" ]; then only="${2:-}"; fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "RULE-BUDGET-INDETERMINATE: python3 not found on PATH — cannot measure the instruction budget"
        return 3
    fi
    python3 - "${RULE_BUDGET_HOME:-$HOME}" "${RULE_BUDGET_DOCS:-${RULE_BUDGET_HOME:-$HOME}/docs_gh}" "$only" <<'PY'
import fnmatch, json, os, re, sys

home, docs, only = sys.argv[1], sys.argv[2], sys.argv[3] or None
WARN = int(os.environ.get("RULE_BUDGET_WARN") or 120000)
LIMIT = int(os.environ.get("RULE_BUDGET_LIMIT") or 150000)
MEM_CAP = 25 * 1024
ALWAYS_STAR = "**"  # a paths: list made only of this pattern still loads everywhere
SKIP = {"worktrees", ".git", "node_modules", "_targets", "renv", ".venv", "venv", "__pycache__"}
IMPORT = re.compile(r"(?<![\w@/.])@((?:~|\.{0,2})/?[\w.\-/]+\.[A-Za-z0-9]+)")


def indeterminate(msg):
    print("RULE-BUDGET-INDETERMINATE: " + msg)
    sys.exit(3)


def read(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def fm_paths(text):
    """None if no paths: key in the frontmatter, else the list of patterns."""
    if not text.startswith("---"):
        return None
    lines = text.split("\n")
    end = next((i for i in range(1, len(lines)) if lines[i].rstrip() == "---"), None)
    if end is None:
        return None
    fm = lines[1:end]
    for i, line in enumerate(fm):
        m = re.match(r"^paths:\s*(.*)$", line)
        if not m:
            continue
        rest = m.group(1).split(" #")[0].strip()
        pats = []
        if rest:
            pats = [x.strip().strip("\"'") for x in rest.strip("[]").split(",") if x.strip()]
        else:
            for l2 in fm[i + 1:]:
                m2 = re.match(r"^\s+-\s*(.*)$", l2)
                if m2:
                    pats.append(m2.group(1).strip().strip("\"'"))
                elif l2.strip():
                    break
        return pats
    return None


def always_loaded(text):
    pats = fm_paths(text)
    return pats is None or all(p == ALWAYS_STAR for p in pats)


def expand(pat):
    return os.path.expanduser(pat)


def load_excludes():
    p = os.path.join(home, ".claude", "settings.json")
    if not os.path.isfile(p):
        return []
    try:
        data = json.loads(read(p))
    except ValueError as e:
        indeterminate("cannot parse %s: %s" % (p, e))
    ex = data.get("claudeMdExcludes", []) if isinstance(data, dict) else []
    return [expand(x) for x in ex if isinstance(x, str)]


EXCL = load_excludes()


def excluded(path):
    return any(fnmatch.fnmatch(path, pat) for pat in EXCL)


def collect(path, seen, depth=0):
    """Chars of `path` plus its resolvable @imports, de-duplicated via `seen`."""
    rp = os.path.realpath(path)
    if rp in seen or not os.path.isfile(rp):
        return 0
    seen.add(rp)
    text = read(rp)
    n = len(text)
    if depth < 5:
        for m in IMPORT.finditer(text):
            cand = expand(m.group(1))
            if not os.path.isabs(cand):
                cand = os.path.join(os.path.dirname(path), cand)
            n += collect(cand, seen, depth + 1)
    return n


def instruction_files(root):
    """(kind, path, relpath) for a project root: its CLAUDE.md files and rules/**."""
    out = []
    for rel in ("CLAUDE.md", os.path.join(".claude", "CLAUDE.md")):
        p = os.path.join(root, rel)
        if os.path.isfile(p):
            out.append(("claude", p, rel))
    rules = os.path.join(root, ".claude", "rules")
    if os.path.isdir(rules):
        for r, ds, fs in os.walk(rules, followlinks=True):
            ds.sort()
            for f in sorted(fs):
                if f.endswith(".md"):
                    p = os.path.join(r, f)
                    out.append(("rule", p, os.path.relpath(p, root)))
    return out


def measure(files, seen):
    """(total chars, rule count, rule chars) of the always-loaded files."""
    total, nrules, rules_chars = 0, 0, 0
    for kind, p, rel in files:
        if excluded(p):
            continue
        if kind == "rule" and not always_loaded(read(p)):
            continue
        n = collect(p, seen)
        total += n
        if kind == "rule" and n:
            nrules += 1
            rules_chars += n
    return total, nrules, rules_chars


# ---- GLOBAL -----------------------------------------------------------
g_claude = os.path.join(home, ".claude", "CLAUDE.md")
g_rules = os.path.join(home, ".claude", "rules")
if not os.path.isfile(g_claude):
    indeterminate("cannot resolve %s (missing or dangling symlink)" % g_claude)
if not os.path.isdir(g_rules):
    indeterminate("cannot resolve rules dir %s" % g_rules)
seen_g = set()
g_cm = 0 if excluded(g_claude) else collect(g_claude, seen_g)
g_files = []
for r, ds, fs in os.walk(g_rules, followlinks=True):
    ds.sort()
    for f in sorted(fs):
        if f.endswith(".md"):
            p = os.path.join(r, f)
            g_files.append(("rule", p, os.path.relpath(p, g_rules)))
g_rules_total, g_nrules, _ = measure(g_files, seen_g)
GLOBAL = g_cm + g_rules_total

owner = os.path.dirname(os.path.dirname(os.path.realpath(g_rules)))  # checkout owning the global rules
owner_ok = os.path.isdir(os.path.join(owner, ".claude", "rules"))
affects_global = bool(only) and os.path.realpath(only) == owner


def find_projects(root, maxdepth=4):
    res = []

    def walk(d, depth):
        try:
            entries = sorted(os.scandir(d), key=lambda e: e.name)
        except OSError:
            return
        if any(e.name == ".claude" and e.is_dir(follow_symlinks=False) for e in entries):
            # a linked worktree has a .git FILE (not a dir): main checkouts only
            if not any(e.name == ".git" and e.is_file(follow_symlinks=False) for e in entries):
                res.append(d)
            return
        if depth >= maxdepth:
            return
        for e in entries:
            if e.name in SKIP or e.name.startswith("."):
                continue
            if e.is_dir(follow_symlinks=False):
                walk(e.path, depth + 1)

    walk(root, 0)
    return res


def memory_chars(path):
    slug = re.sub(r"[^A-Za-z0-9]", "-", path)
    m = os.path.join(home, ".claude", "projects", slug, "memory", "MEMORY.md")
    return min(len(read(m)), MEM_CAP) if os.path.isfile(m) else 0


def name_of(path):
    ap, root = os.path.abspath(path), os.path.abspath(docs)
    if not ap.startswith(root + os.sep):
        return os.path.basename(ap)
    return os.path.relpath(ap, root)


rows = []  # (name, total, detail, counted)
rows.append(("GLOBAL", GLOBAL,
             "CLAUDE.md %d + %d always-loaded rules %d" % (g_cm, g_nrules, g_rules_total),
             (not only) or affects_global))

targets = [os.path.abspath(only)] if only else find_projects(docs)
for d in targets:
    own, _, _ = measure(instruction_files(d), set(seen_g))
    mem = memory_chars(d)
    rows.append((name_of(d), GLOBAL + own + mem,
                 "global %d + project %d + memory %d" % (GLOBAL, own, mem), True))

if owner_ok and ((not only) or affects_global):
    wt = os.path.join(os.path.abspath(docs), "worktrees", os.path.basename(owner), "feat", "budget-probe")
    own = 0
    for kind, p, rel in instruction_files(owner):
        if excluded(os.path.join(wt, rel)):
            continue
        if kind == "rule" and not always_loaded(read(p)):
            continue
        # a worktree's copy has a different path: count it again, never deduplicated
        own += collect(p, set())
    rows.append((os.path.basename(owner) + " worktree", GLOBAL + own,
                 "global %d + worktree copy %d (claudeMdExcludes: %d patterns)" % (GLOBAL, own, len(EXCL)), True))

rank = {"OK": 0, "WARN": 1, "OVER": 4}
worst, nw, no = 0, 0, 0
for name, total, detail, counted in sorted(rows, key=lambda r: -r[1]):
    st = "OVER" if total > LIMIT else "WARN" if total > WARN else "OK"
    if counted:
        nw += st == "WARN"
        no += st == "OVER"
        worst = max(worst, rank[st])
    if name == "GLOBAL" or st != "OK":
        print("RULE-BUDGET-%s: %s %d chars (%s)%s" % (
            st, name, total, detail, "" if counted else " [informational: not touched by this commit]"))
print("RULE-BUDGET-SUMMARY: %d session types, %d over warn (>%d), %d over limit (>%d)" % (
    len([r for r in rows if r[3]]), nw, WARN, no, LIMIT))
sys.exit(worst)
PY
}

if [ "${1:-}" = "--budget" ]; then
    shift
    rc=0
    budget_report "$@" || rc=$?
    exit "$rc"
fi

if [ "${1:-}" = "--selftest" ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    pass=0
    total=0

    check_eq() { # check_eq <desc> <actual> <expected>
        total=$((total + 1))
        if [ "$2" = "$3" ]; then
            pass=$((pass + 1))
        else
            echo "FAIL: $1 — expected [$3] got [$2]"
        fi
    }

    mk_repo() { # mk_repo <repo-dir> <mandatory-names-space-sep> [safety-critical-names-space-sep]
        mkdir -p "$1/.claude/rules"
        {
            printf -- '**Mandatory rules** (auto-loaded): %s.\n' \
                "$(for n in $2; do printf '`%s`, ' "$n"; done | sed 's/, $//')"
            if [ -n "${3:-}" ]; then
                printf -- '**Safety-critical rules** (auto-loaded): %s.\n' \
                    "$(for n in $3; do printf '`%s`, ' "$n"; done | sed 's/, $//')"
            fi
        } > "$1/.claude/CLAUDE.md"
    }

    # --- Combined repo: one of every case at once ---
    r1="$tmp/repo1"
    mk_repo "$r1" "mand-ok mand-scoped mand-absent"
    printf -- '---\ndescription: x\n---\n# mandatory ok\nbody\n' > "$r1/.claude/rules/mand-ok.md"
    printf -- '---\npaths:\n  - "R/**"\n---\n# mandatory but scoped\nbody\n' > "$r1/.claude/rules/mand-scoped.md"
    printf -- '# unscoped non-mandatory\nbody\n' > "$r1/.claude/rules/nonmand-unscoped.md"
    printf -- '---\npaths:\n  - "R/**"\n---\n# scoped non-mandatory\nbody\n' > "$r1/.claude/rules/nonmand-scoped.md"
    # mand-absent.md deliberately not created

    out1="$(audit "$r1/.claude/rules")" && rc1=0 || rc1=$?
    check_eq "combined: exit 3 (B/C beats A)" "$rc1" "3"
    c="$(printf '%s\n' "$out1" | grep -c 'MANDATORY-BUT-SCOPED: mand-scoped' || true)"
    check_eq "combined: mand-scoped flagged MANDATORY-BUT-SCOPED" "$c" "1"
    c="$(printf '%s\n' "$out1" | grep -c 'MANDATORY-BUT-ABSENT: mand-absent' || true)"
    check_eq "combined: mand-absent flagged MANDATORY-BUT-ABSENT" "$c" "1"
    c="$(printf '%s\n' "$out1" | grep -c 'UNSCOPED: nonmand-unscoped.md' || true)"
    check_eq "combined: nonmand-unscoped flagged UNSCOPED" "$c" "1"
    c="$(printf '%s\n' "$out1" | grep -c 'mand-ok' || true)"
    check_eq "combined: mand-ok (correctly configured) NOT mentioned" "$c" "0"
    c="$(printf '%s\n' "$out1" | grep -c 'nonmand-scoped' || true)"
    check_eq "combined: nonmand-scoped (correctly configured) NOT mentioned" "$c" "0"

    # --- Isolated exit-code cases ---
    r2="$tmp/repo2"  # check-A only -> exit 1
    mk_repo "$r2" "mand-ok"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r2/.claude/rules/mand-ok.md"
    printf -- '# unscoped\nbody\n' > "$r2/.claude/rules/nonmand-unscoped.md"
    audit "$r2/.claude/rules" >/dev/null && rc2=0 || rc2=$?
    check_eq "check-A-only exit code" "$rc2" "1"

    r3="$tmp/repo3"  # check-B only -> exit 3
    mk_repo "$r3" "mand-ok"
    printf -- '---\npaths:\n  - "R/**"\n---\n# scoped mandatory\n' > "$r3/.claude/rules/mand-ok.md"
    audit "$r3/.claude/rules" >/dev/null && rc3=0 || rc3=$?
    check_eq "check-B-only exit code" "$rc3" "3"

    r4="$tmp/repo4"  # check-C only -> exit 3
    mk_repo "$r4" "mand-missing"
    audit "$r4/.claude/rules" >/dev/null && rc4=0 || rc4=$?
    check_eq "check-C-only exit code" "$rc4" "3"

    r5="$tmp/repo5"  # clean -> exit 0
    mk_repo "$r5" "mand-ok"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r5/.claude/rules/mand-ok.md"
    printf -- '---\npaths:\n  - "R/**"\n---\n# scoped\n' > "$r5/.claude/rules/nonmand-scoped.md"
    audit "$r5/.claude/rules" >/dev/null && rc5=0 || rc5=$?
    check_eq "clean exit code" "$rc5" "0"

    # --- Fallback path: no CLAUDE.md/AGENTS.md at all ---
    r6="$tmp/repo6"
    mkdir -p "$r6/.claude/rules"
    printf -- '---\ndescription: x\n---\n# bash-safety\n' > "$r6/.claude/rules/bash-safety.md"
    warn="$(resolve_mandatory_list "$r6/.claude/rules" 2>&1 >/dev/null || true)"
    c="$(printf '%s\n' "$warn" | grep -c 'WARN: could not parse' || true)"
    check_eq "fallback prints WARN when no doc source found" "$c" "1"

    # --- Safety-critical tier (llm#943): same B/C contract as mandatory ---
    r7="$tmp/repo7"  # SC-tier rule scoped -> exit 3, SAFETY-CRITICAL-BUT-SCOPED
    mk_repo "$r7" "mand-ok" "sc-scoped"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r7/.claude/rules/mand-ok.md"
    printf -- '---\npaths:\n  - "R/**"\n---\n# safety-critical but scoped\n' > "$r7/.claude/rules/sc-scoped.md"
    out7="$(audit "$r7/.claude/rules")" && rc7=0 || rc7=$?
    check_eq "SC-tier scoped -> exit 3" "$rc7" "3"
    c="$(printf '%s\n' "$out7" | grep -c 'SAFETY-CRITICAL-BUT-SCOPED: sc-scoped' || true)"
    check_eq "SC-tier scoped flagged SAFETY-CRITICAL-BUT-SCOPED" "$c" "1"

    r8="$tmp/repo8"  # SC-tier rule absent -> exit 3, SAFETY-CRITICAL-BUT-ABSENT
    mk_repo "$r8" "mand-ok" "sc-missing"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r8/.claude/rules/mand-ok.md"
    out8="$(audit "$r8/.claude/rules")" && rc8=0 || rc8=$?
    check_eq "SC-tier absent -> exit 3" "$rc8" "3"
    c="$(printf '%s\n' "$out8" | grep -c 'SAFETY-CRITICAL-BUT-ABSENT: sc-missing' || true)"
    check_eq "SC-tier absent flagged SAFETY-CRITICAL-BUT-ABSENT" "$c" "1"

    r9="$tmp/repo9"  # SC-tier rule correctly unscoped -> clean, not mentioned
    mk_repo "$r9" "mand-ok" "sc-ok"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r9/.claude/rules/mand-ok.md"
    printf -- '# safety-critical, correctly unscoped\nbody\n' > "$r9/.claude/rules/sc-ok.md"
    out9="$(audit "$r9/.claude/rules")" && rc9=0 || rc9=$?
    check_eq "SC-tier correctly unscoped -> exit 0" "$rc9" "0"
    c="$(printf '%s\n' "$out9" | grep -c 'sc-ok' || true)"
    check_eq "SC-tier correctly unscoped NOT mentioned" "$c" "0"

    r10="$tmp/repo10"  # doc exists, no SC line -> empty list, no WARN, no false ABSENT
    mk_repo "$r10" "mand-ok"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r10/.claude/rules/mand-ok.md"
    sc_out="$(resolve_safety_critical_list "$r10/.claude/rules" 2>&1 >/dev/null || true)"
    check_eq "doc exists, no SC line -> resolve_safety_critical_list silent (no WARN)" "$sc_out" ""
    audit "$r10/.claude/rules" >/dev/null && rc10=0 || rc10=$?
    check_eq "doc exists, no SC line -> audit still clean (no phantom ABSENT)" "$rc10" "0"

    r11="$tmp/repo11"  # neither doc exists -> SC fallback WARN fires
    mkdir -p "$r11/.claude/rules"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r11/.claude/rules/credential-management.md"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r11/.claude/rules/external-code-zero-trust.md"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r11/.claude/rules/permission-discipline.md"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r11/.claude/rules/destructive-ops-guard.md"
    warn_sc="$(resolve_safety_critical_list "$r11/.claude/rules" 2>&1 >/dev/null || true)"
    c="$(printf '%s\n' "$warn_sc" | grep -c 'WARN: could not find' || true)"
    check_eq "neither doc exists -> SC fallback prints WARN" "$c" "1"

    # --- Content heuristic (check D): advisory only, never blocks ---
    r12="$tmp/repo12"
    mk_repo "$r12" "mand-ok"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r12/.claude/rules/mand-ok.md"
    {
        echo "---"
        echo 'paths:'
        echo '  - "R/**"'
        echo "---"
        echo "# high-risk rule, no justification"
        i=0
        while [ "$i" -lt 16 ]; do
            echo "This line mentions a secret credential token on its own line $i."
            i=$((i + 1))
        done
    } > "$r12/.claude/rules/high-risk-unjustified.md"
    out12="$(audit "$r12/.claude/rules")" && rc12=0 || rc12=$?
    check_eq "content heuristic alone never blocks (exit stays 0)" "$rc12" "0"
    c="$(printf '%s\n' "$out12" | grep -c 'ADVISORY-HIGH-RISK-UNJUSTIFIED: high-risk-unjustified' || true)"
    check_eq "content heuristic flags dense unjustified rule" "$c" "1"

    r13="$tmp/repo13"  # same density, but with scoping-justification -> no advisory
    mk_repo "$r13" "mand-ok"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r13/.claude/rules/mand-ok.md"
    {
        echo "---"
        echo "scoping-justification: enforced by a PreToolUse hook, not advisory-dependent"
        echo 'paths:'
        echo '  - "R/**"'
        echo "---"
        echo "# high-risk rule, justified"
        i=0
        while [ "$i" -lt 16 ]; do
            echo "This line mentions a secret credential token on its own line $i."
            i=$((i + 1))
        done
    } > "$r13/.claude/rules/high-risk-justified.md"
    out13="$(audit "$r13/.claude/rules")"
    c="$(printf '%s\n' "$out13" | grep -c 'ADVISORY-HIGH-RISK-UNJUSTIFIED: high-risk-justified' || true)"
    check_eq "content heuristic silent when scoping-justification present" "$c" "0"

    # --- Companions (llm#1140 follow-up): check A now covers _companions/ ---
    r14="$tmp/repo14"
    mk_repo "$r14" "mand-ok"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r14/.claude/rules/mand-ok.md"
    mkdir -p "$r14/.claude/rules/_companions"
    printf -- '# unscoped companion\nbody\n' > "$r14/.claude/rules/_companions/comp-unscoped.md"
    printf -- '---\npaths:\n  - ".claude/rules/mand-ok.md"\n---\n# scoped companion\nbody\n' \
        > "$r14/.claude/rules/_companions/comp-scoped.md"
    out14="$(audit "$r14/.claude/rules")" && rc14=0 || rc14=$?
    check_eq "unscoped companion -> exit 1 (context bloat, not blocking)" "$rc14" "1"
    c="$(printf '%s\n' "$out14" | grep -c 'UNSCOPED: _companions/comp-unscoped.md' || true)"
    check_eq "unscoped companion flagged UNSCOPED" "$c" "1"
    c="$(printf '%s\n' "$out14" | grep -c 'comp-scoped' || true)"
    check_eq "scoped companion (correctly configured) NOT mentioned" "$c" "0"

    # --- Check E: --budget (always-loaded instruction budget) ---
    # Thresholds are shrunk via env so tiny fixtures can cross them:
    # WARN > 2000, OVER > 4000 chars.
    chars() { head -c "$1" /dev/zero | tr '\0' 'a'; }
    fsize() { wc -c < "$1" | tr -d ' '; }
    bud() { # bud <home> [budget_report args...]   (W/L override thresholds)
        local h="$1"; shift
        RULE_BUDGET_HOME="$h" RULE_BUDGET_DOCS="$h/docs_gh" \
            RULE_BUDGET_WARN="${W:-2000}" RULE_BUDGET_LIMIT="${L:-4000}" budget_report "$@"
    }
    EXCL_WT='["**/worktrees/**/.claude/rules/**"]'
    mk_budget_fx() { # mk_budget_fx <home> [claudeMdExcludes-json] — GLOBAL = AGENTS 300 + always-a 600 + star
        local h="$1" d="$1/docs_gh"
        mkdir -p "$d/llm/.claude/rules" "$h/.claude" "$d/pA/.claude"
        chars 300 > "$d/llm/AGENTS.md"
        chars 600 > "$d/llm/.claude/rules/always-a.md"
        { printf -- '---\npaths: ["**"]\n---\n'; chars 378; } > "$d/llm/.claude/rules/star.md"
        { printf -- '---\npaths:\n  - "R/**"\n---\n'; chars 5000; } > "$d/llm/.claude/rules/scoped.md"
        ln -s "$d/llm/AGENTS.md" "$h/.claude/CLAUDE.md"
        ln -s "$d/llm/.claude/rules" "$h/.claude/rules"
        chars 100 > "$d/pA/.claude/CLAUDE.md"
        if [ -n "${2:-}" ]; then printf '{"claudeMdExcludes": %s}\n' "$2" > "$h/.claude/settings.json"; fi
    }
    mk_project() { # mk_project <home> <name> <chars> — adds a project with one CLAUDE.md of that size
        mkdir -p "$1/docs_gh/$2/.claude"
        chars "$3" > "$1/docs_gh/$2/.claude/CLAUDE.md"
    }

    b1="$tmp/b1"; mk_budget_fx "$b1" "$EXCL_WT"
    expect_global=$(( $(fsize "$b1/docs_gh/llm/AGENTS.md") + $(fsize "$b1/docs_gh/llm/.claude/rules/always-a.md") + $(fsize "$b1/docs_gh/llm/.claude/rules/star.md") ))
    out="$(bud "$b1")" && rc=0 || rc=$?
    check_eq "budget: everything under WARN -> exit 0" "$rc" "0"
    c="$(printf '%s\n' "$out" | grep -c "^RULE-BUDGET-OK: GLOBAL $expect_global chars" || true)"
    check_eq "budget: GLOBAL line always printed; paths:[\"**\"] counted, paths:[R/**] not" "$c" "1"
    c="$(printf '%s\n' "$out" | grep -c 'RULE-BUDGET-WARN\|RULE-BUDGET-OVER' || true)"
    check_eq "budget: nothing over WARN -> no WARN/OVER lines" "$c" "0"
    c="$(printf '%s\n' "$out" | grep -c '^RULE-BUDGET-SUMMARY' || true)"
    check_eq "budget: one SUMMARY line" "$c" "1"

    b2="$tmp/b2"; mk_budget_fx "$b2"   # no claudeMdExcludes -> llm worktree double-counts llm's rules
    out="$(bud "$b2")" && rc=0 || rc=$?
    check_eq "budget: worktree double-count without claudeMdExcludes -> exit 1" "$rc" "1"
    c="$(printf '%s\n' "$out" | grep -c '^RULE-BUDGET-WARN: llm worktree' || true)"
    check_eq "budget: llm worktree variant flagged WARN when not excluded" "$c" "1"
    c="$(printf '%s\n' "$out" | grep -c '^RULE-BUDGET-OK: GLOBAL' || true)"
    check_eq "budget: GLOBAL itself still under WARN" "$c" "1"
    # b1 (same fixture + claudeMdExcludes) already proved the pattern removes the double-count.

    b3="$tmp/b3"; mk_budget_fx "$b3" "$EXCL_WT"; mk_project "$b3" pB 900
    out="$(bud "$b3")" && rc=0 || rc=$?
    check_eq "budget: one project over WARN -> exit 1" "$rc" "1"
    c="$(printf '%s\n' "$out" | grep -c '^RULE-BUDGET-WARN: pB ' || true)"
    check_eq "budget: pB line printed" "$c" "1"
    c="$(printf '%s\n' "$out" | grep -c 'pA ' || true)"
    check_eq "budget: pA (under WARN) not printed" "$c" "0"

    b4="$tmp/b4"; mk_budget_fx "$b4" "$EXCL_WT"; mk_project "$b4" pB 900; mk_project "$b4" pC 3000
    out="$(bud "$b4")" && rc=0 || rc=$?
    check_eq "budget: one project over LIMIT -> exit 4" "$rc" "4"
    c="$(printf '%s\n' "$out" | grep -c '^RULE-BUDGET-OVER: pC ' || true)"
    check_eq "budget: pC flagged OVER" "$c" "1"
    out="$(bud "$b4" --only "$b4/docs_gh/pA")" && rc=0 || rc=$?
    check_eq "budget: --only a clean project ignores other projects' overruns -> exit 0" "$rc" "0"
    out="$(bud "$b4" --only "$b4/docs_gh/pC")" && rc=0 || rc=$?
    check_eq "budget: --only the over-limit project -> exit 4" "$rc" "4"

    b5="$tmp/b5"; mk_budget_fx "$b5" "$EXCL_WT"
    printf '\n@extra.md\n' >> "$b5/docs_gh/pA/.claude/CLAUDE.md"
    chars 500 > "$b5/docs_gh/pA/.claude/extra.md"
    out="$(W=1500 bud "$b5")" && rc=0 || rc=$?
    c="$(printf '%s\n' "$out" | grep -c '^RULE-BUDGET-WARN: pA ' || true)"
    check_eq "budget: an @import pushes pA over WARN (1300+100+500 > 1500)" "$c" "1"

    b6="$tmp/b6"; mk_budget_fx "$b6" "$EXCL_WT"; rm "$b6/.claude/CLAUDE.md"
    out="$(bud "$b6")" && rc=0 || rc=$?
    check_eq "budget: unresolvable ~/.claude/CLAUDE.md -> exit 3 (indeterminate)" "$rc" "3"
    c="$(printf '%s\n' "$out" | grep -c '^RULE-BUDGET-INDETERMINATE' || true)"
    check_eq "budget: indeterminate says so" "$c" "1"

    b7="$tmp/b7"; mk_budget_fx "$b7" "$EXCL_WT"; printf '{ not json' > "$b7/.claude/settings.json"
    out="$(bud "$b7")" && rc=0 || rc=$?
    check_eq "budget: unparseable settings.json -> exit 3 (not silently no-excludes)" "$rc" "3"

    echo "selftest: ${pass}/${total} PASS"
    [ "$pass" -eq "$total" ]
    exit
fi

RULES_DIR="${1:-/Users/johngavin/docs_gh/llm/.claude/rules}"
if [ ! -d "$RULES_DIR" ]; then
    echo "check_rule_scoping: rules dir not found: $RULES_DIR" >&2
    exit 2
fi
rc=0
audit "$RULES_DIR" || rc=$?
if [ "$rc" -eq 0 ]; then
    echo "rule-scoping: OK — all non-tier rules carry paths: frontmatter; all mandatory/safety-critical rules load unconditionally"
fi
exit "$rc"
