#!/bin/sh
# roborev_repo_allowed.sh -- ONE shared guard for every path that can queue a
# roborev review/refine job (llm#1296).
#
# core.hooksPath is global, so every repo on the machine inherits the roborev
# hooks; a queued job can send a diff to a third-party agent. This guard lets a
# repo opt out, and lets the owner keep a local list of private roots, without
# the list ever being committed.
#
# POSIX sh; meant to be SOURCED:   . "$dir/lib/roborev_repo_allowed.sh"
#
#   roborev_repo_allowed [DIR]
#     exit 0  -> allowed (reason empty)
#     exit 1  -> blocked; one-word reason printed on stdout
#     exit 3  -> indeterminate (not a git repo / cannot resolve); callers MUST
#                treat this as "do not enqueue" -- an unknown is not a pass.
#
# A repo is BLOCKED when any of these hold:
#   marker   the repo top level (or its main worktree) has .roborev-disable or PRIVATE
#   noremote the repo has no git remote at all (local-only repo)
#   private-root  its real path is under a root listed in the private-roots file
#   not-allowlisted  (opt-in strict mode only) not under a root in the allow-list
#
# Config (all LOCAL; never commit their contents):
#   ROBOREV_PRIVATE_ROOTS_FILE  default ~/.config/roborev-private-roots
#                               one absolute path per line; '#' comments ok
#   ROBOREV_ALLOWLIST_MODE=1    opt-in fail-closed mode (default OFF)
#   ROBOREV_ALLOWED_ROOTS_FILE  default ~/.config/roborev-allowed-roots
#                               same format; used only in allow-list mode

# _rra_path_under FILE PATH : 0 if PATH equals or is below a root in FILE.
_rra_path_under() {
    _rra_file=$1
    _rra_p=$2
    [ -r "$_rra_file" ] || return 1
    while IFS= read -r _rra_root || [ -n "$_rra_root" ]; do
        case "$_rra_root" in ''|'#'*) continue ;; esac
        # expand a leading ~ ; normalise symlinks so /tmp vs /private/tmp match
        case "$_rra_root" in
            '~'|'~/'*) _rra_root="$HOME${_rra_root#\~}" ;;
        esac
        _rra_real=$(cd -P "$_rra_root" 2>/dev/null && pwd -P) || _rra_real=$_rra_root
        _rra_real=${_rra_real%/}
        [ -n "$_rra_real" ] || continue
        case "$_rra_p" in
            "$_rra_real"|"$_rra_real"/*) return 0 ;;
        esac
    done < "$_rra_file"
    return 1
}

roborev_repo_allowed() {
    _rra_dir=${1:-.}
    _rra_top=$(git -C "$_rra_dir" rev-parse --show-toplevel 2>/dev/null) || return 3
    [ -n "$_rra_top" ] || return 3
    _rra_top=$(cd -P "$_rra_top" 2>/dev/null && pwd -P) || return 3

    # Marker at this checkout's top level, or at the main worktree's top level
    # (an untracked marker in the main checkout must also cover its worktrees).
    _rra_common=$(git -C "$_rra_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || _rra_common=""
    _rra_main=""
    case "$_rra_common" in
        */.git) _rra_main=${_rra_common%/.git} ;;
    esac
    for _rra_r in "$_rra_top" "$_rra_main"; do
        [ -n "$_rra_r" ] || continue
        if [ -e "$_rra_r/.roborev-disable" ] || [ -e "$_rra_r/PRIVATE" ]; then
            echo marker
            return 1
        fi
    done

    # No remote at all -> local-only repo.
    _rra_remotes=$(git -C "$_rra_top" remote 2>/dev/null) || return 3
    if [ -z "$_rra_remotes" ]; then
        echo noremote
        return 1
    fi

    # Locally configured private roots.
    if _rra_path_under "${ROBOREV_PRIVATE_ROOTS_FILE:-$HOME/.config/roborev-private-roots}" "$_rra_top"; then
        echo private-root
        return 1
    fi
    if [ -n "$_rra_main" ] && _rra_path_under "${ROBOREV_PRIVATE_ROOTS_FILE:-$HOME/.config/roborev-private-roots}" "$_rra_main"; then
        echo private-root
        return 1
    fi

    # Opt-in strict mode: only review repos registered on purpose.
    if [ "${ROBOREV_ALLOWLIST_MODE:-0}" = "1" ]; then
        _rra_al=${ROBOREV_ALLOWED_ROOTS_FILE:-$HOME/.config/roborev-allowed-roots}
        if [ ! -r "$_rra_al" ]; then
            echo not-allowlisted
            return 1
        fi
        if ! _rra_path_under "$_rra_al" "$_rra_top"; then
            echo not-allowlisted
            return 1
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# roborev_all_files_excluded DIR REV   (sibling of the guard above)
#
# A commit whose every changed file matches roborev's `exclude_patterns` still
# gets a review job -- with an empty diff ("0 files reviewed, 1 excluded"): a
# wasted agent run and an open review for the merge gate to deal with
# (job 13884, a CHANGELOG.md-only commit). Skip those up front.
#
#   REV is a commit-ish (one commit) or a range "A..B" (e.g. ORIG_HEAD..HEAD).
#     exit 0 -> every changed file is excluded: DO NOT enqueue
#               (prints "skip: all files excluded" on stdout)
#     exit 1 -> at least one file is not excluded, OR there are no files to
#               judge (merge commit: diff-tree lists nothing without -m; empty
#               commit) -> enqueue as before. Not judging is not skipping.
#     exit 3 -> indeterminate (git failed, or a config file has an
#               exclude_patterns key it cannot parse). Callers MUST enqueue:
#               fail toward reviewing. A one-line reason is printed on stdout.
#
# Patterns: repo-top .roborev.toml plus ROBOREV_GLOBAL_CONFIG
# (default ~/.roborev/config.toml), key `exclude_patterns`, single- or multi-line
# array of '..' / ".." strings. Matching (roborev's own matcher is not
# documented -- "filenames or glob patterns"): a pattern matches a file if the
# shell glob matches the full repo-relative path OR the basename. Shell `case`
# globs let `*` cross '/', i.e. slightly broader than gitignore-style; for the
# real patterns (exact names) this is identical.
# ---------------------------------------------------------------------------

# _rra_read_patterns FILE : print one pattern per line. rc 0 ok (incl. key
# absent / file absent), rc 3 = key present but array unparseable.
_rra_read_patterns() {
    [ -r "$1" ] || return 0
    awk '
        BEGIN { inarr = 0; found = 0; closed = 0; bad = 0 }
        {
            line = $0
            if (!inarr) {
                if (line ~ /^[ \t]*exclude_patterns[ \t]*=/) {
                    found = 1
                    sub(/^[^=]*=[ \t]*/, "", line)
                    if (line !~ /^\[/) { bad = 1; next }
                    sub(/^\[/, "", line)
                    inarr = 1
                } else next
            } else if (line ~ /^[ \t]*#/) next
            while (match(line, /"[^"]*"|\047[^\047]*\047/)) {
                s = substr(line, RSTART + 1, RLENGTH - 2)
                if (s != "") print s
                line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH)
            }
            if (line ~ /\]/) { inarr = 0; closed = 1; exit }
        }
        END { if (bad || (found && !closed)) exit 3 }
    ' "$1"
}

roborev_all_files_excluded() {
    _rae_dir=${1:-.}
    _rae_rev=${2:-}
    [ -n "$_rae_rev" ] || { echo "no-rev"; return 3; }
    _rae_top=$(git -C "$_rae_dir" rev-parse --show-toplevel 2>/dev/null) || { echo "no-repo"; return 3; }

    case "$_rae_rev" in
        *..*) _rae_files=$(git -C "$_rae_top" diff --name-only --no-ext-diff "$_rae_rev" 2>/dev/null) || { echo "git-failed"; return 3; } ;;
        *)    _rae_files=$(git -C "$_rae_top" diff-tree --no-commit-id --name-only -r --no-ext-diff "$_rae_rev" 2>/dev/null) || { echo "git-failed"; return 3; } ;;
    esac
    [ -n "$_rae_files" ] || return 1

    _rae_pats=""
    for _rae_cfg in "$_rae_top/.roborev.toml" "${ROBOREV_GLOBAL_CONFIG:-$HOME/.roborev/config.toml}"; do
        _rae_out=$(_rra_read_patterns "$_rae_cfg"); _rae_rc=$?
        if [ "$_rae_rc" -ne 0 ]; then echo "config-unparseable"; return 3; fi
        if [ -n "$_rae_out" ]; then
            _rae_pats="$_rae_pats
$_rae_out"
        fi
    done
    [ -n "$_rae_pats" ] || return 1

    _rae_old_ifs=$IFS
    IFS='
'
    set -f
    for _rae_f in $_rae_files; do
        _rae_base=${_rae_f##*/}
        _rae_hit=1
        for _rae_p in $_rae_pats; do
            # shellcheck disable=SC2254
            case "$_rae_f" in $_rae_p) _rae_hit=0; break ;; esac
            # shellcheck disable=SC2254
            case "$_rae_base" in $_rae_p) _rae_hit=0; break ;; esac
        done
        if [ "$_rae_hit" -ne 0 ]; then
            set +f; IFS=$_rae_old_ifs
            return 1
        fi
    done
    set +f; IFS=$_rae_old_ifs
    echo "skip: all files excluded"
    return 0
}

# _rra_log_skip MSG : append to the hook log; best-effort, never fails the hook.
_rra_log_skip() {
    _rra_lf=${ROBOREV_HOOK_LOG:-$HOME/.claude/logs/roborev_hook_skips.log}
    mkdir -p "$(dirname "$_rra_lf")" 2>/dev/null || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$_rra_lf" 2>/dev/null || true
}

# roborev_skip_if_all_excluded DIR REV : 0 = caller should SKIP enqueue (logged);
# 1 = enqueue (an indeterminate result is logged as such, and still returns 1).
roborev_skip_if_all_excluded() {
    _rsa_msg=$(roborev_all_files_excluded "$1" "$2"); _rsa_rc=$?
    case "$_rsa_rc" in
        0) _rra_log_skip "skip: all files excluded ($2)"; return 0 ;;
        3) _rra_log_skip "indeterminate: $_rsa_msg ($2) -- reviewing anyway"; return 1 ;;
        *) return 1 ;;
    esac
}
