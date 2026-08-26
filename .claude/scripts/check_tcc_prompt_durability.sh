#!/usr/bin/env bash
# check_tcc_prompt_durability.sh — catch the cause of a TCC prompt that
# returns every time a scheduled job runs.
#
# THE MECHANISM
#   macOS binds a TCC grant to a code identity by storing a code-requirement
#   blob (csreq) alongside it. For an AD-HOC SIGNED binary there is no stable
#   designated requirement, so the csreq is stored EMPTY. TCC then cannot
#   verify that the binary asking today is the one authorised yesterday, and
#   re-prompts. A daily launchd job therefore prompts daily, forever, no
#   matter how many times you click Allow.
#
#   Observed: com.johngavin.chrome-tab-backup runs at 09:00. Its plist named
#   /bin/bash, but the script's `#!/usr/bin/env bash` shebang re-exec'd into
#   /opt/homebrew/Cellar/bash/5.3.9/bin/bash (ad-hoc signed). One
#   AUTHREQ_PROMPTING per run, at 09:00:09, every morning.
#
# WHAT THIS CHECKS
#   A. Grants whose csreq is empty  — these will re-prompt.
#   B. Grants keyed to a VERSIONED path (…/Cellar/x/1.2.3/…, /nix/store/…)
#      — these break on the next upgrade even if signed.
#   C. launchd-referenced scripts whose shebang resolves to a non-Apple
#      binary, which is how A happens in the first place.
#
# Reading TCC.db needs Full Disk Access for THIS process. If it is not
# readable that is INDETERMINATE, not clean — check A cannot run and says so
# rather than reporting zero (checks-must-distinguish-unknown).
#
# Usage: check_tcc_prompt_durability.sh [--quiet] | --selftest
# Exit:  0 clean · 1 findings · 2 could not determine
#
# llm#1032 family.

set -uo pipefail

QUIET=0
SELFTEST=0
for a in "$@"; do
    case "$a" in
        (--quiet)    QUIET=1 ;;
        (--selftest) SELFTEST=1 ;;
        (-h|--help)  echo "Usage: $(basename "$0") [--quiet] | --selftest" >&2; exit 2 ;;
    esac
done

TCC_DB="${TCC_DB:-$HOME/Library/Application Support/com.apple.TCC/TCC.db}"
LAUNCH_DIR="${LAUNCH_DIR:-$HOME/Library/LaunchAgents}"

FINDINGS=0
INDETERMINATE=0
_say()  { [ "$QUIET" = "1" ] || printf '%s\n' "$*"; }
_emit() { printf '%s\n' "$*"; }

# ── A + B — grants that cannot persist ───────────────────────────────────────
check_grants() {
    if ! command -v sqlite3 >/dev/null 2>&1; then
        INDETERMINATE=$((INDETERMINATE + 1))
        _emit "INDETERMINATE: sqlite3 not available — cannot inspect TCC grants."
        return 2
    fi
    if [ ! -r "$TCC_DB" ]; then
        INDETERMINATE=$((INDETERMINATE + 1))
        _emit "INDETERMINATE: cannot read $TCC_DB (needs Full Disk Access for this process)."
        _emit "    Not a clean result — checks A and B did not run."
        return 2
    fi

    local rows rc=0
    # Scoped to binaries the USER controls. Apple's own daemons under
    # /System, /usr/libexec and /Library/Apple routinely carry an empty csreq
    # — they are validated by platform identity, not by a stored requirement —
    # and there is nothing to do about them. Left unscoped, ~20 of those buried
    # the one line that matters, which is how a noisy check gets ignored and
    # then deleted.
    rows=$(sqlite3 "$TCC_DB" \
      "SELECT service || '|' || client || '|' || COALESCE(length(csreq),0)
       FROM access
       WHERE client LIKE '/%'
         AND client NOT LIKE '/System/%'
         AND client NOT LIKE '/usr/libexec/%'
         AND client NOT LIKE '/Library/Apple/%'
         AND client NOT LIKE '/usr/sbin/%';" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        INDETERMINATE=$((INDETERMINATE + 1))
        _emit "INDETERMINATE: TCC.db query failed (rc=$rc) — checks A and B did not run."
        return 2
    fi

    local n_empty=0 n_versioned=0
    _VERSIONED_TMP="$(mktemp)" 
    while IFS='|' read -r svc client len; do
        [ -n "${client:-}" ] || continue
        if [ "${len:-0}" = "0" ]; then
            n_empty=$((n_empty + 1)); FINDINGS=$((FINDINGS + 1))
            _emit "FINDING [tcc-grant-cannot-persist] $svc"
            _emit "    $client"
            _emit "    csreq is empty (binary is ad-hoc signed or unsigned), so this grant"
            _emit "    cannot bind to a code identity and WILL re-prompt on every run."
            _emit "    fix: run it via an Apple-signed interpreter, or sign this binary."
        fi
        # Version-pinned paths are real but SECONDARY: they break a grant at
        # the next upgrade, not every day. Emitting one per (service, client)
        # produced 11 lines for a single bash binary and buried the one line
        # that explains the daily prompt. Counted and named once, not flagged.
        case "$client" in
            (*/Cellar/*/[0-9]*/*|/nix/store/*)
                n_versioned=$((n_versioned + 1))
                printf '%s\n' "$client" >> "$_VERSIONED_TMP"
                ;;
        esac
    done <<< "$rows"
    if [ "$n_versioned" -gt 0 ]; then
        _say "check-grants: $n_versioned version-pinned grant(s) across these binaries —"
        _say "  (informational: each breaks at the next upgrade, not daily)"
        sort -u "$_VERSIONED_TMP" 2>/dev/null | while IFS= read -r c; do _say "    $c"; done
    fi
    rm -f "$_VERSIONED_TMP"
    _say "check-grants: empty-csreq=$n_empty version-pinned=$n_versioned"
    return 0
}

# ── C — launchd scripts that re-exec out of an Apple-signed interpreter ──────
check_shebangs() {
    local n=0 scanned=0
    _SHEBANG_TMP="$(mktemp)"
    [ -d "$LAUNCH_DIR" ] || { _say "check-shebangs: $LAUNCH_DIR absent — skipped"; rm -f "$_SHEBANG_TMP"; return 0; }
    while IFS= read -r pl; do
        local scripts
        # plutil -convert json escapes forward slashes: /a/b.sh comes out as
        # \/a\/b.sh. Left unstripped, every path fails its own [ -f ] test and
        # the check reports zero findings while looking at nothing.
        scripts=$(/usr/bin/plutil -convert json -o - "$pl" 2>/dev/null \
                  | tr ',' '\n' | grep -oE '[^"]*\.sh' | tr -d '\\' || true)
        [ -n "$scripts" ] || continue
        while IFS= read -r sc; do
            [ -n "${sc:-}" ] || continue
            local path="${sc/#\~/$HOME}"
            [ -f "$path" ] || continue
            scanned=$((scanned + 1))
            local shebang
            shebang=$(head -1 "$path" 2>/dev/null || true)
            case "$shebang" in
                (*"/usr/bin/env "*)
                    # NOT a finding on its own. Six launchd scripts here use an
                    # env-shebang and exactly one of them touches a
                    # TCC-protected resource; flagging all six would have people
                    # editing five shebangs for no reason, and a check that
                    # cries wolf gets ignored and then deleted. This is the
                    # EXPLANATION for a check-A finding, printed as context.
                    n=$((n + 1))
                    printf '    %-46s %s\n' "$(basename "$pl")" "$path" >> "$_SHEBANG_TMP"
                    ;;
            esac
        done <<< "$scripts"
    done < <(find "$LAUNCH_DIR" -maxdepth 1 -name '*.plist' 2>/dev/null)
    # Only surface the list when check A found something it explains.
    if [ "$n" -gt 0 ] && [ "$FINDINGS" -gt 0 ]; then
        _emit "  Context — launchd scripts whose shebang re-execs out of the plist's"
        _emit "  interpreter into whatever is on PATH (an ad-hoc-signed Homebrew bash):"
        cat "$_SHEBANG_TMP" 2>/dev/null
        _emit "  Only the one whose job touches a protected resource needs pinning to"
        _emit "  #!/bin/bash; the rest are listed so the mechanism is visible."
    fi
    rm -f "$_SHEBANG_TMP"
    _say "check-shebangs: scripts scanned=$scanned env-shebangs=$n"
    return 0
}

selftest() {
    local tmp pass=0 fail=0
    tmp="$(mktemp -d)"
    ok(){ pass=$((pass+1)); echo "  PASS: $1"; }
    bad(){ fail=$((fail+1)); echo "  FAIL: $1"; }
    echo "check_tcc_prompt_durability.sh --selftest"

    # A missing TCC.db must be INDETERMINATE, never clean. This is the whole
    # discipline: "I could not look" and "I looked and found nothing" must not
    # share an exit.
    TCC_DB="$tmp/nope.db"; FINDINGS=0; INDETERMINATE=0; QUIET=1
    check_grants >/dev/null 2>&1 && rc=0 || rc=$?
    if [ "$rc" -eq 2 ] && [ "$INDETERMINATE" -eq 1 ] && [ "$FINDINGS" -eq 0 ]; then
        ok "unreadable TCC.db is INDETERMINATE, not clean"
    else
        bad "unreadable TCC.db misclassified (rc=$rc find=$FINDINGS indet=$INDETERMINATE)"
    fi

    # A synthetic TCC.db: one empty-csreq row (must flag), one with a csreq
    # (must not). Without the second, "flag everything" would pass.
    local db="$tmp/tcc.db"
    sqlite3 "$db" "CREATE TABLE access (service TEXT, client TEXT, csreq BLOB);
                   INSERT INTO access VALUES ('kTCCServiceSystemPolicyAppData','/opt/homebrew/bin/foo',NULL);
                   INSERT INTO access VALUES ('kTCCServiceAppleEvents','/bin/bash',X'0102030405');" 2>/dev/null
    # NOT out="$(check_grants)". These functions increment FINDINGS, and a
    # command substitution runs them in a SUBSHELL, so the counter is thrown
    # away and every assertion on it reads 0. Third instance of this exact
    # mistake today (llm#1012 and llm#1019 both hit it). Redirect to a file
    # and read the file instead.
    TCC_DB="$db"; FINDINGS=0; INDETERMINATE=0; QUIET=1
    check_grants > "$tmp/out1.txt" 2>&1 || true
    if [ "$FINDINGS" -eq 1 ]; then ok "flags exactly the empty-csreq grant"
    else bad "empty-csreq detection wrong (findings=$FINDINGS)"; fi
    # Match the finding's CLIENT line, not any mention of /bin/bash — the
    # remediation text in the finding itself says "invoke via an Apple-signed
    # binary (/bin/bash)", which a naive substring match hits every time.
    if grep -qE '^[[:space:]]+/bin/bash$' "$tmp/out1.txt"; then
        bad "flagged the Apple-signed grant that has a csreq"
    else
        ok "does not flag a grant that has a csreq"
    fi

    # Version-pinned path.
    sqlite3 "$db" "DELETE FROM access;
                   INSERT INTO access VALUES ('kTCCServiceX','/opt/homebrew/Cellar/bash/5.3.9/bin/bash',X'01');" 2>/dev/null
    TCC_DB="$db"; FINDINGS=0; INDETERMINATE=0; QUIET=0
    check_grants > "$tmp/out_vp.txt" 2>&1 || true
    if grep -q 'version-pinned=1' "$tmp/out_vp.txt"; then
        ok "counts a version-pinned grant path"
    else
        bad "missed a version-pinned grant path"
    fi
    # …and does NOT raise it as a finding: it breaks at the next upgrade, not
    # daily, and 11 such lines buried the one that mattered.
    if [ "$FINDINGS" -eq 0 ]; then ok "version-pinned is informational, not a finding"
    else bad "version-pinned raised a finding (findings=$FINDINGS)"; fi

    # Shebang check: env-shebang flagged, /bin/bash shebang not.
    local ld="$tmp/agents"; mkdir -p "$ld"
    printf '#!/usr/bin/env bash\necho hi\n' > "$tmp/bad.sh"; chmod +x "$tmp/bad.sh"
    printf '#!/bin/bash\necho hi\n'        > "$tmp/good.sh"; chmod +x "$tmp/good.sh"
    /usr/bin/python3 - "$ld" "$tmp" <<'PY'
import plistlib, sys, os
ld, tmp = sys.argv[1], sys.argv[2]
for name, script in (("bad", "bad.sh"), ("good", "good.sh")):
    plistlib.dump({"Label": "test."+name,
                   "ProgramArguments": ["/bin/bash", os.path.join(tmp, script)]},
                  open(os.path.join(ld, "test.%s.plist" % name), "wb"))
PY
    # The shebang scan is CONTEXT: it must not raise findings by itself, and
    # must stay silent when check A found nothing to explain.
    LAUNCH_DIR="$ld"; FINDINGS=0; QUIET=1
    check_shebangs > "$tmp/out2.txt" 2>&1 || true
    if [ "$FINDINGS" -eq 0 ]; then ok "shebang scan raises no findings on its own"
    else bad "shebang scan raised $FINDINGS finding(s) unprompted"; fi
    if [ ! -s "$tmp/out2.txt" ]; then ok "shebang context stays silent with no check-A finding"
    else bad "shebang context printed with nothing to explain"; fi

    # …but WITH a check-A finding, it must print, and must name only the
    # env-shebang script.
    LAUNCH_DIR="$ld"; FINDINGS=1; QUIET=1
    check_shebangs > "$tmp/out2b.txt" 2>&1 || true
    if grep -q 'bad\.sh' "$tmp/out2b.txt"; then ok "shebang context names the env-shebang script"
    else bad "shebang context omitted the env-shebang script"; fi
    if grep -q 'good\.sh' "$tmp/out2b.txt"; then
        bad "shebang context named the #!/bin/bash script"
    else
        ok "shebang context does not name the #!/bin/bash script"
    fi
    # The scan must have actually LOOKED at both scripts. Without this, the two
    # assertions above are equally satisfied by a scan that found no files at
    # all — which is precisely what the plutil slash-escaping bug caused.
    QUIET=0; FINDINGS=0
    check_shebangs > "$tmp/out3.txt" 2>&1 || true
    if grep -q 'scripts scanned=2' "$tmp/out3.txt"; then
        ok "scan actually opened both fixture scripts"
    else
        bad "scan opened $(grep -o 'scripts scanned=[0-9]*' "$tmp/out3.txt" || echo '?') of 2 fixtures"
    fi

    rm -rf "$tmp"
    echo ""
    echo "  $pass passed, $fail failed"
    [ "$fail" -eq 0 ] && exit 0 || exit 1
}

[ "$SELFTEST" = "1" ] && selftest

check_grants || true
check_shebangs || true
_say "tcc-prompt-durability: findings=$FINDINGS indeterminate=$INDETERMINATE"
[ "$FINDINGS" -gt 0 ] && exit 1
[ "$INDETERMINATE" -gt 0 ] && exit 2
exit 0
