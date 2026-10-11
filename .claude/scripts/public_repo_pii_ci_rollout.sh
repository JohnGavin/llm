#!/usr/bin/env bash
# public_repo_pii_ci_rollout.sh -- roll the private-data-scan CI gate out to
# every public repo of an owner, and report who has it (llm#1366).
#
# Layer 4 of the private-data-scanning defence (.claude/rules/
# private-data-scanning.md) is a server-side check that no local flag can
# skip. It only counts if (a) the workflow exists in the repo and (b) a
# ruleset makes its status check REQUIRED on the default branch. This script
# reports both, and installs both -- one repo at a time, never by direct push.
#
# MODES (default --check; nothing mutates unless --apply/--apply-ruleset):
#   --check            Per public repo: PASS / FAIL / INDETERMINATE.
#                      PASS = workflow file on the default branch AND an
#                      effective rule requiring the "private-data-scan"
#                      status check. Read-only.
#   --dry-run          Print the exact PR and ruleset each eligible repo
#                      would get. Read-only. (Also what --apply does when
#                      --dry-run is also given.)
#   --apply --repo O/N         Open a PR adding the workflow (clone, branch,
#                              commit, push, gh pr create). One repo only.
#   --apply-ruleset --repo O/N POST a ruleset requiring the check. Refused
#                              unless the workflow is already on the default
#                              branch (requiring a check that does not exist
#                              blocks every merge). Run AFTER the PR merges.
#   --selftest         Stubbed-gh self-test (no network).
# OPTIONS: --owner NAME (default JohnGavin), --include-forks (rollout to
#   forks too; --check always lists them), --scanner-sha SHA (default: llm
#   main HEAD), -h|--help.
#
# EXIT CODES (.claude/rules/exit-code-conventions.md) for --check/--dry-run:
#   0 every repo PASS   1 at least one FAIL   2 usage error
#   3 INDETERMINATE (no FAIL, but at least one repo could not be evaluated)
# Action modes: 0 done, 2 usage, 3 precondition/API error, 1 action failed.
#
# DESIGN CHOICES
# * Scanner delivery: the workflow FETCHES private_data_scan.sh from
#   JohnGavin/llm at a pinned commit SHA and verifies a pinned sha256 before
#   running it (fails closed on mismatch). Vendoring a ~2000-line scanner
#   into dozens of repos means dozens of silently diverging copies; one
#   pinned source has one home. The hash means a rewritten/tampered llm
#   history (it was rewritten once already) cannot change what runs. Cost:
#   llm must stay public, and bumping the pin is a PR per repo.
# * CI runs --no-denylist by design (private-data-scanning.md): a public
#   repo's runner is never handed personal PII literals. Generic E.164 /
#   UK-postcode / IBAN pattern coverage only; the workflow says so.
# * Mutations avoid HTTP PUT/PATCH/DELETE (destructive_api_guard blocks
#   them): the PR goes through git clone/push + gh pr create; the ruleset is
#   a single POST (allowed).
# * The ruleset lets repository admins bypass for pull requests only
#   (bypass_mode pull_request), so a broken scanner cannot lock the owner
#   out of merging. Direct pushes to the default branch are blocked by a
#   required check: repos whose bots/Actions push straight to the default
#   branch WILL break -- review each repo before --apply-ruleset.

set -u

OWNER="JohnGavin"
LLM_REPO="JohnGavin/llm"
SCANNER_PATH=".claude/scripts/private_data_scan.sh"
WF_PATH=".github/workflows/private-data-scan.yml"
CHECK_CONTEXT="private-data-scan"
RULESET_NAME="require-private-data-scan"
PR_BRANCH="chore/private-data-scan-ci"

MODE="check"; DRY=0; APPLY=0; APPLY_RS=0; ONE_REPO=""; INCLUDE_FORKS=0
SCANNER_SHA=""

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

die_usage() { echo "USAGE-ERROR: $*" >&2; exit 2; }

# ---------------------------------------------------------------- helpers
sha256_of() { # stdin -> hex
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    else shasum -a 256 | cut -d' ' -f1; fi
}

GH_OUT=""
gh_try() { GH_OUT="$(gh "$@" 2>&1)"; return $?; }

# check_repo REPO BRANCH -> sets CR_STATE CR_MSG CR_WF (yes|no|unknown) CR_REQ (yes|no|unknown)
check_repo() {
    local r="$1" b="$2" n
    CR_STATE=""; CR_MSG=""; CR_WF="unknown"; CR_REQ="unknown"
    if [ -z "$b" ]; then
        CR_STATE="INDETERMINATE"; CR_MSG="empty repository (no default branch) -- nothing to inspect"
        return
    fi
    if gh_try api "repos/$r/contents/$WF_PATH?ref=$b" --jq .path; then
        CR_WF="yes"
    elif printf '%s' "$GH_OUT" | grep -q 'HTTP 404'; then
        CR_WF="no"
    else
        CR_WF="unknown"; local wf_err="workflow lookup failed: $(printf '%s' "$GH_OUT" | head -n1)"
    fi
    if gh_try api "repos/$r/rules/branches/$b" --jq \
        "[.[] | select(.type==\"required_status_checks\") | .parameters.required_status_checks[]?.context] | map(select(.==\"$CHECK_CONTEXT\")) | length"; then
        case "$GH_OUT" in
            ''|*[!0-9]*) CR_REQ="unknown"; local rq_err="unparseable rules reply" ;;
            0) CR_REQ="no" ;;
            *) CR_REQ="yes" ;;
        esac
    else
        CR_REQ="unknown"; local rq_err="rules lookup failed: $(printf '%s' "$GH_OUT" | head -n1)"
    fi
    # A determinate failure stands even when the other probe was unknown.
    if [ "$CR_WF" = "no" ]; then
        CR_STATE="FAIL"; CR_MSG="workflow missing on $b"
        [ "$CR_REQ" = "yes" ] && CR_MSG="$CR_MSG (a rule requires a check that cannot run)"
    elif [ "$CR_REQ" = "no" ]; then
        CR_STATE="FAIL"; CR_MSG="check '$CHECK_CONTEXT' not required by any ruleset on $b"
        [ "$CR_WF" = "unknown" ] && CR_MSG="$CR_MSG; ${wf_err:-}"
    elif [ "$CR_WF" = "yes" ] && [ "$CR_REQ" = "yes" ]; then
        CR_STATE="PASS"; CR_MSG="workflow present and check required on $b"
    else
        CR_STATE="INDETERMINATE"; CR_MSG="${wf_err:-}${wf_err:+; }${rq_err:-}"
    fi
}

# list_repos -> TSV lines: name<TAB>isFork<TAB>isArchived<TAB>defaultBranch
list_repos() {
    gh repo list "$OWNER" --visibility public --limit 1000 \
        --json nameWithOwner,isFork,isArchived,defaultBranchRef \
        --jq '.[] | [.nameWithOwner,.isFork,.isArchived,(.defaultBranchRef.name // "")] | @tsv'
}

resolve_scanner() { # sets SCANNER_SHA SCANNER_SHA256 ; returns 3 on failure
    if [ -z "$SCANNER_SHA" ]; then
        if ! gh_try api "repos/$LLM_REPO/commits/main" --jq .sha; then
            echo "INDETERMINATE: cannot resolve $LLM_REPO main SHA: $GH_OUT" >&2; return 3
        fi
        SCANNER_SHA="$GH_OUT"
    fi
    case "$SCANNER_SHA" in *[!0-9a-f]*|'') echo "INDETERMINATE: bad scanner SHA '$SCANNER_SHA'" >&2; return 3 ;; esac
    local f; f="$(mktemp)"
    if ! gh api -H 'Accept: application/vnd.github.raw' "repos/$LLM_REPO/contents/$SCANNER_PATH?ref=$SCANNER_SHA" > "$f" 2>"$f.err"; then
        echo "INDETERMINATE: cannot fetch scanner at $SCANNER_SHA: $(cat "$f.err")" >&2; rm -f "$f" "$f.err"; return 3
    fi
    [ -s "$f" ] || { echo "INDETERMINATE: scanner at $SCANNER_SHA is empty" >&2; rm -f "$f" "$f.err"; return 3; }
    SCANNER_SHA256="$(sha256_of < "$f")"   # hash of the exact bytes the runner will download
    rm -f "$f" "$f.err"
    return 0
}

render_workflow() { # BRANCH
    cat <<EOF
# private-data-scan -- CI gate for PII entering this PUBLIC repo.
# Installed by JohnGavin/llm .claude/scripts/public_repo_pii_ci_rollout.sh
# (llm#1366). Layer 4 of the private-data-scanning defence: server-side,
# unbypassable by --no-verify or an uninstalled local hook.
#
# The scanner is NOT vendored: it is fetched from JohnGavin/llm at a pinned
# commit and its sha256 is verified before it runs (fails closed). To bump
# the pin, change both values below together.
#
# Runs with --no-denylist by design: this public repo's runner is never
# handed personal PII literals. Generic E.164 / UK-postcode / IBAN pattern
# coverage only; the run summary says so.

name: private-data-scan

on:
  pull_request:
    branches: [$1]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  $CHECK_CONTEXT:
    name: $CHECK_CONTEXT
    runs-on: ubuntu-latest
    env:
      SCANNER_SHA: $SCANNER_SHA
      SCANNER_SHA256: $SCANNER_SHA256
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Install pdftotext (selftest exits 3 without it)
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y -qq poppler-utils

      - name: Fetch scanner at pinned SHA and verify its hash
        run: |
          mkdir -p "\$RUNNER_TEMP/pds"
          curl -fsSL "https://raw.githubusercontent.com/$LLM_REPO/\${SCANNER_SHA}/$SCANNER_PATH" -o "\$RUNNER_TEMP/pds/private_data_scan.sh"
          echo "\${SCANNER_SHA256}  \$RUNNER_TEMP/pds/private_data_scan.sh" | sha256sum -c -

      - name: Self-check -- prove the detector can fail before trusting it
        run: bash "\$RUNNER_TEMP/pds/private_data_scan.sh" --selftest

      - name: Scan every commit in this PR for PII (generic patterns; no deny-list on CI)
        if: github.event_name == 'pull_request'
        env:
          BASE_SHA: \${{ github.event.pull_request.base.sha }}
          HEAD_SHA: \${{ github.event.pull_request.head.sha }}
          REPO_ROOT: \${{ github.workspace }}
        run: |
          echo "::notice::private-data-scan runs with --no-denylist on CI (generic pattern coverage only)."
          bash "\$RUNNER_TEMP/pds/private_data_scan.sh" --range "\$BASE_SHA" "\$HEAD_SHA" --no-denylist
EOF
}

render_ruleset() {
    cat <<EOF
{
  "name": "$RULESET_NAME",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [ { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request" } ],
  "rules": [ { "type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": false,
      "do_not_enforce_on_create": false,
      "required_status_checks": [ { "context": "$CHECK_CONTEXT" } ] } } ]
}
EOF
}

pr_title() { echo "ci: add required private-data-scan PII gate"; }
pr_body() {
    cat <<EOF
Adds \`$WF_PATH\` (llm#1366): a CI scan of every commit in a PR for
personal identifiers (E.164 phone numbers, UK postcodes, IBANs).

- The scanner is fetched from $LLM_REPO at commit \`$SCANNER_SHA\` and its
  sha256 (\`$SCANNER_SHA256\`) is verified before it runs; it is not vendored.
- Runs with \`--no-denylist\`: no personal literals are given to this runner.
- Merging this PR does not by itself make the check required; a ruleset is
  added as a separate step after merge.

Generated by .claude/scripts/public_repo_pii_ci_rollout.sh.
EOF
}

# ---------------------------------------------------------------- modes
run_check() { # prints per-repo lines + summary; sets exit code
    local pass=0 fail=0 indet=0 arch=0 forks=0 name fork archived branch
    local tsv; tsv="$(list_repos 2>&1)" || { echo "INDETERMINATE: cannot list repos: $tsv" >&2; return 3; }
    [ -n "$tsv" ] || { echo "INDETERMINATE: repo listing for $OWNER is empty" >&2; return 3; }
    while IFS=$'\t' read -r name fork archived branch; do
        [ -n "$name" ] || continue
        [ -z "$ONE_REPO" ] || [ "$ONE_REPO" = "$name" ] || continue
        if [ "$archived" = "true" ]; then arch=$((arch+1)); continue; fi
        local tag=""; [ "$fork" = "true" ] && { tag=" (fork)"; forks=$((forks+1)); }
        check_repo "$name" "$branch"
        case "$CR_STATE" in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; *) indet=$((indet+1));; esac
        printf '%-13s %s%s -- %s\n' "$CR_STATE" "$name" "$tag" "$CR_MSG"
    done <<<"$tsv"
    echo "SUMMARY: PASS=$pass FAIL=$fail INDETERMINATE=$indet (archived skipped=$arch; forks included=$forks)"
    if [ "$fail" -gt 0 ]; then return 1; fi
    if [ "$indet" -gt 0 ]; then return 3; fi
    return 0
}

eligible_for_rollout() { # name fork -> 0 if rollout allowed
    [ "$2" != "true" ] || [ "$INCLUDE_FORKS" = "1" ]
}

run_dry() {
    resolve_scanner || return 3
    local tsv name fork archived branch n=0 skipped=0
    tsv="$(list_repos 2>&1)" || { echo "INDETERMINATE: cannot list repos: $tsv" >&2; return 3; }
    while IFS=$'\t' read -r name fork archived branch; do
        [ -n "$name" ] || continue
        [ -z "$ONE_REPO" ] || [ "$ONE_REPO" = "$name" ] || continue
        [ "$archived" != "true" ] || continue
        if ! eligible_for_rollout "$name" "$fork"; then
            echo "SKIP $name -- fork (upstream-authored history); use --include-forks"; skipped=$((skipped+1)); continue
        fi
        check_repo "$name" "$branch"
        case "$CR_STATE" in
            PASS) echo "NOOP $name -- already PASS"; continue ;;
            INDETERMINATE) echo "SKIP $name -- INDETERMINATE: $CR_MSG"; skipped=$((skipped+1)); continue ;;
        esac
        n=$((n+1))
        echo "=== $name (default branch: $branch) ==="
        if [ "$CR_WF" != "yes" ]; then
            echo "WOULD OPEN PR: base=$branch head=$PR_BRANCH title=\"$(pr_title)\""
            echo "  adds: $WF_PATH (scanner pinned to $LLM_REPO@$SCANNER_SHA, sha256 $SCANNER_SHA256)"
            if [ -n "$ONE_REPO" ]; then render_workflow "$branch" | sed 's/^/  | /'
            else echo "  workflow sha256: $(render_workflow "$branch" | sha256_of) (full text with --repo $name)"; fi
        fi
        if [ "$CR_REQ" != "yes" ]; then
            local when="now"; [ "$CR_WF" != "yes" ] && when="ONLY AFTER the PR above is merged (--apply-ruleset refuses before)"
            echo "WOULD CREATE RULESET ($when): POST repos/$name/rulesets"
            render_ruleset | sed 's/^/  | /'
            echo "  WARNING: blocks direct pushes to $branch; repos with bots/Actions pushing there will break."
        fi
    done <<<"$tsv"
    echo "DRY-RUN: $n repo(s) would change; $skipped skipped. Nothing was modified."
    return 0
}

run_apply() { # PR
    resolve_scanner || return 3
    local line name fork archived branch
    line="$(list_repos 2>&1 | awk -F'\t' -v r="$ONE_REPO" '$1==r')" || true
    [ -n "$line" ] || { echo "INDETERMINATE: $ONE_REPO is not a public repo of $OWNER (or listing failed)" >&2; return 3; }
    IFS=$'\t' read -r name fork archived branch <<<"$line"
    [ "$archived" != "true" ] || { echo "REFUSED: $name is archived" >&2; return 3; }
    eligible_for_rollout "$name" "$fork" || { echo "REFUSED: $name is a fork; pass --include-forks" >&2; return 3; }
    check_repo "$name" "$branch"
    [ "$CR_WF" != "yes" ] || { echo "NOOP: $name already has $WF_PATH on $branch"; return 0; }
    [ "$CR_WF" = "no" ] || { echo "INDETERMINATE: $CR_MSG" >&2; return 3; }
    local tmp; tmp="$(mktemp -d)" || return 3
    echo "PROGRESS: cloning $name and opening PR"
    gh repo clone "$name" "$tmp/repo" -- --depth 1 || { echo "clone failed" >&2; return 1; }
    git -C "$tmp/repo" checkout -b "$PR_BRANCH" || return 1
    mkdir -p "$tmp/repo/.github/workflows"
    render_workflow "$branch" > "$tmp/repo/$WF_PATH"
    pr_body > "$tmp/body.md"
    git -C "$tmp/repo" add "$WF_PATH" || return 1
    git -C "$tmp/repo" commit -q -m "$(pr_title)" || return 1
    git -C "$tmp/repo" push origin "$PR_BRANCH" || return 1
    gh pr create --repo "$name" --base "$branch" --head "$PR_BRANCH" --title "$(pr_title)" --body-file "$tmp/body.md" || return 1
    echo "DONE: PR opened on $name. Merge it, then run --apply-ruleset --repo $name."
    return 0
}

run_apply_ruleset() {
    local line name fork archived branch
    line="$(list_repos 2>&1 | awk -F'\t' -v r="$ONE_REPO" '$1==r')" || true
    [ -n "$line" ] || { echo "INDETERMINATE: $ONE_REPO is not a public repo of $OWNER (or listing failed)" >&2; return 3; }
    IFS=$'\t' read -r name fork archived branch <<<"$line"
    [ "$archived" != "true" ] || { echo "REFUSED: $name is archived" >&2; return 3; }
    eligible_for_rollout "$name" "$fork" || { echo "REFUSED: $name is a fork; pass --include-forks" >&2; return 3; }
    check_repo "$name" "$branch"
    if [ "$CR_WF" != "yes" ]; then
        echo "REFUSED: $WF_PATH not on $name:$branch (state: $CR_WF). Merge the workflow PR first; requiring a check that cannot run blocks every merge." >&2
        return 3
    fi
    [ "$CR_REQ" != "yes" ] || { echo "NOOP: $name already requires $CHECK_CONTEXT"; return 0; }
    [ "$CR_REQ" = "no" ] || { echo "INDETERMINATE: $CR_MSG" >&2; return 3; }
    render_ruleset | gh api -X POST "repos/$name/rulesets" --input - >/dev/null || { echo "ruleset POST failed" >&2; return 1; }
    echo "DONE: ruleset '$RULESET_NAME' created on $name."
    return 0
}

# ---------------------------------------------------------------- selftest
run_selftest() {
    local tmp stub fx rc out fails=0 total=0
    tmp="$(mktemp -d)"; stub="$tmp/bin"; fx="$tmp/fx"; mkdir -p "$stub" "$fx"
    export STUB_FX="$fx" STUB_LOG="$tmp/calls.log"
    : > "$STUB_LOG"
    cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_LOG"
a="$*"
case "$a" in
  "repo list"*) cat "$STUB_FX/repos.tsv"; exit 0 ;;
  "api repos/JohnGavin/llm/commits/main"*) echo "0123456789abcdef0123456789abcdef01234567"; exit 0 ;;
  *"contents/.claude/scripts/private_data_scan.sh"*) printf '#!/bin/bash\necho stub scanner\n'; exit 0 ;;
  "api repos/"*"/contents/.github/workflows/"*)
      repo="${2#repos/}"; repo="${repo%%/contents*}"; f="$STUB_FX/wf_${repo//\//_}"
      case "$(cat "$f" 2>/dev/null)" in
        yes) echo ".github/workflows/private-data-scan.yml"; exit 0 ;;
        no) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
        *) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
      esac ;;
  "api repos/"*"/rules/branches/"*)
      repo="${2#repos/}"; repo="${repo%%/rules*}"; f="$STUB_FX/rq_${repo//\//_}"
      case "$(cat "$f" 2>/dev/null)" in
        yes) echo 1; exit 0 ;;
        no) echo 0; exit 0 ;;
        *) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
      esac ;;
  "api -X POST repos/"*) cat >/dev/null; exit 0 ;;
esac
echo "stub gh: unhandled: $a" >&2; exit 99
STUB
    chmod +x "$stub/gh"
    # repo, fork, archived, branch ; wf, rq
    printf 'JohnGavin/good\tfalse\tfalse\tmain\nJohnGavin/nowf\tfalse\tfalse\tmain\nJohnGavin/norule\tfalse\tfalse\tmaster\nJohnGavin/broken\tfalse\tfalse\tmain\nJohnGavin/forky\ttrue\tfalse\tmain\nJohnGavin/old\tfalse\ttrue\tmain\n' > "$fx/repos.tsv"
    set_fx() { printf '%s' "$2" > "$fx/wf_JohnGavin_$1"; printf '%s' "$3" > "$fx/rq_JohnGavin_$1"; }
    set_fx good yes yes; set_fx nowf no no; set_fx norule yes no; set_fx broken err err; set_fx forky yes yes

    t() { total=$((total+1)); if [ "$1" = "$2" ]; then echo "ok   - $3"; else echo "FAIL - $3 (expected '$2', got '$1')"; fails=$((fails+1)); fi; }
    sc() { PATH="$stub:$PATH" bash "$0" "$@"; }

    out="$(sc --check 2>&1)"; rc=$?
    t "$rc" 1 "check with a FAIL present exits 1"
    t "$(printf '%s\n' "$out" | grep -c '^PASS ')" 2 "good + fork both PASS"
    t "$(printf '%s\n' "$out" | grep -c '^FAIL ')" 2 "nowf + norule FAIL"
    t "$(printf '%s\n' "$out" | grep -c '^INDETERMINATE ')" 1 "broken (HTTP 500) INDETERMINATE, not FAIL"
    t "$(printf '%s\n' "$out" | grep -c 'JohnGavin/old')" 0 "archived repo skipped"
    t "$(printf '%s\n' "$out" | grep -c 'forky (fork)')" 1 "fork listed in --check"
    t "$(printf '%s\n' "$out" | grep -c '^SUMMARY: PASS=2 FAIL=2 INDETERMINATE=1')" 1 "summary shows all three counts"

    sc --check --repo JohnGavin/good >/dev/null 2>&1; t "$?" 0 "only a PASS repo exits 0"
    sc --check --repo JohnGavin/broken >/dev/null 2>&1; t "$?" 3 "only an INDETERMINATE repo exits 3"
    sc --check --repo JohnGavin/nowf >/dev/null 2>&1; t "$?" 1 "only a FAIL repo exits 1"
    # wf lookup errors but rules say not required: determinate FAIL
    set_fx mixed err no; printf 'JohnGavin/mixed\tfalse\tfalse\tmain\n' > "$fx/repos.tsv"
    sc --check >/dev/null 2>&1; t "$?" 1 "wf unknown + not required => FAIL (answerable without the missing probe)"
    # restore
    printf 'JohnGavin/good\tfalse\tfalse\tmain\nJohnGavin/nowf\tfalse\tfalse\tmain\nJohnGavin/norule\tfalse\tfalse\tmaster\nJohnGavin/broken\tfalse\tfalse\tmain\nJohnGavin/forky\ttrue\tfalse\tmain\nJohnGavin/old\tfalse\ttrue\tmain\n' > "$fx/repos.tsv"
    # empty repo => INDETERMINATE with reason
    printf 'JohnGavin/empty\tfalse\tfalse\t\n' > "$fx/repos.tsv"
    out="$(sc --check 2>&1)"; rc=$?
    t "$rc" 3 "empty repo (no default branch) exits 3"
    t "$(printf '%s\n' "$out" | grep -c 'no default branch')" 1 "INDETERMINATE says why"
    printf 'JohnGavin/good\tfalse\tfalse\tmain\nJohnGavin/nowf\tfalse\tfalse\tmain\nJohnGavin/norule\tfalse\tfalse\tmaster\nJohnGavin/broken\tfalse\tfalse\tmain\nJohnGavin/forky\ttrue\tfalse\tmain\nJohnGavin/old\tfalse\ttrue\tmain\n' > "$fx/repos.tsv"

    # dry-run
    : > "$STUB_LOG"
    out="$(sc --dry-run 2>&1)"; rc=$?
    t "$rc" 0 "dry-run exits 0"
    t "$(printf '%s\n' "$out" | grep -c 'WOULD OPEN PR: base=main head=chore/private-data-scan-ci')" 1 "dry-run prints PR for nowf only (forks skipped)"
    t "$(printf '%s\n' "$out" | grep -c 'WOULD CREATE RULESET (ONLY AFTER')" 1 "nowf ruleset gated on PR merge"
    t "$(printf '%s\n' "$out" | grep -c 'WOULD CREATE RULESET (now)')" 1 "norule ruleset can be created now"
    t "$(printf '%s\n' "$out" | grep -c 'SKIP JohnGavin/forky -- fork')" 1 "fork skipped without --include-forks"
    t "$(printf '%s\n' "$out" | grep -c 'SKIP JohnGavin/broken -- INDETERMINATE')" 1 "indeterminate repo not touched"
    t "$(printf '%s\n' "$out" | grep -c '"context": "private-data-scan"')" 2 "ruleset JSON printed"
    t "$(grep -c -E 'POST|clone|push|pr create' "$STUB_LOG")" 0 "dry-run issued no mutating call"
    sc --dry-run --include-forks 2>&1 | grep -q 'forky' ; t "$?" 0 "--include-forks lists the fork"
    out="$(sc --dry-run --repo JohnGavin/nowf 2>&1)"
    t "$(printf '%s\n' "$out" | grep -c 'sha256sum -c')" 1 "single-repo dry-run prints the full workflow incl. hash verify"
    t "$(printf '%s\n' "$out" | grep -c 'branches: \[main\]')" 1 "workflow targets the repo's default branch"

    # apply guards
    sc --apply >/dev/null 2>&1; t "$?" 2 "--apply without --repo is a usage error"
    sc --apply-ruleset >/dev/null 2>&1; t "$?" 2 "--apply-ruleset without --repo is a usage error"
    : > "$STUB_LOG"
    sc --apply-ruleset --repo JohnGavin/nowf >/dev/null 2>&1; t "$?" 3 "ruleset refused while workflow absent"
    t "$(grep -c 'POST' "$STUB_LOG")" 0 "no POST issued when refused"
    sc --apply-ruleset --repo JohnGavin/norule >/dev/null 2>&1; t "$?" 0 "ruleset POST proceeds when workflow present"
    t "$(grep -c 'api -X POST repos/JohnGavin/norule/rulesets' "$STUB_LOG")" 1 "exactly one ruleset POST"
    sc --apply --repo JohnGavin/forky >/dev/null 2>&1; t "$?" 3 "--apply refuses a fork"
    sc --apply --repo JohnGavin/good >/dev/null 2>&1; t "$?" 0 "--apply on repo with workflow is a NOOP"
    sc --bogus >/dev/null 2>&1; t "$?" 2 "unknown flag is a usage error"

    rm -rf "$tmp"
    echo "selftest: $((total-fails))/$total passed"
    [ "$fails" -eq 0 ]
}

# ---------------------------------------------------------------- main
while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE="check"; shift ;;
        --dry-run) DRY=1; shift ;;
        --apply) APPLY=1; shift ;;
        --apply-ruleset) APPLY_RS=1; shift ;;
        --selftest) MODE="selftest"; shift ;;
        --repo) [ $# -ge 2 ] || die_usage "--repo needs OWNER/NAME"; ONE_REPO="$2"; shift 2 ;;
        --owner) [ $# -ge 2 ] || die_usage "--owner needs a name"; OWNER="$2"; shift 2 ;;
        --scanner-sha) [ $# -ge 2 ] || die_usage "--scanner-sha needs a SHA"; SCANNER_SHA="$2"; shift 2 ;;
        --include-forks) INCLUDE_FORKS=1; shift ;;
        -h|--help) usage; exit 2 ;;
        *) die_usage "unknown argument: $1" ;;
    esac
done

if [ "$MODE" = "selftest" ]; then run_selftest; exit $?; fi
command -v gh >/dev/null 2>&1 || { echo "INDETERMINATE: gh not on PATH" >&2; exit 3; }

if [ "$APPLY" = 1 ] && [ "$APPLY_RS" = 1 ]; then die_usage "--apply and --apply-ruleset are separate steps"; fi
if [ "$APPLY" = 1 ] || [ "$APPLY_RS" = 1 ]; then
    [ -n "$ONE_REPO" ] || die_usage "--apply/--apply-ruleset need --repo OWNER/NAME (one repo at a time)"
    [ "$DRY" = 0 ] || { run_dry; exit $?; }
    if [ "$APPLY" = 1 ]; then run_apply; else run_apply_ruleset; fi
    exit $?
fi
if [ "$DRY" = 1 ]; then run_dry; exit $?; fi
run_check
exit $?
