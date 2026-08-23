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
#   private_data_scan.sh --range <rev1> <rev2> [--require-denylist|--no-denylist] [--json] [--quiet]
#   private_data_scan.sh --paths <file...> [--require-denylist|--no-denylist] [--json] [--quiet]
#   private_data_scan.sh --full-history [--max-commits N] [--json] [--quiet]
#   private_data_scan.sh --content-stdin <location-label> [--no-denylist]
#   private_data_scan.sh --selftest
#
# Exit codes: 0 = clean, 1 = findings (or fail-closed error), 2 = usage error.
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

# NANP fictional-use block (FCC-reserved: NPA-555-01XX is reserved for
# fictional use in any North American area code) -- the exact convention
# JohnGavin/llm#997's own test fixtures already use ("+1555…"). Narrow and
# numeric, so it exempts real fixtures without needing a marker comment.
RE_E164_FICTIONAL='^\+1[0-9]{3}55501[0-9]{2}$'

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
MODE=""
JSON=0
QUIET=0
REQUIRE_DENYLIST=1
MAX_COMMITS=2000
RANGE_A=""
RANGE_B=""
PATHS_ARGS=()
CONTENT_LABEL=""

usage() {
    cat <<'EOF'
Usage: private_data_scan.sh MODE [options]
  --staged                    Scan git INDEX content of staged files
  --range <rev1> <rev2>       Scan full blob content of every file changed
                               in every commit in rev1..rev2
  --paths <file...>           Scan given on-disk files directly
  --full-history [--max-commits N]
                               Scan every blob changed across all reachable
                               history (bounded; default N=2000)
  --content-stdin <label>     Scan stdin content (used by editor-time hooks)
  --selftest                  Run the fixture-based self-test suite
Options: --require-denylist (default) | --no-denylist, --json, --quiet
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
        --max-commits) shift; MAX_COMMITS="${1:-2000}"; shift || true ;;
        --require-denylist) REQUIRE_DENYLIST=1; shift ;;
        --no-denylist) REQUIRE_DENYLIST=0; shift ;;
        --json) JSON=1; shift ;;
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
trap 'rm -f "$FINDINGS_FILE"' EXIT

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
    printf '%s' "$1" | "$GREP" -qiE 'EXAMPLE|FAKE|DUMMY|TEST|FIXTURE'
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
    content="$(cat)"
    [ -n "$content" ] || return 0
    [ "${#DENYLIST_VALUES[@]}" -gt 0 ] || return 0
    local v lnum
    for v in "${DENYLIST_VALUES[@]}"; do
        while IFS=: read -r lnum _; do
            [ -n "${lnum:-}" ] || continue
            append_finding "denylist" "critical" "$loc" "$lnum" "known-value" \
                "exact match against a ~/.config/private_values.env entry (value redacted)"
        done < <(printf '%s\n' "$content" | "$GREP" -nF -- "$v" 2>/dev/null)
    done
}

# ---------------------------------------------------------------------------
# Generic PII pattern detection
# ---------------------------------------------------------------------------
# scan_generic LOCATION < content-on-stdin
scan_generic() {
    local loc="$1" content
    content="$(cat)"
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
                match="$(printf '%s' "$line" | "$GREP" -oE '\+[1-9][0-9]{7,14}' | head -1)"
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
                    if is_git_sha_like "$pc_match" || is_html_entity_like "$pc_match" "$line"; then
                        continue
                    fi
                    pc_exempt_all=0
                    break
                done < <(printf '%s' "$line" | "$GREP" -ioE -- "$pat")
                [ "$pc_exempt_all" -eq 1 ] && continue
            fi
            append_finding "generic" "$sev" "$loc" "$lnum" "$name" \
                "PII-shaped value detected (value redacted -- rule: $name)"
        done < <(printf '%s\n' "$content" | "$GREP" $flags -- "$pat" 2>/dev/null)
    done
}

# scan_blob LOCATION < content-on-stdin
scan_blob() {
    local loc="$1" content
    content="$(cat)"
    # Deny-list is UNCONDITIONAL -- always runs, even for a self-reference
    # exempt file. See "Self-reference exemption" above.
    printf '%s' "$content" | scan_denylist "$loc"
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
    local sha path count=0
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        count=$((count + 1))
        if [ "$count" -gt "$MAX_COMMITS" ]; then
            echo "WARNING: --range truncated at $MAX_COMMITS commits -- absence of findings past this point is NOT proof of a clean range." >&2
            break
        fi
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            git -C "$REPO_ROOT" cat-file -p "${sha}:${path}" 2>/dev/null | scan_blob "${sha:0:12}:${path}"
        done < <(git -C "$REPO_ROOT" diff-tree --no-commit-id --name-only --no-ext-diff -r "$sha" 2>/dev/null)
    done < <(git -C "$REPO_ROOT" rev-list "${a}..${b}" 2>/dev/null)
}

scan_paths() {
    local f
    for f in "${PATHS_ARGS[@]}"; do
        [ -f "$f" ] || continue
        case "$f" in
            *.rds|*.rda|*.RData|*.png|*.jpg|*.jpeg|*.gif|*.pdf|*.gz|*.zip|*.duckdb|*.parquet) continue ;;
        esac
        cat "$f" 2>/dev/null | scan_blob "$f"
    done
}

scan_full_history() {
    [ -d "$REPO_ROOT" ] || return 0
    local sha path count=0
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        count=$((count + 1))
        if [ "$count" -gt "$MAX_COMMITS" ]; then
            echo "WARNING: --full-history truncated at $MAX_COMMITS commits -- absence of findings past this point is NOT proof of a clean history. Increase --max-commits or rely on the scheduled resumable audit." >&2
            break
        fi
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            git -C "$REPO_ROOT" cat-file -p "${sha}:${path}" 2>/dev/null | scan_blob "${sha:0:12}:${path}"
        done < <(git -C "$REPO_ROOT" diff-tree --no-commit-id --name-only --no-ext-diff -r "$sha" 2>/dev/null)
    done < <(git -C "$REPO_ROOT" rev-list --all 2>/dev/null)
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

print_report_json() {
    local first=1
    printf '{"findings":['
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
    if [ "$total" -eq 0 ]; then
        [ "$QUIET" -eq 1 ] || echo "private-data-scan: clean -- 0 findings"
        return 0
    fi
    echo "private-data-scan: $total finding(s)"
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

    rm -rf "$tmp"

    echo ""
    echo "selftest: $pass/$total PASS"
    [ "$pass" -eq "$total" ] && return 0
    return 1
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

case "$MODE" in
    staged) scan_staged ;;
    range) scan_range "$RANGE_A" "$RANGE_B" ;;
    paths) scan_paths ;;
    full-history) scan_full_history ;;
    content-stdin) scan_content_stdin ;;
esac

TOTAL=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
VIS="$(repo_visibility)"

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

hk_run_end "ok" "$TOTAL"
exit 0
