#!/usr/bin/env bash
# private_data_scan.sh — aggressive, auto-triggered PII-exposure scanner.
#
# Why this exists (not a rule, not a memory note): a personal phone number
# sat in this PUBLIC repo, in 8 files, across 9 commits, for four months.
# Every existing control was advisory or model-dependent, and every one of
# them failed:
#   - .md rules forbidding PII in public repos were read and ignored under
#     pressure (a PR containing the number was merged anyway).
#   - llm#946 named this exact risk as an open issue; it blocked nothing.
#   - An agent's own PII self-check swept for *billing* keywords, never a
#     phone number, and reported "clean" -- truthfully, for what it checked.
#   - A careful manual check existed but ran on a DIFFERENT PR than the one
#     that mattered.
#   - secret_exposure_scan.sh detects CREDENTIALS, not PII -- no phone
#     pattern exists in it, by design (see "Relationship to
#     secret_exposure_scan.sh" below).
#
# This script is deterministic code, invoked by hooks that do not depend on
# anyone remembering to run it: pre-commit, pre-push, CI (PR gate), and a
# scheduled full-history audit. See .claude/rules/private-data-scanning.md
# for the enforcement architecture (installers, CI workflow, launchd plist)
# -- that rule is DOCUMENTATION; this script and its callers are the
# enforcement.
#
# ─── Relationship to secret_exposure_scan.sh (deliberately BESIDE it, not
# inside it) ──────────────────────────────────────────────────────────────
# secret_exposure_scan.sh detects CREDENTIALS via shape+entropy: a real API
# key/token is high-entropy by construction (CRED_ENTROPY_THRESHOLD=3.0
# bits/char), and its variable NAME follows KEY/TOKEN/SECRET conventions.
# PII is the opposite shape: a phone number, postcode, or IBAN is highly
# STRUCTURED and LOW entropy (digits in fixed groupings) -- entropy would
# never fire on it, and there is no "PII_KEY_NAME=value" convention to
# anchor a name-based heuristic. The two detector families are disjoint by
# construction; forcing them into one file/one heuristic would degrade both
# (a phone-number-tuned entropy floor would either miss real credentials or
# flag every date/ID as PII). There is also no safe automatic --fix for a
# phone number baked into history the way `chmod 600` is a safe automatic
# fix for a world-readable dotfile -- remediation here is always human
# judgement (git filter-repo / orphan-squash), so the --fix machinery does
# not transfer either. Nothing is duplicated: this file defines zero
# credential-shaped patterns and imports none from
# .claude/hooks/lib/cred_patterns.py; the two scanners run "beside" each
# other -- same directory, same housekeeping_runs heartbeat convention (see
# hk_run_start/hk_run_end below, and the private_data_scan_findings table
# added alongside secret_scan_findings in housekeeping_schema_init.sql),
# same --json/--quiet/--selftest flag conventions -- but are logically
# independent scanners over disjoint pattern sets.
#
# ─── Relationship to repo_visibility_guard.sh (JohnGavin/llm#976) ─────────
# repo_visibility_guard.sh is a ONE-TIME GATE at the moment a repo becomes
# public: it blocks `gh repo create --public` / `gh repo edit --visibility
# public` pending a manual `git log --all -p` history audit. This script
# solves the DIFFERENT, ongoing problem: the repo is ALREADY public, and new
# PII must never enter it via a future commit/push/PR. The two are
# complementary, not competing -- #976 is the one-time visibility gate,
# this is the continuous commit/push/PR/scheduled-audit gate. Neither
# duplicates the other's pattern set on purpose: repo_visibility_guard.sh's
# PRIVACY_ERE (home paths, ~/Downloads, Time Machine, tmutil, "irreplaceable",
# email) targets MACHINE-RECONNAISSANCE disclosure; this script's patterns
# (E.164 phone, UK postcode, IBAN, plus an exact-value denylist) target
# PERSONAL-IDENTIFIER disclosure -- the shape that actually leaked. Where
# both scripts touch git history text, both now pass --no-ext-diff (see
# "THE NON-NEGOTIABLE REQUIREMENT" below) -- repo_visibility_guard.sh was
# patched in the same change that added this file.
#
# ─── THE NON-NEGOTIABLE REQUIREMENT: self-check before trusting "clean" ───
# This repo configures difftastic as git's external diff driver
# (diff.external = "difft --display inline", both globally and per-repo).
# `git diff | grep '^+'` is therefore VACUOUS -- difftastic's structural,
# side-by-side output carries no `+`/`-` line prefixes, so the grep matches
# nothing REGARDLESS OF CONTENT and reports clean (JohnGavin/llm#997). A PII
# check is exactly the kind of check written ad-hoc, at the moment
# reassurance is wanted, using `git diff | grep`.
#
# This script is structurally immune to that specific failure: it NEVER
# calls `git diff`/`git log -p`/`git show <commit>` for CONTENT. Every
# content read goes through `git cat-file -p "<tree-ish>:<path>"` (a direct
# blob read -- no diff machinery, no external diff driver, ever invoked).
# The only diff-family calls that remain are NAME enumeration
# (`git diff --cached --name-only`, `git diff-tree --name-only -r`), which
# issue #997 itself confirmed is safe (`--name-only` does not invoke
# textconv/the external diff driver) -- and even those pass --no-ext-diff
# defensively, belt-and-braces, per the issue's own recommendation.
#
# Beyond the structural fix, EVERY invocation of this script (every mode,
# unconditionally, not skippable by any flag) runs assert_can_detect() FIRST
# -- an in-process runtime assertion that feeds a known-bad synthetic
# fixture through the real detector functions and requires a hit. If the
# detector cannot detect its own known-bad fixture, the script aborts with a
# non-zero exit BEFORE scanning anything real. "Clean" is never reported by
# a detector that has not just proven, in this run, it is capable of
# reporting "dirty". See assert_can_detect() below.
#
# ─── Deny-list source: a DEDICATED file, not a direct read of secrets.env ──
# The deny-list lives at ~/.config/private_values.env (KEY=value, mode 600),
# NOT ~/.config/secrets.env, for three reasons:
#   1. Blast radius: secrets.env holds live credentials (API keys, tokens)
#      consumed by many other scripts for operational use (dialling out,
#      launching daemons). Giving this scanner direct read access to
#      secrets.env means every future bug/log-leak in the scanner exposes
#      ALL secrets, not just the handful of PII literals it actually needs.
#   2. Schema coupling: secrets.env's format/contents are owned by a
#      different subsystem (with-secrets, render_signal_launchd_plists.sh)
#      with a different lifecycle (rotation). Coupling this scanner's
#      correctness to that schema means an unrelated secrets.env change can
#      silently break PII detection.
#   3. Wrong shape for the job: most of secrets.env is high-entropy
#      credentials -- exactly what looks_like_credential_value() in
#      secret_exposure_scan.sh is tuned to flag, and exactly what this
#      script must NOT redundantly re-detect (see "beside it, not inside
#      it" above). A deny-list scoped ONLY to "literal values that must
#      never appear" (phone numbers, addresses, personal emails) keeps the
#      two scanners' inputs as disjoint as their pattern sets.
# private_values_sync.sh (delivered alongside this script) extracts named
# keys (e.g. SIGNAL_ACCOUNT, the value llm#946 flagged as embedding a phone
# number) FROM secrets.env INTO private_values.env, so secrets.env stays the
# single source of truth for that value while this scanner gets a narrow,
# independently-permissioned, purpose-built file. This script only ever
# READS private_values.env; it never writes to it.
#
# ─── Fail-closed (deliberate divergence from this repo's usual fail-open
# hook convention) ──────────────────────────────────────────────────────
# secret_leak_guard.sh, repo_visibility_guard.sh, and every other PreToolUse
# guard in this repo fail OPEN on internal error ("a broken guard must never
# wedge a session"). This script fails CLOSED: a missing/unreadable
# deny-list (when required), an internal scanner error, or a failed
# self-check all exit non-zero -- BLOCK, not allow. The two conventions are
# not in tension: PreToolUse guards protect an interactive session where
# wedging the agent has its own cost; this script protects a PUBLISH
# boundary (commit -> push -> merge -> live on a public repo) where the cost
# of a silent false "clean" is a permanent, indexable disclosure. A blocked
# commit is recoverable (fix the error, retry, or use the documented
# bypass); a merged PII leak is not. Local hooks (pre-commit/pre-push) and
# the scheduled full-history audit run with --require-denylist (the
# default) and fail closed if ~/.config/private_values.env is missing,
# unreadable, or empty. CI runs with --no-denylist BY DESIGN (a public
# repo's Actions runner must never be handed personal PII literals, even as
# a masked secret, without an explicit opt-in the user configures
# themselves -- see private-data-scanning.md's CI section) and is NOT a
# fail-closed violation: it is a documented, narrower guarantee (generic
# pattern coverage only), never silently presented as the full guarantee.
#
# Usage:
#   private_data_scan.sh --staged [--require-denylist|--no-denylist] [--json] [--quiet]
#   private_data_scan.sh --range <rev1> <rev2> [--max-commits N] [--require-denylist|--no-denylist] [--json] [--quiet]
#   private_data_scan.sh --paths <file...> [--require-denylist|--no-denylist] [--json] [--quiet]
#   private_data_scan.sh --full-history [--max-commits N] [--json] [--quiet]
#   private_data_scan.sh --content-stdin <location-label> [--no-denylist]
#   private_data_scan.sh --selftest
#
# --max-commits: OPTIONAL, both --full-history and --range. When OMITTED
# (the default), every reachable commit is scanned -- no cap. Pass it only
# to deliberately bound cost (e.g. an interactive spot-check); doing so makes
# the run's "clean" result INDETERMINATE whenever it actually truncates
# before covering every reachable commit (see exit codes below). Prior to
# JohnGavin/llm#1204, --full-history silently defaulted to a fixed 2000-commit
# cap: `git rev-list --all`'s enumeration order is not a stable sort
# guarantee, so which ~2000 of a larger reachable set got scanned varied
# run to run, producing non-deterministic finding counts on an identical
# repo state. The fix is this file's default-unlimited behaviour, not
# private_data_history_audit.sh (which only ever calls this scanner and
# propagates its exit code -- see that file's header).
#
# Exit codes: 0 = clean (every reachable/in-range commit was scanned and
# none had findings), 1 = findings present (or a fail-closed error), 2 =
# usage error, 3 = INDETERMINATE -- an explicit --max-commits truncated a
# --full-history or --range scan before it covered every reachable commit,
# and nothing was found in the subset that WAS scanned. Absence of findings
# in a truncated scan is NOT proof of a clean history/range; re-run without
# --max-commits (or with a higher value) for a determinate result.
#
# NOTE on exit 1: it is OVERLOADED by design. Pre-commit/pre-push/CI treat any
# non-zero as "block", so a fail-closed internal error (missing deny-list,
# failed self-check) also exits 1. A caller that must tell "findings" from
# "scanner broke" (private_data_history_audit.sh) uses --tsv and requires the
# 'private-data-scan: N finding(s)' summary line: exit 1 WITHOUT it is an
# error, not a finding.
#
# Log: ~/.claude/logs/private_data_scan.log (one line per invocation summary).
# Housekeeping heartbeat: writes housekeeping_runs (task='private_data_scan')
# and private_data_scan_findings, same batched-write pattern as
# secret_exposure_scan.sh's write_findings_to_db -- see hk_run_start below.
#
# Origin: 2026-08-22 incident (personal phone number, 8 files, 9 commits,
# 4 months exposed on a public repo). Companion: JohnGavin/llm#946, #976,
# #997.

set -uo pipefail
# Deliberately NOT `set -e`: individual grep non-matches (exit 1) are
# expected control flow throughout this script, not errors.

# ---------------------------------------------------------------------------
# grep/sed binary pinning (llm#976's phi-scan-hook.sh fix, same rationale)
# ---------------------------------------------------------------------------
# ugrep (frequently first on PATH on this machine) does not reliably honour
# \b word boundaries in -E mode -- a check built on \b silently never
# matches anything under ugrep and reports false-clean. Pin to the system
# grep, which is guaranteed present on macOS and supports \b correctly.
GREP="${PRIVATE_DATA_SCAN_GREP:-/usr/bin/grep}"
[ -x "$GREP" ] || GREP="grep"   # fail soft on non-macOS / grep relocated

HOME_DIR="${HOME:-/Users/johngavin}"
LOG_DIR="${HOME_DIR}/.claude/logs"
LOG_FILE="${LOG_DIR}/private_data_scan.log"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DENYLIST_FILE="${PRIVATE_VALUES_FILE:-${HOME_DIR}/.config/private_values.env}"
UNIFIED_DB="${UNIFIED_DB_PATH:-${HOME_DIR}/.claude/logs/unified.duckdb}"

# ---------------------------------------------------------------------------
# Generic PII pattern set. Deliberately disjoint from CRED_PATTERNS
# (.claude/hooks/lib/cred_patterns.py) -- see header comment.
# UK postcode pattern is intentionally the SAME shape already battle-tested
# in phi-scan-hook.sh / phi_scan.sh (reused for consistency, not forked
# credential logic -- this is the PII domain those files already cover;
# E.164 and IBAN are the gap this script closes).
# ---------------------------------------------------------------------------
# E.164: leading '+', country code digit 1-9, 8-15 digits total, not
# preceded by another digit/plus (avoids matching inside a longer numeric
# run), \b after (grep -E, system grep honours \b -- see pinning above).
RE_E164='(^|[^0-9])\+[1-9][0-9]{7,14}\b'
# UK postcode, full format (e.g. SW1A 2AA, EC2Y 8NH) -- same shape as
# phi-scan-hook.sh's existing pattern.
RE_UK_POSTCODE='\b[A-Za-z]{1,2}[0-9][0-9A-Za-z]?[[:space:]]?[0-9][A-Za-z]{2}\b'
# IBAN: 2 letters (country) + 2 digits (check) + up to 30 alphanumerics.
RE_IBAN='\b[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\b'

# name → pattern → severity, in one array trio (parallel arrays keep this
# bash-3-compatible -- no associative arrays).
PII_RULE_NAMES=(e164-phone uk-postcode iban)
PII_RULE_PATTERNS=("$RE_E164" "$RE_UK_POSTCODE" "$RE_IBAN")
PII_RULE_SEVERITY=(critical high high)
PII_RULE_CI=(0 1 0)   # 1 = case-insensitive (-i)

# Reserved / never-assignable phone ranges -- numbers that CANNOT belong to a
# real person, so flagging them is always a false positive.
#
# WHY THIS LIST GREW (llm#1004 follow-up, 2026-08-27)
# --------------------------------------------------
# The original single pattern covered only NPA-555-01XX, i.e. 555 as the
# EXCHANGE. It missed 555 as the AREA CODE (+1555XXXXXXX) -- the older and more
# common fictional convention, and the one this repo's own Signal test fixtures
# actually use. Consequence: private_data_scan.sh blocked commits with 12
# "critical e164-phone" findings across 4 already-committed test files, all of
# them the same fictional number. The scanner's guidance in that state is
# "sanctioned override: git commit --no-verify", so a false positive on a
# SAFETY-CRITICAL gate trains the operator to bypass it. That is a worse
# outcome than the narrow pattern was protecting against -- a gate people
# routinely skip is not a gate.
#
# TRADE-OFF, stated rather than assumed: every range added here is a range the
# scanner will never flag again. That is acceptable ONLY because each is
# reserved by its national regulator and can never be issued to a subscriber,
# so no real person's number can fall inside one. Do NOT add a range merely
# because a fixture happens to use it -- add it only if the regulator reserves
# it. Anything else belongs in the marker-based looks_like_fixture_context()
# path, which requires an explicit EXAMPLE/FAKE/DUMMY/TEST/FIXTURE word.
#
#   NANP  555-01XX in any area code   FCC-reserved for fiction
#   NANP  area code 555               never assignable
#   UK    07700 900000-900999         Ofcom drama range (mobile)
#   UK    020 7946 0000-0999          Ofcom drama range (London)
#   UK    01632 960000-960999         Ofcom drama range (national)
RE_E164_FICTIONAL='^\+1[0-9]{3}55501[0-9]{2}$|^\+1555[0-9]{7}$|^\+447700900[0-9]{3}$|^\+442079460[0-9]{3}$|^\+441632960[0-9]{3}$'

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
MODE=""
JSON=0
TSV=0
QUIET=0
REQUIRE_DENYLIST=1
MAX_COMMITS=2000
MAX_COMMITS_EXPLICIT=0   # 1 only when the user passes --max-commits; default is unlimited (llm#1204)
RANGE_A=""
RANGE_B=""
PATHS_ARGS=()
CONTENT_LABEL=""

# Coverage/determinism tracking for --full-history and --range (llm#1204).
# Set by scan_full_history()/scan_range(); left at these defaults (and
# therefore invisible to print_coverage_line/the exit-3 check below) for
# every other mode, which has no "reachable commit set" concept.
_SCAN_TRUNCATED=0
_SCAN_SCANNED=0
_SCAN_TOTAL_REACHABLE=""

usage() {
    cat <<'EOF'
Usage: private_data_scan.sh MODE [options]
  --staged                    Scan git INDEX content of staged files
  --range <rev1> <rev2> [--max-commits N]
                               (rev1 may be --not-remotes[=<glob>]: every commit
                               reachable from rev2 on no remote-tracking ref;
                               used by the global pre-push for new branches)
                               Scan full blob content of every file changed
                               in every commit in rev1..rev2 (default:
                               unlimited; same --max-commits/exit-3 semantics
                               as --full-history)
  --paths <file...>           Scan given on-disk files directly
  --full-history [--max-commits N]
                               Scan every blob changed across all reachable
                               history (default: unlimited -- every reachable
                               commit; pass --max-commits N to cap for cost
                               control, which makes a clean truncated run
                               exit 3/INDETERMINATE rather than 0)
  --content-stdin <label>     Scan stdin content (used by editor-time hooks)
  --selftest                  Run the fixture-based self-test suite
Options: --require-denylist (default) | --no-denylist, --json, --quiet,
         --tsv (machine-readable: after the summary line, one
         'FINDING<TAB>src<TAB>sev<TAB>loc<TAB>line<TAB>rule<TAB>note' row per
         finding; used by private_data_history_audit.sh)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --staged) MODE="staged"; shift ;;
        --range) MODE="range"; shift; RANGE_A="${1:-}"; shift || true; RANGE_B="${1:-}"; shift || true ;;
        --paths)
            MODE="paths"; shift
            while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do PATHS_ARGS+=("$1"); shift; done
            ;;
        --full-history) MODE="full-history"; shift ;;
        --content-stdin) MODE="content-stdin"; shift; CONTENT_LABEL="${1:-stdin}"; shift || true ;;
        --selftest) MODE="selftest"; shift ;;
        --max-commits) shift; MAX_COMMITS="${1:-2000}"; MAX_COMMITS_EXPLICIT=1; shift || true ;;
        --require-denylist) REQUIRE_DENYLIST=1; shift ;;
        --no-denylist) REQUIRE_DENYLIST=0; shift ;;
        --json) JSON=1; shift ;;
        --tsv) TSV=1; shift ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "private_data_scan: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$MODE" ]; then
    usage >&2
    exit 2
fi

FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/private_data_scan.XXXXXX")"
# INDET_FILE: one line per file whose content could NOT be fully inspected
# (llm#1358: document text could not be extracted). A file, not a variable,
# because scan_blob runs as the last element of a pipeline (a subshell).
INDET_FILE="$(mktemp "${TMPDIR:-/tmp}/private_data_scan_indet.XXXXXX")"
trap 'rm -f "$FINDINGS_FILE" "$INDET_FILE"' EXIT

# append_finding SOURCE SEVERITY LOCATION LINE RULE NOTE
# NOTE must be fixed/generic -- NEVER the matched value. This is the single
# choke point guaranteeing the no-leaked-value contract.
append_finding() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$FINDINGS_FILE"
}

log_line() {
    { mkdir -p "$LOG_DIR" 2>/dev/null
      printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$1" >> "$LOG_FILE"
    } 2>/dev/null || true
}

file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null || echo ""; }

# ---------------------------------------------------------------------------
# Fixture-context exemption (generic-pattern detectors ONLY -- never applied
# to a deny-list hit; a real leaked value with "TEST" written nearby is
# still a real leak). Same EXAMPLE/FAKE/DUMMY/TEST/FIXTURE convention as
# secret_exposure_scan.sh's looks_like_fixture_value(), reimplemented (not
# imported) because it gates a different match set (PII lines, not
# credential-assignment lines) -- see header "beside it, not inside it".
# ---------------------------------------------------------------------------
looks_like_fixture_context() {
    printf '%s' "$1" | LC_ALL=C "$GREP" -qiE 'EXAMPLE|FAKE|DUMMY|TEST|FIXTURE'
}

is_e164_fictional() {
    printf '%s' "$1" | "$GREP" -qE "$RE_E164_FICTIONAL"
}

# ---------------------------------------------------------------------------
# Git short-SHA collision guard -- uk-postcode ONLY (see rationale below).
# ---------------------------------------------------------------------------
# RE_UK_POSTCODE is matched case-insensitively (PII_RULE_CI[uk-postcode]=1),
# so it also matches a bare git abbreviated SHA whenever the SHA happens to
# be composed entirely of hex letters, e.g. ca7f8fd (2 letters + digit +
# alnum + digit + 2 letters -- the exact postcode shape). Naively rejecting
# every all-hex candidate is WRONG: EC1A 1BB is a real London postcode and is
# ALSO all-hex (E,C,1,A,1,B,B are all valid hex characters) -- rejecting
# all-hex would create a false NEGATIVE on real postcodes, which is the wrong
# direction for a privacy gate (a missed leak costs more than a blocked
# commit -- see "prefer the false positive" in this script's task history).
#
# The three signals that together are unique to a git short SHA -- and that
# a conventionally-written postcode never carries all at once -- are:
#   1. every character is a valid hex digit (0-9a-f)
#   2. no whitespace (a real postcode's outward/inward split, even when
#      compacted, is written by a human either WITH the space or in
#      UPPERCASE -- never both stripped AND lowercased in practice)
#   3. every letter is lowercase (git SHAs are always lowercase hex; a real
#      postcode written in prose is conventionally uppercase, e.g. SW1A 1AA,
#      EC1A 1BB -- even a compact, spaceless real postcode like "EC1A1BB"
#      keeps the uppercase convention)
# A single regex captures all three at once: a string matching ^[0-9a-f]+$
# has no uppercase letters (fails #3 otherwise), no non-hex letters (fails
# #1 otherwise), and no whitespace (whitespace is not in the class, so any
# match with the anchors fails #2 otherwise). Any ONE signal missing means
# the candidate stays flagged:
#   EC1A 1BB  -> has a space + uppercase letters -> STILL FLAGGED
#   SW1A 1AA  -> S,W are not hex characters       -> STILL FLAGGED
#   EC1A1BB   -> uppercase letters                -> STILL FLAGGED
#   ca7f8fd   -> all-hex, no space, all-lowercase -> exempted (SHA-shaped)
#
# Known accepted gap: a real postcode written BOTH spaceless AND lowercase
# (e.g. "ec1a1bb") is indistinguishable from a short SHA by this guard and
# would be exempted. This is deliberately accepted as out of scope: PII
# leaks in this repo's history/prose are addresses copy-pasted or typed by a
# human, and postcodes are conventionally cased/spaced in that context (see
# the module header's origin incident) -- the false-negative surface this
# leaves is narrower than the false-positive surface (every 7-char lowercase
# hex git SHA in CHANGELOG/commit-footer text) it closes.
#
# Scoped to uk-postcode only: e164-phone requires a leading '+' (never
# hex-only) and iban's pattern is case-SENSITIVE on an uppercase country
# code (PII_RULE_CI[iban]=0, RE_IBAN starts '[A-Z]{2}'), so a lowercase git
# SHA can never match either -- this collision is unique to uk-postcode's
# combination of an all-alnum shape with case-insensitive matching.
is_git_sha_like() {
    printf '%s' "$1" | "$GREP" -qE '^[0-9a-f]+$'
}

# ---------------------------------------------------------------------------
# HTML numeric character reference collision guard -- uk-postcode ONLY.
# ---------------------------------------------------------------------------
# RE_UK_POSTCODE also matches inside an HTML hex character reference such as
# &#x1F4CB; (an emoji), because the reference's own syntax -- a leading 'x'
# (hex-radix marker) immediately followed by hex digits -- happens to fit
# the same 1-2-letters + digit + alnum + digit + 2-letters shape as a
# compact UK postcode: x1F4CB -> x(letter) 1(digit) F(alnum) 4(digit)
# CB(2 letters). Found live in
# .claude/scripts/send_roborev_weekly_rollup_email.R: "&#x1F4CB; Weekly
# Rollup" (2026-08-23).
#
# Unlike the git-SHA collision above, this is not a shape ambiguity needing
# a multi-signal heuristic: an HTML numeric character reference's own
# delimiters (&# immediately before the payload, ; immediately after) are
# unambiguous, always present in valid markup, and never appear wrapped
# around a postcode written in prose. So the guard is a literal-context
# check: is the candidate match wrapped in "&#<match>;" on the line it came
# from? If yes, it is the entity's hex payload, not a postcode.
#
# Scoped to uk-postcode only, for the same reason as the SHA guard: e164
# requires a leading '+' and iban requires an uppercase country-code prefix
# -- neither can match a lowercase hex entity payload like "x1f4cb".
is_html_entity_like() {
    local match="$1" line="$2"
    printf '%s' "$line" | "$GREP" -qFi -- "&#${match};"
}

# ---------------------------------------------------------------------------
# CSS hex colour collision guard -- uk-postcode ONLY.
# ---------------------------------------------------------------------------
# RE_UK_POSTCODE also matches the hex digits of a CSS colour literal such as
# #E4E9EF (E,4,E,9,EF = letter + digit + alnum + digit + 2 letters). Found
# live in .claude/reports/capability_registry_template.html ("--ink:#E4E9EF;")
# on PR #1303 (2026-09-30).
#
# Like the HTML entity guard this is a literal-context check, not a shape
# heuristic: the candidate is exempt only when the line contains
# "#<match>" where <match> is ENTIRELY hex digits, is exactly 3, 4, 6 or 8
# digits long (the only valid CSS colour lengths), and is followed by a
# non-alphanumeric character or end of line. Consequences:
#   #E4E9EF;       -> exempt (6 hex digits, bounded)
#   EC1A 1BB       -> not exempt (no '#', contains a space)
#   #EC1A1BB       -> not exempt (7 digits is not a valid colour length)
#   #E4E9EFzz      -> not exempt (not bounded by a non-alnum character)
# The leading '#' is required, so a postcode written without '#' is never
# exempted. Residual accepted gap: a real compact postcode of exactly 6
# characters, all hex, written directly after a '#' (e.g. "#EC1A1B" is not
# a postcode, but "#E11AAB"-style strings can be) would be exempted; human
# written addresses do not put '#' in front of a postcode.
#
# Scoped to uk-postcode only: e164 needs a leading '+' and iban an
# uppercase country-code prefix followed by digits/alnum of different shape.
is_css_hex_colour_like() {
    local match="$1" line="$2"
    case "${#match}" in 3|4|6|8) ;; *) return 1 ;; esac
    printf '%s' "$match" | "$GREP" -qE '^[0-9A-Fa-f]+$' || return 1
    printf '%s' "$line" | "$GREP" -qiE -- "#${match}([^0-9A-Za-z]|\$)"
}

# ---------------------------------------------------------------------------
# Self-reference exemption -- GENERIC-PATTERN DETECTION ONLY, never deny-list.
# ---------------------------------------------------------------------------
# This scanner's own source (and its sibling private_values_sync.sh, whose
# selftest builds synthetic phone-number fixtures) legitimately contains
# PII-SHAPED text that is not a leak: assert_can_detect()'s liveness probe
# (+19998887766) deliberately carries NO EXAMPLE/FIXTURE marker -- adding
# one would exempt it from the very detection it exists to prove (see
# assert_can_detect()'s own comment on this) -- and this file's own
# RE_UK_POSTCODE doc comment cites example postcode shapes the way any
# regex documentation would. Discovered when this scanner's own PR (#1004)
# tripped its own generic detectors scanning its own source (2026-08-22).
#
# The exemption is deliberately narrow:
#   - EXACT relative paths only, listed below -- never a glob or path
#     prefix. A new file does NOT silently inherit this; adding a path
#     here is a one-line, grep-visible, reviewable change, and the list is
#     scanner-source-only (never a data/config file).
#   - GENERIC-PATTERN detection only (scan_generic, called from
#     scan_blob below). Deny-list detection (scan_denylist) is
#     UNCONDITIONALLY applied to every file, including these two -- a
#     real leaked value sitting in this scanner's own source is still
#     caught. See run_selftest's "deny-list still fires inside an
#     exempted file" case, which exists specifically to prove this
#     boundary holds; without that test this exemption would be a hole,
#     not a fix.
#   - assert_can_detect()'s own probe call uses the "SELFCHECK" location
#     label, which matches nothing in this list -- the liveness check
#     itself is never exempted, so this change does not weaken it.
#
# .claude/hooks/phi-scan-hook.sh (a DIFFERENT, pre-existing PII hook that
# arrived via JohnGavin/llm#976, not part of this scanner) is deliberately
# NOT added here -- see private-data-scanning.md's "Self-reference
# exemption scope" section for why it got a doc-comment fix (an EXAMPLE
# marker word) instead: it is not this scanner's own source, and the
# general-purpose marker mechanism already available to any file is the
# more consistent fix for a file this scanner does not own.
SELF_REFERENCE_EXEMPT_FILES=(
    ".claude/scripts/private_data_scan.sh"
    ".claude/scripts/private_values_sync.sh"
)

is_self_reference_exempt() {
    local loc="$1" f
    for f in "${SELF_REFERENCE_EXEMPT_FILES[@]}"; do
        case "$loc" in
            "$f"|*":$f"|*"/$f") return 0 ;;
        esac
    done
    return 1
}

# ---------------------------------------------------------------------------
# Deny-list (exact-value) detection
# ---------------------------------------------------------------------------
DENYLIST_VALUES=()

load_denylist() {
    DENYLIST_VALUES=()
    [ -r "$DENYLIST_FILE" ] || return 1
    local mode
    mode="$(file_mode "$DENYLIST_FILE")"
    case "$mode" in
        600|400) : ;;
        "") : ;;  # couldn't stat -- don't block on a phantom permission finding
        *) echo "WARNING: $DENYLIST_FILE has mode $mode (expected 600/400) -- tighten with: chmod 600 $DENYLIST_FILE" >&2 ;;
    esac
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        line="${line#export }"
        [ "$line" != "${line#*=}" ] || continue
        local val="${line#*=}"
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        [ "${#val}" -ge 6 ] || continue
        DENYLIST_VALUES+=("$val")
    done < "$DENYLIST_FILE"
    [ "${#DENYLIST_VALUES[@]}" -gt 0 ]
}

# scan_denylist LOCATION < content-on-stdin
scan_denylist() {
    local loc="$1" content
    # tr -d strips NUL bytes BEFORE bash's $(...) command substitution ever
    # sees them. $(...) silently truncates its captured value at the first
    # embedded NUL -- a binary file whose format places a NUL byte early
    # (a DuckDB header, most compiled binaries, many image formats)
    # previously got truncated to its leading bytes before this function
    # ever ran, so the remainder of the file was never scanned and the
    # overall result still reported "clean" (JohnGavin/llm#1160). Deleting
    # NUL bytes -- not replacing them with a placeholder -- is deliberate:
    # it keeps the scan NUL-safe end-to-end (nothing downstream can
    # truncate either) and every byte of the file is scanned. Concatenating
    # what were NUL-adjacent bytes can only ever CREATE additional matches,
    # never hide a real one -- consistent with this script's documented
    # "prefer the false positive" posture (see RE_E164_FICTIONAL above).
    #
    # LC_ALL=C (JohnGavin/llm#1358): under a UTF-8 locale (the macOS default)
    # `tr` aborts with "Illegal byte sequence" on any blob that is not valid
    # UTF-8, so the blob read as EMPTY and was never scanned -- the deny-list
    # exact-match check included. The same applies to the grep calls below
    # (BSD grep -F silently fails to match a line containing an invalid
    # byte). Byte filtering and matching are therefore done in the C locale,
    # where every byte is a character.
    content="$(LC_ALL=C tr -d '\000')"
    [ -n "$content" ] || return 0
    [ "${#DENYLIST_VALUES[@]}" -gt 0 ] || return 0
    local v lnum
    for v in "${DENYLIST_VALUES[@]}"; do
        while IFS=: read -r lnum _; do
            [ -n "${lnum:-}" ] || continue
            append_finding "denylist" "critical" "$loc" "$lnum" "known-value" \
                "exact match against a ~/.config/private_values.env entry (value redacted)"
        done < <(printf '%s\n' "$content" | LC_ALL=C "$GREP" -nF -- "$v" 2>/dev/null)
    done
}

# ---------------------------------------------------------------------------
# Generic PII pattern detection
# ---------------------------------------------------------------------------
# scan_generic LOCATION < content-on-stdin
scan_generic() {
    local loc="$1" content
    # See scan_denylist's comment above -- same NUL-truncation fix
    # (JohnGavin/llm#1160), applied here for the same reason: this function
    # also captures its stdin into a bash variable via $(...). LC_ALL=C: see
    # scan_denylist (JohnGavin/llm#1358).
    content="$(LC_ALL=C tr -d '\000')"
    [ -n "$content" ] || return 0
    local i name pat sev ci lnum line match
    for i in "${!PII_RULE_NAMES[@]}"; do
        name="${PII_RULE_NAMES[$i]}"; pat="${PII_RULE_PATTERNS[$i]}"
        sev="${PII_RULE_SEVERITY[$i]}"; ci="${PII_RULE_CI[$i]}"
        local flags="-nE"; [ "$ci" = "1" ] && flags="-niE"
        while IFS=: read -r lnum line; do
            [ -n "${lnum:-}" ] || continue
            looks_like_fixture_context "$line" && continue
            if [ "$name" = "e164-phone" ]; then
                match="$(printf '%s' "$line" | LC_ALL=C "$GREP" -oE '\+[1-9][0-9]{7,14}' | head -1)"
                [ -n "$match" ] && is_e164_fictional "$match" && continue
            fi
            if [ "$name" = "uk-postcode" ]; then
                # Check EVERY match on the line, not just the first -- a
                # line can legitimately carry both an exempt (SHA/HTML
                # entity) hit and a real postcode (e.g. an icon entity
                # earlier in a line whose prose also names a genuine
                # postcode). Skip the line only when ALL matches are exempt.
                local pc_exempt_all=1 pc_match
                while IFS= read -r pc_match; do
                    [ -n "$pc_match" ] || continue
                    if is_git_sha_like "$pc_match" || is_html_entity_like "$pc_match" "$line" \
                        || is_css_hex_colour_like "$pc_match" "$line"; then
                        continue
                    fi
                    pc_exempt_all=0
                    break
                done < <(printf '%s' "$line" | LC_ALL=C "$GREP" -ioE -- "$pat")
                [ "$pc_exempt_all" -eq 1 ] && continue
            fi
            append_finding "generic" "$sev" "$loc" "$lnum" "$name" \
                "PII-shaped value detected (value redacted -- rule: $name)"
        done < <(printf '%s\n' "$content" | LC_ALL=C "$GREP" $flags -- "$pat" 2>/dev/null)
    done
}

# Binary blobs: skip GENERIC shape rules only (never the deny-list).
# uk-postcode / e164-phone / iban are regexes over text shapes. Run over
# compressed or serialised binary (R .rds/.rdb, fonts, images, archives,
# minified bundles) they fire thousands of times on byte coincidences (a
# 2026-10 full-history audit had ~2,700 uk-postcode hits in .rds files alone),
# burying real findings. Extension-based on purpose: a content sniff (NUL
# byte) would also skip text with a stray NUL, which the llm#1160 selftests
# require to still be scanned. PDF is deliberately NOT in this list: this
# scanner cannot extract text from a PDF, but a PDF can carry readable PII in
# uncompressed text objects, so it stays a scanned type (accepted: some PDF
# noise remains).
is_generic_skip_blob() {
    local lc
    lc="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    case "$lc" in
        *.rds|*.rda|*.rdata|*.rdb|*.rdx|*.woff|*.woff2|*.ttf|*.otf|*.eot) return 0 ;;
        *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.zip|*.gz|*.min.js) return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Document-format gate and text extraction (JohnGavin/llm#1358)
# ---------------------------------------------------------------------------
# Office/PDF/mail documents hold their text in a compressed or container
# layer, so the byte-level scan below sees none of it: PII inside one is
# invisible to every layer (pre-commit, pre-push, CI, history audit), and a
# hit on one is a coincidence of compressed bytes. Two controls close that:
#
#   1. A FILE-TYPE GATE. In a PUBLIC repo, a document-format file is a
#      critical finding unless its exact repo-relative path is on the
#      allow-list WITH a stated reason (default-permit is fail-open).
#      Visibility comes from repo_visibility(), which treats UNKNOWN as
#      public, so the gate fails closed. In --full-history mode the same
#      condition is reported as its own rule, document-format-in-public-
#      history: it is what the generic regexes cannot see.
#   2. TEXT EXTRACTION (pdf only: pdftotext, poppler). The extracted text is
#      run through the deny-list and the generic rules. When the extractor is
#      missing, fails, or finds no text layer, the file's content was NOT
#      inspected: that is recorded in INDET_FILE and the run exits 3
#      (INDETERMINATE) if it found nothing else -- never clean.
#
# Allow-list: $REPO_ROOT/.claude/private_data_document_allowlist.txt (override
# for tests: PRIVATE_DATA_DOC_ALLOWLIST). One entry per line,
# "<exact repo-relative path> | <reason>". A line with no reason, or no path,
# is ignored with a warning, so a bare path allows nothing. The file is read
# from the working tree, so adding an entry is a reviewable diff.
DOC_FORMAT_EXTS="pdf docx xlsx doc xls odt rtf eml msg"
PDFTOTEXT="${PRIVATE_DATA_SCAN_PDFTOTEXT:-pdftotext}"
DOC_ALLOWLIST_FILE="${PRIVATE_DATA_DOC_ALLOWLIST:-}"
DOC_ALLOW_PATHS=()
VIS="public"   # main() sets the real value BEFORE scanning; unknown stays public

doc_extension() {
    local lc
    lc="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    [ "${lc##*.}" != "$lc" ] || return 1
    printf '%s' "${lc##*.}"
}

is_document_format_path() {
    local ext e
    ext="$(doc_extension "$1")" || return 1
    for e in $DOC_FORMAT_EXTS; do
        [ "$ext" = "$e" ] && return 0
    done
    return 1
}

# doc_loc_path LOCATION -> repo-relative path (strips "staged:" / "<sha12>:")
doc_loc_path() {
    local p="$1"
    case "$p" in staged:*) p="${p#staged:}" ;; esac
    if printf '%s' "$p" | LC_ALL=C "$GREP" -qE '^[0-9a-f]{12}:'; then p="${p:13}"; fi
    printf '%s' "$p"
}

load_doc_allowlist() {
    DOC_ALLOW_PATHS=()
    local f="${DOC_ALLOWLIST_FILE:-${REPO_ROOT}/.claude/private_data_document_allowlist.txt}"
    [ -r "$f" ] || return 0
    local line p r
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in
            *" | "*) p="${line%% | *}"; r="${line#* | }" ;;
            *) echo "WARNING: ignoring document allow-list line with no ' | <reason>' (a bare path allows nothing)" >&2; continue ;;
        esac
        p="${p%"${p##*[![:space:]]}"}"
        if [ -z "$p" ] || [ -z "$(printf '%s' "$r" | tr -d '[:space:]')" ]; then
            echo "WARNING: ignoring document allow-list line with an empty path or reason" >&2
            continue
        fi
        DOC_ALLOW_PATHS+=("$p")
    done < "$f"
    return 0
}

# scan_document_format LOCATION RAW-FILE -- runs in the caller's shell/subshell;
# findings go to FINDINGS_FILE, unscannable files to INDET_FILE.
scan_document_format() {
    local loc="$1" rawf="$2" path ext allowed=0 a rule
    path="$(doc_loc_path "$loc")"
    ext="$(doc_extension "$path")"
    if [ "${#DOC_ALLOW_PATHS[@]}" -gt 0 ]; then
        for a in "${DOC_ALLOW_PATHS[@]}"; do
            [ "$a" = "$path" ] && allowed=1
        done
    fi
    if [ "$allowed" -eq 0 ] && [ "${VIS:-public}" != "private" ]; then
        rule="document-format-blocked"
        [ "$MODE" = "full-history" ] && rule="document-format-in-public-history"
        append_finding "gate" "critical" "$loc" "0" "$rule" \
            "document-format file in a public repo, not on the document allow-list (text not visible to byte-level rules)"
    fi
    [ "$ext" = "pdf" ] || return 0   # pdf is the only format with an extractor
    if ! command -v "$PDFTOTEXT" >/dev/null 2>&1; then
        printf '%s\t%s\n' "$loc" "text extractor ($PDFTOTEXT) not available" >> "$INDET_FILE"
        return 0
    fi
    local txt; txt="$(mktemp "${TMPDIR:-/tmp}/private_data_scan_txt.XXXXXX")"
    if "$PDFTOTEXT" -q "$rawf" "$txt" 2>/dev/null; then
        if [ -n "$(LC_ALL=C tr -d '[:space:]\000' < "$txt" | head -c 1)" ]; then
            scan_denylist "$loc" < "$txt"
            scan_generic "$loc" < "$txt"
        else
            printf '%s\t%s\n' "$loc" "no text layer extracted (image content not inspected)" >> "$INDET_FILE"
        fi
    else
        printf '%s\t%s\n' "$loc" "text extraction failed" >> "$INDET_FILE"
    fi
    rm -f "$txt"
}

# ---------------------------------------------------------------------------
# Path rules: sensitive filename (JohnGavin/llm#1369) and images outside
# generated-figure folders (JohnGavin/llm#1370)
# ---------------------------------------------------------------------------
# A file's NAME says what it is (a hospital letter, a payslip) and a photo of
# a letter is invisible to every text rule, so both rules look at the PATH,
# not the content. Both are PUBLIC-repo gates (VIS != private), both lift on
# the same exact-path "<path> | <reason>" allow-list as the document gate
# (DOC_ALLOW_PATHS, #1358), and both are rules in the "gate" source.
#
# ---- sensitive-filename (critical, every mode) ----
# The path is lower-cased and split into tokens on every character that is
# not a-z0-9, so word boundaries are exact: "ipaddress.pyi" does not contain
# the token "address", "taxonomy" is not "tax", "clinical" is not "clinic",
# "nhs_letter" holds "nhs" and "letter". A token also matches with trailing
# digits stripped ("payslip2024" -> "payslip", "letter1" -> "letter").
#
#   STRONG words: a hit on any path segment is a finding, whatever the
#   extension. They name a document class and have no common code meaning:
#   nhs hospital clinic payslip payslips p60 p45 p11d passport discharge
#   prescription.
#
#   BROAD words: ordinary English words that are also everyday code
#   identifiers (tax.R, statement.sql, bank.py, contact.js, signal.py,
#   address.pyi). They count ONLY when the FILE has a document, image or
#   plain-data extension (BROAD_EXTS below). Code and markup extensions never
#   count, so a source file is not flagged for its identifier:
#   letter letters statement statements invoice invoices tax taxes bank
#   licence license contact contacts address medical salary payroll mortgage
#   appointment appointments referral.
#   Deliberately absent: "signal" (a Python module and a messaging app, and
#   the single noisiest word on the 2026-10-11 inventory).
#
# Tuning evidence (counts only, 2026-10-11 inventory of the owner's public
# repos): see .claude/rules/private-data-scanning.md. To change a list, run
# the same count again and record before/after there.
FILENAME_STRONG_WORDS=" nhs hospital clinic payslip payslips p60 p45 p11d passport discharge prescription "
FILENAME_BROAD_WORDS=" letter letters statement statements invoice invoices tax taxes bank licence license contact contacts address medical salary payroll mortgage appointment appointments referral "
FILENAME_BROAD_EXTS=" pdf doc docx xls xlsx odt ods rtf eml msg csv tsv txt png jpg jpeg gif heic heif tif tiff bmp webp "
IMAGE_EXTS=" png jpg jpeg gif webp heic heif tif tiff bmp "

# path_basename_ext PATH -> lower-case extension of the BASENAME ("" if none)
path_basename_ext() {
    local b="${1##*/}"
    b="$(printf '%s' "$b" | tr 'A-Z' 'a-z')"
    [ "${b##*.}" != "$b" ] || return 0
    printf '%s' "${b##*.}"
}

# sensitive_filename_word PATH -> prints the matched word and returns 0, or
# returns 1. Pure: no allow-list, no visibility (the caller applies both).
sensitive_filename_word() {
    local lc ext tok t
    lc="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' ' ')"
    ext="$(path_basename_ext "$1")"
    local broad_ok=0
    case "$FILENAME_BROAD_EXTS" in *" $ext "*) [ -n "$ext" ] && broad_ok=1 ;; esac
    for tok in $lc; do
        case "$FILENAME_STRONG_WORDS" in *" $tok "*) printf '%s' "$tok"; return 0 ;; esac
        t="$tok"
        while [ "${t%[0-9]}" != "$t" ]; do t="${t%[0-9]}"; done
        [ -n "$t" ] || continue
        case "$FILENAME_STRONG_WORDS" in *" $t "*) printf '%s' "$t"; return 0 ;; esac
        if [ "$broad_ok" -eq 1 ]; then
            case "$FILENAME_BROAD_WORDS" in *" $t "*) printf '%s' "$t"; return 0 ;; esac
        fi
    done
    return 1
}

# ---- image-outside-figures (critical; image-in-public-history, high, in
# --full-history) ----
# A photo or screenshot of a letter cannot be read by any text rule. Images
# are blocked in a public repo unless they sit in a GENERATED-figure folder
# or are on the allow-list. Generated folders (anchored where stated; an
# unanchored "docs/" would let "notes/docs/scan.jpg" through):
#   man/figures/            (root)   roxygen / README figures
#   docs/                   (root)   pkgdown / rendered-site output
#   vignettes/<x>_files/    (root)   knitr / Quarto vignette figure dirs
#   */<x>_files/figure-*/   (any)    Quarto / knitr figure output
#   _freeze/  _site/        (any)    Quarto freeze and site output
is_image_path() {
    local ext; ext="$(path_basename_ext "$1")"
    [ -n "$ext" ] || return 1
    case "$IMAGE_EXTS" in *" $ext "*) return 0 ;; esac
    return 1
}

is_generated_figure_path() {
    case "$1" in
        man/figures/*|docs/*|vignettes/*_files/*) return 0 ;;
        *_files/figure-*/*) return 0 ;;
        _freeze/*|*/_freeze/*|_site/*|*/_site/*) return 0 ;;
    esac
    return 1
}

path_allow_listed() {
    local a
    [ "${#DOC_ALLOW_PATHS[@]}" -gt 0 ] || return 1
    for a in "${DOC_ALLOW_PATHS[@]}"; do
        [ "$a" = "$1" ] && return 0
    done
    return 1
}

# scan_path_rules LOCATION RAW-FILE-or-"" -- findings to FINDINGS_FILE.
scan_path_rules() {
    local loc="$1" rawf="$2" path word rule sev size
    [ "${VIS:-public}" != "private" ] || return 0
    path="$(doc_loc_path "$loc")"
    path_allow_listed "$path" && return 0
    if word="$(sensitive_filename_word "$path")"; then
        append_finding "gate" "critical" "$loc" "0" "sensitive-filename" \
            "path contains a health/money/identity/contact word from the scanner's list, not on the allow-list (content not inspected for meaning)"
    fi
    if is_image_path "$path" && ! is_generated_figure_path "$path"; then
        size="unknown"
        [ -n "$rawf" ] && size="$(wc -c < "$rawf" | tr -d ' ')"
        rule="image-outside-figures"; sev="critical"
        if [ "$MODE" = "full-history" ]; then rule="image-in-public-history"; sev="high"; fi
        append_finding "gate" "$sev" "$loc" "0" "$rule" \
            "image file outside generated-figure folders, not on the allow-list (${size} bytes; pixels not inspected)"
    fi
}

# scan_blob LOCATION < content-on-stdin
scan_blob() {
    local loc="$1" content rawf=""
    # See scan_denylist's comment above -- same NUL-truncation fix
    # (JohnGavin/llm#1160). This is the entry point every blob (staged
    # content, a historical commit's content, an on-disk file, --content-
    # stdin) first passes through, so fixing the capture here is what
    # actually stops the truncation at its source; scan_denylist's and
    # scan_generic's own fixes are defense-in-depth for any caller that
    # invokes them directly with raw content (e.g. the selftest below).
    if is_document_format_path "$loc" || is_image_path "$(doc_loc_path "$loc")"; then
        rawf="$(mktemp "${TMPDIR:-/tmp}/private_data_scan_doc.XXXXXX")"
        cat > "$rawf"
        is_document_format_path "$loc" && scan_document_format "$loc" "$rawf"
        scan_path_rules "$loc" "$rawf"
        content="$(LC_ALL=C tr -d '\000' < "$rawf")"
        rm -f "$rawf"
    else
        scan_path_rules "$loc" ""
        content="$(LC_ALL=C tr -d '\000')"
    fi
    # Deny-list is UNCONDITIONAL -- always runs, even for a self-reference
    # exempt file. See "Self-reference exemption" above.
    printf '%s' "$content" | scan_denylist "$loc"
    # Generic SHAPE rules are meaningless on binary content -- skip them for
    # known-binary types. The deny-list above has ALREADY run on every blob
    # regardless of type: an exact real value can sit in a binary.
    if is_generic_skip_blob "$loc"; then
        return 0
    fi
    if is_self_reference_exempt "$loc"; then
        return 0
    fi
    printf '%s' "$content" | scan_generic "$loc"
}

# ---------------------------------------------------------------------------
# THE NON-NEGOTIABLE REQUIREMENT: runtime self-check, every invocation,
# not skippable. See header comment.
# ---------------------------------------------------------------------------
assert_can_detect() {
    # NOTE: this probe sentence must NOT contain any of the
    # looks_like_fixture_context() marker words (EXAMPLE/FAKE/DUMMY/TEST/
    # FIXTURE) -- doing so would make the probe exempt from generic
    # detection by the very allowlist this self-check exists to bypass,
    # silently defeating the check (found empirically while writing this
    # selftest: the word "fixture" in the probe sentence itself caused
    # assert_can_detect to always pass, for the wrong reason).
    local probe_generic="Runtime detector liveness probe: reach the number +19998887766 now."
    # scan_generic appends into $FINDINGS_FILE directly -- swap in a
    # throwaway findings file for the probe call so it never pollutes the
    # real findings report (the probe is never scanned against the real
    # FINDINGS_FILE at any point below).
    local real_findings_file="$FINDINGS_FILE"
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/private_data_scan_selfcheck.XXXXXX")"
    printf '%s' "$probe_generic" | scan_generic "SELFCHECK" >/dev/null 2>&1
    local generic_hits
    generic_hits="$(wc -l < "$FINDINGS_FILE" | tr -d ' ')"
    rm -f "$FINDINGS_FILE"

    if [ "${PRIVATE_DATA_SCAN_SELFCHECK_FORCE_FAIL:-0}" = "1" ]; then
        generic_hits=0   # test-only override: prove the abort path fires
    fi

    if [ "${generic_hits:-0}" -lt 1 ]; then
        FINDINGS_FILE="$real_findings_file"
        echo "SELF-CHECK FAILED: the generic PII detector did not flag a known-bad synthetic fixture (+19998887766)." >&2
        echo "This means the detector cannot be trusted to report 'clean' -- it may be structurally broken (wrong grep binary, pattern regression, or an environment change)." >&2
        echo "Aborting BEFORE scanning real content. See private_data_scan.sh's assert_can_detect()." >&2
        log_line "SELFCHECK_FAILED"
        exit 1
    fi
    FINDINGS_FILE="$real_findings_file"

    # Deny-list mechanism self-check: only meaningful when a deny-list is
    # actually loaded. Uses a SYNTHETIC value appended temporarily -- never
    # the real loaded values -- so this never risks printing a real one.
    if [ "${#DENYLIST_VALUES[@]}" -gt 0 ]; then
        local synthetic="SELFCHECK_PROBE_9f3aQ7xR2mN"
        local saved=("${DENYLIST_VALUES[@]}")
        DENYLIST_VALUES=("$synthetic")
        local df="$FINDINGS_FILE"
        FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/private_data_scan_selfcheck2.XXXXXX")"
        printf 'probe line containing %s here\n' "$synthetic" | scan_denylist "SELFCHECK" >/dev/null 2>&1
        local deny_hits
        deny_hits="$(wc -l < "$FINDINGS_FILE" | tr -d ' ')"
        rm -f "$FINDINGS_FILE"
        FINDINGS_FILE="$df"
        DENYLIST_VALUES=("${saved[@]}")
        if [ "${PRIVATE_DATA_SCAN_SELFCHECK_FORCE_FAIL:-0}" = "1" ]; then
            deny_hits=0
        fi
        if [ "${deny_hits:-0}" -lt 1 ]; then
            echo "SELF-CHECK FAILED: the deny-list detector did not flag a synthetic known-bad probe value." >&2
            echo "Aborting BEFORE scanning real content. See private_data_scan.sh's assert_can_detect()." >&2
            log_line "SELFCHECK_FAILED_DENYLIST"
            exit 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Content retrieval -- NEVER via git diff/log -p/show <commit> (see header).
# Every real read is a direct blob read via git cat-file -p "<tree-ish>:<path>".
# ---------------------------------------------------------------------------

scan_staged() {
    [ -d "$REPO_ROOT" ] || return 0
    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        git -C "$REPO_ROOT" cat-file -p ":${path}" 2>/dev/null | scan_blob "staged:${path}"
    done < <(git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACM --no-ext-diff 2>/dev/null)
}

scan_range() {
    local a="$1" b="$2"
    [ -n "$a" ] && [ -n "$b" ] || { echo "private_data_scan: --range requires two revisions" >&2; return 2; }
    [ -d "$REPO_ROOT" ] || return 0
    # llm#1365: "<a>" may be --not-remotes[=<glob>], meaning "every commit
    # reachable from <b> that is on no remote-tracking ref (of <glob>)". That is
    # the only correct range for a NEW branch or a first push: "<root>..<b>"
    # excludes the root commit itself, and there may be no base to name at all.
    local -a revspec
    case "$a" in
        --not-remotes)   revspec=("$b" --not --remotes) ;;
        --not-remotes=*) revspec=("$b" --not "--remotes=${a#--not-remotes=}") ;;
        *)               revspec=("${a}..${b}") ;;
    esac
    _SCAN_TRUNCATED=0
    _SCAN_SCANNED=0
    _SCAN_TOTAL_REACHABLE=""
    # Only pay for a second (cheap -- rev-list alone, no diff-tree/cat-file)
    # enumeration when the caller explicitly bounded the scan; the default
    # (unlimited) path derives the total from the same single pass below
    # (llm#1204) -- see the header's "--max-commits" note.
    if [ "$MAX_COMMITS_EXPLICIT" -eq 1 ]; then
        _SCAN_TOTAL_REACHABLE="$(git -C "$REPO_ROOT" rev-list "${revspec[@]}" 2>/dev/null | wc -l | tr -d ' ')"
    fi
    local sha path count=0
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        count=$((count + 1))
        if [ "$MAX_COMMITS_EXPLICIT" -eq 1 ] && [ "$count" -gt "$MAX_COMMITS" ]; then
            _SCAN_TRUNCATED=1
            echo "WARNING: --range truncated at $MAX_COMMITS commits -- absence of findings past this point is NOT proof of a clean range." >&2
            break
        fi
        _SCAN_SCANNED=$((_SCAN_SCANNED + 1))
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            git -C "$REPO_ROOT" cat-file -p "${sha}:${path}" 2>/dev/null | scan_blob "${sha:0:12}:${path}"
        done < <(git -C "$REPO_ROOT" diff-tree --root --no-commit-id --name-only --no-ext-diff -r "$sha" 2>/dev/null)
    done < <(git -C "$REPO_ROOT" rev-list "${revspec[@]}" 2>/dev/null)
    [ -n "$_SCAN_TOTAL_REACHABLE" ] || _SCAN_TOTAL_REACHABLE="$_SCAN_SCANNED"
}

scan_paths() {
    local f
    for f in "${PATHS_ARGS[@]}"; do
        [ -f "$f" ] || continue
        case "$f" in
            # *.pdf is deliberately NOT skipped: it must reach the
            # document-format gate in scan_blob (llm#1358).
            # Images are likewise NOT skipped: they must reach the
            # image-outside-figures gate (llm#1370); generic rules skip them.
            *.rds|*.rda|*.RData|*.gz|*.zip|*.duckdb|*.parquet) continue ;;
        esac
        cat "$f" 2>/dev/null | scan_blob "$f"
    done
}

scan_full_history() {
    [ -d "$REPO_ROOT" ] || return 0
    _SCAN_TRUNCATED=0
    _SCAN_SCANNED=0
    _SCAN_TOTAL_REACHABLE=""
    # See scan_range()'s identical comment: the second enumeration (a cheap
    # `rev-list | wc -l`, never the expensive diff-tree/cat-file work) only
    # runs when the caller explicitly bounded the scan (llm#1204).
    if [ "$MAX_COMMITS_EXPLICIT" -eq 1 ]; then
        _SCAN_TOTAL_REACHABLE="$(git -C "$REPO_ROOT" rev-list --all 2>/dev/null | wc -l | tr -d ' ')"
    fi
    local sha path count=0
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        count=$((count + 1))
        if [ "$MAX_COMMITS_EXPLICIT" -eq 1 ] && [ "$count" -gt "$MAX_COMMITS" ]; then
            _SCAN_TRUNCATED=1
            echo "WARNING: --full-history truncated at $MAX_COMMITS commits -- absence of findings past this point is NOT proof of a clean history. Increase --max-commits or rely on the scheduled resumable audit." >&2
            break
        fi
        _SCAN_SCANNED=$((_SCAN_SCANNED + 1))
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            git -C "$REPO_ROOT" cat-file -p "${sha}:${path}" 2>/dev/null | scan_blob "${sha:0:12}:${path}"
        done < <(git -C "$REPO_ROOT" diff-tree --root --no-commit-id --name-only --no-ext-diff -r "$sha" 2>/dev/null)
    done < <(git -C "$REPO_ROOT" rev-list --all 2>/dev/null)
    [ -n "$_SCAN_TOTAL_REACHABLE" ] || _SCAN_TOTAL_REACHABLE="$_SCAN_SCANNED"
}

scan_content_stdin() {
    cat | scan_blob "$CONTENT_LABEL"
}

# ---------------------------------------------------------------------------
# Public/private awareness
# ---------------------------------------------------------------------------
# repo_visibility -- best-effort; UNKNOWN visibility defaults to "public"
# (the STRICTER profile) rather than "private" -- guessing wrong toward
# private could let a real leak through on an actually-public repo; guessing
# wrong toward public just means occasional extra scanning. Same
# fail-toward-safety spirit as the rest of this script.
repo_visibility() {
    [ -d "$REPO_ROOT" ] || { echo "public"; return; }
    local vis
    vis="$(cd "$REPO_ROOT" && gh repo view --json visibility -q .visibility 2>/dev/null)" || true
    case "$vis" in
        PRIVATE|private) echo "private" ;;
        *) echo "public" ;;  # PUBLIC, empty, or gh failure -> strict default
    esac
}

# ---------------------------------------------------------------------------
# Housekeeping heartbeat (mirrors secret_exposure_scan.sh's hk_run_start /
# hk_run_end / write_findings_to_db exactly -- see that script's header for
# the full rationale). Writes to private_data_scan_findings, added alongside
# secret_scan_findings in housekeeping_schema_init.sql.
# ---------------------------------------------------------------------------
_duckdb_ok=0
if command -v duckdb >/dev/null 2>&1 && [ -f "$UNIFIED_DB" ]; then
    _duckdb_ok=1
fi
_run_id=""
_run_started=""

hk_run_start() {
    [ "$_duckdb_ok" = "1" ] || return 0
    _run_id="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    [ -n "$_run_id" ] || return 0
    _run_started="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    duckdb -init /dev/null "$UNIFIED_DB" -c "
        INSERT OR IGNORE INTO housekeeping_runs
          (id, task, source_script, started_at, status, rows_written)
        VALUES ('${_run_id}', 'private_data_scan', '${SCRIPT_DIR}/private_data_scan.sh',
                TIMESTAMPTZ '${_run_started}', 'ok', 0);
    " >/dev/null 2>&1 || true
}

hk_run_end() {
    [ "$_duckdb_ok" = "1" ] || return 0
    [ -n "$_run_id" ] || return 0
    local status="$1" rows="${2:-0}" ended
    ended="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    duckdb -init /dev/null "$UNIFIED_DB" -c "
        UPDATE housekeeping_runs SET ended_at = TIMESTAMPTZ '${ended}', status = '${status}', rows_written = ${rows}
        WHERE id = '${_run_id}';
    " >/dev/null 2>&1 || true
}

write_findings_to_db() {
    [ "$_duckdb_ok" = "1" ] || return 0
    [ -n "$_run_id" ] || return 0
    [ -s "${FINDINGS_FILE:-}" ] || return 0
    duckdb -init /dev/null "$UNIFIED_DB" -c "
        INSERT OR IGNORE INTO private_data_scan_findings
        SELECT md5(run_id || ':' || source || ':' || location || ':' || line_num || ':' || rule) AS id,
               run_id, fired_at, source, severity, location, line_num, rule, note
        FROM (
          SELECT '${_run_id}' AS run_id, TIMESTAMPTZ '${_run_started}' AS fired_at,
            column0 AS source, column1 AS severity, column2 AS location,
            column3 AS line_num, column4 AS rule, column5 AS note
          FROM read_csv('${FINDINGS_FILE}', delim='\t', header=false, quote='',
            columns={'column0':'VARCHAR','column1':'VARCHAR','column2':'VARCHAR',
                     'column3':'VARCHAR','column4':'VARCHAR','column5':'VARCHAR'})
        );
    " >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

# print_coverage_line -- llm#1204 determinism fix. Reports actual commit
# coverage for --full-history/--range explicitly on stdout, unconditionally
# (NOT gated by --quiet -- see print_report's "clean" message for contrast,
# which IS quiet-gated; coverage is the determinacy signal this whole fix
# exists to surface, so it is never silenced). A no-op for every other mode
# (--staged/--paths/--content-stdin), where _SCAN_TOTAL_REACHABLE is left
# unset because there is no "reachable commit set" concept to report.
print_coverage_line() {
    [ -n "${_SCAN_TOTAL_REACHABLE:-}" ] || return 0
    local pct=100
    if [ "$_SCAN_TOTAL_REACHABLE" -gt 0 ]; then
        pct=$(( _SCAN_SCANNED * 100 / _SCAN_TOTAL_REACHABLE ))
    fi
    if [ "${_SCAN_TRUNCATED:-0}" -eq 1 ]; then
        echo "private-data-scan: scanned=${_SCAN_SCANNED}/${_SCAN_TOTAL_REACHABLE} commits (${pct}%) -- TRUNCATED"
    else
        echo "private-data-scan: scanned=${_SCAN_SCANNED}/${_SCAN_TOTAL_REACHABLE} commits (${pct}%)"
    fi
}

print_report_json() {
    local first=1
    printf '{'
    if [ -n "${_SCAN_TOTAL_REACHABLE:-}" ]; then
        printf '"scanned_commits":%s,"total_reachable_commits":%s,"truncated":%s,' \
            "$_SCAN_SCANNED" "$_SCAN_TOTAL_REACHABLE" \
            "$([ "${_SCAN_TRUNCATED:-0}" -eq 1 ] && echo true || echo false)"
    fi
    printf '"findings":['
    while IFS=$'\t' read -r src sev loc lnum rule note; do
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"source":"%s","severity":"%s","location":"%s","line":"%s","rule":"%s","note":"%s"}' \
            "$(json_escape "$src")" "$(json_escape "$sev")" "$(json_escape "$loc")" \
            "$(json_escape "$lnum")" "$(json_escape "$rule")" "$(json_escape "$note")"
    done < "$FINDINGS_FILE"
    printf ']}\n'
}

print_report() {
    local total; total=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
    if [ "$JSON" -eq 1 ]; then print_report_json; return 0; fi
    print_coverage_line
    if [ "$total" -eq 0 ]; then
        [ "$QUIET" -eq 1 ] || echo "private-data-scan: clean -- 0 findings"
        return 0
    fi
    echo "private-data-scan: $total finding(s)"
    if [ "$TSV" -eq 1 ]; then
        # Raw rows for programmatic consumers; same fields as the human
        # lines (never the matched value).
        awk -F'\t' 'BEGIN{OFS="\t"} {print "FINDING",$1,$2,$3,$4,$5,$6}' "$FINDINGS_FILE"
        return 0
    fi
    while IFS=$'\t' read -r src sev loc lnum rule note; do
        printf '  [%s] src=%s %s:%s %s -- %s\n' "$sev" "$src" "$loc" "$lnum" "$rule" "$note"
    done < "$FINDINGS_FILE"
}

# ---------------------------------------------------------------------------
# --selftest
# ---------------------------------------------------------------------------
run_selftest() {
    local pass=0 total=0
    _check() {
        total=$((total + 1))
        if [ "$1" = "0" ]; then pass=$((pass + 1)); printf 'PASS  %s\n' "$2"
        else printf 'FAIL  %s\n' "$2"; fi
    }

    # ── 1-2: assert_can_detect proves it can fail (mutation test, in-process) ──
    # --no-denylist isolates these two cases to the assert_can_detect path
    # itself -- otherwise a missing/present ~/.config/private_values.env on
    # the machine running this selftest would decide the outcome instead.
    local ff_out; ff_out="$(mktemp "${TMPDIR:-/tmp}/pds_selftest_ff.XXXXXX")"
    ( PRIVATE_DATA_SCAN_SELFCHECK_FORCE_FAIL=1 bash "$0" --paths /dev/null --no-denylist >"$ff_out" 2>&1 )
    local rc=$?
    if [ "$rc" -eq 1 ] && "$GREP" -q "SELF-CHECK FAILED" "$ff_out"; then
        _check 0 "assert_can_detect aborts (exit 1) when forced to fail -- proves the abort path fires"
    else
        _check 1 "assert_can_detect did NOT abort when forced to fail (rc=$rc)"
    fi
    rm -f "$ff_out"

    local norm_out; norm_out="$(mktemp "${TMPDIR:-/tmp}/pds_selftest_norm.XXXXXX")"
    ( bash "$0" --paths /dev/null --no-denylist >"$norm_out" 2>&1 )
    rc=$?
    if [ "$rc" -eq 0 ]; then
        _check 0 "assert_can_detect passes on a normal (non-forced) invocation"
    else
        _check 1 "assert_can_detect unexpectedly failed on a normal invocation (rc=$rc): $(cat "$norm_out")"
    fi
    rm -f "$norm_out"

    # ── llm#1004 follow-up: reserved-range exemptions ──────────────────────
    # Each reserved range must be EXEMPT, and — the assertion that actually
    # matters — a real-shaped number must still be CAUGHT. Without the
    # negative cases, widening the exemption to ".*" would pass every
    # positive case here.
    _check "$(is_e164_fictional '+15555550142' && echo 0 || echo 1)" "exempt: NANP NPA-555-01XX (pre-existing)"
    _check "$(is_e164_fictional '+15551234567' && echo 0 || echo 1)" "exempt: NANP 555 area code (llm#1004 gap)"
    _check "$(is_e164_fictional '+447700900123' && echo 0 || echo 1)" "exempt: UK Ofcom 07700 900xxx"
    _check "$(is_e164_fictional '+442079460123' && echo 0 || echo 1)" "exempt: UK Ofcom 020 7946 0xxx"
    _check "$(is_e164_fictional '+441632960123' && echo 0 || echo 1)" "exempt: UK Ofcom 01632 960xxx"
    # Negative controls — these MUST still be flagged.
    _check "$(is_e164_fictional '+14155552671' && echo 1 || echo 0)" "NOT exempt: real-shaped US number"
    _check "$(is_e164_fictional '+442071838750' && echo 1 || echo 0)" "NOT exempt: real-shaped UK landline"
    _check "$(is_e164_fictional '+447700123456' && echo 1 || echo 0)" "NOT exempt: UK mobile outside the drama range"
    _check "$(is_e164_fictional '+19998887766' && echo 1 || echo 0)" "NOT exempt: the script's own known-bad probe"
    # Boundary: one digit outside the reserved block must NOT be exempt.
    _check "$(is_e164_fictional '+447700901123' && echo 1 || echo 0)" "NOT exempt: 07700 901xxx (just past the range)"

    # ── fixtures ──
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/private_data_scan_selftest.XXXXXX")"
    mkdir -p "$tmp/repo"
    git -C "$tmp/repo" init -q
    git -C "$tmp/repo" config user.email t@example.com
    git -C "$tmp/repo" config user.name t
    git -C "$tmp/repo" -c diff.external="" config diff.external ""

    printf 'initial\n' > "$tmp/repo/README.txt"
    git -C "$tmp/repo" add README.txt
    git -C "$tmp/repo" commit -q -m "initial"

    printf 'call me on +14155552671 or +442071838750\nUK postcode SW1A 1AA lives here\nIBAN: GB29NWBK60161331926819\nfictional +15555550142 is fine\ntest fixture +19998887766 EXAMPLE\n' > "$tmp/repo/leak.txt"
    git -C "$tmp/repo" add leak.txt
    git -C "$tmp/repo" commit -q -m "add leak"

    REPO_ROOT="$tmp/repo"

    # 3: --paths mode finds all three generic classes
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f1.XXXXXX")"
    PATHS_ARGS=("$tmp/repo/leak.txt")
    scan_paths
    _check "$([ "$(awk -F'\t' '$5=="e164-phone"' "$FINDINGS_FILE" | grep -c .)" -ge 1 ] && echo 0 || echo 1)" "E.164 phone detected via --paths"
    _check "$([ "$(awk -F'\t' '$5=="uk-postcode"' "$FINDINGS_FILE" | grep -c .)" -ge 1 ] && echo 0 || echo 1)" "UK postcode detected via --paths"
    _check "$([ "$(awk -F'\t' '$5=="iban"' "$FINDINGS_FILE" | grep -c .)" -ge 1 ] && echo 0 || echo 1)" "IBAN detected via --paths"
    # fictional NANP block (line 4, no marker) must NOT fire; marker line (line 5) must NOT fire either
    _check "$([ "$(awk -F'\t' '$4=="4"' "$FINDINGS_FILE" | grep -c .)" -eq 0 ] && echo 0 || echo 1)" "NANP-555-01XX fictional range is allowlisted"
    _check "$([ "$(awk -F'\t' '$4=="5"' "$FINDINGS_FILE" | grep -c .)" -eq 0 ] && echo 0 || echo 1)" "EXAMPLE-marked fixture line is exempted"
    rm -f "$FINDINGS_FILE"

    # 4: content-not-diff proof -- value exists ONLY in an older commit,
    # absent from the working tree and from HEAD. --range must still find it
    # via direct blob content, structurally independent of any diff driver.
    printf 'clean file, no PII\n' > "$tmp/repo/leak.txt"
    git -C "$tmp/repo" add leak.txt
    git -C "$tmp/repo" commit -q -m "scrub (working tree/HEAD now clean)"
    BASE_SHA="$(git -C "$tmp/repo" rev-parse HEAD~2)"
    HEAD_SHA="$(git -C "$tmp/repo" rev-parse HEAD)"
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f2.XXXXXX")"
    scan_range "$BASE_SHA" "$HEAD_SHA"
    _check "$([ "$(awk -F'\t' '$5=="e164-phone"' "$FINDINGS_FILE" | grep -c .)" -ge 1 ] && echo 0 || echo 1)" "content-not-diff: --range finds a value present ONLY in an intermediate commit (absent from HEAD)"
    rm -f "$FINDINGS_FILE"

    # 5: HEAD-only scan (--paths on current working tree) is clean -- proves
    # test 4 is not a false positive from scanning the wrong ref.
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f3.XXXXXX")"
    PATHS_ARGS=("$tmp/repo/leak.txt")
    scan_paths
    _check "$([ "$(wc -l < "$FINDINGS_FILE" | tr -d ' ')" -eq 0 ] && echo 0 || echo 1)" "HEAD/working-tree scan is clean after scrub (confirms test 4 used history, not HEAD)"
    rm -f "$FINDINGS_FILE"

    # 6-8: deny-list detection + no-leaked-value contract
    local denylist_tmp="$tmp/private_values.env"
    local sentinel="SELFTEST_SENTINEL_zQ9xxNeverPrintMe_7f3a"
    printf 'MY_PHONE=%s\n' "$sentinel" > "$denylist_tmp"
    chmod 600 "$denylist_tmp"
    DENYLIST_FILE="$denylist_tmp"
    load_denylist
    _check "$([ "${#DENYLIST_VALUES[@]}" -ge 1 ] && echo 0 || echo 1)" "load_denylist parses KEY=value from private_values.env"

    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f4.XXXXXX")"
    printf 'a line containing %s the sentinel\n' "$sentinel" | scan_denylist "test"
    _check "$([ "$(wc -l < "$FINDINGS_FILE" | tr -d ' ')" -ge 1 ] && echo 0 || echo 1)" "deny-list exact-match detection fires on a known value"
    local out; out="$(print_report 2>&1)"
    case "$out" in
        *"$sentinel"*) _check 1 "REGRESSION: sentinel value leaked into report output" ;;
        *) _check 0 "no-leaked-value contract: sentinel never appears in report output" ;;
    esac
    rm -f "$FINDINGS_FILE"

    # 9: fail-closed on missing deny-list (--require-denylist semantics,
    # exercised via main()'s own logic further down -- here we test the
    # load_denylist return code directly).
    DENYLIST_FILE="$tmp/does_not_exist.env"
    if load_denylist; then
        _check 1 "load_denylist should return non-zero for a missing file"
    else
        _check 0 "load_denylist returns non-zero (fail-closed signal) for a missing file"
    fi

    # 10: --content-stdin mode
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f5.XXXXXX")"
    printf 'reach me at +442071838750 please\n' | scan_blob "content-stdin-test"
    _check "$([ "$(wc -l < "$FINDINGS_FILE" | tr -d ' ')" -ge 1 ] && echo 0 || echo 1)" "--content-stdin path (scan_blob) detects a live UK-format E.164 number"
    rm -f "$FINDINGS_FILE"

    # 11-14: self-reference exemption (JohnGavin/llm#1004) -- narrow,
    # generic-only, deny-list still fires. All four location forms this
    # scanner actually produces (staged:/sha:/plain-path/absolute-path) are
    # exercised so the case-match logic in is_self_reference_exempt() is
    # proven, not assumed.
    for loc in \
        ".claude/scripts/private_data_scan.sh" \
        "staged:.claude/scripts/private_data_scan.sh" \
        "abc123456789:.claude/scripts/private_values_sync.sh" \
        "/Users/x/docs_gh/llm/.claude/scripts/private_data_scan.sh"
    do
        FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f6.XXXXXX")"
        printf 'liveness probe text with +19998887766 and SW1A 1AA and GB29NWBK60161331926819\n' | scan_blob "$loc"
        _check "$([ "$(wc -l < "$FINDINGS_FILE" | tr -d ' ')" -eq 0 ] && echo 0 || echo 1)" "self-reference exemption: generic patterns NOT flagged for location '$loc'"
        rm -f "$FINDINGS_FILE"
    done

    # 15: THE critical safety-preserving case -- a real deny-list value
    # sitting inside an exempted file's content is STILL caught. Without
    # this test the exemption above would be an unproven hole, not a
    # verified narrowing (see the coordinator's constraint #2 on #1004).
    local exempt_sentinel="SELFTEST_EXEMPT_DENYLIST_SENTINEL_k3Rn9x"
    local saved_denylist=("${DENYLIST_VALUES[@]}")
    DENYLIST_VALUES=("$exempt_sentinel")
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f7.XXXXXX")"
    printf 'a comment that happens to contain %s inside an exempted file\n' "$exempt_sentinel" \
        | scan_blob ".claude/scripts/private_data_scan.sh"
    _check "$([ "$(awk -F'\t' '$1=="denylist"' "$FINDINGS_FILE" | grep -c .)" -ge 1 ] && echo 0 || echo 1)" \
        "self-reference exemption does NOT cover deny-list: a known-bad value inside an exempted file is still flagged"
    rm -f "$FINDINGS_FILE"
    DENYLIST_VALUES=("${saved_denylist[@]}")

    # 16: a non-exempted file with the SAME generic-pattern content is
    # still flagged -- proves the exemption is scoped to the two listed
    # files, not a global relaxation of scan_generic.
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f8.XXXXXX")"
    printf 'reach +19998887766 in a totally unrelated file\n' | scan_blob "R/some_other_file.R"
    _check "$([ "$(wc -l < "$FINDINGS_FILE" | tr -d ' ')" -ge 1 ] && echo 0 || echo 1)" "self-reference exemption is scoped: an unlisted file with the same content is still flagged"
    rm -f "$FINDINGS_FILE"

    # 17: git short-SHA collision guard (see is_git_sha_like()'s header
    # comment) -- a bare abbreviated SHA that happens to be all-hex must NOT
    # be flagged as a uk-postcode false positive.
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f9.XXXXXX")"
    printf 'fixed in commit ca7f8fd today\n' | scan_blob "R/some_other_file.R"
    _check "$([ "$(awk -F'\t' '$5=="uk-postcode"' "$FINDINGS_FILE" | grep -c .)" -eq 0 ] && echo 0 || echo 1)" "git short SHA 'ca7f8fd' is NOT flagged as a uk-postcode false positive"
    rm -f "$FINDINGS_FILE"

    # 18: the git-SHA guard must not weaken real postcode detection -- every
    # one of these still matches RE_UK_POSTCODE (including all-hex shapes)
    # but fails at least one of the three SHA-collision signals, so all must
    # still be flagged.
    for pc in "EC1A 1BB" "SW1A 1AA" "EC1Y 8NH"; do
        FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f10.XXXXXX")"
        printf 'postcode %s lives here\n' "$pc" | scan_blob "R/some_other_file.R"
        _check "$([ "$(awk -F'\t' '$5=="uk-postcode"' "$FINDINGS_FILE" | grep -c .)" -ge 1 ] && echo 0 || echo 1)" "real postcode '$pc' is still flagged (SHA guard does not weaken postcode detection)"
        rm -f "$FINDINGS_FILE"
    done

    # 19: an uppercase, SPACELESS, all-hex postcode (EC1A1BB) still fails
    # the "all-lowercase" signal -- proves the guard is not merely "has a
    # space", it genuinely requires all three signals together.
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f11.XXXXXX")"
    printf 'postcode EC1A1BB lives here\n' | scan_blob "R/some_other_file.R"
    _check "$([ "$(awk -F'\t' '$5=="uk-postcode"' "$FINDINGS_FILE" | grep -c .)" -ge 1 ] && echo 0 || echo 1)" "uppercase spaceless all-hex postcode 'EC1A1BB' is still flagged"
    rm -f "$FINDINGS_FILE"

    # 20-21: HTML numeric character reference collision guard (see
    # is_html_entity_like()'s header comment) -- a hex entity's own hex
    # payload (leading 'x' + hex digits, wrapped in &#...;) must NOT be
    # flagged as a uk-postcode false positive. Both entities actually
    # present in .claude/scripts/send_roborev_weekly_rollup_email.R.
    for ent in "&#x1F4CB; Weekly Rollup" "&#x1F4CA; Chart"; do
        FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f12.XXXXXX")"
        printf '%s\n' "$ent" | scan_blob "R/some_other_file.R"
        _check "$([ "$(awk -F'\t' '$5=="uk-postcode"' "$FINDINGS_FILE" | grep -c .)" -eq 0 ] && echo 0 || echo 1)" "HTML entity '$ent' is NOT flagged as a uk-postcode false positive"
        rm -f "$FINDINGS_FILE"
    done

    # 22: a real postcode on the SAME line as an HTML entity is still
    # flagged -- proves the guard skips only the exempt match, not the
    # whole line (the per-match loop, not a first-match-only check).
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f13.XXXXXX")"
    printf '%s\n' "&#x1F4CB; postcode EC1A 1BB lives here" | scan_blob "R/some_other_file.R"
    _check "$([ "$(awk -F'\t' '$5=="uk-postcode"' "$FINDINGS_FILE" | grep -c .)" -ge 1 ] && echo 0 || echo 1)" "real postcode on the same line as an HTML entity is still flagged"
    rm -f "$FINDINGS_FILE"

    # 22a: CSS hex colour collision guard (see is_css_hex_colour_like()'s
    # header comment) -- the exact line from PR #1303 must NOT be flagged.
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f14.XXXXXX")"
    printf '%s\n' "      --ink:#E4E9EF; --ink-2:#C6CFD8; --muted:#AAB6C2; --line:#28323D;" | scan_blob "R/some_other_file.R"
    _check "$([ "$(awk -F'\t' '$5=="uk-postcode"' "$FINDINGS_FILE" | grep -c .)" -eq 0 ] && echo 0 || echo 1)" "CSS hex colours '#E4E9EF' are NOT flagged as uk-postcode false positives"
    rm -f "$FINDINGS_FILE"

    # 22b: a real postcode on the SAME line as a CSS hex colour is still flagged.
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f15.XXXXXX")"
    printf '%s\n' "--ink:#E4E9EF; postcode EC1A 1BB lives here" | scan_blob "R/some_other_file.R"
    _check "$([ "$(awk -F'\t' '$5=="uk-postcode"' "$FINDINGS_FILE" | grep -c .)" -ge 1 ] && echo 0 || echo 1)" "real postcode on the same line as a CSS hex colour is still flagged"
    rm -f "$FINDINGS_FILE"

    # 22c: a compact postcode after '#' (7 chars, not a valid colour length)
    # is still flagged. (A colour-shaped token NOT bounded by a non-alnum
    # char, e.g. "#E4E9EFzz", cannot arise: RE_UK_POSTCODE's own \b anchors
    # would not match a substring of it, so there is nothing to exempt.)
    for frag in "#EC1A1BB here"; do
        FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f16.XXXXXX")"
        printf 'ref %s\n' "$frag" | scan_blob "R/some_other_file.R"
        _check "$([ "$(awk -F'\t' '$5=="uk-postcode"' "$FINDINGS_FILE" | grep -c .)" -ge 1 ] && echo 0 || echo 1)" "non-colour '#' token '$frag' is still flagged"
        rm -f "$FINDINGS_FILE"
    done

    # ── 23-27: NUL-byte truncation (JohnGavin/llm#1160) ────────────────────
    # bash's printf can WRITE a literal NUL byte to a file's output stream
    # (the format string itself is plain ASCII "\000" -- only the resulting
    # OUTPUT bytes contain the NUL, so this is the portable, no-external-
    # tool way to build the fixture).
    #
    # IMPORTANT, empirically verified while writing this test (both
    # /opt/homebrew/bin/bash 5.3.9 and macOS system /bin/bash 3.2.57): on
    # THIS machine, $(...) command substitution does NOT hard-truncate at
    # the first NUL byte -- it silently STRIPS every NUL byte from the
    # captured value while continuing to capture everything after them,
    # and prints "warning: command substitution: ignored null byte in
    # input" to stderr while doing so. That still means content after a
    # deny-listed/generic-pattern value never gets LOST on this bash build
    # -- so a fixture with only a couple of leading NUL bytes does not, by
    # itself, reproduce a missed detection here (verified: it does not --
    # see the falsification note below). Older/other bash builds have
    # historically differed on this exact point (hard truncation at the
    # first NUL, losing everything after it, is the literal mechanism
    # JohnGavin/llm#1160 describes and is exactly the risk this fix
    # removes) -- the fix (routing content through `tr -d '\000'` BEFORE
    # bash's own $(...) ever sees it) is correct and needed regardless of
    # which of the two behaviors a given bash build has, because it makes
    # NUL-handling deterministic and explicit instead of depending on an
    # unspecified, version-dependent bash internal.
    #
    # The genuinely falsifiable signal ON THIS MACHINE is therefore the
    # stderr warning itself: pre-fix, bash's own $(...) emits it on every
    # NUL-laden blob; post-fix, `tr -d '\000'` has already removed every
    # NUL byte before $(...) ever runs, so the warning never fires. This
    # was verified to flip red (2 occurrences of the warning, content
    # still fully captured) -> green (0 occurrences) when the fix was
    # temporarily reverted and restored during development of this test.
    local nul_sentinel="SELFTEST_NUL_SENTINEL_p8Vt2xQmZ4"
    local nul_fixture; nul_fixture="$(mktemp "${TMPDIR:-/tmp}/pds_nul_fixture.XXXXXX")"
    printf 'DUCK\000\000\000leading binary header %s trailing text\n' "$nul_sentinel" > "$nul_fixture"

    # 23: sanity -- the fixture genuinely contains an embedded NUL byte
    # (proves this test would actually exercise the NUL-handling path, not
    # a vacuous fixture that never had a NUL in it). A NUL byte cannot be
    # passed as a shell argument (argv strings are NUL-terminated too), so
    # detect it via a hex dump instead of grepping for it directly.
    _check "$(LC_ALL=C od -An -tx1 -- "$nul_fixture" 2>/dev/null | "$GREP" -q ' 00' && echo 0 || echo 1)" \
        "NUL-byte fixture sanity check: the fixture genuinely contains an embedded NUL byte"

    # 24-25: a deny-list value placed AFTER the NUL byte is still detected,
    # AND scanning it no longer triggers bash's own null-byte warning (the
    # falsifiable half of this test -- see note above).
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f14.XXXXXX")"
    local saved_denylist_nul=("${DENYLIST_VALUES[@]}")
    DENYLIST_VALUES=("$nul_sentinel")
    local nul_stderr1; nul_stderr1="$(mktemp "${TMPDIR:-/tmp}/pds_f14_stderr.XXXXXX")"
    scan_blob "R/nul_fixture.bin" < "$nul_fixture" 2>"$nul_stderr1"
    _check "$([ "$(awk -F'\t' '$1=="denylist"' "$FINDINGS_FILE" | grep -c .)" -ge 1 ] && echo 0 || echo 1)" \
        "JohnGavin/llm#1160: deny-list value AFTER an embedded NUL byte is still detected (not silently truncated)"
    _check "$("$GREP" -qi 'null byte' "$nul_stderr1" && echo 1 || echo 0)" \
        "JohnGavin/llm#1160: scanning NUL-laden content no longer triggers bash's own 'ignored null byte' warning (NULs are stripped deterministically before \$(...) ever runs)"
    rm -f "$FINDINGS_FILE" "$nul_stderr1"
    DENYLIST_VALUES=("${saved_denylist_nul[@]}")

    # 26-27: a generic-pattern value (UK postcode) placed AFTER a NUL byte
    # is still detected, and the same warning-suppression holds -- proves
    # the fix covers scan_generic's own capture too, not only
    # scan_denylist's.
    local nul_fixture2; nul_fixture2="$(mktemp "${TMPDIR:-/tmp}/pds_nul_fixture2.XXXXXX")"
    printf 'PK\003\004\000\000binary header postcode SW1A 1AA trailing\n' > "$nul_fixture2"
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f15.XXXXXX")"
    local nul_stderr2; nul_stderr2="$(mktemp "${TMPDIR:-/tmp}/pds_f15_stderr.XXXXXX")"
    scan_blob "R/nul_fixture2.bin" < "$nul_fixture2" 2>"$nul_stderr2"
    _check "$([ "$(awk -F'\t' '$5=="uk-postcode"' "$FINDINGS_FILE" | grep -c .)" -ge 1 ] && echo 0 || echo 1)" \
        "JohnGavin/llm#1160: generic-pattern (uk-postcode) value AFTER an embedded NUL byte is still detected"
    _check "$("$GREP" -qi 'null byte' "$nul_stderr2" && echo 1 || echo 0)" \
        "JohnGavin/llm#1160: generic-pattern scan of NUL-laden content also no longer triggers bash's null-byte warning"
    rm -f "$FINDINGS_FILE" "$nul_stderr2"
    rm -f "$nul_fixture" "$nul_fixture2"

    # ── 28-38: JohnGavin/llm#1204 -- unlimited-by-default coverage + the
    # exit-3/INDETERMINATE distinction for a truncated-but-clean scan. ─────
    # $tmp/repo at this point has exactly 3 reachable commits: "initial",
    # "add leak" (contains the real PII this selftest's earlier tests
    # already proved detectable via --range), and "scrub" (HEAD, clean).
    # `git rev-list` lists newest-first, so with --max-commits 1 the ONLY
    # commit scanned is "scrub" (clean) -- the commit holding the real leak
    # is silently excluded, which is exactly the scenario that must report
    # INDETERMINATE (exit 3), never a clean 0.

    # 28-29: default (no --max-commits) --full-history does NOT truncate a
    # small repo, and scans exactly every reachable commit.
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f16.XXXXXX")"
    MAX_COMMITS_EXPLICIT=0
    MAX_COMMITS=2000
    scan_full_history
    _check "$([ "$_SCAN_TRUNCATED" -eq 0 ] && echo 0 || echo 1)" \
        "llm#1204: default --full-history (no --max-commits) does not truncate"
    _check "$([ "$_SCAN_SCANNED" -eq "$_SCAN_TOTAL_REACHABLE" ] && [ "$_SCAN_SCANNED" -ge 3 ] && echo 0 || echo 1)" \
        "llm#1204: default --full-history scans exactly all reachable commits (scanned == total, >= 3)"
    rm -f "$FINDINGS_FILE"

    # 30-32: explicit --max-commits below the true reachable count truncates,
    # scans exactly the cap, and still reports the TRUE total reachable
    # count (not just the cap) for an honest percentage.
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f17.XXXXXX")"
    MAX_COMMITS_EXPLICIT=1
    MAX_COMMITS=1
    scan_full_history 2>/dev/null
    _check "$([ "$_SCAN_TRUNCATED" -eq 1 ] && echo 0 || echo 1)" \
        "llm#1204: explicit --max-commits below the true reachable count truncates --full-history"
    _check "$([ "$_SCAN_SCANNED" -eq 1 ] && echo 0 || echo 1)" \
        "llm#1204: truncated --full-history scans exactly --max-commits commits"
    _check "$([ "$_SCAN_TOTAL_REACHABLE" -ge 3 ] && echo 0 || echo 1)" \
        "llm#1204: truncated --full-history still reports the TRUE total reachable commit count, not the cap"
    rm -f "$FINDINGS_FILE"

    # 33: explicit --max-commits AT/ABOVE the true reachable count does not
    # truncate -- proves this isn't "explicit flag always truncates".
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f18.XXXXXX")"
    MAX_COMMITS_EXPLICIT=1
    MAX_COMMITS=100
    scan_full_history
    _check "$([ "$_SCAN_TRUNCATED" -eq 0 ] && echo 0 || echo 1)" \
        "llm#1204: explicit --max-commits above the true reachable count does not truncate"
    rm -f "$FINDINGS_FILE"
    MAX_COMMITS_EXPLICIT=0
    MAX_COMMITS=2000

    # 34: end-to-end -- a truncated (--max-commits 1) --full-history run
    # that finds 0 findings in what it scanned (the leak-bearing commit is
    # excluded) must exit 3 (INDETERMINATE), never 0.
    local e2e1; e2e1="$(mktemp "${TMPDIR:-/tmp}/pds_e2e1.XXXXXX")"
    ( REPO_ROOT="$tmp/repo" bash "$0" --full-history --max-commits 1 --no-denylist --quiet >"$e2e1" 2>&1 )
    rc=$?
    _check "$([ "$rc" -eq 3 ] && echo 0 || echo 1)" \
        "llm#1204 end-to-end: truncated + clean --full-history exits 3 (INDETERMINATE), not 0"
    _check "$("$GREP" -q "TRUNCATED" "$e2e1" && echo 0 || echo 1)" \
        "llm#1204 end-to-end: truncated run's own output reports TRUNCATED coverage (not just inferable from logs)"
    rm -f "$e2e1"

    # 35: end-to-end control -- the SAME repo, scanned WITHOUT truncation
    # (default, unlimited), finds the real leak and exits 1, never 3 or 0.
    # Proves test 34's exit 3 comes from truncation, not from this repo
    # being clean outright.
    local e2e2; e2e2="$(mktemp "${TMPDIR:-/tmp}/pds_e2e2.XXXXXX")"
    ( REPO_ROOT="$tmp/repo" bash "$0" --full-history --no-denylist --quiet >"$e2e2" 2>&1 )
    rc=$?
    _check "$([ "$rc" -eq 1 ] && echo 0 || echo 1)" \
        "llm#1204 end-to-end: default (untruncated) --full-history on the same repo finds the real leak and exits 1"
    rm -f "$e2e2"

    # 36: findings-present convention is unaffected by truncation -- a
    # truncated scan that DOES cover the leak-bearing commit (max-commits 2:
    # "scrub" + "add leak") still exits 1, not 3 (INDETERMINATE is reserved
    # for the 0-findings case per this script's own exit-code contract).
    local e2e3; e2e3="$(mktemp "${TMPDIR:-/tmp}/pds_e2e3.XXXXXX")"
    ( REPO_ROOT="$tmp/repo" bash "$0" --full-history --max-commits 2 --no-denylist --quiet >"$e2e3" 2>&1 )
    rc=$?
    _check "$([ "$rc" -eq 1 ] && echo 0 || echo 1)" \
        "llm#1204: truncated --full-history WITH findings still exits 1 (findings-present convention unaffected by truncation)"
    rm -f "$e2e3"

    # 37-38: --range has the same shape/fix -- truncating the range to
    # exclude the leak-bearing commit (max-commits 1 out of the 2-commit
    # range "add leak".."scrub") must ALSO report INDETERMINATE, not clean.
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_f19.XXXXXX")"
    MAX_COMMITS_EXPLICIT=1
    MAX_COMMITS=1
    scan_range "$BASE_SHA" "$HEAD_SHA" 2>/dev/null
    _check "$([ "$_SCAN_TRUNCATED" -eq 1 ] && echo 0 || echo 1)" \
        "llm#1204: explicit --max-commits below the range's true commit count truncates --range"
    _check "$([ "$(wc -l < "$FINDINGS_FILE" | tr -d ' ')" -eq 0 ] && echo 0 || echo 1)" \
        "llm#1204: truncated --range (excluding the leak-bearing commit) reports 0 findings in the scanned subset"
    rm -f "$FINDINGS_FILE"
    MAX_COMMITS_EXPLICIT=0
    MAX_COMMITS=2000

    local e2e4; e2e4="$(mktemp "${TMPDIR:-/tmp}/pds_e2e4.XXXXXX")"
    ( REPO_ROOT="$tmp/repo" bash "$0" --range "$BASE_SHA" "$HEAD_SHA" --max-commits 1 --no-denylist --quiet >"$e2e4" 2>&1 )
    rc=$?
    _check "$([ "$rc" -eq 3 ] && echo 0 || echo 1)" \
        "llm#1204 end-to-end: truncated + clean --range exits 3 (INDETERMINATE), not 0"
    rm -f "$e2e4"

    # ── Binary-blob skip (generic rules only) + --tsv + exact exit codes ───
    # Same content, two locations: generic shape rules must fire on the text
    # path and be SKIPPED on a binary-typed path.
    local bin_text='postcode SW1A 1AA and reach +14155552671 here'
    local bin_ext
    # These cases are about the GENERIC rules on binary types; the image gate
    # (llm#1370) would add a finding for 'data/blob.png' in a public repo, so
    # visibility is private for this section (the gate has its own cases below).
    local vis_pre_bin="$VIS"; VIS=private
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_bin0.XXXXXX")"
    printf '%s\n' "$bin_text" | scan_blob "R/notes.txt"
    _check "$([ "$(awk -F'\t' '$1=="generic"' "$FINDINGS_FILE" | grep -c .)" -ge 2 ] && echo 0 || echo 1)" \
        "binary skip control: generic rules DO fire on a text path"
    rm -f "$FINDINGS_FILE"
    for bin_ext in rds rdb rdx woff woff2 ttf png jpg jpeg gif zip gz min.js; do
        FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_bin1.XXXXXX")"
        printf '%s\n' "$bin_text" | scan_blob "abc123456789:data/blob.$bin_ext"
        _check "$([ "$(wc -l < "$FINDINGS_FILE" | tr -d ' ')" -eq 0 ] && echo 0 || echo 1)" \
            "binary skip: generic rules skipped for '.$bin_ext'"
        rm -f "$FINDINGS_FILE"
    done
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_bin2.XXXXXX")"
    printf '%s\n' "$bin_text" | scan_blob "abc123456789:docs/letter.pdf"
    _check "$([ "$(awk -F'\t' '$1=="generic"' "$FINDINGS_FILE" | grep -c .)" -ge 2 ] && echo 0 || echo 1)" \
        "binary skip: .pdf is NOT skipped (PDFs can hold readable PII; documented gap)"
    rm -f "$FINDINGS_FILE"
    # The deny-list must STILL fire on every binary type.
    # NB: no EXAMPLE/FAKE/DUMMY/TEST/FIXTURE word in the sentinel -- that
    # would exempt the whole line from the generic rules and make the
    # "generic stays skipped" half of the assertion vacuous.
    local bin_sentinel="BINSENT_w5Lq8z_denyprobe"
    local saved_denylist_bin=("${DENYLIST_VALUES[@]}")
    DENYLIST_VALUES=("$bin_sentinel")
    for bin_ext in rds woff2 png min.js; do
        FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_bin3.XXXXXX")"
        printf 'binaryish %s %s\n' "$bin_sentinel" "$bin_text" | scan_blob "abc123456789:data/blob.$bin_ext"
        _check "$([ "$(awk -F'\t' '$1=="denylist"' "$FINDINGS_FILE" | grep -c .)" -eq 1 ] && [ "$(awk -F'\t' '$1=="generic"' "$FINDINGS_FILE" | grep -c .)" -eq 0 ] && echo 0 || echo 1)" \
            "binary skip: deny-list still fires on '.$bin_ext' while generic rules stay skipped"
        rm -f "$FINDINGS_FILE"
    done
    DENYLIST_VALUES=("${saved_denylist_bin[@]}")
    VIS="$vis_pre_bin"

    # --tsv end-to-end on the temp repo built above (3 commits; "add leak"
    # holds generic findings). Asserts the machine-readable contract the
    # history-audit wrapper depends on, and exact exit codes 1 / 2.
    local tsv_out; tsv_out="$(mktemp "${TMPDIR:-/tmp}/pds_tsv.XXXXXX")"
    ( REPO_ROOT="$tmp/repo" bash "$0" --full-history --no-denylist --tsv >"$tsv_out" 2>/dev/null )
    rc=$?
    _check "$([ "$rc" -eq 1 ] && echo 0 || echo 1)" "--tsv --full-history with findings exits exactly 1 (rc=$rc)"
    local tsv_n tsv_hdr
    tsv_hdr="$("$GREP" -oE '^private-data-scan: [0-9]+ finding' "$tsv_out" | "$GREP" -oE '[0-9]+')"
    tsv_n="$("$GREP" -c "^FINDING$(printf '\t')" "$tsv_out")"
    _check "$([ -n "$tsv_hdr" ] && [ "$tsv_hdr" -eq "$tsv_n" ] && [ "$tsv_n" -ge 3 ] && echo 0 || echo 1)" \
        "--tsv: FINDING row count ($tsv_n) equals the summary-line count ($tsv_hdr)"
    _check "$([ "$("$GREP" -c "^FINDING$(printf '\t')generic$(printf '\t')" "$tsv_out")" -eq "$tsv_n" ] && echo 0 || echo 1)" \
        "--tsv: rows carry the source column"
    rm -f "$tsv_out"
    ( bash "$0" --no-such-flag >/dev/null 2>&1 )
    rc=$?
    _check "$([ "$rc" -eq 2 ] && echo 0 || echo 1)" "unknown argument exits exactly 2 (rc=$rc)"
    ( bash "$0" >/dev/null 2>&1 )
    rc=$?
    _check "$([ "$rc" -eq 2 ] && echo 0 || echo 1)" "no mode exits exactly 2 (rc=$rc)"

    # ── JohnGavin/llm#1358: three blind spots ──────────────────────────────
    # Sentinels carry no EXAMPLE/FAKE/DUMMY/TEST/FIXTURE word and are only
    # ever used as deny-list values, never read from the real deny-list.
    local selftest_indet=() cnt

    # Item 1: a blob that is NOT valid UTF-8 must still be scanned under a
    # UTF-8 locale. The precondition (tr really does fail on it there) is
    # checked, otherwise the test would be vacuous on this machine.
    # Pick any installed UTF-8 locale (llm#1358): prefer en_GB, en_US, then
    # C.UTF-8 (always present on glibc Linux, listed as C.utf8), then any
    # `locale -a` entry matching utf-?8. GNU tr/grep are byte-safe, so on Linux
    # tr does not fail on \377 there; the locale-independence assertion below
    # is still meaningful, so existence of the locale is the only requirement.
    local utf8loc="" cand avail norm
    avail="$(locale -a 2>/dev/null)"
    for cand in en_GB.UTF-8 en_US.UTF-8 C.UTF-8; do
        norm="$(printf '%s' "$cand" | tr -d '-' | tr '[:upper:]' '[:lower:]')"
        utf8loc="$(printf '%s\n' "$avail" | awk -v n="$norm" '{ l=$0; gsub(/-/,"",l); if (tolower(l)==n) { print $0; exit } }')"
        [ -n "$utf8loc" ] && break
    done
    if [ -z "$utf8loc" ]; then
        utf8loc="$(printf '%s\n' "$avail" | awk 'tolower($0) ~ /utf-?8/ { print $0; exit }')"
    fi
    if [ -n "$utf8loc" ]; then
        local u_sent="NONUTF8_w4Kp7Zq_denyprobe" saved_dl=("${DENYLIST_VALUES[@]}")
        DENYLIST_VALUES=("$u_sent")
        FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_u1.XXXXXX")"
        ( export LC_ALL="$utf8loc"; printf 'head \377\376 bytes %s tail\nsecond line\n' "$u_sent" | scan_blob "R/blob.bin" )
        _check "$([ "$(awk -F'\t' '$1=="denylist" && $4=="1"' "$FINDINGS_FILE" | grep -c .)" -eq 1 ] && echo 0 || echo 1)" \
            "llm#1358 item 1: deny-list value on a NON-UTF-8 line is detected under a UTF-8 locale ($utf8loc)"
        rm -f "$FINDINGS_FILE"
        DENYLIST_VALUES=("${saved_dl[@]}")
    else
        selftest_indet+=("no UTF-8 locale available: item 1 (non-UTF-8 blob) could not be exercised")
    fi

    # Item 1, locale independence: the SAME scanner run, as a subprocess,
    # must produce the same findings whatever LANG the caller has. The
    # comparison is between a UTF-8 caller locale and LC_ALL=C.
    if [ -n "$utf8loc" ]; then
        local l_sent="LOCALEDEP_b2Hs9Xv_denyprobe" l_blob="$tmp/nonutf8.bin" l_pv="$tmp/l_pv.env"
        printf 'MY_VALUE=%s\n' "$l_sent" > "$l_pv"; chmod 600 "$l_pv"
        printf 'pre \377\376 %s post\nplain +14155552671 line\n' "$l_sent" > "$l_blob"
        mkdir -p "$tmp/home"
        local l_utf l_c
        l_utf="$(env -u LC_ALL HOME="$tmp/home" LANG="$utf8loc" UNIFIED_DB_PATH="$tmp/none.duckdb" PRIVATE_VALUES_FILE="$l_pv" bash "$0" --paths "$l_blob" --tsv 2>/dev/null | "$GREP" -c '^FINDING')"
        l_c="$(env HOME="$tmp/home" LC_ALL=C UNIFIED_DB_PATH="$tmp/none.duckdb" PRIVATE_VALUES_FILE="$l_pv" bash "$0" --paths "$l_blob" --tsv 2>/dev/null | "$GREP" -c '^FINDING')"
        _check "$([ "$l_utf" = "$l_c" ] && [ "$l_c" -ge 2 ] && echo 0 || echo 1)" \
            "llm#1358 item 1: findings under LANG=$utf8loc ($l_utf) equal findings under LC_ALL=C ($l_c), both >= 2 (deny-list + e164)"
    fi

    # Item 2: files added in a ROOT commit are scanned by --full-history and
    # --range. (diff-tree without --root lists nothing for a root commit.)
    local rr="$tmp/rootrepo" r_sent="ROOTCOMMIT_n3Vx8Lm_denyprobe" r_sha
    mkdir -p "$rr"
    git -C "$rr" init -q
    git -C "$rr" config user.email t@example.com
    git -C "$rr" config user.name t
    printf 'value %s here\n' "$r_sent" > "$rr/rootfile.txt"
    git -C "$rr" add rootfile.txt
    git -C "$rr" commit -q -m "root adds a file"
    r_sha="$(git -C "$rr" rev-parse HEAD)"
    git -C "$rr" rm -q rootfile.txt
    git -C "$rr" commit -q -m "remove it again"
    local saved_root="$REPO_ROOT" saved_dl2=("${DENYLIST_VALUES[@]}")
    REPO_ROOT="$rr"
    DENYLIST_VALUES=("$r_sent")
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_r1.XXXXXX")"
    scan_full_history
    _check "$([ "$(awk -F'\t' -v s="${r_sha:0:12}:rootfile.txt" '$1=="denylist" && $3==s' "$FINDINGS_FILE" | grep -c .)" -eq 1 ] && echo 0 || echo 1)" \
        "llm#1358 item 2: --full-history scans a file added in the ROOT commit"
    rm -f "$FINDINGS_FILE"
    # --range: a root commit is only inside a..b when a is on an unrelated
    # history, so build one with plumbing (no checkout, no refs).
    local r_base r_tree r_orph r_blob
    r_base="$(git -C "$rr" rev-parse HEAD)"
    r_blob="$(printf 'value %s again\n' "$r_sent" | git -C "$rr" hash-object -w --stdin)"
    r_tree="$(printf '100644 blob %s\tunrelated.txt\n' "$r_blob" | git -C "$rr" mktree)"
    r_orph="$(git -C "$rr" commit-tree "$r_tree" -m "unrelated root")"
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_r2.XXXXXX")"
    scan_range "$r_base" "$r_orph"
    _check "$([ "$(awk -F'\t' -v s="${r_orph:0:12}:unrelated.txt" '$1=="denylist" && $3==s' "$FINDINGS_FILE" | grep -c .)" -eq 1 ] && echo 0 || echo 1)" \
        "llm#1358 item 2: --range scans a file added in a ROOT commit inside the range"
    rm -f "$FINDINGS_FILE"
    REPO_ROOT="$saved_root"
    DENYLIST_VALUES=("${saved_dl2[@]}")

    # Item 3: document-format gate. VIS is set in-process; INDET_FILE is
    # reset before each case.
    local ext vis_saved="$VIS"
    local -a doc_exts=(pdf docx xlsx doc xls odt rtf eml msg)
    for ext in "${doc_exts[@]}"; do
        FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_d1.XXXXXX")"; : > "$INDET_FILE"
        VIS=public
        printf 'opaque\n' | scan_blob "abc123456789:docs/f.$ext"
        cnt="$(awk -F'\t' '$1=="gate" && $2=="critical" && $5=="document-format-blocked"' "$FINDINGS_FILE" | grep -c .)"
        _check "$([ "$cnt" -eq 1 ] && echo 0 || echo 1)" "llm#1358 item 3: .$ext in a PUBLIC repo is blocked (document-format-blocked, critical)"
        rm -f "$FINDINGS_FILE"
        FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_d2.XXXXXX")"
        VIS=private
        printf 'opaque\n' | scan_blob "abc123456789:docs/f.$ext"
        cnt="$(awk -F'\t' '$1=="gate"' "$FINDINGS_FILE" | grep -c .)"
        _check "$([ "$cnt" -eq 0 ] && echo 0 || echo 1)" "llm#1358 item 3: .$ext in a PRIVATE repo is not gated"
        rm -f "$FINDINGS_FILE"
    done
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_d3.XXXXXX")"
    VIS=public
    printf 'opaque\n' | scan_blob "docs/UPPER.PDF"
    _check "$([ "$(awk -F'\t' '$1=="gate"' "$FINDINGS_FILE" | grep -c .)" -eq 1 ] && echo 0 || echo 1)" "llm#1358 item 3: extension match is case-insensitive (.PDF)"
    : > "$FINDINGS_FILE"
    printf 'opaque\n' | scan_blob "docs/notes.pdf.txt"
    printf 'opaque\n' | scan_blob "docs/pdf"
    _check "$([ "$(awk -F'\t' '$1=="gate"' "$FINDINGS_FILE" | grep -c .)" -eq 0 ] && echo 0 || echo 1)" "llm#1358 item 3: 'notes.pdf.txt' and a bare 'pdf' are not document formats"
    rm -f "$FINDINGS_FILE"

    # History mode reports its own rule.
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_d4.XXXXXX")"
    local mode_saved="$MODE"
    MODE="full-history"
    printf 'opaque\n' | scan_blob "abc123456789:docs/old.docx"
    MODE="$mode_saved"
    _check "$([ "$(awk -F'\t' '$1=="gate" && $2=="critical" && $5=="document-format-in-public-history"' "$FINDINGS_FILE" | grep -c .)" -eq 1 ] && echo 0 || echo 1)" \
        "llm#1358 item 3: --full-history reports document-format-in-public-history (critical)"
    rm -f "$FINDINGS_FILE"

    # Visibility: UNKNOWN is public (fail closed). gh is stubbed via PATH.
    local stubdir="$tmp/stub"; mkdir -p "$stubdir"
    printf '#!/bin/sh\n[ "$STUB_VIS" = fail ] && exit 1\necho "$STUB_VIS"\n' > "$stubdir/gh"
    chmod +x "$stubdir/gh"
    saved_root="$REPO_ROOT"; REPO_ROOT="$tmp/repo"
    _check "$([ "$(PATH="$stubdir:$PATH" STUB_VIS=fail repo_visibility)" = "public" ] && echo 0 || echo 1)" "llm#1358 item 3: visibility lookup failure is treated as public"
    _check "$([ "$(PATH="$stubdir:$PATH" STUB_VIS=PRIVATE repo_visibility)" = "private" ] && echo 0 || echo 1)" "llm#1358 item 3: visibility PRIVATE is private"
    _check "$([ "$(PATH="$stubdir:$PATH" STUB_VIS=PUBLIC repo_visibility)" = "public" ] && echo 0 || echo 1)" "llm#1358 item 3: visibility PUBLIC is public"
    REPO_ROOT="$saved_root"

    # Allow-list: exact path + stated reason; anything else allows nothing.
    local alf="$tmp/doc_allow.txt"
    {
        printf '# comment\n\n'
        printf 'docs/ok.pdf | published brochure, no personal data\n'
        printf 'docs/bare.pdf\n'
        printf 'docs/noreason.pdf | \n'
        printf ' | reason without a path\n'
    } > "$alf"
    DOC_ALLOWLIST_FILE="$alf"
    load_doc_allowlist 2>/dev/null
    _check "$([ "${#DOC_ALLOW_PATHS[@]}" -eq 1 ] && [ "${DOC_ALLOW_PATHS[0]}" = "docs/ok.pdf" ] && echo 0 || echo 1)" \
        "llm#1358 item 3: allow-list keeps only entries with a path AND a reason (1 of 4 non-comment lines)"
    VIS=public
    for loc in "docs/ok.pdf" "staged:docs/ok.pdf" "abc123456789:docs/ok.pdf"; do
        FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_a1.XXXXXX")"
        printf 'opaque\n' | scan_blob "$loc"
        _check "$([ "$(awk -F'\t' '$1=="gate"' "$FINDINGS_FILE" | grep -c .)" -eq 0 ] && echo 0 || echo 1)" "llm#1358 item 3: allow-listed path is not blocked (location form '$loc')"
        rm -f "$FINDINGS_FILE"
    done
    for loc in "docs/bare.pdf" "docs/noreason.pdf" "other/docs/ok.pdf" "docs/ok.pdf.docx"; do
        FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_a2.XXXXXX")"
        printf 'opaque\n' | scan_blob "$loc"
        _check "$([ "$(awk -F'\t' '$1=="gate"' "$FINDINGS_FILE" | grep -c .)" -eq 1 ] && echo 0 || echo 1)" "llm#1358 item 3: '$loc' is NOT allow-listed (no reason / not an exact path) and is blocked"
        rm -f "$FINDINGS_FILE"
    done
    DOC_ALLOW_PATHS=(); DOC_ALLOWLIST_FILE=""

    # Text extraction (pdftotext). The PDF stores its text as a hex string, so
    # the literal value is NOT present in the file's bytes: only extraction can
    # find it. Control: with the extractor missing, nothing is found and the
    # file is recorded as not-inspected.
    _mkpdf() {   # _mkpdf FILE TEXT
        local hex body
        hex="$(printf '%s' "$2" | od -An -tx1 | tr -d ' \n')"
        body="BT /F1 12 Tf 10 50 Td <${hex}> Tj ET"
        {
            printf '%%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
            printf '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
            printf '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 100]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj\n'
            printf '4 0 obj<</Length %s>>stream\n%s\nendstream endobj\n' "${#body}" "$body"
            printf '5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\n'
            printf 'trailer<</Root 1 0 R/Size 6>>\n%%%%EOF\n'
        } > "$1"
    }
    local p_sent="PDFTEXT_h6Rw2Qk_denyprobe" pdf1="$tmp/with_value.pdf" pdf2="$tmp/plain.pdf"
    _mkpdf "$pdf1" "see $p_sent end"
    _mkpdf "$pdf2" "hello world"
    _check "$("$GREP" -qF -- "$p_sent" "$pdf1" && echo 1 || echo 0)" "llm#1358 item 3 sanity: the fixture PDF's raw bytes do not contain the value"
    local saved_dl3=("${DENYLIST_VALUES[@]}"); DENYLIST_VALUES=("$p_sent")
    VIS=private
    if command -v "$PDFTOTEXT" >/dev/null 2>&1; then
        FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_x1.XXXXXX")"; : > "$INDET_FILE"
        scan_blob "abc123456789:docs/x.pdf" < "$pdf1"
        _check "$([ "$(awk -F'\t' '$1=="denylist"' "$FINDINGS_FILE" | grep -c .)" -ge 1 ] && echo 0 || echo 1)" "llm#1358 item 3: a deny-list value inside a PDF text layer is found via pdftotext"
        _check "$([ ! -s "$INDET_FILE" ] && echo 0 || echo 1)" "llm#1358 item 3: a successfully extracted PDF is not marked not-inspected"
        rm -f "$FINDINGS_FILE"
    else
        selftest_indet+=("pdftotext not installed: PDF text-extraction checks could not be exercised")
    fi
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_x2.XXXXXX")"; : > "$INDET_FILE"
    ( PDFTOTEXT="no_such_extractor_1358"; scan_blob "abc123456789:docs/x.pdf" < "$pdf1" )
    _check "$([ "$(awk -F'\t' '$1=="denylist"' "$FINDINGS_FILE" | grep -c .)" -eq 0 ] && [ "$(grep -c . "$INDET_FILE")" -eq 1 ] && echo 0 || echo 1)" \
        "llm#1358 item 3: missing extractor -> nothing found AND the file is recorded as not-inspected (control)"
    rm -f "$FINDINGS_FILE"; : > "$INDET_FILE"
    DENYLIST_VALUES=("${saved_dl3[@]}")
    VIS="$vis_saved"

    # End to end: exact exit codes. gh is stubbed; the scanner runs as a
    # subprocess against synthetic repos with HOME redirected.
    local er="$tmp/e2erepo" e2e_out="$tmp/e2e.out" e2e_err="$tmp/e2e.err" e2e_rc
    mkdir -p "$er/docs" "$tmp/home"
    git -C "$er" init -q
    git -C "$er" config user.email t@example.com
    git -C "$er" config user.name t
    cp "$pdf2" "$er/docs/ok.pdf"
    git -C "$er" add docs/ok.pdf
    git -C "$er" commit -q -m "add a document"
    printf 'docs/ok.pdf | published brochure, no personal data\n' > "$tmp/e2e_allow.txt"
    _e2e() {   # _e2e VIS ALLOWLIST EXTRACTOR ARGS...
        local v="$1" al="$2" ex="$3"; shift 3
        env HOME="$tmp/home" UNIFIED_DB_PATH="$tmp/none.duckdb" PATH="$stubdir:$PATH" STUB_VIS="$v" \
            REPO_ROOT="$er" PRIVATE_DATA_DOC_ALLOWLIST="$al" ${ex:+PRIVATE_DATA_SCAN_PDFTOTEXT="$ex"} \
            bash "$0" "$@" --no-denylist --tsv >"$e2e_out" 2>"$e2e_err"
        e2e_rc=$?
    }
    _e2e fail "" "" --full-history
    _check "$([ "$e2e_rc" -eq 1 ] && "$GREP" -q 'document-format-in-public-history' "$e2e_out" && echo 0 || echo 1)" \
        "llm#1358 e2e: --full-history, unknown visibility, un-allow-listed PDF -> exit exactly 1 with document-format-in-public-history (rc=$e2e_rc)"
    _e2e PUBLIC "$tmp/e2e_allow.txt" "no_such_extractor_1358" --full-history
    _check "$([ "$e2e_rc" -eq 3 ] && echo 0 || echo 1)" "llm#1358 e2e: allow-listed PDF, extractor missing -> exit exactly 3 INDETERMINATE (rc=$e2e_rc)"
    if command -v "$PDFTOTEXT" >/dev/null 2>&1; then
        _e2e PUBLIC "$tmp/e2e_allow.txt" "" --full-history
        _check "$([ "$e2e_rc" -eq 0 ] && echo 0 || echo 1)" "llm#1358 e2e: allow-listed PDF, extractor present, no PII -> exit exactly 0 (rc=$e2e_rc)"
        _e2e PRIVATE "" "" --full-history
        _check "$([ "$e2e_rc" -eq 0 ] && echo 0 || echo 1)" "llm#1358 e2e: PDF in a PRIVATE repo, extractor present -> exit exactly 0 (rc=$e2e_rc)"
    fi
    local e2e_empty e2e_unrel
    e2e_empty="$(git -C "$er" hash-object -t tree -w /dev/null)"
    e2e_unrel="$(git -C "$er" commit-tree "$e2e_empty" -m "unrelated empty root")"
    _e2e PUBLIC "$tmp/e2e_allow.txt" "no_such_extractor_1358" --range "$e2e_unrel" HEAD
    _check "$([ "$e2e_rc" -eq 3 ] && echo 0 || echo 1)" "llm#1358 e2e: --range reaches a PDF added in a root commit (un-inspectable -> exit exactly 3, not a clean 0) (rc=$e2e_rc)"
    _e2e fail "" "" --paths "$er/docs/ok.pdf"
    _check "$([ "$e2e_rc" -eq 1 ] && "$GREP" -q 'document-format-blocked' "$e2e_out" && echo 0 || echo 1)" "llm#1358 e2e: --paths no longer skips a PDF silently; gate fires -> exit exactly 1 (rc=$e2e_rc)"

    # ── llm#1369 sensitive-filename and llm#1370 image-outside-figures ─────
    # _rule_count LOCATION RULE -> number of gate findings of RULE for a blob
    # (content is irrelevant to both rules, so a one-line stub is used).
    _rule_count() {
        FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_pr.XXXXXX")"
        printf 'opaque\n' | scan_blob "$1"
        awk -F'\t' -v r="$2" '$1=="gate" && $5==r' "$FINDINGS_FILE" | grep -c .
        rm -f "$FINDINGS_FILE"
    }
    VIS=public
    DOC_ALLOW_PATHS=()
    local lp
    # Fires: strong words in any position/extension; broad words with a
    # document/image/data extension; word boundaries incl. separators and digits.
    for lp in "abc123456789:notes/nhs-letter.txt" "abc123456789:x/Hospital/readme.md" \
              "abc123456789:in/payslip2024.csv" "abc123456789:in/p60.png" \
              "abc123456789:id/Passport_scan.jpg" "abc123456789:med/discharge.R" \
              "abc123456789:fin/bank_statement.pdf" "abc123456789:fin/INVOICE-7.xlsx" \
              "abc123456789:a/tax.csv" "abc123456789:a/contacts.tsv" \
              "abc123456789:a/licence.docx" "staged:a/letter.txt"; do
        _check "$([ "$(_rule_count "$lp" sensitive-filename)" -eq 1 ] && echo 0 || echo 1)" \
            "llm#1369: sensitive-filename (critical gate) fires for '$lp'"
    done
    # Does not fire: code identifiers and lookalikes (the false positives the
    # tuning removed): broad word with a code extension, substring-only hits.
    for lp in "abc123456789:R/tax.R" "abc123456789:lib/ipaddress.pyi" "abc123456789:R/taxonomy.R" \
              "abc123456789:src/statement.sql" "abc123456789:bin/signal.py" "abc123456789:R/address.R" \
              "abc123456789:hooks/clinical_data_guard.sh" "abc123456789:docs/letterhead.css" \
              "abc123456789:a/dischargeable.txt" "abc123456789:a/bankruptcy.pdf" \
              "abc123456789:a/contactless.csv" "abc123456789:README.md" "abc123456789:a/p6.png" \
              "abc123456789:a/nhsx/x"; do
        _check "$([ "$(_rule_count "$lp" sensitive-filename)" -eq 0 ] && echo 0 || echo 1)" \
            "llm#1369: sensitive-filename does NOT fire for '$lp' (code identifier / lookalike)"
    done
    # Severity and source.
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_pr2.XXXXXX")"
    printf 'opaque\n' | scan_blob "abc123456789:a/payslip.txt"
    _check "$([ "$(awk -F'\t' '$1=="gate" && $2=="critical" && $5=="sensitive-filename"' "$FINDINGS_FILE" | grep -c .)" -eq 1 ] && [ "$(grep -c . "$FINDINGS_FILE")" -eq 1 ] && echo 0 || echo 1)" \
        "llm#1369: exactly one critical gate finding for a payslip path"
    rm -f "$FINDINGS_FILE"
    # Private repo: not gated. Allow-list: exact path + reason lifts it; a near miss does not.
    VIS=private
    _check "$([ "$(_rule_count "abc123456789:a/payslip.txt" sensitive-filename)" -eq 0 ] && echo 0 || echo 1)" "llm#1369: private repo is not gated"
    VIS=public
    local af2="$tmp/path_allow.txt"
    {
        printf 'a/payslip.txt | synthetic sample for documentation, no real person\n'
        printf 'a/nhs.txt\n'
        printf 'img/photo.png | product screenshot, no personal content\n'
    } > "$af2"
    DOC_ALLOWLIST_FILE="$af2"; load_doc_allowlist 2>/dev/null
    _check "$([ "$(_rule_count "abc123456789:a/payslip.txt" sensitive-filename)" -eq 0 ] && echo 0 || echo 1)" "llm#1369: allow-listed path is not flagged"
    _check "$([ "$(_rule_count "staged:a/payslip.txt" sensitive-filename)" -eq 0 ] && echo 0 || echo 1)" "llm#1369: allow-list applies to the 'staged:' location form"
    _check "$([ "$(_rule_count "abc123456789:b/payslip.txt" sensitive-filename)" -eq 1 ] && echo 0 || echo 1)" "llm#1369: same name in another directory is still flagged (exact paths only)"
    _check "$([ "$(_rule_count "abc123456789:a/nhs.txt" sensitive-filename)" -eq 1 ] && echo 0 || echo 1)" "llm#1369: allow-list line with no reason allows nothing"
    # Falsification: with the word lists emptied the positives must go quiet,
    # proving the fires above depend on the lists and not on something else.
    local sw_saved="$FILENAME_STRONG_WORDS" bw_saved="$FILENAME_BROAD_WORDS"
    FILENAME_STRONG_WORDS=" "; FILENAME_BROAD_WORDS=" "
    _check "$([ "$(_rule_count "abc123456789:b/payslip.txt" sensitive-filename)" -eq 0 ] && [ "$(_rule_count "abc123456789:fin/bank_statement.pdf" sensitive-filename)" -eq 0 ] && echo 0 || echo 1)" \
        "llm#1369 falsification: with both word lists emptied the rule goes quiet (it was the lists that fired)"
    FILENAME_STRONG_WORDS="$sw_saved"; FILENAME_BROAD_WORDS="$bw_saved"
    _check "$([ "$(_rule_count "abc123456789:b/payslip.txt" sensitive-filename)" -eq 1 ] && echo 0 || echo 1)" "llm#1369 falsification: lists restored, rule fires again"

    # Images (#1370). Outside generated-figure folders: blocked.
    for lp in "abc123456789:img/photo.JPG" "abc123456789:letter.png" "abc123456789:notes/docs/scan.jpg" \
              "abc123456789:man/figures2/a.png" "abc123456789:vignettes/a.png" "abc123456789:R/pics/x.heic" \
              "abc123456789:img/photo2.png" "staged:scans/page1.tiff" "abc123456789:x/docs.gif"; do
        _check "$([ "$(_rule_count "$lp" image-outside-figures)" -eq 1 ] && echo 0 || echo 1)" \
            "llm#1370: image-outside-figures (critical gate) fires for '$lp'"
    done
    # Generated-figure folders and non-images: not blocked.
    for lp in "abc123456789:man/figures/logo.png" "abc123456789:docs/reference/figures/p.png" \
              "abc123456789:vignettes/intro_files/figure-html/c.png" "abc123456789:vignettes/intro_files/x.png" \
              "abc123456789:report_files/figure-html/p-1.png" "abc123456789:_freeze/post/p.png" \
              "abc123456789:sub/_freeze/post/p.png" "abc123456789:_site/p.png" \
              "abc123456789:R/plot.R" "abc123456789:img/diagram.svg" "abc123456789:img/photo.png.txt"; do
        _check "$([ "$(_rule_count "$lp" image-outside-figures)" -eq 0 ] && echo 0 || echo 1)" \
            "llm#1370: image-outside-figures does NOT fire for '$lp' (generated folder / not an image)"
    done
    # Allow-list (img/photo.png has a reason; img/photo2.png does not exist there).
    _check "$([ "$(_rule_count "abc123456789:img/photo.png" image-outside-figures)" -eq 0 ] && echo 0 || echo 1)" "llm#1370: allow-listed image is not blocked"
    _check "$([ "$(_rule_count "abc123456789:img/photo2.png" image-outside-figures)" -eq 1 ] && echo 0 || echo 1)" "llm#1370: a neighbouring image is still blocked"
    VIS=private
    _check "$([ "$(_rule_count "abc123456789:img/photo2.png" image-outside-figures)" -eq 0 ] && echo 0 || echo 1)" "llm#1370: private repo is not gated"
    VIS=public
    # Severity/rule split: critical in range/staged, high + own rule in --full-history. Size, not content.
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_im1.XXXXXX")"
    printf '12345678901234567890' | scan_blob "abc123456789:img/photo2.png"
    _check "$([ "$(awk -F'\t' '$2=="critical" && $5=="image-outside-figures" && $6 ~ /20 bytes/' "$FINDINGS_FILE" | grep -c .)" -eq 1 ] && echo 0 || echo 1)" "llm#1370: finding is critical and reports the size (20 bytes), not content"
    rm -f "$FINDINGS_FILE"
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pds_im2.XXXXXX")"
    mode_saved="$MODE"; MODE="full-history"
    printf 'x' | scan_blob "abc123456789:img/photo2.png"
    MODE="$mode_saved"
    _check "$([ "$(awk -F'\t' '$2=="high" && $5=="image-in-public-history"' "$FINDINGS_FILE" | grep -c .)" -eq 1 ] && [ "$(awk -F'\t' '$5=="image-outside-figures"' "$FINDINGS_FILE" | grep -c .)" -eq 0 ] && echo 0 || echo 1)" \
        "llm#1370: --full-history reports image-in-public-history at severity high (not critical)"
    rm -f "$FINDINGS_FILE"
    # Falsification: IMAGE_EXTS emptied -> nothing fires.
    local ie_saved="$IMAGE_EXTS"; IMAGE_EXTS=" "
    _check "$([ "$(_rule_count "abc123456789:img/photo2.png" image-outside-figures)" -eq 0 ] && echo 0 || echo 1)" "llm#1370 falsification: with IMAGE_EXTS emptied the rule goes quiet"
    IMAGE_EXTS="$ie_saved"
    _check "$([ "$(_rule_count "abc123456789:img/photo2.png" image-outside-figures)" -eq 1 ] && echo 0 || echo 1)" "llm#1370 falsification: restored, rule fires again"
    DOC_ALLOW_PATHS=(); DOC_ALLOWLIST_FILE=""

    # End to end on a synthetic repo: exact exit codes in staged / range / history.
    local pr="$tmp/pathrepo" pr_allow="$tmp/pr_allow.txt"
    mkdir -p "$pr/img" "$pr/man/figures" "$pr/R"
    git -C "$pr" init -q
    git -C "$pr" config user.email t@example.com
    git -C "$pr" config user.name t
    printf 'clean\n' > "$pr/README.txt"
    git -C "$pr" add README.txt
    git -C "$pr" commit -q -m "base"
    local pr_base; pr_base="$(git -C "$pr" rev-parse HEAD)"
    printf 'PNGDATA' > "$pr/img/photo.png"
    printf 'PNGDATA' > "$pr/man/figures/logo.png"
    printf 'x <- 1\n' > "$pr/R/tax.R"
    printf 'a,b\n' > "$pr/payslip.csv"
    git -C "$pr" add img/photo.png man/figures/logo.png R/tax.R payslip.csv
    _pe2e() {   # _pe2e VIS ALLOWLIST ARGS...
        local v="$1" al="$2"; shift 2
        env HOME="$tmp/home" UNIFIED_DB_PATH="$tmp/none.duckdb" PATH="$stubdir:$PATH" STUB_VIS="$v" \
            REPO_ROOT="$pr" PRIVATE_DATA_DOC_ALLOWLIST="$al" bash "$0" "$@" --no-denylist --tsv >"$e2e_out" 2>"$e2e_err"
        e2e_rc=$?
    }
    _pe2e PUBLIC "" --staged
    _check "$([ "$e2e_rc" -eq 1 ] && [ "$("$GREP" -c 'image-outside-figures' "$e2e_out")" -eq 1 ] && [ "$("$GREP" -c 'sensitive-filename' "$e2e_out")" -eq 1 ] && echo 0 || echo 1)" \
        "llm#1369/1370 e2e: --staged, public -> exit exactly 1; ONE image finding (img/, not man/figures/) and ONE filename finding (payslip, not tax.R) (rc=$e2e_rc)"
    _pe2e PRIVATE "" --staged
    _check "$([ "$e2e_rc" -eq 0 ] && echo 0 || echo 1)" "llm#1369/1370 e2e: --staged, private repo -> exit exactly 0 (rc=$e2e_rc)"
    printf 'img/photo.png | product screenshot, no personal content\npayslip.csv | synthetic sample, no real person\n' > "$pr_allow"
    _pe2e PUBLIC "$pr_allow" --staged
    _check "$([ "$e2e_rc" -eq 0 ] && echo 0 || echo 1)" "llm#1369/1370 e2e: --staged, both paths allow-listed with reasons -> exit exactly 0 (rc=$e2e_rc)"
    git -C "$pr" commit -q -m "add images and a payslip"
    _pe2e PUBLIC "" --range "$pr_base" HEAD
    _check "$([ "$e2e_rc" -eq 1 ] && "$GREP" -q 'critical.*image-outside-figures\|image-outside-figures' "$e2e_out" && echo 0 || echo 1)" "llm#1370 e2e: --range (pre-push/CI), public -> exit exactly 1, rule image-outside-figures (rc=$e2e_rc)"
    _pe2e PUBLIC "" --full-history
    _check "$([ "$e2e_rc" -eq 1 ] && "$GREP" -q 'image-in-public-history' "$e2e_out" && ! "$GREP" -q 'image-outside-figures' "$e2e_out" && echo 0 || echo 1)" "llm#1370 e2e: --full-history, public -> exit 1 with image-in-public-history only (rc=$e2e_rc)"
    _pe2e PUBLIC "$pr_allow" --full-history
    _check "$([ "$e2e_rc" -eq 0 ] && echo 0 || echo 1)" "llm#1369/1370 e2e: --full-history with both allow-listed -> exit exactly 0 (rc=$e2e_rc)"
    _pe2e fail "" --full-history
    _check "$([ "$e2e_rc" -eq 1 ] && echo 0 || echo 1)" "llm#1369/1370 e2e: unknown visibility is treated as public -> exit exactly 1 (rc=$e2e_rc)"
    VIS="$vis_saved"

    if [ "${#selftest_indet[@]}" -gt 0 ]; then
        local m
        for m in "${selftest_indet[@]}"; do echo "INDETERMINATE  $m"; done
    fi

    rm -rf "$tmp"

    echo ""
    echo "selftest: $pass/$total PASS"
    if [ "$pass" -ne "$total" ]; then return 1; fi
    # Every check that ran passed, but some could not run: not a clean result.
    if [ "${#selftest_indet[@]}" -gt 0 ]; then return 3; fi
    return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
if [ "$MODE" = "selftest" ]; then
    run_selftest
    exit $?
fi

# THE NON-NEGOTIABLE REQUIREMENT — unconditional, first thing, every mode.
if [ "$REQUIRE_DENYLIST" -eq 1 ] && [ "$MODE" != "content-stdin" ]; then
    if ! load_denylist; then
        echo "BLOCKED (fail-closed): deny-list at $DENYLIST_FILE is missing, unreadable, or empty." >&2
        echo "Create it (KEY=value lines, mode 600) before this scanner can run in its default mode." >&2
        echo "See .claude/scripts/private_values_sync.sh and .claude/rules/private-data-scanning.md." >&2
        echo "To run generic-pattern-only (no deny-list, e.g. CI on a public runner): --no-denylist" >&2
        log_line "BLOCKED_MISSING_DENYLIST"
        exit 1
    fi
else
    load_denylist || true   # best-effort; --no-denylist tolerates absence
fi
assert_can_detect

hk_run_start

# Visibility and the document allow-list are resolved BEFORE scanning: the
# document-format gate (llm#1358) reads them inside scan_blob.
VIS="$(repo_visibility)"
load_doc_allowlist

case "$MODE" in
    staged) scan_staged ;;
    range) scan_range "$RANGE_A" "$RANGE_B" ;;
    paths) scan_paths ;;
    full-history) scan_full_history ;;
    content-stdin) scan_content_stdin ;;
esac

TOTAL=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
N_INDET=$(wc -l < "$INDET_FILE" | tr -d ' ')
if [ "${N_INDET:-0}" -gt 0 ]; then
    echo "private-data-scan: ${N_INDET} document file(s) could not be text-inspected (content NOT scanned):" >&2
    awk -F'\t' '{printf "  %s -- %s\n", $1, $2}' "$INDET_FILE" >&2
fi

print_report
write_findings_to_db
log_line "mode=${MODE} visibility=${VIS} findings=${TOTAL}"

if [ "$TOTAL" -gt 0 ]; then
    if [ "$VIS" = "public" ]; then
        hk_run_end "ok" "$TOTAL"
        exit 1
    fi
    # Private repo: deny-list (exact known-bad) hits still block; generic
    # pattern-only hits warn but do not block (private repos may legitimately
    # hold real personal data in configs/notes -- see repo_visibility() note).
    if awk -F'\t' '$1=="denylist"' "$FINDINGS_FILE" | grep -q .; then
        hk_run_end "ok" "$TOTAL"
        exit 1
    fi
    echo "private-data-scan: repo is private -- generic-pattern findings reported but not blocking. Deny-list findings always block." >&2
    hk_run_end "ok" "$TOTAL"
    exit 0
fi

# TOTAL == 0: nothing found in what WAS scanned. If an explicit
# --max-commits truncated a --full-history/--range scan before it covered
# every reachable commit, that is INDETERMINATE, not clean -- see
# checks-must-distinguish-unknown and this file's header. Findings-present
# runs above are unaffected: this branch only ever executes when TOTAL is 0.
if [ "${N_INDET:-0}" -gt 0 ]; then
    echo "private-data-scan: INDETERMINATE -- ${N_INDET} document file(s) were not text-inspected (see above); absence of findings is NOT proof they are clean. Install poppler (pdftotext) or remove the file." >&2
    log_line "mode=${MODE} visibility=${VIS} findings=${TOTAL} unextracted=${N_INDET} result=indeterminate"
    hk_run_end "ok" "$TOTAL"
    exit 3
fi
if [ "${_SCAN_TRUNCATED:-0}" -eq 1 ]; then
    echo "private-data-scan: INDETERMINATE -- scan was truncated (--max-commits) before covering every reachable commit; absence of findings in the scanned subset is NOT proof of a clean history/range. See the WARNING above; re-run without --max-commits (or with a higher value) for a determinate result." >&2
    log_line "mode=${MODE} visibility=${VIS} findings=${TOTAL} truncated=1 result=indeterminate"
    hk_run_end "ok" "$TOTAL"
    exit 3
fi

hk_run_end "ok" "$TOTAL"
exit 0
