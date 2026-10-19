#!/usr/bin/env bash
# tests/test_mem_pr_gate.sh
#
# llm#1446 / llm#770 (root cause llm#510): dirty memory edits in the main
# checkout must become a PR WITHOUT /bye. Covers .claude/scripts/mem_pr.sh and
# the Stop-hook wiring in .claude/hooks/session_stop.sh, using a temp git repo
# + bare remote + a stub `gh`. Never touches the real ~/.claude or any real repo.
#
# Falsification built in:
#   - test 8 runs the real hook (must fire mem_pr with NO /bye sentinel) and a
#     MUTATED copy that restores the old `_bye_detected` gate (must NOT fire):
#     red when the gate would skip, green when it fires.
#   - test 6 blocks the commit with a failing pre-commit hook (exit 3, nothing
#     pushed) and then removes it (exit 0), so the block is not vacuous.
#
# Exits 0 if all pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MEM_PR="${REPO_ROOT}/.claude/scripts/mem_pr.sh"
SESSION_STOP="${REPO_ROOT}/.claude/hooks/session_stop.sh"

PASS=0
FAIL=0
T="$(mktemp -d)"
LIVE_PID=""
cleanup() {
  [ -n "${LIVE_PID}" ] && kill "${LIVE_PID}" 2>/dev/null
  rm -rf "${T}"
}
trap cleanup EXIT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — expected='$2' actual='$3'"; fi
}
assert_contains() {
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 — '$2' not in output: $3" ;; esac
}

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

BRANCH="chore/memory-$(date -u +%Y%m%d)"

# Fixture: bare remote + main checkout (with the prose files and one code file)
# + a stub gh on PATH.
new_fixture() {
  local d="$1"
  mkdir -p "${d}/bin" "${d}/state" "${d}/home"
  git init -q --bare -b main "${d}/remote.git"
  git clone -q "${d}/remote.git" "${d}/main" 2>/dev/null
  mkdir -p "${d}/main/.claude/memory" "${d}/main/.claude/rules" "${d}/main/src"
  echo "index" > "${d}/main/.claude/memory/MEMORY.md"
  echo "rule" > "${d}/main/.claude/rules/r.md"
  echo "log" > "${d}/main/CHANGELOG.md"
  echo "code" > "${d}/main/src/code.R"
  git -C "${d}/main" add -A
  git -C "${d}/main" commit -q -m init
  git -C "${d}/main" branch -M main
  git -C "${d}/main" push -q -u origin main 2>/dev/null
  cat > "${d}/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${GH_LOG}"
case "$1 $2" in
  "pr list") [ -f "${GH_PR_FILE}" ] && cat "${GH_PR_FILE}"; exit 0 ;;
  "pr create") echo "https://example.invalid/pull/1" | tee "${GH_PR_FILE}"; exit 0 ;;
esac
exit 0
EOF
  chmod +x "${d}/bin/gh"
}

# run_mem_pr <fixture> [extra env assignments...]; sets OUT and RC.
run_mem_pr() {
  local d="$1"; shift
  OUT="$(env HOME="${d}/home" PATH="${d}/bin:${PATH}" GH_LOG="${d}/gh.log" \
    GH_PR_FILE="${d}/pr_url" MEM_PR_STATE_DIR="${d}/state" MEM_PR_MIN_INTERVAL=0 \
    "$@" bash "${MEM_PR}" "${d}/main" 2>&1)"
  RC=$?
}
create_count() {
  if [ -f "$1/gh.log" ]; then grep -c '^pr create' "$1/gh.log" || true; else echo 0; fi
}
remote_has_branch() { git -C "$1/remote.git" rev-parse --verify --quiet "refs/heads/${BRANCH}" >/dev/null; echo $?; }
branch_commits() { git -C "$1/remote.git" rev-list --count "main..${BRANCH}" 2>/dev/null || echo 0; }

echo "== test 0: syntax =="
for f in "${MEM_PR}" "${SESSION_STOP}"; do
  rc=0; bash -n "${f}" 2>/dev/null || rc=$?
  assert_eq "test0: bash -n $(basename "${f}")" "0" "${rc}"
done

echo "== test 1: nothing dirty -> no-op =="
F1="${T}/f1"; new_fixture "${F1}"
run_mem_pr "${F1}"
assert_eq "test1: exit 0" "0" "${RC}"
assert_contains "test1: says nothing to route" "nothing to route" "${OUT}"
assert_eq "test1: no remote branch" "1" "$(remote_has_branch "${F1}")"
assert_eq "test1: no gh call" "0" "$(create_count "${F1}")"

echo "== test 2: only memory dirty -> branch + commit + PR =="
F2="${T}/f2"; new_fixture "${F2}"
echo "changed" >> "${F2}/main/.claude/memory/MEMORY.md"
echo "new note" > "${F2}/main/.claude/memory/new_note.md"
head_before="$(git -C "${F2}/main" rev-parse HEAD)"
run_mem_pr "${F2}"
assert_eq "test2: exit 0" "0" "${RC}"
assert_eq "test2: remote branch exists" "0" "$(remote_has_branch "${F2}")"
assert_eq "test2: one commit on the branch" "1" "$(branch_commits "${F2}")"
assert_eq "test2: PR create attempted once" "1" "$(create_count "${F2}")"
assert_eq "test2: untracked note is on the branch" "new note" \
  "$(git -C "${F2}/remote.git" show "${BRANCH}:.claude/memory/new_note.md")"
assert_eq "test2: main checkout HEAD untouched" "${head_before}" "$(git -C "${F2}/main" rev-parse HEAD)"
assert_eq "test2: main checkout still on main" "main" "$(git -C "${F2}/main" rev-parse --abbrev-ref HEAD)"
assert_eq "test2: main checkout files left in place" "new note" "$(cat "${F2}/main/.claude/memory/new_note.md")"
assert_eq "test2: no leftover worktree" "1" "$(git -C "${F2}/main" worktree list | wc -l | tr -d ' ')"

echo "== test 3: non-memory dirty files are left alone =="
F3="${T}/f3"; new_fixture "${F3}"
echo "changed" >> "${F3}/main/.claude/memory/MEMORY.md"
echo "edited code" >> "${F3}/main/src/code.R"
echo "secret-ish" > "${F3}/main/.claude/settings.local.json.20261010"
run_mem_pr "${F3}"
assert_eq "test3: exit 0" "0" "${RC}"
files="$(git -C "${F3}/remote.git" diff --name-only "main..${BRANCH}")"
assert_eq "test3: commit holds ONLY the memory file" ".claude/memory/MEMORY.md" "${files}"
assert_eq "test3: code edit still dirty locally" " M src/code.R" \
  "$(git -C "${F3}/main" status --short -- src/code.R)"
assert_eq "test3: settings.local file untouched" "secret-ish" \
  "$(cat "${F3}/main/.claude/settings.local.json.20261010")"

echo "== test 4: second run idempotent; later edit updates the same PR =="
run_mem_pr "${F3}"
assert_eq "test4: exit 0" "0" "${RC}"
assert_contains "test4: already routed" "already routed" "${OUT}"
assert_eq "test4: still one commit" "1" "$(branch_commits "${F3}")"
assert_eq "test4: still one PR create" "1" "$(create_count "${F3}")"
echo "more" >> "${F3}/main/.claude/memory/MEMORY.md"
run_mem_pr "${F3}"
assert_eq "test4b: exit 0" "0" "${RC}"
assert_eq "test4b: second commit on the SAME branch" "2" "$(branch_commits "${F3}")"
assert_eq "test4b: no second PR created" "1" "$(create_count "${F3}")"
assert_contains "test4b: PR updated" "PR updated" "${OUT}"

echo "== test 5: lock prevents concurrent runs =="
F5="${T}/f5"; new_fixture "${F5}"
echo "changed" >> "${F5}/main/.claude/memory/MEMORY.md"
sleep 60 &
LIVE_PID=$!
mkdir -p "${F5}/state/mem_pr.lock"
echo "${LIVE_PID}" > "${F5}/state/mem_pr.lock/pid"
run_mem_pr "${F5}"
assert_eq "test5: exit 0 while another run holds the lock" "0" "${RC}"
assert_contains "test5: reports active run" "another mem_pr run is active" "${OUT}"
assert_eq "test5: nothing pushed while locked" "1" "$(remote_has_branch "${F5}")"
assert_eq "test5: live lock not removed" "yes" "$([ -d "${F5}/state/mem_pr.lock" ] && echo yes || echo no)"
kill "${LIVE_PID}" 2>/dev/null; wait "${LIVE_PID}" 2>/dev/null; LIVE_PID=""
run_mem_pr "${F5}"
assert_eq "test5b: stale lock (dead pid) is recovered, exit 0" "0" "${RC}"
assert_eq "test5b: branch pushed after recovery" "0" "$(remote_has_branch "${F5}")"
assert_eq "test5b: lock released at exit" "no" "$([ -d "${F5}/state/mem_pr.lock" ] && echo yes || echo no)"

echo "== test 5c: throttle =="
F5C="${T}/f5c"; new_fixture "${F5C}"
echo "changed" >> "${F5C}/main/.claude/memory/MEMORY.md"
date +%s > "${F5C}/state/mem_pr.last_attempt"
run_mem_pr "${F5C}" MEM_PR_MIN_INTERVAL=3600
assert_contains "test5c: throttled" "throttled" "${OUT}"
assert_eq "test5c: nothing pushed" "1" "$(remote_has_branch "${F5C}")"

echo "== test 6: private-data scan blocking -> exit 3, never bypassed =="
F6="${T}/f6"; new_fixture "${F6}"
echo "changed" >> "${F6}/main/.claude/memory/MEMORY.md"
mkdir -p "${F6}/main/.git/hooks"
printf '#!/bin/sh\necho "private-data scan: 1 finding" >&2\nexit 1\n' > "${F6}/main/.git/hooks/pre-commit"
chmod +x "${F6}/main/.git/hooks/pre-commit"
run_mem_pr "${F6}"
assert_eq "test6: exit 3 (blocked, not 0)" "3" "${RC}"
assert_contains "test6: reported as BLOCKED" "BLOCKED" "${OUT}"
assert_eq "test6: nothing pushed" "1" "$(remote_has_branch "${F6}")"
assert_eq "test6: no PR attempted" "0" "$(create_count "${F6}")"
assert_eq "test6: main checkout file untouched" " M .claude/memory/MEMORY.md" \
  "$(git -C "${F6}/main" status --short -- .claude/memory)"
rm -f "${F6}/main/.git/hooks/pre-commit"
run_mem_pr "${F6}"
assert_eq "test6b: control — same fixture without the blocking hook exits 0" "0" "${RC}"
assert_eq "test6b: control — branch pushed" "0" "$(remote_has_branch "${F6}")"

echo "== test 6c: stale base (origin/main moved the file) is skipped, not overwritten =="
F9="${T}/f9"; new_fixture "${F9}"
git clone -q "${F9}/remote.git" "${F9}/other" 2>/dev/null
echo "newer upstream" > "${F9}/other/.claude/memory/MEMORY.md"
git -C "${F9}/other" commit -q -am upstream
git -C "${F9}/other" push -q origin main 2>/dev/null
echo "local edit on old base" >> "${F9}/main/.claude/memory/MEMORY.md"
run_mem_pr "${F9}"
assert_eq "test6c: exit 0" "0" "${RC}"
assert_contains "test6c: reported stale base" "stale base, left alone: .claude/memory/MEMORY.md" "${OUT}"
assert_eq "test6c: nothing pushed" "1" "$(remote_has_branch "${F9}")"

echo "== test 7: SKIP_MEM_PR opt-out =="
F7="${T}/f7"; new_fixture "${F7}"
echo "changed" >> "${F7}/main/.claude/memory/MEMORY.md"
run_mem_pr "${F7}" SKIP_MEM_PR=1
assert_eq "test7: exit 0" "0" "${RC}"
assert_eq "test7: nothing pushed" "1" "$(remote_has_branch "${F7}")"

echo "== test 8: Stop hook fires mem_pr WITHOUT a /bye sentinel (falsified) =="
H="${T}/hook"
mkdir -p "${H}/home/.claude/scripts" "${H}/home/.claude/logs" "${H}/project"
cat > "${H}/home/.claude/scripts/mem_pr.sh" <<EOF
#!/usr/bin/env bash
echo "\$1" > "${H}/marker"
EOF
chmod +x "${H}/home/.claude/scripts/mem_pr.sh"

run_hook() {  # run_hook <hook file>
  rm -f "${H}/marker"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID HOME="${H}/home" \
    CLAUDE_PROJECT_DIR="${H}/project" LLM_MAIN_CHECKOUT="${H}/maincheckout" \
    bash "$1" >/dev/null 2>&1 || true
  local i=0
  while [ ! -f "${H}/marker" ] && [ "${i}" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -f "${H}/marker" ] && cat "${H}/marker" || echo "NOT_FIRED"
}

assert_eq "test8: real hook fires mem_pr on the MAIN checkout, no sentinel" \
  "${H}/maincheckout" "$(run_hook "${SESSION_STOP}")"

# Mutation: restore the old /bye gate; the hook must now skip (proves the
# assertion above can go red).
sed 's|^if \[ -x "\$_MEM_PR_SCRIPT" \]; then|if [ "$_bye_detected" -eq 1 ] \&\& [ -x "$_MEM_PR_SCRIPT" ]; then|' \
  "${SESSION_STOP}" > "${H}/session_stop_gated.sh"
if cmp -s "${SESSION_STOP}" "${H}/session_stop_gated.sh"; then
  fail "test8: mutation did not change the hook (sed pattern stale)"
else
  assert_eq "test8: MUTATED hook (old /bye gate) does NOT fire — gate skip is detectable" \
    "NOT_FIRED" "$(run_hook "${H}/session_stop_gated.sh")"
fi

echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"
[ "${FAIL}" -eq 0 ]
