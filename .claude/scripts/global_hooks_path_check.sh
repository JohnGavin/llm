#!/usr/bin/env bash
# global_hooks_path_check.sh -- report clones of PUBLIC GitHub repos whose
# effective core.hooksPath bypasses the global git hooks (llm#1388, parent #1382).
#
# Why: the PII gate (pre-commit / pre-push / commit-msg, git-hooks/) runs only
# where git resolves core.hooksPath to the global hooks directory. A repo-local
# `core.hooksPath` (or one unset because the global setting is gone) silently
# turns the gate off for that clone, and nothing else notices.
#
# Scope: every git clone under $GHPC_SCAN_ROOT (default ~/docs_gh), at most
# $GHPC_SCAN_DEPTH (default 4) directories deep. Only directories that contain a
# `.git` DIRECTORY count: a linked worktree (`.git` is a FILE) shares its main
# clone's config, so it is skipped; clones are also de-duplicated by
# git-common-dir. Anything under a `worktrees/` path component is skipped.
# A clone qualifies when `origin` is a github.com remote whose repo is PUBLIC
# (`gh repo view OWNER/REPO --json visibility`, looked up once per repo per run).
# Clones with no origin, a non-GitHub origin, or a private repo are not checked.
#
# Expected hooks dir: $GHPC_EXPECTED_HOOKS if set, else the GLOBAL
# `git config --global core.hooksPath`, else <this checkout>/git-hooks. A clone
# passes when `git -C <clone> config --type=path core.hooksPath` (local over
# global, ~ expanded) resolves, after symlinks, to the same directory.
#
# READ-ONLY: it reads git config and asks gh for visibility; it changes nothing.
#
# Exit codes (checks-must-distinguish-unknown): 0 every public clone resolves to
# the global hooks dir; 1 at least one clone bypasses it (determinate, wins over
# 3); 2 usage error; 3 INDETERMINATE -- no bypass found but a visibility lookup
# failed, so some clones could not be classified. Absence of a bypass in the
# clones that WERE classified is not proof about the ones that were not.
#
# Output: one `BYPASS <clone> hooksPath=<value|unset>` line per bypassing clone,
# `UNKNOWN <clone> <owner/repo>` per failed lookup, then a one-line summary.
set -uo pipefail

case "${1:-}" in
    "") : ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "global_hooks_path_check: unknown argument: $1" >&2; exit 2 ;;
esac

HOME_DIR="${HOME:-/Users/johngavin}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
SCAN_ROOT="${GHPC_SCAN_ROOT:-${HOME_DIR}/docs_gh}"
SCAN_DEPTH="${GHPC_SCAN_DEPTH:-4}"
GH_BIN="${GHPC_GH:-gh}"

resolve_dir() { # resolve_dir PATH -> physical absolute path; returns 1 (no output) if PATH is not a directory
    local d
    d="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
    printf '%s' "$d"
}

expected="${GHPC_EXPECTED_HOOKS:-}"
if [ -z "$expected" ]; then
    expected="$(git config --global --type=path core.hooksPath 2>/dev/null || true)"
fi
[ -n "$expected" ] || expected="$SCRIPT_DIR/../../git-hooks"
expected_phys="$(resolve_dir "$expected")"
if [ -z "$expected_phys" ]; then
    echo "global_hooks_path_check: INDETERMINATE -- expected hooks dir does not exist: $expected" >&2
    exit 3
fi
if [ ! -d "$SCAN_ROOT" ]; then
    echo "global_hooks_path_check: INDETERMINATE -- scan root does not exist: $SCAN_ROOT" >&2
    exit 3
fi

VIS_CACHE="$(mktemp "${TMPDIR:-/tmp}/ghpc_vis.XXXXXX")"
SEEN="$(mktemp "${TMPDIR:-/tmp}/ghpc_seen.XXXXXX")"
trap 'rm -f "$VIS_CACHE" "$SEEN"' EXIT

# owner_repo URL -> owner/repo for a github.com remote, else return 1
owner_repo() {
    local url="$1" rest
    case "$url" in *github.com*) : ;; *) return 1 ;; esac
    rest="${url#*github.com:}"; rest="${rest#*github.com/}"
    [ "$rest" != "$url" ] || return 1
    rest="${rest%/}"; rest="${rest%.git}"
    case "$rest" in */*/*|/*|*/|"") return 1 ;; esac
    case "$rest" in */*) printf '%s' "$rest" ;; *) return 1 ;; esac
}

# visibility OWNER/REPO -> PUBLIC | other | UNKNOWN (cached for this run)
visibility() {
    local key="$1" hit v
    hit="$(awk -F'\t' -v k="$key" '$1 == k {print $2; exit}' "$VIS_CACHE")"
    if [ -n "$hit" ]; then printf '%s' "$hit"; return 0; fi
    v="$("$GH_BIN" repo view "$key" --json visibility -q .visibility 2>/dev/null)" || v=""
    case "$v" in PUBLIC|public) v="PUBLIC" ;; PRIVATE|private|INTERNAL|internal) v="PRIVATE" ;; *) v="UNKNOWN" ;; esac
    printf '%s\t%s\n' "$key" "$v" >> "$VIS_CACHE"
    printf '%s' "$v"
}

checked=0; bypass=0; unknown=0
while IFS= read -r gitdir; do
    [ -n "$gitdir" ] || continue
    [ -d "$gitdir" ] || continue            # a .git FILE is a linked worktree
    clone="${gitdir%/.git}"
    case "$clone" in */worktrees/*|*/worktrees) continue ;; esac
    common="$(git -C "$clone" rev-parse --git-common-dir 2>/dev/null)" || continue
    common_phys="$(resolve_dir "$clone/$common")"
    [ -n "$common_phys" ] || common_phys="$(resolve_dir "$common")"
    [ -n "$common_phys" ] || continue
    if grep -qxF -- "$common_phys" "$SEEN"; then continue; fi
    printf '%s\n' "$common_phys" >> "$SEEN"

    url="$(git -C "$clone" remote get-url origin 2>/dev/null)" || continue
    repo="$(owner_repo "$url")" || continue
    vis="$(visibility "$repo")"
    case "$vis" in
        PUBLIC) : ;;
        UNKNOWN) unknown=$((unknown + 1)); echo "UNKNOWN $clone $repo"; continue ;;
        *) continue ;;
    esac
    checked=$((checked + 1))
    raw="$(git -C "$clone" config --type=path core.hooksPath 2>/dev/null)" || raw=""
    if [ -z "$raw" ]; then
        bypass=$((bypass + 1)); echo "BYPASS $clone hooksPath=unset"; continue
    fi
    case "$raw" in /*) hp="$raw" ;; *) hp="$clone/$raw" ;; esac
    hp_phys="$(resolve_dir "$hp")"
    if [ "$hp_phys" != "$expected_phys" ]; then
        bypass=$((bypass + 1)); echo "BYPASS $clone hooksPath=$raw"
    fi
done < <(find "$SCAN_ROOT" -mindepth 1 -maxdepth "$SCAN_DEPTH" -name .git -prune -print 2>/dev/null | sort)

echo "global-hooks-path-check: public_clones=${checked} bypass=${bypass} unknown_visibility=${unknown} expected=${expected_phys}"
if [ "$bypass" -gt 0 ]; then exit 1; fi
if [ "$unknown" -gt 0 ]; then
    echo "global-hooks-path-check: INDETERMINATE -- ${unknown} clone(s) could not be classified (visibility lookup failed); no bypass found among the rest" >&2
    exit 3
fi
exit 0
