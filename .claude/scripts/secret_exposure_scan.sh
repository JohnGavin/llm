#!/usr/bin/env bash
# secret-exposure-scan: pattern-definitions -- this file legitimately embeds
# the credential-shaped regex/name literals it exists to detect. The
# detector-2/4 self-reference exemption (see the rule doc's "Self-Reference
# Exemption" section) skips literal-value matching for THIS file only.
# Detectors 1 (source-capture patterns) and 3 (permissions) still apply.
# secret_exposure_scan.sh — aggressive, auto-triggered secret-exposure scanner.
#
# Why this exists (not a rule, not a memory note): three incidents in one
# week hit the same failure shape — a whole-environment or whole-file
# capture routed somewhere it should not go, plus plaintext credentials at
# rest with wrong permissions:
#   1. `gh issue comment --body "...printenv..."` spliced the whole shell
#      environment into a PUBLIC GitHub comment (14 live credentials).
#   2. `default.sh` did `export -p | grep -v <denylist> > nix_env.sh`
#      (world-readable, mode 644) — a DENYLIST filter fails open; it only
#      knows what to hide, not what is safe to keep (11 live credentials).
#   3. A migration "commented out" secrets instead of deleting them —
#      still fully readable in ~/.zshenv.
# A rule/memory note is advisory and gets ignored under pressure. This
# script is deterministic code, run on a schedule and at session start,
# that TAKES ACTION on the safe subset of findings. Aggressive detection,
# conservative mutation — see the "--fix actions" table below.
#
# Usage:
#   secret_exposure_scan.sh [--scan|--fix|--selftest] [--json] [--quiet] [--fast]
#
#   --scan      (default) detect and report. Exit 0 clean, 1 findings.
#   --fix       detect, then apply the SAFE remediations only (see table).
#               Exit 0 if all remaining findings were remediated, 1 if
#               manual action is still required.
#   --selftest  run the fixture-based acceptance suite. Prints
#               "selftest: N/N PASS" and exits non-zero on any failure.
#   --json      emit findings as JSON instead of text (scan/fix only).
#   --quiet     suppress the "clean" banner on a 0-finding scan.
#   --fast      dotfile/config set ONLY — skips the repo source-tree scan.
#               Use this at session start so the hook stays fast; the
#               full repo scan (default, no --fast) is for the scheduled
#               launchd run. Session-init has NOT been wired to call this
#               yet — wiring is a separate change; this flag exists so
#               that wiring only needs to add one call.
#
# Detectors (full detail + the allowlist-vs-denylist rule: see
# .claude/rules/secret-exposure-scanning.md):
#   1. whole-environment capture in *.sh/*.R/*.py/*.plist source, routed to
#      a file/pipe. Report only — never auto-rewrite source.
#   2. plaintext credential at rest: a literal credential-shaped value, OR
#      a credential-assignment -- a variable whose NAME has a whole
#      underscore/camelCase SEGMENT equal to key|token|secret|password|
#      passwd|pat|credential|apikey (not a substring match -- `compat_mode`
#      and `date_key` no longer match on name alone) AND whose VALUE itself
#      looks credential-shaped: >=16 chars, Shannon entropy >=3.0 bits/char,
#      and not a path/URL/template/pure-number (see the rule doc's
#      "credential-assignment: name AND value" section for the full
#      heuristic and why a digit is NOT required). Report only — deleting
#      user data is not a safe automatic action; the report prints the
#      exact removal command. Skipped for a file carrying the
#      `pattern-definitions` self-reference marker (see below), and for a
#      literal whose value looks like an obviously-fake test/doc fixture
#      (see below).
#   3. bad permissions on a Detector-2-flagged file (not 600/400).
#      `--fix` DOES `chmod 600` this automatically — reversible, no data
#      change.
#   4. a Detector-2-shaped assignment sitting on a COMMENT line —
#      "commented out" is not "removed". Same skip rules as detector 2.
#
# Self-reference exemption: a file that must legitimately contain the
# credential-shaped patterns THIS scanner looks for (i.e. security tooling
# defining the same regex/name literals) can declare
# `# secret-exposure-scan: pattern-definitions` anywhere in its first 40
# lines. Detectors 2/4 then skip literal-value matching for that file only;
# detectors 1 and 3 are unaffected. An explicit opt-in marker is preferred
# over a hardcoded filename list — a list silently goes stale, a marker
# travels with the file that needs it.
#
# Fixture-value heuristic (detectors 2/4 only): a matched value is treated
# as an obviously-fake test/doc fixture — and skipped — when it contains
# EXAMPLE, FAKE, DUMMY, TEST, xxxx, AAAA, 0000 (case-insensitive), or a run
# of 8+ identical characters. This is a VALUE heuristic, not a path
# heuristic: tests/ is deliberately never pruned by directory, because a
# real credential accidentally committed to a test file must still be
# caught. Files/paths that still trip on real-looking fixture values are
# reported so a marker can be added to the fixture, not the rule widened.
#
# CRITICAL correctness requirement: this scanner must NEVER print a
# credential value, in --scan, --fix, --json, or the log file. Findings
# carry file, line number, variable NAME, and a detector id ONLY — never
# the matched line text. Verified by --selftest's sentinel-value check.
#
# Performance: pruned dirs are .git, node_modules, _targets, worktrees
# (covers .claude/worktrees), renv, library (covers renv/library), plus
# generated/vendored build output that only ever mirrors a source file we
# already scan: .quarto, _freeze, docs, libs, site_libs, and any
# *.min.js/*.map file regardless of directory. The cred-shape pattern set
# runs as ONE grep pass (all patterns as -e alternatives) instead of one
# pass per pattern -- that was the single largest contributor to the
# pre-tune runtime. Target is ~3s on this repo; measured ~6.6s on the
# actual llm checkout (~1455 files post-prune) after the 2026-08 tuning
# pass -- down from ~10s pre-tune, but still short of target. The three
# remaining full-tree grep passes (source-capture scan, combined cred-shape
# scan, assign-scan) are the dominant cost; collapsing further would mean
# merging detector classification logic that currently differs per pass
# (comment-vs-literal, name-pattern-vs-value-pattern) -- left as a follow-up
# rather than done here. If a future repo blows the budget further, use
# --fast for the session-start path and reserve the full scan for the
# scheduled launchd job (which is exactly what --fast is for today).
#
# Log: ~/.claude/logs/secret_exposure_scan.log (one line per --fix action;
# ISO-8601 UTC timestamp, detector id, path, action taken). Log failures
# never abort the scan (best-effort, `|| true` throughout).
#
# Housekeeping heartbeat (llm#951, housekeeping-framework rule): every
# --scan/--fix invocation writes a housekeeping_runs start row (task=
# 'secret_exposure_scan') and updates it at the end with ended_at,
# rows_written, and status ('ok'|'failed') -- including a clean 0-finding
# run, so a scanner that silently stopped firing at its 03:40 launchd slot
# is distinguishable from a scanner reporting zero findings
# (zero-metric-evidence-or-defect). Every finding is ALSO persisted to
# secret_scan_findings, batched (one INSERT...SELECT per run, not one per
# finding) -- same 6-tuple already printed by print_report(), so the
# no-leaked-value contract carries over unchanged: no column ever holds a
# credential value. Target DB: ~/.claude/logs/unified.duckdb (override via
# UNIFIED_DB_PATH). Guarded throughout -- duckdb absent, DB missing, or any
# write failure never aborts the scan itself; the housekeeping_runs write
# itself only ever fails to 'failed' status when the SCAN cannot run at all
# (currently: its findings tempfile could not be created). See
# `write_findings_to_db`/`hk_run_start`/`hk_run_end` below and the digest
# email section in send_overnight_self_review_email.R.
#
# Origin: three incidents, 2026-08 (see header above and the companion
# rule file for full incident detail). Tuned 2026-08 after day-1 signal
# showed 615 findings / ~5% precision — see the rule doc's "Tuning" note.

set -uo pipefail
# Deliberately NOT `set -e`: a single non-matching grep (exit 1) or a
# failed chmod on one file must never abort the rest of the scan.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HOME_DIR="${HOME:-/Users/johngavin}"
LOG_DIR="${HOME_DIR}/.claude/logs"
LOG_FILE="${LOG_DIR}/secret_exposure_scan.log"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# REPO_ROOT is normally auto-detected from this script's own location (so the
# session-init/launchd callers never need to think about it). It can be
# pinned via a pre-set REPO_ROOT env var -- used to measure/tune this
# detector against a specific checkout regardless of which worktree the
# script itself lives in (see the rule doc's "Measuring against a specific
# checkout" note).
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

DEFAULT_DOTFILES=(
    "$HOME_DIR/.config"
    "$HOME_DIR/.claude/env"
    "$HOME_DIR/.zshenv"
    "$HOME_DIR/.zshrc"
    "$HOME_DIR/.bashrc"
    "$HOME_DIR/.bash_profile"
    "$HOME_DIR/.profile"
)

PRUNE_ARGS=(
    --exclude-dir=.git
    --exclude-dir=node_modules
    --exclude-dir=_targets
    --exclude-dir=worktrees
    --exclude-dir=renv
    --exclude-dir=library
    --exclude-dir=.quarto
    --exclude-dir=_freeze
    --exclude-dir=docs
    --exclude-dir=libs
    --exclude-dir=site_libs
    --exclude='*.min.js'
    --exclude='*.map'
)

# Literal credential-shaped value patterns. Overlap between generic and
# specific patterns (e.g. sk- vs sk-ant-) is deliberate belt-and-braces —
# both firing on the same line is a harmless duplicate finding, not a bug.
CRED_SHAPE_PATTERNS=(
    'ghp_[A-Za-z0-9]{30,}'
    'gho_[A-Za-z0-9]{30,}'
    'ghs_[A-Za-z0-9]{30,}'
    'github_pat_[A-Za-z0-9_]{20,}'
    'sk-ant-[A-Za-z0-9_-]{20,}'
    'sk-[A-Za-z0-9]{20,}'
    'hf_[A-Za-z0-9]{20,}'
    'xoxb-[A-Za-z0-9-]{10,}'
    'xoxp-[A-Za-z0-9-]{10,}'
    'AIza[A-Za-z0-9_-]{30,}'
    'AKIA[A-Z0-9]{16}'
    'glpat-[A-Za-z0-9_-]{20,}'
    '\-\-\-\-\-BEGIN[A-Z ]*PRIVATE KEY\-\-\-\-\-'
)

# Credential-shaped variable NAME (case-insensitive) -- COARSE candidate
# filter only. This substring regex is deliberately over-inclusive (it also
# matches `compat_mode`, `date_key`, `KEYWORDS`); every candidate it selects
# is re-checked by name_segment_matches() below, which requires a whole
# underscore/camelCase SEGMENT to equal a credential word, not a substring.
ASSIGN_NAME_RE='[A-Za-z_][A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|PAT|CREDENTIAL)[A-Za-z0-9_]*'
# A literal (non-$) value follows `=`. Matches with OR without a leading
# `#` comment marker — classified into detector 2 vs 4 after the match.
ASSIGN_RE="^[[:space:]]*#?[[:space:]]*(export[[:space:]]+)?${ASSIGN_NAME_RE}[[:space:]]*=[[:space:]]*[^\$[:space:]]"

# Whole-segment credential words for name_segment_matches(). "apikey" is
# listed separately because it has no internal separator/camelCase boundary
# to split on (it is one segment, not two).
CRED_NAME_SEGMENTS_RE='^(key|token|secret|password|passwd|pat|credential|apikey)$'

# Shannon-entropy floor (bits/char) for a value to be treated as
# credential-shaped in the credential-assignment heuristic below. 3.0 was
# chosen empirically against this repo's real findings: natural-language /
# dictionary-derived strings (config descriptions, prose, repeated-letter
# words) score below it once folded into per-character frequency (common
# letters e/t/a/o/n dominate, pulling entropy down); random tokens -- even
# pure-lowercase ones such as a 16-char Gmail app password, which is 16
# independently-random letters from a 26-symbol alphabet -- land at or
# above it because their character histogram is close to uniform. See the
# rule doc for the worked calculation on both a real token and a
# dictionary-word control string.
CRED_ENTROPY_THRESHOLD="3.0"

# Whole-environment capture trigger tokens (detector 1).
ENV_CAPTURE_RE='(^|[;&|[:space:]])(export[[:space:]]+-p|declare[[:space:]]+-x|set[[:space:]]+-o[[:space:]]+posix|printenv|env)([[:space:]]|$)'

# Housekeeping heartbeat target (llm#951) -- see the header comment's
# "Housekeeping heartbeat" section. UNIFIED_DB_PATH lets --selftest (and any
# manual measurement run) redirect writes to a throwaway DB; it must NEVER
# default to anything but the real unified.duckdb in production.
UNIFIED_DB="${UNIFIED_DB_PATH:-${HOME_DIR}/.claude/logs/unified.duckdb}"

MODE="scan"
JSON=0
QUIET=0
FAST=0

FINDINGS_FILE=""

usage() {
    cat <<'EOF'
Usage: secret_exposure_scan.sh [--scan|--fix|--selftest] [--json] [--quiet] [--fast]
EOF
}

for arg in "$@"; do
    case "$arg" in
        --scan) MODE="scan" ;;
        --fix) MODE="fix" ;;
        --selftest) MODE="selftest" ;;
        --json) JSON=1 ;;
        --quiet) QUIET=1 ;;
        --fast) FAST=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "secret_exposure_scan: unknown argument: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# append_finding DETECTOR SEVERITY FILE LINE NAME NOTE
# NOTE must be a fixed, generic description — NEVER the matched line text
# or any captured value. This is the single choke point that guarantees
# the no-leaked-value contract; every caller MUST respect it.
append_finding() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$FINDINGS_FILE"
}

log_action() {
    # log_action DETECTOR PATH ACTION — best-effort, never aborts the scan.
    {
        mkdir -p "$LOG_DIR" 2>/dev/null
        local ts
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
        printf '%s\tdet=%s\tpath=%s\taction=%s\n' "$ts" "$1" "$2" "$3" >> "$LOG_FILE"
    } 2>/dev/null || true
}

file_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null || echo ""
}

# is_pattern_definitions_file FILE
# A file may opt out of detector-2/4 literal-value matching by declaring
# `# secret-exposure-scan: pattern-definitions` in its first 40 lines --
# security tooling legitimately embeds the credential-shaped regex/name
# literals it exists to detect. Detectors 1 and 3 are unaffected -- this
# only suppresses detector-2/4 findings FOR THIS FILE.
is_pattern_definitions_file() {
    head -n 40 "$1" 2>/dev/null | grep -qF '# secret-exposure-scan: pattern-definitions'
}

# looks_like_fixture_value LINE
# Classifies a matched line (never printed -- see the no-leaked-value
# contract at the top of this file) as an obviously-fake test/doc fixture:
# EXAMPLE, FAKE, DUMMY, TEST, xxxx, AAAA, 0000 (case-insensitive), or a run
# of 8+ identical characters. A VALUE heuristic, not a path heuristic --
# tests/ is never pruned by directory.
looks_like_fixture_value() {
    if printf '%s' "$1" | grep -qiE 'EXAMPLE|FAKE|DUMMY|TEST|xxxx|AAAA|0000'; then
        return 0
    fi
    printf '%s' "$1" | grep -qE '(.)\1{7,}'
}

# ---------------------------------------------------------------------------
# Housekeeping heartbeat + batched persistence (llm#951)
#
# All three functions below are guarded by _duckdb_ok / a non-empty _run_id
# and are best-effort ( `|| true` ) -- a DB write failure NEVER aborts the
# scan. _duckdb_ok, _run_id, _run_started are plain globals (not `local`)
# so --selftest can override them to point at a throwaway DB and call these
# functions directly, without ever touching the real unified.duckdb.
# ---------------------------------------------------------------------------

_duckdb_ok=0
if command -v duckdb >/dev/null 2>&1 && [ -f "$UNIFIED_DB" ]; then
    _duckdb_ok=1
fi
_run_id=""
_run_started=""

# hk_run_start — insert the housekeeping_runs start row for this invocation.
# No-op (leaves _run_id empty) if duckdb/the DB is unavailable; hk_run_end
# and write_findings_to_db both check _run_id before doing anything, so
# downstream calls stay safe even when this is skipped.
hk_run_start() {
    [ "$_duckdb_ok" = "1" ] || return 0
    _run_id="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    [ -n "$_run_id" ] || return 0
    _run_started="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    duckdb -init /dev/null "$UNIFIED_DB" -c "
        INSERT OR IGNORE INTO housekeeping_runs
          (id, task, source_script, started_at, status, rows_written)
        VALUES (
          '${_run_id}',
          'secret_exposure_scan',
          '${SCRIPT_DIR}/secret_exposure_scan.sh',
          TIMESTAMPTZ '${_run_started}',
          'ok',
          0
        );
    " >/dev/null 2>&1 || true
}

# hk_run_end STATUS ROWS_WRITTEN — update the housekeeping_runs row opened
# by hk_run_start. No-op if hk_run_start never ran (duckdb/DB unavailable).
hk_run_end() {
    [ "$_duckdb_ok" = "1" ] || return 0
    [ -n "$_run_id" ] || return 0
    local status="$1" rows="${2:-0}" ended
    ended="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    duckdb -init /dev/null "$UNIFIED_DB" -c "
        UPDATE housekeeping_runs
        SET ended_at = TIMESTAMPTZ '${ended}',
            status = '${status}',
            rows_written = ${rows}
        WHERE id = '${_run_id}';
    " >/dev/null 2>&1 || true
}

# write_findings_to_db — batch-insert every row currently in $FINDINGS_FILE
# into secret_scan_findings via ONE INSERT...SELECT sourced from read_csv()
# (not one INSERT per finding — see the housekeeping-framework rule's
# "Performance" guidance and the header comment above). `quote=''` disables
# CSV quote handling: findings are plain tab-separated text written by
# append_finding() (printf, no CSV escaping applied), so a literal `"`
# inside a note (e.g. the denylist-capture note, which embeds a grep -E
# pattern in double quotes) must not be misread as a quote-open. `note` is
# ALREADY the fixed, generic, non-credential description from
# append_finding's no-leaked-value contract -- this persists exactly the
# same 6-tuple print_report() already renders, never anything wider.
# INSERT OR IGNORE on the deterministic md5-based id makes replaying this
# call for the same _run_id (e.g. a retried write) idempotent.
write_findings_to_db() {
    [ "$_duckdb_ok" = "1" ] || return 0
    [ -n "$_run_id" ] || return 0
    [ -s "${FINDINGS_FILE:-}" ] || return 0
    duckdb -init /dev/null "$UNIFIED_DB" -c "
        INSERT OR IGNORE INTO secret_scan_findings
        SELECT
          md5(run_id || ':' || detector || ':' || file_path || ':' || line_num || ':' || name) AS id,
          run_id, fired_at, detector, severity, file_path, line_num, name, note
        FROM (
          SELECT
            '${_run_id}' AS run_id,
            TIMESTAMPTZ '${_run_started}' AS fired_at,
            column0 AS detector, column1 AS severity, column2 AS file_path,
            column3 AS line_num, column4 AS name, column5 AS note
          FROM read_csv('${FINDINGS_FILE}', delim='\t', header=false, quote='',
            columns={'column0':'VARCHAR','column1':'VARCHAR','column2':'VARCHAR',
                     'column3':'VARCHAR','column4':'VARCHAR','column5':'VARCHAR'})
        );
    " >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# credential-assignment value/name heuristic (detectors 2 + 4)
#
# The old heuristic fired on NAME alone (any substring match) with a value
# test that only checked "does not start with $" -- meaningless outside
# bash, and it treated `compat_mode`/`date_key`/`API_KEY_HEADER` as
# credentials. It is replaced by requiring BOTH:
#   (a) name_segment_matches   -- a whole name SEGMENT, not a substring
#   (b) looks_like_credential_value -- the VALUE itself is credential-shaped
# See the rule doc's "credential-assignment: name AND value" section.
# ---------------------------------------------------------------------------

# name_segment_matches NAME
# Splits NAME on `_`, `-`, `.`, and camelCase boundaries; TRUE if any whole
# segment (case-insensitive) equals a credential word. `compat_mode` ->
# compat,mode -> no match. `date_key` -> date,key -> matches (name alone is
# not sufficient -- the value heuristic below is what actually excludes it).
# Single awk call (camelCase split + lowercase + segment lookup all in one
# subprocess) -- this runs once per ASSIGN_RE candidate (hundreds per scan
# on this repo), so collapsing what was 3 sed/tr calls plus a per-segment
# grep loop into one process is a measurable chunk of the scan's runtime.
name_segment_matches() {
    printf '%s' "$1" | awk -v words="key token secret password passwd pat credential apikey" '
        BEGIN { n = split(words, w, " "); for (i = 1; i <= n; i++) target[w[i]] = 1 }
        {
            s = $0; out = ""; len = length(s)
            for (i = 1; i <= len; i++) {
                c = substr(s, i, 1)
                if (i > 1) {
                    prev = substr(s, i - 1, 1)
                    if (prev ~ /[a-z0-9]/ && c ~ /[A-Z]/) out = out "_"
                }
                if (c == "." || c == "-") c = "_"
                out = out c
            }
            m = split(tolower(out), segs, "_")
            for (i = 1; i <= m; i++) { if (segs[i] in target) exit 0 }
            exit 1
        }'
}

# strip_assignment_value RAW_VALUE
# Extracts the actual assigned value from everything the coarse grep
# captured after `=` -- which may include a following shell command (e.g.
# `HF_TOKEN='hf_xxx' hf auth whoami  # comment`, a common foreground
# env-assignment idiom). If the value is quoted, take only the content
# between the FIRST matching pair of quotes (not "the whole rest of the
# line", which would wrongly absorb `hf auth whoami # comment` as part of
# the value and inflate its entropy/length). If unquoted, stop at the
# first whitespace -- shell word-splitting semantics. Does not attempt to
# strip a trailing `# comment` from an unquoted value beyond that
# whitespace boundary -- under-stripping past the first word cannot hide a
# credential, since the credential itself would already be the first word.
strip_assignment_value() {
    local v
    v="$(printf '%s' "$1" | sed -E 's/^[[:space:]]+//')"
    case "$v" in
        \"*) v="${v#\"}"; v="${v%%\"*}" ;;
        \'*) v="${v#\'}"; v="${v%%\'*}" ;;
        *)   v="${v%%[[:space:]]*}" ;;
    esac
    printf '%s' "$v"
}

# value_entropy VALUE -> prints Shannon entropy in bits/char (order-0, over
# the value's own character histogram). Kept as a standalone function for
# --selftest / manual tuning use; looks_like_credential_value below inlines
# the same computation to avoid a second subprocess per candidate.
value_entropy() {
    printf '%s' "$1" | awk '
        { n = length($0)
          if (n == 0) { print 0; exit }
          for (i = 1; i <= n; i++) { c = substr($0, i, 1); count[c]++ }
          e = 0
          for (c in count) { p = count[c] / n; e -= p * log(p) / log(2) }
          printf "%.4f", e }'
}

# looks_like_credential_value VALUE
# TRUE if VALUE is long enough, entropy-dense enough, and not obviously a
# path/URL/template/pure-number. Deliberately does NOT require a digit: a
# 16-char all-lowercase Gmail app password is a real credential with no
# digit at all, and a digit requirement would silence it. Entropy is the
# signal that actually separates random secrets from dictionary/config
# text; the digit test was a bash-only proxy that never worked for .py/.R.
#
# The cheap structural checks (length via bash `${#v}`, and the `$`/path/
# URL/template/code-expression shapes via bash `case`) run first and cost
# no subprocess at all. Only a value that survives all of them pays for
# ONE awk call that does letter-presence + pure-numeric + entropy together
# -- this used to be 4 separate subprocess calls (2x grep, 2x awk); one
# candidate line, one subprocess, once per ASSIGN_RE match.
looks_like_credential_value() {
    local v="$1"
    [ "${#v}" -ge 16 ] || return 1
    case "$v" in
        \$*) return 1 ;;                                  # $VAR indirection, not a literal
        /*|./*|~*) return 1 ;;                           # path
        *'://'*) return 1 ;;                              # URL (http/https/hf/ftp/...)
        *'{{'*|*'${'*|*'%s'*|*'<'*|*'>'*) return 1 ;;      # template/placeholder
        *'('*|*')'*|*'['*|*']'*|*','*) return 1 ;;         # code expression, not a literal
                                                           # (a Python/R `key_x = fn(a, b)`
                                                           # RHS -- real credential values do
                                                           # not contain parens/brackets/commas)
    esac
    printf '%s' "$v" | awk -v thr="$CRED_ENTROPY_THRESHOLD" '
        { n = length($0)
          if ($0 !~ /[A-Za-z]/) exit 1                         # pure-numeric/symbol
          if ($0 ~ /^[0-9]+([.:\/_-][0-9]+)*$/) exit 1          # date/number
          for (i = 1; i <= n; i++) { c = substr($0, i, 1); count[c]++ }
          e = 0
          for (c in count) { p = count[c] / n; e -= p * log(p) / log(2) }
          exit !(e >= thr) }'
}

# ---------------------------------------------------------------------------
# Detector 1 — whole-environment capture in source
# ---------------------------------------------------------------------------

scan_source_patterns() {
    [ -d "$REPO_ROOT" ] || return 0
    while IFS=: read -r file lnum rest; do
        [ -n "${file:-}" ] || continue
        # Candidate only if the line ALSO routes somewhere (pipe/redirect).
        if ! printf '%s' "$rest" | grep -qE '(\||>)'; then
            continue
        fi
        if printf '%s' "$rest" | grep -qE 'grep[^|]*-[a-zA-Z]*v[a-zA-Z]*'; then
            append_finding "1" "high" "$file" "$lnum" "denylist-capture" \
                "export/env dump filtered by a DENYLIST (grep -v...) -- fails open; use an explicit ALLOWLIST (grep -E \"^declare -x (ALLOWED_VAR1|ALLOWED_VAR2)=\") instead"
        elif printf '%s' "$rest" | grep -qE '\bgrep\b'; then
            : # positive grep present with no -v flag -- treated as an allowlist, not a finding
        else
            append_finding "1" "high" "$file" "$lnum" "unfiltered-capture" \
                "whole-environment/file capture routed to a file or pipe with no filter at all"
        fi
    done < <(grep -rnIE \
        --include='*.sh' --include='*.R' --include='*.py' --include='*.plist' \
        "${PRUNE_ARGS[@]}" \
        "$ENV_CAPTURE_RE" "$REPO_ROOT" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Detectors 2 + 4 — plaintext credentials at rest (live vs commented)
# ---------------------------------------------------------------------------

scan_at_rest() {
    local paths=()
    local p
    for p in "${DEFAULT_DOTFILES[@]}"; do
        [ -e "$p" ] && paths+=("$p")
    done
    if [ "$FAST" -eq 0 ] && [ -d "$REPO_ROOT" ]; then
        paths+=("$REPO_ROOT")
    fi
    [ "${#paths[@]}" -gt 0 ] || return 0

    # Literal credential shapes -- always detector 2 regardless of comment
    # status; an exposed value is exposed whether or not a `#` precedes it.
    # Skipped for a self-referencing pattern-definitions file, and for a
    # value that looks like an obviously-fake test/doc fixture.
    #
    # One grep pass with all patterns as -e alternatives, not one pass per
    # pattern -- 13 separate full-tree walks was the largest single
    # contributor to the pre-tune ~10s runtime. A line matching more than
    # one CRED_SHAPE_PATTERNS entry (e.g. both sk- and sk-ant-) is now
    # reported once instead of once per matching pattern -- a deliberate,
    # welcome side effect (fewer duplicate findings), not a detection gap:
    # the line is still caught, just not double-counted.
    local cred_pattern_args=()
    local pat
    for pat in "${CRED_SHAPE_PATTERNS[@]}"; do
        cred_pattern_args+=(-e "$pat")
    done
    while IFS=: read -r file lnum rest; do
        [ -n "${file:-}" ] || continue
        is_pattern_definitions_file "$file" && continue
        looks_like_fixture_value "$rest" && continue
        append_finding "2" "critical" "$file" "$lnum" "cred-shape" \
            "literal credential-shaped value detected (value redacted -- see rule doc for the pattern class)"
    done < <(grep -rnIE "${PRUNE_ARGS[@]}" "${cred_pattern_args[@]}" "${paths[@]}" 2>/dev/null)

    # Credential-shaped NAME assigned a credential-SHAPED value -- comment
    # line goes to detector 4, everything else to detector 2. The initial
    # grep (ASSIGN_RE) is a coarse candidate filter only; every candidate
    # must then pass BOTH name_segment_matches (whole segment, not
    # substring) AND looks_like_credential_value (length/entropy/not-a-
    # path-or-URL-or-template) before it is reported. Same skip rules as
    # above, applied first since they are cheaper than the parse below.
    while IFS=: read -r file lnum rest; do
        [ -n "${file:-}" ] || continue
        is_pattern_definitions_file "$file" && continue
        looks_like_fixture_value "$rest" && continue

        stripped_line="$(printf '%s' "$rest" | sed -E 's/^[[:space:]]*#?[[:space:]]*//; s/^export[[:space:]]+//')"
        # NAME may have trailing whitespace before `=` (e.g. `foo = "..."`)
        # -- trim it, or the last split segment carries a stray space and
        # never equals a bare credential word.
        assign_name="$(printf '%s' "${stripped_line%%=*}" | sed -E 's/[[:space:]]+$//')"
        assign_value="$(strip_assignment_value "${stripped_line#*=}")"

        name_segment_matches "$assign_name" || continue
        looks_like_credential_value "$assign_value" || continue

        if printf '%s' "$rest" | grep -qE '^[[:space:]]*#'; then
            append_finding "4" "high" "$file" "$lnum" "commented-credential-assignment" \
                "credential-shaped NAME with a credential-shaped literal value left on a comment line -- commenting out is NOT removal"
        else
            append_finding "2" "critical" "$file" "$lnum" "credential-assignment" \
                "credential-shaped variable NAME assigned a credential-shaped literal value"
        fi
    done < <(grep -rnIiE "${PRUNE_ARGS[@]}" -e "$ASSIGN_RE" "${paths[@]}" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Detector 3 — permissions on any Detector-2-flagged file
# ---------------------------------------------------------------------------

check_permissions() {
    local file mode
    while IFS= read -r file; do
        [ -n "$file" ] && [ -e "$file" ] || continue
        mode="$(file_mode "$file")"
        case "$mode" in
            600|400) continue ;;
            "") continue ;; # couldn't stat -- don't report a phantom finding
            *)
                append_finding "3" "high" "$file" "-" "bad-permissions" \
                    "mode $mode -- a file holding a live credential should be 600 or 400"
                ;;
        esac
    done < <(awk -F'\t' '$1=="2"{print $3}' "$FINDINGS_FILE" | sort -u)
}

# ---------------------------------------------------------------------------
# --fix — conservative remediation
# ---------------------------------------------------------------------------

apply_fixes() {
    while IFS=$'\t' read -r det sev file lnum name note; do
        case "$det" in
            3)
                if chmod 600 "$file" 2>/dev/null; then
                    log_action "3" "$file" "chmod 600 (was mode $note)"
                else
                    log_action "3" "$file" "chmod 600 FAILED"
                fi
                ;;
            2)
                log_action "2" "${file}:${lnum}" "NOT auto-fixed (deleting user data is unsafe) -- remove manually: sed -i '' '${lnum}d' '${file}'  # verify the line first"
                ;;
            4)
                log_action "4" "${file}:${lnum}" "NOT auto-fixed -- remove the commented-out assignment manually: sed -i '' '${lnum}d' '${file}'"
                ;;
            1)
                log_action "1" "${file}:${lnum}" "NOT auto-fixed -- source pattern requires human judgement (allowlist vs denylist); see rule doc"
                ;;
        esac
    done < "$FINDINGS_FILE"
}

remaining_after_fix() {
    local remaining
    remaining=$(awk -F'\t' '$1=="1"||$1=="2"||$1=="4"' "$FINDINGS_FILE" | wc -l | tr -d ' ')
    local file mode
    while IFS=$'\t' read -r det sev file lnum name note; do
        [ "$det" = "3" ] || continue
        mode="$(file_mode "$file")"
        case "$mode" in
            600|400) : ;;
            *) remaining=$((remaining + 1)) ;;
        esac
    done < "$FINDINGS_FILE"
    printf '%s' "$remaining"
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

print_report_json() {
    local first=1
    printf '{"findings":['
    while IFS=$'\t' read -r det sev file lnum name note; do
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"detector":"%s","severity":"%s","file":"%s","line":"%s","name":"%s","note":"%s"}' \
            "$(json_escape "$det")" "$(json_escape "$sev")" "$(json_escape "$file")" \
            "$(json_escape "$lnum")" "$(json_escape "$name")" "$(json_escape "$note")"
    done < "$FINDINGS_FILE"
    printf ']}\n'
}

print_report() {
    local total
    total=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')

    if [ "$JSON" -eq 1 ]; then
        print_report_json
        return 0
    fi

    if [ "$total" -eq 0 ]; then
        [ "$QUIET" -eq 1 ] || echo "secret-exposure-scan: clean -- 0 findings"
        return 0
    fi

    echo "secret-exposure-scan: $total finding(s)"
    awk -F'\t' '{c[$1]++} END{for (d in c) print "  detector " d ": " c[d]}' "$FINDINGS_FILE" | sort
    echo "---"
    while IFS=$'\t' read -r det sev file lnum name note; do
        printf '  [%s] det=%s %s:%s %s -- %s\n' "$sev" "$det" "$file" "$lnum" "$name" "$note"
    done < "$FINDINGS_FILE"
}

# ---------------------------------------------------------------------------
# --selftest
# ---------------------------------------------------------------------------

run_selftest() {
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/secret_scan_selftest.XXXXXX")"

    mkdir -p "$tmp/repo" "$tmp/dotfiles" "$tmp/repo/tests/testthat" \
        "$tmp/repo/vendor/_freeze/site_libs" "$tmp/repo/vendor/dist"

    # 1: denylist-filtered export -p redirect -> FINDING (detector 1)
    cat > "$tmp/repo/bad_denylist.sh" <<'EOF'
#!/bin/bash
export -p | grep -vE "PASSWORD|TOKEN" > /tmp/dump.sh
EOF

    # 2: allowlist-filtered export -p redirect -> NO finding
    cat > "$tmp/repo/good_allowlist.sh" <<'EOF'
#!/bin/bash
export -p | grep -E "^declare -x (PATH|NIX_STORE)=" > /tmp/safe.sh
EOF

    # 3: literal ghp_-shaped credential -> FINDING (detector 2)
    cat > "$tmp/dotfiles/leaked_token.env" <<'EOF'
GITHUB_TOKEN=ghp_ABCDEFGHIJ0123456789abcdefghij0123456789
EOF

    # 4/5/6: mode-644 file holding a credential shape -> FINDING (detector 3);
    #        after --fix, mode is 600 and a re-scan is clean.
    cat > "$tmp/dotfiles/insecure_perms.env" <<'EOF'
HF_TOKEN=hf_ABCDEFGHIJ0123456789abcd
EOF
    chmod 644 "$tmp/dotfiles/insecure_perms.env"

    # 7/8: commented-out credential (detector 4) + indirection, not a
    #      literal (no finding).
    cat > "$tmp/dotfiles/commented.env" <<'EOF'
# API_KEY=sk-1234567890ABCDEFGHIJ
API_KEY=$SOME_VAR
EOF

    # 9: prose containing the word "password" -> NO finding (over-match check)
    cat > "$tmp/dotfiles/prose.txt" <<'EOF'
Remember to reset your password before the meeting.
EOF

    # 10/11/12: sentinel value must never surface in stdout, stderr, or the log
    local sentinel="SENTINEL_zQ9xxNeverPrintMe_7f3a"
    cat > "$tmp/dotfiles/sentinel.env" <<EOF
AWS_SECRET_ACCESS_KEY=${sentinel}
EOF

    # 13: vendored/minified build output under a pruned dir + pruned filename
    #     -> NO finding (directory prune AND filename exclude both apply)
    cat > "$tmp/repo/vendor/_freeze/site_libs/pdfmake.min.js" <<'EOF'
var t = "AKIAABCDEFGHIJKLMNOP";
EOF

    # 14: self-reference marker in a would-be scanner file -> NO finding
    #     (detector 2/4 exempted; detector 1 still runs but this file has
    #     no env-capture pattern so it would not fire anyway).
    cat > "$tmp/repo/fake_scanner.sh" <<'EOF'
#!/usr/bin/env bash
# secret-exposure-scan: pattern-definitions
GITHUB_TOKEN=ghp_ZYXWVUTSRQPONMLKJIHGFEDCBA0123456789
EOF

    # 15: fake/fixture-shaped token value assigned to a credential-shaped
    #     NAME (R keyword-arg style, matches ASSIGN_RE the way ccusage
    #     test fixtures do) -> NO finding (fixture-value heuristic).
    cat > "$tmp/repo/tests/testthat/test-fixture-token.R" <<'EOF'
api_token = "TEST_FAKE_0000000000000000"
EOF

    # 16: a REAL-looking (no fake marker) credential-shaped assignment
    #     sitting in a tests/ path -> STILL a finding (detector 2). tests/
    #     is deliberately never pruned by directory.
    cat > "$tmp/repo/tests/testthat/test-real-leak.R" <<'EOF'
api_token = "zK7wPlqRstUvWxYzAB12mQ9nR3sT"
EOF

    # 17-24: credential-assignment name-AND-value heuristic, one case per
    # line so each assertion below checks a specific reason for its
    # pass/fail, not just "some finding somewhere in the file".
    #   L1 compat_mode      -- name has no whole-word credential segment
    #   L2 date_key         -- name matches ("key"), value too short (10<16)
    #   L3 API_KEY_HEADER   -- name matches, value too short (9<16)
    #   L4 TOKEN_PATTERN    -- name matches, value too short (5<16)
    #   L5 API_KEY          -- name matches, value is a real 16-char
    #                          mixed-case+digit token -> FINDING
    #   L6 GMAIL_APP_PASSWORD -- name matches ("password"), value is a
    #                          16-char ALL-LOWERCASE token with NO digit --
    #                          this is the regression case: a digit
    #                          requirement would have silenced a real
    #                          Gmail app password -> FINDING
    #   L7 SECRET_PATH      -- name matches ("secret"), value is a path
    #   L8 API_KEY_URL      -- name matches ("key"), value is a URL
    #   L9 HF_TOKEN         -- quoted value followed by a trailing shell
    #                          command + comment (a common foreground
    #                          env-assignment idiom); the quoted literal
    #                          itself is only 6 chars -- must extract JUST
    #                          "hf_xxx", not "hf_xxx' hf auth whoami # ..."
    #                          (which would be long/entropy-dense enough to
    #                          wrongly pass)
    #   L10 API_SECRET      -- value is a quoted $VAR reference -- quote
    #                          stripping must not hide the indirection
    #   L11 key_strength    -- value is a Python code expression (parens/
    #                          brackets/comma), not a string literal --
    #                          real credentials never contain these chars
    cat > "$tmp/dotfiles/value_heuristic_cases.env" <<'EOF'
compat_mode = "something"
date_key = "2026-08-13"
API_KEY_HEADER = "x-api-key"
TOKEN_PATTERN = '^ghp_'
API_KEY = "aB3xK9mQ2pL7vN4t"
GMAIL_APP_PASSWORD = "wjqzxvkbmtynfcgh"
SECRET_PATH = "/usr/local/bin/thing"
API_KEY_URL = "https://example.com/aVeryLongPath"
HF_TOKEN='hf_xxx' hf auth whoami   # must print your username, not an error
API_SECRET="$OTHER_SECRET_VAR"
key_strength = max((channels[idx] for idx in non_spill), default=0.0)
EOF

    REPO_ROOT="$tmp/repo"
    DEFAULT_DOTFILES=("$tmp/dotfiles")
    FAST=0
    JSON=0
    QUIET=0

    local f1 f2 pass=0 total=27
    f1="$(mktemp "${TMPDIR:-/tmp}/secret_scan_selftest_f1.XXXXXX")"
    FINDINGS_FILE="$f1"
    scan_source_patterns
    scan_at_rest
    check_permissions

    if awk -F'\t' '$1=="1" && $3 ~ /bad_denylist\.sh$/' "$f1" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: denylist export capture not flagged (detector 1)"
    fi

    if awk -F'\t' '$3 ~ /good_allowlist\.sh$/' "$f1" | grep -q .; then
        echo "FAIL: allowlist export capture wrongly flagged"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$1=="2" && $3 ~ /leaked_token\.env$/' "$f1" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: ghp_-shaped token not flagged (detector 2)"
    fi

    if awk -F'\t' '$1=="3" && $3 ~ /insecure_perms\.env$/' "$f1" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: mode-644 credential file not flagged (detector 3)"
    fi

    if awk -F'\t' '$3 ~ /pdfmake\.min\.js$/' "$f1" | grep -q .; then
        echo "FAIL: vendored/minified build output under a pruned dir was flagged"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$3 ~ /fake_scanner\.sh$/' "$f1" | grep -q .; then
        echo "FAIL: self-reference pattern-definitions marker not honoured"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$3 ~ /test-fixture-token\.R$/' "$f1" | grep -q .; then
        echo "FAIL: fake/fixture-shaped token value was flagged"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$1=="2" && $3 ~ /test-real-leak\.R$/' "$f1" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: unmarked credential-shaped assignment in a tests/ path not flagged"
    fi

    if awk -F'\t' '$3 ~ /value_heuristic_cases\.env$/ && $4=="1"' "$f1" | grep -q .; then
        echo "FAIL: compat_mode wrongly flagged (name has no whole-word credential segment)"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$3 ~ /value_heuristic_cases\.env$/ && $4=="2"' "$f1" | grep -q .; then
        echo "FAIL: date_key wrongly flagged (name matches but value is only 10 chars)"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$3 ~ /value_heuristic_cases\.env$/ && $4=="3"' "$f1" | grep -q .; then
        echo "FAIL: API_KEY_HEADER wrongly flagged (value \"x-api-key\" is only 9 chars)"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$3 ~ /value_heuristic_cases\.env$/ && $4=="4"' "$f1" | grep -q .; then
        echo "FAIL: TOKEN_PATTERN wrongly flagged (value is a 5-char regex fragment)"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$1=="2" && $3 ~ /value_heuristic_cases\.env$/ && $4=="5"' "$f1" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: API_KEY with a real 16-char mixed-case+digit value not flagged"
    fi

    if awk -F'\t' '$1=="2" && $3 ~ /value_heuristic_cases\.env$/ && $4=="6"' "$f1" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: REGRESSION -- 16-char all-lowercase Gmail-app-password-style value not flagged (a digit requirement would silence real Gmail app passwords)"
    fi

    if awk -F'\t' '$3 ~ /value_heuristic_cases\.env$/ && $4=="7"' "$f1" | grep -q .; then
        echo "FAIL: SECRET_PATH wrongly flagged (value is a filesystem path)"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$3 ~ /value_heuristic_cases\.env$/ && $4=="8"' "$f1" | grep -q .; then
        echo "FAIL: API_KEY_URL wrongly flagged (value is a URL)"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$3 ~ /value_heuristic_cases\.env$/ && $4=="9"' "$f1" | grep -q .; then
        echo "FAIL: HF_TOKEN wrongly flagged -- quote extraction absorbed the trailing 'hf auth whoami # comment' shell text instead of stopping at the closing quote"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$3 ~ /value_heuristic_cases\.env$/ && $4=="10"' "$f1" | grep -q .; then
        echo "FAIL: API_SECRET wrongly flagged -- quoted \$VAR indirection not recognised as non-literal"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$3 ~ /value_heuristic_cases\.env$/ && $4=="11"' "$f1" | grep -q .; then
        echo "FAIL: key_strength wrongly flagged -- Python code expression (parens/brackets/comma) treated as a credential literal"
    else
        pass=$((pass + 1))
    fi

    local out
    out="$(FINDINGS_FILE="$f1" JSON=0 QUIET=0 print_report 2>&1)"
    apply_fixes >/dev/null 2>&1 || true

    local mode_after
    mode_after="$(file_mode "$tmp/dotfiles/insecure_perms.env")"
    if [ "$mode_after" = "600" ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: chmod 600 not applied by --fix (mode=$mode_after)"
    fi

    f2="$(mktemp "${TMPDIR:-/tmp}/secret_scan_selftest_f2.XXXXXX")"
    FINDINGS_FILE="$f2"
    scan_source_patterns
    scan_at_rest
    check_permissions
    if awk -F'\t' '$1=="3" && $3 ~ /insecure_perms\.env$/' "$f2" | grep -q .; then
        echo "FAIL: still flagged as bad-permissions after --fix + re-scan"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$1=="4" && $3 ~ /commented\.env$/' "$f2" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: commented-out credential assignment not flagged (detector 4)"
    fi

    # Line 2 of commented.env is `API_KEY=$SOME_VAR` -- indirection, not a
    # literal. Line 1 (the commented-out secret) legitimately also matches
    # the generic cred-shape detector as detector 2 -- a literal value is
    # exposed whether or not a `#` precedes it -- so this assertion must
    # check line 2 specifically, not "no detector-2 finding anywhere in
    # the file".
    if awk -F'\t' '$1=="2" && $3 ~ /commented\.env$/ && $4=="2"' "$f2" | grep -q .; then
        echo "FAIL: \$VAR indirection wrongly flagged as a literal credential"
    else
        pass=$((pass + 1))
    fi

    if grep -q "prose\.txt" "$f2"; then
        echo "FAIL: prose containing the word 'password' was over-matched"
    else
        pass=$((pass + 1))
    fi

    local out_json
    out_json="$(FINDINGS_FILE="$f2" JSON=1 print_report 2>&1)"
    case "$out $out_json" in
        *"$sentinel"*) echo "FAIL: sentinel value leaked into stdout" ;;
        *) pass=$((pass + 1)) ;;
    esac

    local err_capture
    err_capture="$( { scan_at_rest; } 2>&1 1>/dev/null )"
    case "$err_capture" in
        *"$sentinel"*) echo "FAIL: sentinel value leaked into stderr" ;;
        *) pass=$((pass + 1)) ;;
    esac

    if [ -f "$LOG_FILE" ] && grep -q "$sentinel" "$LOG_FILE" 2>/dev/null; then
        echo "FAIL: sentinel value leaked into the log file"
    else
        pass=$((pass + 1))
    fi

    rm -rf "$tmp" "$f1" "$f2" 2>/dev/null || true

    # -----------------------------------------------------------------------
    # Housekeeping heartbeat + persistence (llm#951) — NEVER touches the real
    # ~/.claude/logs/unified.duckdb. Every DB used below is a throwaway temp
    # file created by this block and removed at the end. Skipped (not
    # failed) when duckdb is not in PATH — the "duckdb-absent path still
    # completes the scan" property is instead proven by the subprocess check
    # further down, which needs no DB at all.
    # -----------------------------------------------------------------------
    if ! command -v duckdb >/dev/null 2>&1; then
        echo "SKIP: duckdb not in PATH -- 5 heartbeat/persistence checks skipped"
    else
        local hk_dir hk_db hk_sentinel="SENTINEL_hk8pQmXwR3fZaLg_neverPrintMe"
        hk_dir="$(mktemp -d "${TMPDIR:-/tmp}/secret_scan_selftest_hk.XXXXXX")"
        hk_db="${hk_dir}/unified.duckdb"
        duckdb -init /dev/null "$hk_db" < "${SCRIPT_DIR}/housekeeping_schema_init.sql" >/dev/null 2>&1 || true

        # Override the heartbeat globals to point at the throwaway DB.
        UNIFIED_DB="$hk_db"
        _duckdb_ok=1

        # Run the REAL detectors (not a hand-written findings file) against a
        # mode-644 dotfile whose VALUE is the sentinel -- same shape as the
        # existing sentinel.env fixture above, so this exercises detector 2
        # (credential-assignment: AWS_SECRET_ACCESS_KEY name-segment match +
        # entropy-qualifying value) AND detector 3 (bad-permissions) in one
        # pass. Critically, the sentinel lives ONLY in the file's CONTENT --
        # never in its path or name -- matching how a real leak looks, so
        # the "sentinel absent from DB" check below is a genuine assertion
        # about redaction, not a check against a self-inflicted plant.
        local hk_repo hk_dot hk_prior_repo_root="$REPO_ROOT"
        local hk_prior_dotfiles=("${DEFAULT_DOTFILES[@]}")
        hk_repo="$(mktemp -d "${TMPDIR:-/tmp}/secret_scan_selftest_hkrepo.XXXXXX")"
        hk_dot="$(mktemp -d "${TMPDIR:-/tmp}/secret_scan_selftest_hkdot.XXXXXX")"
        cat > "${hk_dot}/hk_sentinel.env" <<EOF
AWS_SECRET_ACCESS_KEY=${hk_sentinel}
EOF
        chmod 644 "${hk_dot}/hk_sentinel.env"

        REPO_ROOT="$hk_repo"
        DEFAULT_DOTFILES=("$hk_dot")

        local hk_findings
        hk_findings="$(mktemp "${TMPDIR:-/tmp}/secret_scan_selftest_hkfind.XXXXXX")"
        FINDINGS_FILE="$hk_findings"
        scan_source_patterns
        scan_at_rest
        check_permissions

        REPO_ROOT="$hk_prior_repo_root"
        DEFAULT_DOTFILES=("${hk_prior_dotfiles[@]}")

        local hk_total
        hk_total=$(wc -l < "$hk_findings" | tr -d ' ')

        _run_id=""
        _run_started=""
        hk_run_start
        if [ -z "$_run_id" ]; then
            echo "FAIL: hk_run_start did not set _run_id with duckdb available"
        else
            total=$((total + 1)); pass=$((pass + 1))
        fi

        write_findings_to_db
        hk_run_end "ok" "$hk_total"

        # Check: heartbeat row persisted ok/<hk_total>, and hk_total is the
        # expected 2 findings (detector 2 + detector 3 on the one fixture
        # file) -- if this drifts to 0 the rest of the block is testing
        # nothing, so assert the count explicitly rather than trusting it.
        total=$((total + 1))
        local hb_row
        hb_row="$(duckdb -init /dev/null -noheader -list "$hk_db" -c "
            SELECT status || '|' || rows_written FROM housekeeping_runs WHERE id='${_run_id}';
        " 2>/dev/null)"
        if [ "$hb_row" = "ok|${hk_total}" ] && [ "$hk_total" = "2" ]; then
            pass=$((pass + 1))
        else
            echo "FAIL: expected an 'ok|2' heartbeat row from the fixture (got '$hb_row', hk_total=$hk_total)"
        fi

        # Check: per-finding rows persisted (one per line in FINDINGS_FILE).
        total=$((total + 1))
        local finding_count
        finding_count="$(duckdb -init /dev/null -noheader -list "$hk_db" -c "
            SELECT count(*) FROM secret_scan_findings WHERE run_id='${_run_id}';
        " 2>/dev/null)"
        if [ "$finding_count" = "$hk_total" ]; then
            pass=$((pass + 1))
        else
            echo "FAIL: expected $hk_total secret_scan_findings rows for run_id, got '$finding_count'"
        fi

        # Check: replaying write_findings_to_db for the SAME run_id/tempfile
        # is idempotent (INSERT OR IGNORE on the deterministic md5 id) --
        # count must stay the same, not double.
        total=$((total + 1))
        write_findings_to_db
        local finding_count2
        finding_count2="$(duckdb -init /dev/null -noheader -list "$hk_db" -c "
            SELECT count(*) FROM secret_scan_findings WHERE run_id='${_run_id}';
        " 2>/dev/null)"
        if [ "$finding_count2" = "$finding_count" ]; then
            pass=$((pass + 1))
        else
            echo "FAIL: replaying write_findings_to_db duplicated rows (before=$finding_count, after='$finding_count2')"
        fi

        # Check: the planted sentinel (the CREDENTIAL VALUE, embedded only in
        # the fixture file's content) never reaches the DB in ANY column --
        # extends the stdout/stderr/log-file sentinel checks above to the
        # fourth sink this dispatch adds.
        total=$((total + 1))
        local sentinel_hits
        sentinel_hits="$(duckdb -init /dev/null -noheader -list "$hk_db" -c "
            SELECT count(*) FROM secret_scan_findings
            WHERE run_id='${_run_id}' AND (
              file_path LIKE '%${hk_sentinel}%' OR name LIKE '%${hk_sentinel}%'
              OR note LIKE '%${hk_sentinel}%'
            );
        " 2>/dev/null)"
        if [ "$sentinel_hits" = "0" ]; then
            pass=$((pass + 1))
        else
            echo "FAIL: sentinel value reached secret_scan_findings ($sentinel_hits row(s))"
        fi

        rm -rf "$hk_dir" "$hk_repo" "$hk_dot" 2>/dev/null || true
        rm -f "$hk_findings" 2>/dev/null || true
    fi

    # -----------------------------------------------------------------------
    # Full-process checks (llm#951) — invoke the script as a real subprocess
    # so the top-level MODE=scan wiring (hk_run_start / mktemp-failure guard
    # / write_findings_to_db / hk_run_end) is exercised end-to-end, not just
    # the functions in isolation above. Each gets its own throwaway DB and
    # fixture dirs; the real ~/.claude/logs/unified.duckdb is never touched
    # (UNIFIED_DB_PATH is always overridden).
    # -----------------------------------------------------------------------
    local sp_script="${SCRIPT_DIR}/secret_exposure_scan.sh"
    local sp_repo sp_dot
    sp_repo="$(mktemp -d "${TMPDIR:-/tmp}/secret_scan_selftest_sprepo.XXXXXX")"
    sp_dot="$(mktemp -d "${TMPDIR:-/tmp}/secret_scan_selftest_spdot.XXXXXX")"

    if command -v duckdb >/dev/null 2>&1; then
        # Check: a ZERO-finding run (empty repo, no dotfiles) still writes a
        # heartbeat row -- 'a run finds nothing must still leave proof it ran'.
        total=$((total + 1))
        local sp_db sp_dir
        sp_dir="$(mktemp -d "${TMPDIR:-/tmp}/secret_scan_selftest_spdb.XXXXXX")"
        sp_db="${sp_dir}/unified.duckdb"
        duckdb -init /dev/null "$sp_db" < "${SCRIPT_DIR}/housekeeping_schema_init.sql" >/dev/null 2>&1 || true
        REPO_ROOT="$sp_repo" HOME="$sp_dot" UNIFIED_DB_PATH="$sp_db" \
            bash "$sp_script" --scan --quiet >/dev/null 2>&1
        local zero_row
        zero_row="$(duckdb -init /dev/null -noheader -list "$sp_db" -c "
            SELECT status || '|' || rows_written FROM housekeeping_runs
            WHERE task='secret_exposure_scan' LIMIT 1;
        " 2>/dev/null)"
        if [ "$zero_row" = "ok|0" ]; then
            pass=$((pass + 1))
        else
            echo "FAIL: zero-finding real-process run did not write an 'ok|0' heartbeat row (got '$zero_row')"
        fi
        rm -rf "$sp_dir" 2>/dev/null || true

        # Check: a genuine scan-tempfile failure (TMPDIR pointing at a
        # nonexistent directory, so mktemp fails) records status='failed',
        # not a silently-open or missing row.
        total=$((total + 1))
        local ff_db ff_dir
        ff_dir="$(mktemp -d "${TMPDIR:-/tmp}/secret_scan_selftest_ffdb.XXXXXX")"
        ff_db="${ff_dir}/unified.duckdb"
        duckdb -init /dev/null "$ff_db" < "${SCRIPT_DIR}/housekeeping_schema_init.sql" >/dev/null 2>&1 || true
        TMPDIR="${ff_dir}/does-not-exist" REPO_ROOT="$sp_repo" HOME="$sp_dot" UNIFIED_DB_PATH="$ff_db" \
            bash "$sp_script" --scan --quiet >/dev/null 2>&1
        local ff_status
        ff_status="$(duckdb -init /dev/null -noheader -list "$ff_db" -c "
            SELECT status FROM housekeeping_runs WHERE task='secret_exposure_scan' LIMIT 1;
        " 2>/dev/null)"
        if [ "$ff_status" = "failed" ]; then
            pass=$((pass + 1))
        else
            echo "FAIL: forced tempfile-creation failure did not record status='failed' (got '$ff_status')"
        fi
        rm -rf "$ff_dir" 2>/dev/null || true
    else
        echo "SKIP: duckdb not in PATH -- 2 real-process heartbeat checks skipped"
    fi

    # Check: with duckdb entirely OFF the subprocess's PATH, the scan still
    # completes cleanly (never crashes on a missing telemetry sink).
    total=$((total + 1))
    local noduck_exit
    PATH="/usr/bin:/bin" REPO_ROOT="$sp_repo" HOME="$sp_dot" \
        bash "$sp_script" --scan --quiet >/dev/null 2>&1
    noduck_exit=$?
    if [ "$noduck_exit" -eq 0 ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: duckdb-absent scan did not complete cleanly (exit=$noduck_exit, expected 0 for an empty fixture repo)"
    fi

    rm -rf "$sp_repo" "$sp_dot" 2>/dev/null || true

    echo "selftest: ${pass}/${total} PASS"
    [ "$pass" -eq "$total" ]
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$MODE" = "selftest" ]; then
    run_selftest
    exit $?
fi

# Heartbeat start row -- written BEFORE the findings tempfile exists so a
# tempfile-creation failure (disk full, /tmp missing/unwritable, TMPDIR
# pointing nowhere) still gets a heartbeat row, closed out as 'failed'
# below rather than leaving an eternally-open 'ok' row.
hk_run_start

FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/secret_exposure_scan.XXXXXX")"
if [ -z "$FINDINGS_FILE" ] || [ ! -f "$FINDINGS_FILE" ]; then
    echo "secret_exposure_scan: ERROR could not create a findings tempfile (TMPDIR=${TMPDIR:-/tmp})" >&2
    hk_run_end "failed" 0
    exit 1
fi
trap 'rm -f "$FINDINGS_FILE"' EXIT

scan_source_patterns
scan_at_rest
check_permissions

total=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
write_findings_to_db
hk_run_end "ok" "$total"

if [ "$MODE" = "fix" ]; then
    apply_fixes
    remaining="$(remaining_after_fix)"
    print_report
    [ "$remaining" -eq 0 ]
    exit $?
fi

print_report
[ "$total" -eq 0 ]
exit $?
