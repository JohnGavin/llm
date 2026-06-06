#!/usr/bin/env bash
# canonical_projects_migrate.sh — idempotent CSV→DuckDB migration
# Closes llm#533.
#
# Usage:
#   canonical_projects_migrate.sh           # apply to live DB
#   canonical_projects_migrate.sh --dry-run # print SQL without executing
#   canonical_projects_migrate.sh --selftest # 5-test fixture run then exit

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIVE_DB="$HOME/.claude/logs/unified.duckdb"
PROJECTS_CSV="$REPO_ROOT/.claude/data/canonical_projects.csv"
ALIASES_CSV="$REPO_ROOT/.claude/data/canonical_project_aliases.csv"
NIX_DEFAULT="$REPO_ROOT/default.nix"
NIX_SHELL_BIN="/nix/var/nix/profiles/default/bin/nix-shell"

LOG="$HOME/.claude/logs/canonical_projects_migrate.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [canonical_projects_migrate] $*" | tee -a "$LOG"; }

# ── mode --------------------------------------------------------------------
MODE="apply"
case "${1:-}" in
    --dry-run)  MODE="dry-run"  ;;
    --selftest) MODE="selftest" ;;
esac

# ── duckdb runner -----------------------------------------------------------
duck_run() {
    local db="$1"; shift
    if [ -f "$NIX_DEFAULT" ] && [ -x "$NIX_SHELL_BIN" ]; then
        "$NIX_SHELL_BIN" "$NIX_DEFAULT" --run "duckdb \"$db\" $*"
    else
        duckdb "$db" "$@"
    fi
}

# duck_query: scalar-result helper. Args: <db> <sql>
# Uses stdin piping into duckdb to avoid quote-mangling inside `nix-shell --run "..."`.
# Filters out: Run Time banners, extension-loaded banners, db-open lines, memory: lines, blanks.
duck_query() {
    local db="$1" sql="$2"
    local raw
    if [ -f "$NIX_DEFAULT" ] && [ -x "$NIX_SHELL_BIN" ]; then
        raw="$(printf '%s\n' "$sql" | "$NIX_SHELL_BIN" "$NIX_DEFAULT" --run "duckdb -noheader -list \"$db\"" 2>/dev/null)"
    else
        raw="$(printf '%s\n' "$sql" | duckdb -noheader -list "$db" 2>/dev/null)"
    fi
    printf '%s\n' "$raw" | awk '
        /^Run Time/        { next }
        /^loaded / && /;$/ { next }
        /^memory:/         { next }
        /^[a-zA-Z0-9_.-]+: \// { next }
        /^$/               { next }
        { print }
    ' | tail -1
}

# ── SQL fragments -----------------------------------------------------------
ddl_sql() {
    cat <<'ENDSQL'
CREATE TABLE IF NOT EXISTS canonical_projects (
    slug         VARCHAR PRIMARY KEY,
    display_name VARCHAR,
    repo         VARCHAR,
    kind         VARCHAR CHECK (kind IN (
                     'r-package','quarto-website','dashboard',
                     'analysis','meta-config','other')),
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMP NOT NULL DEFAULT current_timestamp,
    notes        VARCHAR
);

CREATE TABLE IF NOT EXISTS canonical_project_aliases (
    slug   VARCHAR NOT NULL REFERENCES canonical_projects(slug),
    alias  VARCHAR NOT NULL,
    PRIMARY KEY (slug, alias)
);
ENDSQL
}

upsert_sql() {
    local projects_csv="$1"
    local aliases_csv="$2"
    cat <<ENDSQL
INSERT INTO canonical_projects (slug, display_name, repo, kind, is_active, created_at, notes)
SELECT
    slug,
    display_name,
    repo,
    kind,
    is_active,
    current_timestamp,
    notes
FROM read_csv_auto('${projects_csv}', header=true)
ON CONFLICT (slug) DO UPDATE SET
    display_name = excluded.display_name,
    repo         = excluded.repo,
    kind         = excluded.kind,
    is_active    = excluded.is_active,
    notes        = excluded.notes;

INSERT INTO canonical_project_aliases (slug, alias)
SELECT slug, alias FROM read_csv_auto('${aliases_csv}', header=true)
ON CONFLICT (slug, alias) DO NOTHING;

SELECT COUNT(*) AS projects_total FROM canonical_projects;
SELECT COUNT(*) AS aliases_total  FROM canonical_project_aliases;
ENDSQL
}

# ── dry-run mode ------------------------------------------------------------
if [ "$MODE" = "dry-run" ]; then
    log "DRY-RUN: DDL"
    ddl_sql
    log "DRY-RUN: UPSERT"
    upsert_sql "$PROJECTS_CSV" "$ALIASES_CSV"
    log "DRY-RUN complete — no DB changes made"
    exit 0
fi

# ── selftest mode -----------------------------------------------------------
if [ "$MODE" = "selftest" ]; then
    FIXTURE_DB="/tmp/canonical_projects_test_$$.duckdb"
    PASS=0; FAIL=0

    assert_eq() {
        local desc="$1" expected="$2" actual="$3"
        if [ "$actual" = "$expected" ]; then
            echo "  PASS: $desc (got $actual)"
            PASS=$((PASS+1))
        else
            echo "  FAIL: $desc — expected $expected, got $actual"
            FAIL=$((FAIL+1))
        fi
    }

    log "selftest: fixture DB at $FIXTURE_DB"

    # Test 1 — DDL creates tables
    printf '%s\n' "$(ddl_sql)" | duck_query "$FIXTURE_DB" "$(ddl_sql)" > /dev/null
    result=$(duck_query "$FIXTURE_DB" "SELECT COUNT(*) FROM information_schema.tables WHERE table_name IN ('canonical_projects','canonical_project_aliases');")
    assert_eq "DDL creates both tables" "2" "$result"

    # Test 2 — UPSERT loads 18 projects
    duck_query "$FIXTURE_DB" "$(upsert_sql "$PROJECTS_CSV" "$ALIASES_CSV")" > /dev/null
    count_projects=$(duck_query "$FIXTURE_DB" "SELECT COUNT(*) FROM canonical_projects;")
    assert_eq "18 projects after first UPSERT" "18" "$count_projects"

    # Test 3 — UPSERT loads 1 alias
    count_aliases=$(duck_query "$FIXTURE_DB" "SELECT COUNT(*) FROM canonical_project_aliases;")
    assert_eq "1 alias after first UPSERT" "1" "$count_aliases"

    # Test 4 — idempotency: second UPSERT leaves counts unchanged
    duck_query "$FIXTURE_DB" "$(upsert_sql "$PROJECTS_CSV" "$ALIASES_CSV")" > /dev/null
    count_projects2=$(duck_query "$FIXTURE_DB" "SELECT COUNT(*) FROM canonical_projects;")
    assert_eq "18 projects after second UPSERT (idempotency)" "18" "$count_projects2"

    # Test 5 — alias slug exists (coMMpass → commpass)
    alias_check=$(duck_query "$FIXTURE_DB" "SELECT alias FROM canonical_project_aliases WHERE slug='coMMpass';")
    assert_eq "alias commpass exists for coMMpass" "commpass" "$alias_check"

    rm -f "$FIXTURE_DB"
    echo ""
    echo "selftest: $((PASS+FAIL))/5 — PASS=$PASS FAIL=$FAIL"
    [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ── apply mode (default) ----------------------------------------------------
log "apply: DB=$LIVE_DB"
log "apply: projects CSV=$PROJECTS_CSV"
log "apply: aliases CSV=$ALIASES_CSV"

if [ ! -f "$PROJECTS_CSV" ]; then
    log "ERROR: projects CSV not found: $PROJECTS_CSV"
    exit 1
fi
if [ ! -f "$ALIASES_CSV" ]; then
    log "ERROR: aliases CSV not found: $ALIASES_CSV"
    exit 1
fi

log "apply: running DDL..."
printf '%s\n' "$(ddl_sql)" | "$NIX_SHELL_BIN" "$NIX_DEFAULT" --run "duckdb \"$LIVE_DB\"" 2>&1 | grep -vE '^(Run Time|loaded |^$)' | tee -a "$LOG"

log "apply: running UPSERT..."
printf '%s\n' "$(upsert_sql "$PROJECTS_CSV" "$ALIASES_CSV")" | "$NIX_SHELL_BIN" "$NIX_DEFAULT" --run "duckdb \"$LIVE_DB\"" 2>&1 | grep -vE '^(Run Time|loaded |^$)' | tee -a "$LOG"

log "apply: done"
