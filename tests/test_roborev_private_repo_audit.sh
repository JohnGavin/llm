#!/usr/bin/env bash
# Test for .claude/scripts/roborev_private_repo_audit.sh (llm#1296) and, by
# delegation, the git-hooks guard self-test. Fixture DB + temp repos only; the
# real ~/.roborev/reviews.db and ~/.config roots files are never touched.
#
# Falsification is built in: the same fixture yields exit 0 (clean), 1
# (blocked), and 3 (unreadable DB / unverifiable) -- all three outcomes.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT="$ROOT/.claude/scripts/roborev_private_repo_audit.sh"
WORK=$(mktemp -d)
WORK=$(cd -P "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export ROBOREV_PRIVATE_ROOTS_FILE="$WORK/none"
unset ROBOREV_ALLOWLIST_MODE

fail=0
check() { # label expected_rc actual_rc
  if [ "$2" = "$3" ]; then echo "PASS $1 (rc=$3)"; else echo "FAIL $1: expected rc=$2 got rc=$3"; fail=1; fi
}

mk() { # dir
  mkdir -p "$1"; git -C "$1" init -q -b main
  git -C "$1" remote add origin https://example.invalid/r.git
}
# NOTE: fixture repos live under $WORK (a temp dir) but the audit only excludes
# temp roots by path prefix for *registered* rows; to exercise the real logic we
# register them under a non-temp-looking alias via symlink-free path: use HOME
# scratch inside the repo checkout instead.
BASE="$ROOT/.audit_test_$$"
mkdir -p "$BASE"
trap 'rm -rf "$WORK" "$BASE"' EXIT
BASE=$(cd -P "$BASE" && pwd -P)
mk "$BASE/good"
mk "$BASE/marked"; touch "$BASE/marked/.roborev-disable"
mk "$BASE/noremote"; git -C "$BASE/noremote" remote remove origin

DB="$WORK/reviews.db"
sqlite3 "$DB" "CREATE TABLE repos (id INTEGER PRIMARY KEY, root_path TEXT UNIQUE NOT NULL, name TEXT NOT NULL);
INSERT INTO repos(root_path,name) VALUES ('$BASE/good','g');"
export ROBOREV_DB="$DB"

out=$("$AUDIT" 2>&1); rc=$?
check "clean DB (only an allowed repo) -> 0" 0 "$rc"

sqlite3 "$DB" "INSERT INTO repos(root_path,name) VALUES ('$BASE/marked','m'),('$BASE/noremote','n');"
out=$("$AUDIT" 2>&1); rc=$?
check "marker + no-remote repos registered -> 1" 1 "$rc"
case "$out" in *"blocked=2"*"marker=1 noremote=1"*) echo "PASS counts: blocked=2 marker=1 noremote=1" ;; *) echo "FAIL counts: $out"; fail=1 ;; esac
case "$out" in *"$BASE"*) echo "FAIL default output names a repo path"; fail=1 ;; *) echo "PASS default output is counts only (no paths)" ;; esac

# Read-only: the DB row count is unchanged after the audit.
n=$(sqlite3 "$DB" "SELECT COUNT(*) FROM repos;")
check "audit deleted nothing (3 rows remain)" 3 "$n"

rm -f "$BASE/marked/.roborev-disable"; git -C "$BASE/noremote" remote add origin https://example.invalid/r.git
out=$("$AUDIT" 2>&1); rc=$?
check "falsify: marker removed + remote added -> 0" 0 "$rc"

printf '%s\n' "$BASE/good" > "$ROBOREV_PRIVATE_ROOTS_FILE"
out=$("$AUDIT" 2>&1); rc=$?
check "private-roots file lists a registered repo -> 1" 1 "$rc"
rm -f "$ROBOREV_PRIVATE_ROOTS_FILE"

sqlite3 "$DB" "INSERT INTO repos(root_path,name) VALUES ('$BASE/gone','x');"
out=$("$AUDIT" 2>&1); rc=$?
check "registered checkout missing (unverifiable) -> 3, not 0" 3 "$rc"

ROBOREV_DB="$WORK/does-not-exist.db" "$AUDIT" >/dev/null 2>&1; rc=$?
check "unreadable DB -> 3 (indeterminate)" 3 "$rc"

# The hook/guard self-test (two-sided, stubbed roborev).
bash "$ROOT/git-hooks/test-post-commit-guard.sh" >"$WORK/hook_test.out" 2>&1; rc=$?
check "git-hooks/test-post-commit-guard.sh" 0 "$rc"
[ "$rc" -eq 0 ] || cat "$WORK/hook_test.out"

exit "$fail"
