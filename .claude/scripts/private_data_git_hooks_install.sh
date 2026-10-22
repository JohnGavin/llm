#!/usr/bin/env bash
# private_data_git_hooks_install.sh — install the private_data_scan.sh gate
# into a repo's pre-commit and pre-push git hooks.
#
# MANUAL INSTALL ONLY: this script is never auto-invoked and never run for
# real by any agent dispatch. Review with --dry-run, then run it yourself.
# (Mirrors roborev_install_post_merge_hook.sh's own "MANUAL INSTALL ONLY"
# convention -- see that script's header.)
#
# Why pre-commit AND pre-push, not just one:
#   pre-commit  catches PII before it enters local history at all (cheapest,
#               earliest point -- scans the STAGED index content).
#   pre-push    catches everything pre-commit missed: --no-verify commits,
#               agent-made commits from a different tool, cherry-picks,
#               rebases that reintroduce old content, or a pre-commit that
#               was simply never installed on a collaborator's machine.
#               Scans full blob content of every file changed in every
#               commit about to be pushed (git_hook's stdin protocol gives
#               us the exact local/remote SHA range).
#
# Both hooks are appended/chained, never a wholesale overwrite: this repo's
# pre-commit already runs a skill-size check + rule-scoping guard, and
# pre-push already runs the git-lfs shim (see the CHAIN_CALL logic below).
# Idempotent: re-running with the marker already present is a no-op.
#
# Usage:
#   private_data_git_hooks_install.sh [--repo <path>] --dry-run [--hook pre-commit|pre-push|both]
#   private_data_git_hooks_install.sh [--repo <path>] --install [--hook pre-commit|pre-push|both]
#   private_data_git_hooks_install.sh [--repo <path>] --uninstall [--hook pre-commit|pre-push|both]
#   private_data_git_hooks_install.sh --selftest
#   private_data_git_hooks_install.sh --audit [--root DIR]
#
# --audit (llm#1434 Gap 1) -- REPORT-ONLY coverage audit; changes no repo.
#   A repo that sets a LOCAL core.hooksPath replaces the global hooks dir
#   (git-hooks/, llm#1365), so the global PII gate never runs there. For every
#   clone under DIR (default $PDHI_AUDIT_ROOT or ~/docs_gh; depth
#   $PDHI_AUDIT_DEPTH, default 4) the audit resolves the EFFECTIVE hooks dir
#   (`git config --type=path core.hooksPath`: local beats global; ~ expanded;
#   a relative value is relative to the clone's top; unset everywhere means the
#   default <common-git-dir>/hooks) and applies ONE rule:
#     COVERED  <=> <effective hooks dir>/pre-commit is an executable regular
#                  file (git ignores non-executable hooks) whose text contains
#                  `pii_gate.sh` (the global hook), `private_data_scan.sh` or
#                  the installer marker `private-data-scan pre-commit gate`
#                  (a repo hook written by --install).
#   Otherwise UNCOVERED. A local override whose directory holds no such hook is
#   therefore uncovered even if .git/hooks/pre-commit has one (git ignores it).
#   The test is textual: a hook that merely MENTIONS the scanner in a comment
#   counts as covered (heuristic; the owner reads the list, it does not gate).
#   Enumeration is the same as global_hooks_path_check.sh (llm#1388): a `.git`
#   DIRECTORY (linked worktrees share their clone's config and are skipped),
#   de-duplicated by git-common-dir, nothing under a worktrees/ path component.
#   Unlike that script it covers public AND private clones, so it needs no gh
#   call. Output never prints a repo name or path: one line per problem,
#   `UNCOVERED <label> reason=<...>` or `UNINSPECTABLE <label> reason=<...>`,
#   label `repo-<8 hex of sha256 of the physical git-common-dir>` (stable,
#   not reversible without the clone list), then
#   `repos=N covered=N uncovered=N indeterminate=N`.
#   Exit: 0 all covered; 1 any uncovered (wins over 3); 2 usage; 3 at least one
#   repo could not be inspected (broken config, unreadable hook) or the root is
#   missing, and none is uncovered. 3 is never reported as 0.
#
# Bypass: git's own `--no-verify` (no custom kill-switch env var is added --
# see private-data-scanning.md's "Why no custom bypass" section: a second,
# undocumented-by-git bypass mechanism would sit alongside git's own
# well-known one for no additional safety benefit, and would be one more
# thing to keep in sync with the fail-closed posture this gate exists for).
#
# Issue: 2026-08-22 PII incident. Companion: JohnGavin/llm#976, #997.

set -euo pipefail

PRECOMMIT_MARKER="private-data-scan pre-commit gate — installed by private_data_git_hooks_install.sh"
PREPUSH_MARKER="private-data-scan pre-push gate — installed by private_data_git_hooks_install.sh"

usage() { grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//' | head -34; }

REPO_PATH=""
ACTION=""
HOOK="both"
SELFTEST=0
AUDIT=0
AUDIT_ROOT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) shift; REPO_PATH="${1:-}"; shift ;;
        --dry-run) ACTION="dry-run"; shift ;;
        --install) ACTION="install"; shift ;;
        --uninstall) ACTION="uninstall"; shift ;;
        --hook) shift; HOOK="${1:-both}"; shift ;;
        --selftest) SELFTEST=1; shift ;;
        --audit) AUDIT=1; shift ;;
        --root) shift; AUDIT_ROOT="${1:-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Hook content builders
# ---------------------------------------------------------------------------

build_precommit_block() {
    cat <<EOF

# ── ${PRECOMMIT_MARKER} ──
# Installed: $(date '+%Y-%m-%d')
PRIVATE_DATA_SCAN_BIN="\${PRIVATE_DATA_SCAN_BIN:-\$HOME/.claude/scripts/private_data_scan.sh}"
if [ -x "\$PRIVATE_DATA_SCAN_BIN" ]; then
  # Resolve REPO_ROOT from the CALLER's cwd, at hook-run time, and export
  # it explicitly for this one invocation -- never rely on
  # private_data_scan.sh's own SCRIPT_DIR-based auto-detection here. When
  # PRIVATE_DATA_SCAN_BIN is a machine-wide/symlinked path (the documented
  # default, \$HOME/.claude/scripts/...), its own auto-detection resolves
  # REPO_ROOT to wherever THAT SCRIPT physically lives, not to the repo
  # this hook is actually running in -- silently scanning the wrong repo
  # and reporting "clean" regardless of what's staged here
  # (JohnGavin/llm#1161). private_data_scan.sh already honours
  # \${REPO_ROOT:-...} as an override, so setting it here is sufficient.
  REPO_ROOT="\$(git rev-parse --show-toplevel)" "\$PRIVATE_DATA_SCAN_BIN" --staged
  _pds_rc=\$?
  if [ "\$_pds_rc" -ne 0 ]; then
    echo "" >&2
    echo "Commit BLOCKED by private_data_scan.sh (PII detected, or the scanner" >&2
    echo "itself failed -- fail-closed by design; see private-data-scanning.md)." >&2
    echo "Review the findings above. If this is a false positive, the sanctioned" >&2
    echo "override is git's own: git commit --no-verify (logged by git itself)." >&2
    exit 1
  fi
fi
EOF
}

build_prepush_block() {
    cat <<EOF
# ── ${PREPUSH_MARKER} ──
# Installed: $(date '+%Y-%m-%d')
# git's pre-push protocol passes "<local ref> <local sha1> <remote ref> <remote sha1>"
# lines on stdin. We must consume stdin here AND still let any chained hook
# (e.g. the git-lfs shim below) see the same lines -- so we tee stdin to a
# temp file, scan using the sha1 range(s) found in it, then replay the file
# on stdin for the chained call.
_pds_stdin="\$(mktemp "\${TMPDIR:-/tmp}/private_data_prepush_stdin.XXXXXX")"
cat > "\$_pds_stdin"
PRIVATE_DATA_SCAN_BIN="\${PRIVATE_DATA_SCAN_BIN:-\$HOME/.claude/scripts/private_data_scan.sh}"
_pds_blocked=0
if [ -x "\$PRIVATE_DATA_SCAN_BIN" ]; then
  while read -r _pds_lref _pds_lsha _pds_rref _pds_rsha; do
    [ -n "\${_pds_lsha:-}" ] || continue
    # Deleting a ref (local sha all-zero) -- nothing to scan.
    case "\$_pds_lsha" in 0000000000000000000000000000000000000000) continue ;; esac
    _pds_base="\$_pds_rsha"
    case "\$_pds_rsha" in
      ''|0000000000000000000000000000000000000000)
        # New branch / remote ref does not exist yet -- scan from the
        # merge-base with the default branch, falling back to the root
        # commit if that also fails (first-ever push of a fresh history).
        _pds_base="\$(git merge-base "\$_pds_lsha" origin/HEAD 2>/dev/null || git rev-list --max-parents=0 "\$_pds_lsha" 2>/dev/null | tail -1)"
        ;;
    esac
    [ -n "\$_pds_base" ] || continue
    # Same REPO_ROOT fix as the pre-commit block above (JohnGavin/llm#1161)
    # -- resolve it from the caller's cwd at hook-run time, never leave it
    # to private_data_scan.sh's own SCRIPT_DIR-based auto-detection.
    REPO_ROOT="\$(git rev-parse --show-toplevel)" "\$PRIVATE_DATA_SCAN_BIN" --range "\$_pds_base" "\$_pds_lsha" || _pds_blocked=1
  done < "\$_pds_stdin"
fi
if [ "\$_pds_blocked" -ne 0 ]; then
  echo "" >&2
  echo "Push BLOCKED by private_data_scan.sh (PII detected in a commit about" >&2
  echo "to be pushed, or the scanner itself failed -- fail-closed by design;" >&2
  echo "see private-data-scanning.md). Sanctioned override: git push --no-verify." >&2
  rm -f "\$_pds_stdin"
  exit 1
fi
EOF
}

# ---------------------------------------------------------------------------
# Install/uninstall one hook file, chaining existing content.
# ---------------------------------------------------------------------------

# install_hook REPO_PATH HOOK_NAME MARKER BUILD_FN
install_hook() {
    local repo="$1" hookname="$2" marker="$3" build_fn="$4"
    local git_dir hook_path backup_path
    git_dir="$(git -C "$repo" rev-parse --git-dir)"
    case "$git_dir" in /*) : ;; *) git_dir="${repo}/${git_dir}" ;; esac
    hook_path="${git_dir}/hooks/${hookname}"
    backup_path="${hook_path}.pre-privatedata.bak"

    if [ -f "$hook_path" ] && grep -qF "$marker" "$hook_path" 2>/dev/null; then
        echo "  ${hookname}: already installed (marker present) -- no changes."
        return 0
    fi

    local new_block; new_block="$("$build_fn")"
    local final_content

    if [ "$hookname" = "pre-push" ]; then
        # Scan block goes FIRST (cheap, fails fast, before the chained
        # git-lfs/existing content runs), so an existing hook's content is
        # appended AFTER the new block, not before.
        if [ -f "$hook_path" ]; then
            final_content="#!/bin/sh
${new_block}
# ── original ${hookname} content (chained) ──
$(tail -n +2 "$hook_path")"
        else
            final_content="#!/bin/sh
${new_block}"
        fi
    else
        # pre-commit: existing checks run FIRST (unchanged behaviour),
        # the new scan block is appended at the end.
        if [ -f "$hook_path" ]; then
            final_content="$(cat "$hook_path")
${new_block}"
        else
            final_content="#!/bin/sh
${new_block}"
        fi
    fi

    if [ "$ACTION" = "dry-run" ]; then
        echo "  [dry-run] ${hookname}: would write ${hook_path}:"
        echo "  --- begin ---"
        printf '%s\n' "$final_content" | sed 's/^/    /'
        echo "  --- end ---"
        return 0
    fi

    if [ -f "$hook_path" ] && [ ! -f "$backup_path" ]; then
        cp "$hook_path" "$backup_path"
        echo "  ${hookname}: backed up existing hook to ${backup_path}"
    fi
    mkdir -p "$(dirname "$hook_path")"
    printf '%s\n' "$final_content" > "$hook_path"
    chmod +x "$hook_path"
    echo "  ${hookname}: installed -> ${hook_path}"
}

uninstall_hook() {
    local repo="$1" hookname="$2" marker="$3"
    local git_dir hook_path backup_path
    git_dir="$(git -C "$repo" rev-parse --git-dir)"
    case "$git_dir" in /*) : ;; *) git_dir="${repo}/${git_dir}" ;; esac
    hook_path="${git_dir}/hooks/${hookname}"
    backup_path="${hook_path}.pre-privatedata.bak"

    if [ ! -f "$hook_path" ] || ! grep -qF "$marker" "$hook_path" 2>/dev/null; then
        echo "  ${hookname}: not installed (no marker found) -- nothing to remove."
        return 0
    fi
    if [ "$ACTION" = "dry-run" ]; then
        echo "  [dry-run] ${hookname}: would remove the marker-delimited block (restoring from backup if present)"
        return 0
    fi
    if [ -f "$backup_path" ]; then
        mv "$backup_path" "$hook_path"
        chmod +x "$hook_path"
        echo "  ${hookname}: restored from ${backup_path}"
    else
        rm -f "$hook_path"
        echo "  ${hookname}: removed (no backup existed -- was a fresh install)"
    fi
}

run_for_repo() {
    local repo="$1"
    echo "private_data_git_hooks_install: ${ACTION} on ${repo} (hook=${HOOK})"
    case "$ACTION" in
        uninstall)
            [ "$HOOK" = "pre-commit" ] || [ "$HOOK" = "both" ] && uninstall_hook "$repo" "pre-commit" "$PRECOMMIT_MARKER"
            [ "$HOOK" = "pre-push" ]   || [ "$HOOK" = "both" ] && uninstall_hook "$repo" "pre-push" "$PREPUSH_MARKER"
            ;;
        *)
            [ "$HOOK" = "pre-commit" ] || [ "$HOOK" = "both" ] && install_hook "$repo" "pre-commit" "$PRECOMMIT_MARKER" build_precommit_block
            [ "$HOOK" = "pre-push" ]   || [ "$HOOK" = "both" ] && install_hook "$repo" "pre-push" "$PREPUSH_MARKER" build_prepush_block
            ;;
    esac
}

# ---------------------------------------------------------------------------
# --selftest — fixture repo, never touches a real .git/hooks directory.
# ---------------------------------------------------------------------------
run_selftest() {
    local pass=0 total=0
    _check() { total=$((total + 1)); if [ "$1" = "0" ]; then pass=$((pass + 1)); echo "PASS  $2"; else echo "FAIL  $2"; fi; }

    local fx; fx="$(mktemp -d "${TMPDIR:-/tmp}/pds_hooks_selftest.XXXXXX")"
    git -C "$fx" init -q
    git -C "$fx" config user.email t@example.com
    git -C "$fx" config user.name t
    mkdir -p "$fx/.git/hooks"
    # Simulate an existing pre-commit (like this repo's real one) and an
    # existing pre-push (like this repo's git-lfs shim).
    printf '#!/bin/sh\necho existing-precommit\n' > "$fx/.git/hooks/pre-commit"
    chmod +x "$fx/.git/hooks/pre-commit"
    printf '#!/bin/sh\necho existing-prepush\n' > "$fx/.git/hooks/pre-push"
    chmod +x "$fx/.git/hooks/pre-push"

    # 1: dry-run writes nothing
    ACTION="dry-run" run_for_repo "$fx" >/dev/null
    if grep -qF "$PRECOMMIT_MARKER" "$fx/.git/hooks/pre-commit" 2>/dev/null; then
        _check 1 "dry-run must not modify pre-commit"
    else
        _check 0 "dry-run does not modify pre-commit"
    fi

    # 2: real install — marker present, existing content preserved
    ACTION="install" run_for_repo "$fx" >/dev/null
    if grep -qF "$PRECOMMIT_MARKER" "$fx/.git/hooks/pre-commit" && grep -qF "existing-precommit" "$fx/.git/hooks/pre-commit"; then
        _check 0 "install: pre-commit has marker AND preserves original content"
    else
        _check 1 "install: pre-commit missing marker or lost original content"
    fi
    if grep -qF "$PREPUSH_MARKER" "$fx/.git/hooks/pre-push" && grep -qF "existing-prepush" "$fx/.git/hooks/pre-push"; then
        _check 0 "install: pre-push has marker AND preserves original content"
    else
        _check 1 "install: pre-push missing marker or lost original content"
    fi
    [ -x "$fx/.git/hooks/pre-commit" ] && [ -x "$fx/.git/hooks/pre-push" ] && _check 0 "installed hooks are executable" || _check 1 "installed hooks are executable"

    # 3: idempotent re-install
    local mtime_before mtime_after
    mtime_before="$(stat -f '%m' "$fx/.git/hooks/pre-commit" 2>/dev/null || stat -c '%Y' "$fx/.git/hooks/pre-commit")"
    ACTION="install" run_for_repo "$fx" >/dev/null
    mtime_after="$(stat -f '%m' "$fx/.git/hooks/pre-commit" 2>/dev/null || stat -c '%Y' "$fx/.git/hooks/pre-commit")"
    [ "$mtime_before" = "$mtime_after" ] && _check 0 "re-install is idempotent (no-op)" || _check 1 "re-install modified an already-installed hook"

    # 4: actually fires and blocks — build a tiny stand-in scanner that
    # always fails, point PRIVATE_DATA_SCAN_BIN at it, run the installed
    # pre-commit hook directly (as git would).
    local fake_bin; fake_bin="$(mktemp "${TMPDIR:-/tmp}/pds_fake_bin.XXXXXX")"
    printf '#!/bin/sh\nexit 1\n' > "$fake_bin"
    chmod +x "$fake_bin"
    set +e
    PRIVATE_DATA_SCAN_BIN="$fake_bin" bash "$fx/.git/hooks/pre-commit" >/tmp/pds_hook_out.$$ 2>&1
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ] && grep -q "BLOCKED" /tmp/pds_hook_out.$$; then
        _check 0 "installed pre-commit hook actually blocks when the scanner reports a finding (mutation test)"
    else
        _check 1 "installed pre-commit hook did NOT block when the scanner reported a finding (rc=$rc)"
    fi
    rm -f /tmp/pds_hook_out.$$

    # 5: fires and ALLOWS when the scanner is clean
    printf '#!/bin/sh\nexit 0\n' > "$fake_bin"
    set +e
    PRIVATE_DATA_SCAN_BIN="$fake_bin" bash "$fx/.git/hooks/pre-commit" >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 0 ] && _check 0 "installed pre-commit hook allows when the scanner is clean" || _check 1 "installed pre-commit hook wrongly blocked a clean scan"
    rm -f "$fake_bin"

    # 6: pre-push stdin passthrough — chained (original) hook still sees
    # the ref lines on stdin after the scan block consumes/replays them.
    local fake_bin2; fake_bin2="$(mktemp "${TMPDIR:-/tmp}/pds_fake_bin2.XXXXXX")"
    printf '#!/bin/sh\nexit 0\n' > "$fake_bin2"
    chmod +x "$fake_bin2"
    # Give the fixture repo a commit + a "remote" to construct a real
    # local-sha/remote-sha line.
    printf 'x\n' > "$fx/f.txt"
    git -C "$fx" add f.txt
    git -C "$fx" commit -q -m "c1"
    local sha1; sha1="$(git -C "$fx" rev-parse HEAD)"
    printf '%s\n' "refs/heads/main $sha1 refs/heads/main 0000000000000000000000000000000000000000" > /tmp/pds_prepush_stdin.$$
    set +e
    PRIVATE_DATA_SCAN_BIN="$fake_bin2" bash "$fx/.git/hooks/pre-push" < /tmp/pds_prepush_stdin.$$ > /tmp/pds_prepush_out.$$ 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] && grep -q "existing-prepush" /tmp/pds_prepush_out.$$; then
        _check 0 "pre-push chains to the original (existing-prepush) hook after a clean scan"
    else
        _check 1 "pre-push did not chain correctly (rc=$rc, out=$(cat /tmp/pds_prepush_out.$$ 2>/dev/null))"
    fi
    rm -f /tmp/pds_prepush_stdin.$$ /tmp/pds_prepush_out.$$ "$fake_bin2"

    # 7: uninstall restores the original
    ACTION="uninstall" run_for_repo "$fx" >/dev/null
    if grep -qF "$PRECOMMIT_MARKER" "$fx/.git/hooks/pre-commit" 2>/dev/null; then
        _check 1 "uninstall left the marker behind"
    else
        _check 0 "uninstall removed the marker"
    fi
    if grep -qF "existing-precommit" "$fx/.git/hooks/pre-commit" 2>/dev/null; then
        _check 0 "uninstall restored the ORIGINAL pre-commit content"
    else
        _check 1 "uninstall lost the original pre-commit content"
    fi

    rm -rf "$fx"

    # 8: symlink/REPO_ROOT regression (JohnGavin/llm#1161) -- the installed
    # hook must scan the repo it is actually running in, never the repo the
    # global PRIVATE_DATA_SCAN_BIN script happens to physically live inside.
    # On the maintainer's machine ~/.claude/scripts symlinks into
    # ~/docs_gh/llm, so private_data_scan.sh's own SCRIPT_DIR-based
    # REPO_ROOT auto-detection silently resolves to `llm` for every OTHER
    # repo installing these hooks with the documented default -- llm's own
    # use of the installer is an UNREPRESENTATIVE test case, because the
    # symlink happens to resolve back into llm's own tree. This case
    # exercises the REAL private_data_scan.sh (not a stub, unlike cases
    # 4-6 above) against TWO separate fixture repos to actually reproduce
    # the symlink-vs-cwd mismatch, not merely call a stand-in scanner.
    local self_dir; self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    local sym_root; sym_root="$(mktemp -d "${TMPDIR:-/tmp}/pds_hooks_symtest.XXXXXX")"

    # "scanner_host_repo" stands in for `llm`: a DIFFERENT git repo that
    # happens to physically host a copy of the real scanner script, exactly
    # like ~/docs_gh/llm hosts .claude/scripts/private_data_scan.sh --
    # private_data_scan.sh's own SCRIPT_DIR auto-detection resolves here.
    local scanner_host="$sym_root/scanner_host_repo"
    mkdir -p "$scanner_host/.claude/scripts"
    git -C "$scanner_host" init -q
    git -C "$scanner_host" config user.email t@example.com
    git -C "$scanner_host" config user.name t
    printf 'seed\n' > "$scanner_host/seed.txt"
    git -C "$scanner_host" add seed.txt
    git -C "$scanner_host" commit -q -m seed
    cp "$self_dir/private_data_scan.sh" "$scanner_host/.claude/scripts/private_data_scan.sh"
    chmod +x "$scanner_host/.claude/scripts/private_data_scan.sh"

    # "target_repo" stands in for `rallyr`: an UNRELATED repo, entirely
    # outside scanner_host's tree, that installs the hooks using the
    # documented default (PRIVATE_DATA_SCAN_BIN pointed at scanner_host's
    # copy -- simulating the symlink pointing away from this repo).
    local target_repo="$sym_root/target_repo"
    mkdir -p "$target_repo"
    git -C "$target_repo" init -q
    git -C "$target_repo" config user.email t@example.com
    git -C "$target_repo" config user.name t
    printf 'seed\n' > "$target_repo/seed.txt"
    git -C "$target_repo" add seed.txt
    git -C "$target_repo" commit -q -m seed

    ACTION="install" run_for_repo "$target_repo" >/dev/null

    # A throwaway deny-list so the REAL scanner's default fail-closed
    # require-denylist mode has something to match against -- never the
    # machine's real ~/.config/private_values.env.
    local sym_denylist="$sym_root/private_values.env"
    local sym_sentinel="SELFTEST_1161_SENTINEL_h7Qm3xNp"
    printf 'MY_SENTINEL=%s\n' "$sym_sentinel" > "$sym_denylist"
    chmod 600 "$sym_denylist"

    printf 'leak: %s\n' "$sym_sentinel" > "$target_repo/leak.txt"
    git -C "$target_repo" add leak.txt

    set +e
    ( cd "$target_repo" && \
      PRIVATE_DATA_SCAN_BIN="$scanner_host/.claude/scripts/private_data_scan.sh" \
      PRIVATE_VALUES_FILE="$sym_denylist" \
      UNIFIED_DB_PATH="$sym_root/does_not_exist.duckdb" \
      bash .git/hooks/pre-commit ) >/tmp/pds_sym_out.$$ 2>&1
    local sym_rc=$?
    set -e
    if [ "$sym_rc" -ne 0 ] && grep -q "BLOCKED" /tmp/pds_sym_out.$$; then
        _check 0 "JohnGavin/llm#1161: installed hook blocks a real leak staged in an UNRELATED target repo (REPO_ROOT resolves to the target, not the scanner's own host repo)"
    else
        _check 1 "JohnGavin/llm#1161: installed hook did NOT block a real leak staged in the target repo (rc=$sym_rc, out=$(cat /tmp/pds_sym_out.$$ 2>/dev/null))"
    fi
    rm -f /tmp/pds_sym_out.$$
    rm -rf "$sym_root"
    echo ""
    echo "private_data_git_hooks_install selftest: $pass/$total PASS"
    [ "$pass" -eq "$total" ]
}

# ---------------------------------------------------------------------------
# --audit (llm#1434 Gap 1): report-only coverage audit. See the header.
# ---------------------------------------------------------------------------
_audit_phys() { local d; d="$(cd "$1" 2>/dev/null && pwd -P)" || return 1; printf '%s' "$d"; }

_audit_label() { # physical-dir -> repo-<8 hex>; never the name or path
    local h
    if command -v shasum >/dev/null 2>&1; then h="$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"
    elif command -v sha256sum >/dev/null 2>&1; then h="$(printf '%s' "$1" | sha256sum | cut -c1-8)"
    else h="$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; fi
    printf 'repo-%s' "$h"
}

# _audit_one CLONE -> prints "COVERED" | "UNCOVERED reason" | "INDETERMINATE reason"
_audit_one() {
    local clone="$1" raw rc common hp hook
    # Effective hooksPath. rc 1 = key unset everywhere (default hooks dir);
    # any other non-zero rc (e.g. 128 broken config) = cannot inspect.
    raw="$(git -C "$clone" config --type=path --get core.hooksPath 2>/dev/null)" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then echo "INDETERMINATE config-unreadable"; return 0; fi
    if [ "$rc" -eq 1 ] || [ -z "$raw" ]; then
        common="$(git -C "$clone" rev-parse --git-common-dir 2>/dev/null)" || { echo "INDETERMINATE git-dir-unresolved"; return 0; }
        case "$common" in /*) : ;; *) common="$clone/$common" ;; esac
        hp="$common/hooks"
    else
        case "$raw" in /*) hp="$raw" ;; *) hp="$clone/$raw" ;; esac
    fi
    hook="$hp/pre-commit"
    if [ ! -e "$hook" ]; then echo "UNCOVERED no-pre-commit-in-effective-hooks-dir"; return 0; fi
    if [ ! -f "$hook" ] || [ ! -x "$hook" ]; then echo "UNCOVERED pre-commit-not-executable-file"; return 0; fi
    if [ ! -r "$hook" ]; then echo "INDETERMINATE hook-unreadable"; return 0; fi
    if grep -qE 'pii_gate\.sh|private_data_scan\.sh|private-data-scan pre-commit gate' "$hook" 2>/dev/null; then
        echo "COVERED"
    else
        echo "UNCOVERED pre-commit-does-not-run-scanner"
    fi
}

run_audit() {
    local root="${AUDIT_ROOT:-${PDHI_AUDIT_ROOT:-${HOME:-/Users/johngavin}/docs_gh}}"
    local depth="${PDHI_AUDIT_DEPTH:-4}"
    local repos=0 covered=0 uncovered=0 indet=0
    if [ ! -d "$root" ]; then
        echo "private_data_git_hooks_install --audit: INDETERMINATE -- scan root does not exist" >&2
        echo "repos=0 covered=0 uncovered=0 indeterminate=1"
        return 3
    fi
    local seen; seen="$(mktemp "${TMPDIR:-/tmp}/pdhi_audit_seen.XXXXXX")"
    local gitdir clone common common_phys label res verdict reason
    while IFS= read -r gitdir; do
        [ -n "$gitdir" ] || continue
        [ -d "$gitdir" ] || continue            # a .git FILE is a linked worktree
        clone="${gitdir%/.git}"
        case "$clone" in */worktrees/*|*/worktrees) continue ;; esac
        common="$(git -C "$clone" rev-parse --git-common-dir 2>/dev/null)" || common=""
        common_phys=""
        if [ -n "$common" ]; then
            case "$common" in /*) common_phys="$(_audit_phys "$common")" || true ;; *) common_phys="$(_audit_phys "$clone/$common")" || true ;; esac
        fi
        [ -n "$common_phys" ] || common_phys="$(_audit_phys "$gitdir")" || common_phys="$gitdir"
        if grep -qxF -- "$common_phys" "$seen"; then continue; fi
        printf '%s\n' "$common_phys" >> "$seen"
        repos=$((repos + 1))
        label="$(_audit_label "$common_phys")"
        res="$(_audit_one "$clone")"
        verdict="${res%% *}"; reason="${res#* }"
        case "$verdict" in
            COVERED) covered=$((covered + 1)) ;;
            UNCOVERED) uncovered=$((uncovered + 1)); echo "UNCOVERED $label reason=$reason" ;;
            *) indet=$((indet + 1)); echo "UNINSPECTABLE $label reason=$reason" ;;
        esac
    done < <(find "$root" -mindepth 1 -maxdepth "$depth" -name .git -prune -print 2>/dev/null | sort)
    rm -f "$seen"
    echo "repos=${repos} covered=${covered} uncovered=${uncovered} indeterminate=${indet}"
    if [ "$uncovered" -gt 0 ]; then return 1; fi
    if [ "$indet" -gt 0 ]; then return 3; fi
    return 0
}

if [ "$AUDIT" -eq 1 ]; then
    if [ -n "$ACTION" ] || [ "$SELFTEST" -eq 1 ] || [ -n "$REPO_PATH" ]; then
        echo "ERROR: --audit takes no other action (only --root DIR)" >&2; exit 2
    fi
    run_audit
    exit $?
fi

if [ "$SELFTEST" -eq 1 ]; then
    run_selftest
    exit $?
fi

if [ -z "$ACTION" ]; then
    echo "ERROR: one of --dry-run, --install, --uninstall is required" >&2
    usage >&2
    exit 1
fi

if [ -z "$REPO_PATH" ]; then
    REPO_PATH="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$REPO_PATH" ] || { echo "ERROR: not inside a git repository and --repo not specified" >&2; exit 1; }
fi
git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: $REPO_PATH is not a git repository" >&2; exit 1; }

run_for_repo "$REPO_PATH"

echo ""
echo "Verify: CLAUDE_HOOK_SELFTEST=1 bash $0 --selftest"
