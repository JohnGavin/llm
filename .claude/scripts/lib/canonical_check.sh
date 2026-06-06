#!/usr/bin/env bash
# canonical_check.sh — shared helper for producer-side skip-and-warn (#536)
#
# Source this file; do NOT execute directly.
#
# Usage:
#   source /path/to/.claude/scripts/lib/canonical_check.sh
#
#   if is_canonical_project "llm"; then
#       echo "canonical"
#   else
#       log_canonical_skip "roborev_pmhook_test_abc" "my_producer.sh"
#       echo "skipped"
#   fi
#
# Opt-out: set CANONICAL_PROJECTS_INCLUDE_FIXTURES=1 before sourcing to
# bypass all checks (useful in CI / self-test harnesses).
#
# Skip log: ~/.claude/logs/canonical_producer_skip.log
#
# Issue: JohnGavin/llm#536

# Process-local cache — ":delimited:" string, populated lazily on first call.
_CANONICAL_LIST_CACHE=""

# is_canonical_project SLUG
#
# Returns 0 (true) if SLUG appears in canonical_projects or
# canonical_project_aliases in unified.duckdb.
# Returns 1 (false) otherwise.
#
# When CANONICAL_PROJECTS_INCLUDE_FIXTURES=1 always returns 0.
is_canonical_project() {
    local candidate="$1"

    # Opt-out: treat everything as canonical when fixtures are included
    if [ "${CANONICAL_PROJECTS_INCLUDE_FIXTURES:-0}" = "1" ]; then
        return 0
    fi

    # Lazy-load on first call
    if [ -z "$_CANONICAL_LIST_CACHE" ]; then
        _load_canonical_cache
    fi

    # O(1) substring match on ":slug:" pattern
    case ":${_CANONICAL_LIST_CACHE}:" in
        *":${candidate}:"*) return 0 ;;
        *) return 1 ;;
    esac
}

# _load_canonical_cache
#
# Internal: populates _CANONICAL_LIST_CACHE from unified.duckdb.
# Falls back to empty (all-reject) when the DB is unavailable.
_load_canonical_cache() {
    local db
    db="${UNIFIED_DB:-${HOME}/.claude/logs/unified.duckdb}"

    if [ ! -f "$db" ]; then
        # DB unavailable — treat cache as empty (callers will skip everything)
        _CANONICAL_LIST_CACHE="__EMPTY__"
        return
    fi

    local sql="SELECT slug FROM canonical_projects WHERE is_active = TRUE UNION ALL SELECT alias FROM canonical_project_aliases;"
    local raw
    # stdin-pipe to avoid duckdb -c stall risk
    raw="$(printf '%s\n' "$sql" | duckdb -noheader -list "$db" 2>/dev/null)"

    if [ -z "$raw" ]; then
        _CANONICAL_LIST_CACHE="__EMPTY__"
        return
    fi

    # Build ":slug1:slug2:..." from newline-separated output
    # Strip DuckDB startup noise lines (Run Time, loaded ..., memory:)
    local cleaned
    cleaned="$(printf '%s\n' "$raw" | awk '
        /^Run Time/           { next }
        /^loaded /            { next }
        /^memory:/            { next }
        /^[a-zA-Z0-9_.-]+: \// { next }
        /^$/                  { next }
        { print }
    ')"

    _CANONICAL_LIST_CACHE="$(printf '%s\n' "$cleaned" | tr '\n' ':')"
    # Ensure no leading/trailing colons cause false matches
    _CANONICAL_LIST_CACHE="${_CANONICAL_LIST_CACHE%:}"
    _CANONICAL_LIST_CACHE="${_CANONICAL_LIST_CACHE#:}"
}

# log_canonical_skip SLUG PRODUCER
#
# Appends one line to the canonical skip log.
CANONICAL_SKIP_LOG="${HOME}/.claude/logs/canonical_producer_skip.log"

log_canonical_skip() {
    local slug="$1"
    local producer="$2"
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s SKIP slug=%s producer=%s\n' "$ts" "$slug" "$producer" >> "$CANONICAL_SKIP_LOG"
}
