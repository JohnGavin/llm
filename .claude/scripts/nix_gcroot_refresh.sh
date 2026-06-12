#!/usr/bin/env bash
# nix_gcroot_refresh.sh — keep a GC-rooted store derivation for a project's
# nix shell so launchd crons can run `nix-shell <drv>` with ZERO evaluation
# and ZERO network (llm#596).
#
# Why: default.nix pins nixpkgs via an unhashed fetchTarball URL. Evaluating
# it (any plain `nix-shell default.nix` call) re-downloads the tarball once
# the tarball TTL lapses — and the launchd environment cannot resolve
# github.com, so kb_digest/config_digest crons died before doing any work.
# Instantiating once (here, where network is available) and GC-rooting both
# the .drv and its realized outputs removes evaluation from cron runtime.
#
# Usage: nix_gcroot_refresh.sh [/abs/path/to/default.nix] [--force]
#   default nix file: /Users/johngavin/docs_gh/llm/default.nix
#   Skips work when the drv root is newer than the nix file (unless --force).
# Exit 0 = root fresh or refreshed (or stale-but-usable after a failed
# refresh); exit 1 = no usable root exists and refresh failed.
#
# Callers: bin/kb_digest_daily_cron.sh, bin/config_digest_cron.sh (best-effort
# pre-step); safe to run interactively after editing default.nix.
set -euo pipefail

NIX_FILE="/Users/johngavin/docs_gh/llm/default.nix"
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *) NIX_FILE="$arg" ;;
    esac
done

GCROOT_DIR="${HOME}/.claude/nix-gcroots"
LOG_FILE="${HOME}/.claude/logs/nix_gcroot_refresh.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

if [ ! -f "$NIX_FILE" ]; then
    log "ERROR: nix file not found: $NIX_FILE"
    echo "nix_gcroot_refresh: nix file not found: $NIX_FILE" >&2
    exit 1
fi

# Root name derived from the project directory: .../llm/default.nix -> llm-shell
PROJECT="$(basename "$(dirname "$NIX_FILE")")"
DRV_ROOT="${GCROOT_DIR}/${PROJECT}-shell.drv"
OUT_ROOT="${GCROOT_DIR}/${PROJECT}-shell-out"
# Freshness stamp: the drv root is a symlink into /nix/store where every file
# has mtime=1970, so `-nt` against the root itself always reads stale. The
# stamp is touched after each successful refresh and carries the real time.
STAMP="${DRV_ROOT}.stamp"

mkdir -p "$GCROOT_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

# Fresh enough? (stamp newer than the nix file that produced the drv)
if [ "$FORCE" -eq 0 ] && [ -e "$DRV_ROOT" ] && [ -e "$STAMP" ] && [ "$STAMP" -nt "$NIX_FILE" ]; then
    log "fresh: $STAMP newer than $NIX_FILE — skipping"
    echo "$DRV_ROOT"
    exit 0
fi

log "refresh: instantiating $NIX_FILE -A shell (root: $DRV_ROOT)"
if nix-instantiate "$NIX_FILE" -A shell --indirect --add-root "$DRV_ROOT" >> "$LOG_FILE" 2>&1; then
    log "refresh: instantiate OK"
    if nix-store --realise "$DRV_ROOT" --indirect --add-root "$OUT_ROOT" >> "$LOG_FILE" 2>&1; then
        log "refresh: realise OK (outputs rooted at $OUT_ROOT)"
    else
        log "WARN: realise failed — drv rooted but outputs unprotected against GC"
    fi
    touch "$STAMP"
    echo "$DRV_ROOT"
    exit 0
fi

# Instantiate failed (typically: no network for the fetchTarball)
if [ -e "$DRV_ROOT" ]; then
    log "WARN: refresh failed — keeping existing (possibly stale) root $DRV_ROOT"
    echo "$DRV_ROOT"
    exit 0
fi
log "ERROR: refresh failed and no existing root at $DRV_ROOT"
echo "nix_gcroot_refresh: refresh failed, no usable root" >&2
exit 1
