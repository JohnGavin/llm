#!/usr/bin/env bash
# credential_hygiene_check.sh — two credential-hygiene checks that were silent
# for two weeks (llm#1032).
#
# CHECK A — a credential embedded in a git remote URL.
#   `https://x-access-token:<token>@github.com/owner/repo` is world-readable to
#   anything that can run `git remote -v`, leaks into any log line that prints
#   the slug, and survives rotation silently. One repo here carried a GitHub
#   PAT this way; it was found only because a diagnostic added in llm#1019
#   logged the slug and put the token in a plaintext log.
#
# CHECK B — an auth env var that is SET but REJECTED.
#   A revoked GH_TOKEN in the environment SHADOWS the working keyring
#   credential: `gh` prefers the env var, so every call 401s while
#   `gh auth status` reports a healthy login. That is strictly worse than
#   unset. It cost ~5 GB of retained worktrees (llm#1019) and a merge gate
#   that could not fail (llm#1012), for two weeks.
#
# WHY A SCRIPT AND NOT A RULE
#   `credential-management.md` is already safety-critical and unconditionally
#   loaded, and did not prevent either. Same lesson as llm#946: if you are
#   relying on a .md to prevent a leak, the enforcement is missing.
#
# Usage:
#   credential_hygiene_check.sh [--quiet] [--json] [root ...]
#   credential_hygiene_check.sh --selftest
#
# Exit: 0 clean · 1 findings · 2 could not run
#       Exit 2 is NOT "clean". If the API cannot be reached, Check B has not
#       established anything and says so — the rule this repo keeps relearning
#       (checks-must-distinguish-unknown).
#
# NEVER prints a credential value. Findings name the repo, the variable, and
# the shape; never the secret.

set -uo pipefail

QUIET=0
EMIT_JSON=0
SELFTEST=0
ROOTS=()

while [ $# -gt 0 ]; do
    case "$1" in
        (--quiet)    QUIET=1; shift ;;
        (--json)     EMIT_JSON=1; shift ;;
        (--selftest) SELFTEST=1; shift ;;
        (-h|--help)
            echo "Usage: $(basename "$0") [--quiet] [--json] [root ...]" >&2
            echo "       $(basename "$0") --selftest" >&2
            exit 2 ;;
        (*) ROOTS+=("$1"); shift ;;
    esac
done

[ "${#ROOTS[@]}" -eq 0 ] && ROOTS=("$HOME/docs_gh")

FINDINGS=0
INDETERMINATE=0

# _say  — routine progress. Suppressed by --quiet.
# _emit — findings and indeterminate results. NEVER suppressed.
#
# The distinction is not cosmetic. The first version had --quiet silence
# everything, so the session-init banner (which pipes --quiet output through a
# FINDING filter) came back empty whether or not anything was wrong: "nothing
# found" and "output suppressed" were the same bytes. That is the defect this
# entire script exists to detect, reproduced inside it within minutes of
# writing it. Caught by running the banner command, not by reading it.
_say()  { [ "$QUIET" = "1" ] || printf '%s\n' "$*"; }
_emit() { printf '%s\n' "$*"; }

# ── Check A — credentials embedded in git remote URLs ───────────────────────
# Matches `scheme://<anything>:<anything>@host/`. Prints the repo and the
# redacted URL; the credential itself never reaches stdout.
check_remotes() {
    local root scanned=0 hits=0
    for root in "${ROOTS[@]}"; do
        [ -d "$root" ] || continue
        while IFS= read -r cfg; do
            local repo urls
            repo=$(dirname "$(dirname "$cfg")")
            scanned=$((scanned + 1))
            urls=$(git -C "$repo" config --get-regexp '^remote\..*\.url' 2>/dev/null || true)
            case "$urls" in
                (*"://"*":"*"@"*)
                    hits=$((hits + 1))
                    FINDINGS=$((FINDINGS + 1))
                    _emit "FINDING [remote-credential] $repo"
                    _emit "    $(printf '%s' "$urls" | sed -E 's#://[^@]*@#://<REDACTED>@#' | tr '\n' ' ')"
                    _emit "    fix: git -C '$repo' remote set-url origin https://github.com/OWNER/REPO.git"
                    ;;
            esac
        done < <(find "$root" -maxdepth 8 -name config -path '*/.git/config' -not -path '*/worktrees/*' 2>/dev/null)
    done
    _say "check-a: repos scanned=$scanned credentialed-remotes=$hits"
    REMOTES_SCANNED=$scanned
    REMOTES_HITS=$hits
}

# ── Check B — an auth env var that is set but rejected ───────────────────────
# Three outcomes, three exits. "Could not reach the API" is NOT "fine".
check_env_token() {
    local var="$1" url="$2" val code
    val="${!var:-}"
    if [ -z "$val" ]; then
        _say "check-b: $var unset — fine (the credential helper / keyring is used)"
        return 0
    fi

    # curl writes 000 to stdout AND exits non-zero on a connection failure, so
    # `|| echo "000"` appended a SECOND 000 and produced "000000" -- which fell
    # through the dedicated 000 branch to the catch-all and printed a nonsense
    # status. Correct behaviour either way (both are INDETERMINATE), wrong
    # message, and a branch that could never run. Capture, then default.
    local curl_rc=0
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H "Authorization: Bearer $val" "$url" 2>/dev/null) || curl_rc=$?
    if [ "$curl_rc" -ne 0 ] || [ -z "$code" ]; then code="000"; fi

    case "$code" in
        (200)
            _say "check-b: $var set and accepted (HTTP 200)"
            return 0 ;;
        (401|403)
            FINDINGS=$((FINDINGS + 1))
            _emit "FINDING [dead-auth-env-var] $var is set and REJECTED (HTTP $code)"
            _emit "    It SHADOWS the working credential: gh prefers the env var, so every"
            _emit "    call fails while 'gh auth status' still reports a healthy login."
            _emit "    fix: unset it at its source, then start a NEW shell. 'exec zsh' does"
            _emit "    NOT clear it — a running shell keeps the inherited value and hands it"
            _emit "    to every child. Use: exec env -u $var \$SHELL"
            return 1 ;;
        (000)
            INDETERMINATE=$((INDETERMINATE + 1))
            _emit "INDETERMINATE: could not reach $url to validate \$$var."
            _emit "    This is NOT a pass. The variable is set and unverified."
            return 2 ;;
        (*)
            INDETERMINATE=$((INDETERMINATE + 1))
            _emit "INDETERMINATE: $url returned HTTP $code validating \$$var — cannot classify."
            return 2 ;;
    esac
}

# ── Selftest ─────────────────────────────────────────────────────────────────
selftest() {
    local tmp pass=0 fail=0
    tmp="$(mktemp -d)"
    ok(){ pass=$((pass+1)); echo "  PASS: $1"; }
    bad(){ fail=$((fail+1)); echo "  FAIL: $1"; }
    echo "credential_hygiene_check.sh --selftest"

    # A fixture that was not created must FAIL, never read as clean — the
    # defect this whole family is about, and one that has already bitten a
    # sibling selftest (llm#1030).
    _fixture(){ [ -d "$1" ] || { bad "fixture $1 missing"; return 1; }; return 0; }

    # -- Check A: a credentialed remote is found.
    local cred="$tmp/credrepo"
    mkdir -p "$cred"
    git init -q "$cred"
    git -C "$cred" remote add origin "https://x-access-token:FAKEFAKEFAKEFAKE1234@github.com/o/r.git"
    ROOTS=("$tmp"); FINDINGS=0; QUIET=1
    _fixture "$cred" && check_remotes
    if [ "$FINDINGS" -eq 1 ]; then ok "check A finds a credentialed remote"
    else bad "check A missed a credentialed remote (findings=$FINDINGS)"; fi

    # -- and it does NOT report the credential itself.
    ROOTS=("$tmp"); FINDINGS=0; QUIET=0
    local out
    out="$(check_remotes 2>&1)"
    case "$out" in
        (*FAKEFAKEFAKEFAKE1234*) bad "check A leaked the credential into its own output" ;;
        (*) ok "check A redacts the credential in its finding" ;;
    esac

    # -- a clean remote is not flagged. Without this the check could be
    #    satisfied by flagging every repo unconditionally.
    local clean="$tmp/cleanrepo"
    mkdir -p "$clean"
    git init -q "$clean"
    git -C "$clean" remote add origin "https://github.com/o/r.git"
    rm -rf "$cred"
    ROOTS=("$tmp"); FINDINGS=0; QUIET=1
    _fixture "$clean" && check_remotes
    if [ "$FINDINGS" -eq 0 ]; then ok "check A does not flag a clean remote"
    else bad "check A false-positives on a clean remote"; fi

    # -- an SSH remote (user@host:path, no scheme) is not a finding.
    git -C "$clean" remote set-url origin "git@github.com:o/r.git"
    ROOTS=("$tmp"); FINDINGS=0; QUIET=1
    check_remotes
    if [ "$FINDINGS" -eq 0 ]; then ok "check A does not flag an SSH remote"
    else bad "check A false-positives on git@host:path"; fi

    # -- Check B: unset is fine; rejected is a finding; unreachable is
    #    INDETERMINATE and must not be confused with either.
    QUIET=1; FINDINGS=0; INDETERMINATE=0
    unset SELFTEST_TOKEN_VAR 2>/dev/null || true
    check_env_token SELFTEST_TOKEN_VAR "https://127.0.0.1:1/never" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ] && [ "$FINDINGS" -eq 0 ]; then ok "check B: unset var is clean"
    else bad "check B: unset var not treated as clean (rc=$rc)"; fi

    QUIET=1; FINDINGS=0; INDETERMINATE=0
    SELFTEST_TOKEN_VAR="anything" check_env_token SELFTEST_TOKEN_VAR "https://127.0.0.1:1/never" && rc=0 || rc=$?
    if [ "$rc" -eq 2 ] && [ "$INDETERMINATE" -eq 1 ] && [ "$FINDINGS" -eq 0 ]; then
        ok "check B: unreachable API is INDETERMINATE, not a pass and not a finding"
    else
        bad "check B: unreachable API misclassified (rc=$rc findings=$FINDINGS indet=$INDETERMINATE)"
    fi

    # The 000 branch must be REACHED, not merely equivalent to the catch-all.
    # It was dead: curl prints 000 and exits non-zero, so `|| echo "000"`
    # produced "000000" and fell through to the generic handler. The
    # classification was right and the message was nonsense, which is how a
    # dead branch survives.
    QUIET=0; FINDINGS=0; INDETERMINATE=0
    local unreach
    unreach="$(SELFTEST_TOKEN_VAR="anything" check_env_token SELFTEST_TOKEN_VAR "https://127.0.0.1:1/never" 2>&1 || true)"
    case "$unreach" in
        (*"could not reach"*) ok "check B: unreachable API takes the dedicated 000 branch" ;;
        (*) bad "check B: 000 branch not reached — got: $(printf '%s' "$unreach" | head -1)" ;;
    esac

    # And a findings line must survive --quiet, or the session-init banner
    # (which pipes --quiet output through a FINDING filter) is empty whether
    # or not anything is wrong.
    QUIET=1; FINDINGS=0; INDETERMINATE=0
    local quiet_out
    quiet_out="$(SELFTEST_TOKEN_VAR="anything" check_env_token SELFTEST_TOKEN_VAR "https://127.0.0.1:1/never" 2>&1 || true)"
    case "$quiet_out" in
        (*INDETERMINATE*) ok "check B: findings survive --quiet (banner is not silently empty)" ;;
        (*) bad "check B: --quiet suppressed the finding itself" ;;
    esac

    rm -rf "$tmp"
    echo ""
    echo "  $pass passed, $fail failed"
    [ "$fail" -eq 0 ] && exit 0 || exit 1
}

[ "$SELFTEST" = "1" ] && selftest

# ── Main ─────────────────────────────────────────────────────────────────────
REMOTES_SCANNED=0
REMOTES_HITS=0
check_remotes
check_env_token GH_TOKEN     "https://api.github.com/user" || true
check_env_token GITHUB_TOKEN "https://api.github.com/user" || true

if [ "$EMIT_JSON" = "1" ]; then
    printf '{"findings":%d,"indeterminate":%d,"repos_scanned":%d,"credentialed_remotes":%d}\n' \
        "$FINDINGS" "$INDETERMINATE" "$REMOTES_SCANNED" "$REMOTES_HITS"
fi

_say "credential-hygiene: findings=$FINDINGS indeterminate=$INDETERMINATE"

[ "$FINDINGS" -gt 0 ] && exit 1
[ "$INDETERMINATE" -gt 0 ] && exit 2
exit 0
