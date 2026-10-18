#!/usr/bin/env bash
# Tests .claude/scripts/push_coverage_branch.sh against a local bare repo.
# Override the script under test with COVERAGE_SCRIPT=<path> (used to
# falsify: a copy that pushes to main must turn this test red).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${COVERAGE_SCRIPT:-$here/../.claude/scripts/push_coverage_branch.sh}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/covpush.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export COVERAGE_PUSH_SLEEP_BASE=0

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

bare="$tmp/origin.git"
work="$tmp/work"
git init -q --bare -b main "$bare"
git init -q -b main "$work"
mkdir -p "$work/inst/extdata"
echo readme > "$work/README"
git -C "$work" add README
git -C "$work" commit -q -m "init"
git -C "$work" remote add origin "$bare"
git -C "$work" push -q origin main
main_sha="$(git -C "$bare" rev-parse refs/heads/main)"
f="inst/extdata/coverage.rds"
run() { (cd "$work" && bash "$script" "$f" coverage-data "$@"); }

# 1. first push creates the branch with exactly one file
echo v1 > "$work/$f"
run origin >"$tmp/o1" 2>&1
check "first push exits 0" 0 "$?"
check "branch has exactly one file" "$f" "$(git -C "$bare" ls-tree -r --name-only refs/heads/coverage-data)"
check "branch has one commit" 1 "$(git -C "$bare" rev-list --count refs/heads/coverage-data)"
check "pushed blob content" v1 "$(git -C "$bare" show refs/heads/coverage-data:$f)"
check "main untouched after first push" "$main_sha" "$(git -C "$bare" rev-parse refs/heads/main)"
check "main has no coverage file" "README" "$(git -C "$bare" ls-tree -r --name-only refs/heads/main)"
check "local HEAD branch untouched" main "$(git -C "$work" rev-parse --abbrev-ref HEAD)"
check "local index clean" "" "$(git -C "$work" diff --cached --name-only)"

# 2. unchanged file -> no new commit
tip1="$(git -C "$bare" rev-parse refs/heads/coverage-data)"
run origin >"$tmp/o2" 2>&1
check "unchanged exits 0" 0 "$?"
check "unchanged adds no commit" "$tip1" "$(git -C "$bare" rev-parse refs/heads/coverage-data)"

# 3. changed file -> exactly one new commit, parent is old tip, still one file
echo v2 > "$work/$f"
COVERAGE_PUSH_REMOTE="$bare" bash -c "cd '$work' && bash '$script' '$f' coverage-data" >"$tmp/o3" 2>&1
check "changed (remote via env) exits 0" 0 "$?"
check "changed adds exactly one commit" 2 "$(git -C "$bare" rev-list --count refs/heads/coverage-data)"
check "new commit parent is old tip" "$tip1" "$(git -C "$bare" rev-parse refs/heads/coverage-data^)"
check "new content pushed" v2 "$(git -C "$bare" show refs/heads/coverage-data:$f)"
check "still exactly one file" "$f" "$(git -C "$bare" ls-tree -r --name-only refs/heads/coverage-data)"
check "commit message has [skip ci]" yes \
  "$(git -C "$bare" log -1 --format=%s refs/heads/coverage-data | grep -qF '[skip ci]' && echo yes || echo no)"
check "main untouched after update" "$main_sha" "$(git -C "$bare" rev-parse refs/heads/main)"

# 4. guard: refusing main
echo v3 > "$work/$f"
(cd "$work" && bash "$script" "$f" main origin) >"$tmp/o4" 2>&1
check "branch main refused with exit 2" 2 "$?"

# 5. rejected push retries, then exits non-zero
tip2="$(git -C "$bare" rev-parse refs/heads/coverage-data)"
mkdir -p "$bare/hooks"
cat > "$bare/hooks/pre-receive" <<'HOOK'
#!/bin/sh
echo x >> "$GIT_DIR/reject-count"
echo "rejected by test hook" >&2
exit 1
HOOK
chmod +x "$bare/hooks/pre-receive"
run origin >"$tmp/o5" 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then ok "rejected push exits 1"; else bad "rejected push exits 1 (got $rc)"; fi
check "hook saw 3 attempts" 3 "$(wc -l < "$bare/reject-count" | tr -d ' ')"
check "branch unchanged after rejection" "$tip2" "$(git -C "$bare" rev-parse refs/heads/coverage-data)"
check "main untouched after rejection" "$main_sha" "$(git -C "$bare" rev-parse refs/heads/main)"
check "error annotation emitted" yes \
  "$(grep -qF 'could not push' "$tmp/o5" && echo yes || echo no)"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
