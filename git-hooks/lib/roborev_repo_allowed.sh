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
