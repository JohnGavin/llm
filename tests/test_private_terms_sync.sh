#!/usr/bin/env bash
# Test for .claude/scripts/private_terms_sync.sh (llm#1386). Temp dir, env
# overrides and a stub `gh` on PATH only: no network, and the real
# ~/.config/private_terms.txt / private_aliases.tsv are never touched.
# All names below are synthetic.
#
# Falsification is built in: the no-leak assertion is also run against a
# deliberately leaky copy of the script and must go red.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/private_terms_sync.sh"
WORK=$(mktemp -d)
WORK=$(cd -P "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/home"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_GH_FAIL:-0}" = "1" ]; then echo "stub gh failure" >&2; exit 1; fi
cat "$STUB_GH_JSON"
EOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export HOME="$WORK/home"
export PRIVATE_TERMS_FILE="$WORK/cfg/private_terms.txt"
export PRIVATE_ALIASES_FILE="$WORK/cfg/private_aliases.tsv"
export PRIVATE_TERMS_EXTRA_DIRS_FILE="$WORK/none_dirs"
export PRIVATE_TOPICS_FILE="$WORK/none_topics"
export PRIVATE_PATHS_FILE="$WORK/none_paths"
export STUB_GH_JSON="$WORK/repos.json"
unset PRIVATE_TERMS_MIN STUB_GH_FAIL

fail=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then echo "PASS $1 ($3)"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi
}
mkjson() { # name...
  local first=1 n
  printf '[' > "$STUB_GH_JSON"
  for n in "$@"; do
    if [ "$first" = 1 ]; then first=0; else printf ',' >> "$STUB_GH_JSON"; fi
    printf '{"name":"%s"}' "$n" >> "$STUB_GH_JSON"
  done
  printf ']\n' >> "$STUB_GH_JSON"
}
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
run() { # script args... ; captures $WORK/out, $WORK/err; sets rc
  bash "$@" > "$WORK/out" 2> "$WORK/err"
  rc=$?
}
no_leak() { # file term... ; prints 0 if no term appears, else 1
  local f=$1 t; shift
  for t in "$@"; do
    if grep -qi -- "$t" "$f"; then echo 1; return; fi
  done
  echo 0
}

FULL=(alphaproj betaproj gammaproj deltaproj epsilonproj zetaproj etaproj1 thetaproj iotaproj kappaproj lambdaproj muproj01)
mkjson "${FULL[@]}"

# 1. happy path ----------------------------------------------------------
run "$SCRIPT"
check "happy rc" 0 "$rc"
check "terms file mode" 600 "$(mode_of "$PRIVATE_TERMS_FILE")"
check "aliases file mode" 600 "$(mode_of "$PRIVATE_ALIASES_FILE")"
check "canary present" 1 "$(grep -cx 'zzcanaryprivterm7q' "$PRIVATE_TERMS_FILE")"
hdr=$(head -1 "$PRIVATE_TERMS_FILE")
case "$hdr" in "# private_terms v1 generated="*" count="*) echo "PASS header format" ;; *) echo "FAIL header format: $hdr"; fail=1 ;; esac
hcount=${hdr##*count=}
check "header count matches body" "$(grep -vc '^#' "$PRIVATE_TERMS_FILE")" "$hcount"
check "body count" 13 "$hcount"
check "alias rows (canary excluded)" 12 "$(wc -l < "$PRIVATE_ALIASES_FILE" | tr -d ' ')"
check "alias format" 12 "$(grep -cE '^[a-z0-9]+	private-project-[0-9][0-9]$' "$PRIVATE_ALIASES_FILE")"

# 2. no term values in stdout/stderr ---------------------------------------
check "no leak in stdout" 0 "$(no_leak "$WORK/out" "${FULL[@]}" zzcanaryprivterm7q)"
check "no leak in stderr" 0 "$(no_leak "$WORK/err" "${FULL[@]}" zzcanaryprivterm7q)"

# 2b. falsify the leak assertion: a leaky copy of the script must go red
sed 's|^echo "total (incl. canary).*|echo "alphaproj"|' "$SCRIPT" > "$WORK/leaky.sh"
run "$WORK/leaky.sh" --dry-run
check "falsification: leaky script is detected" 1 "$(no_leak "$WORK/out" "${FULL[@]}")"

# 3. alias stability across runs -------------------------------------------
cp "$PRIVATE_ALIASES_FILE" "$WORK/aliases.run1"
mkjson "${FULL[@]}" nupproj1
run "$SCRIPT"
check "run2 rc" 0 "$rc"
diff_old=$(grep -vc 'nupproj1' "$PRIVATE_ALIASES_FILE")
check "old rows kept" 12 "$diff_old"
check "old aliases unchanged" 0 "$(sort "$WORK/aliases.run1" | comm -23 - <(sort "$PRIVATE_ALIASES_FILE") | wc -l | tr -d ' ')"
check "new term gets next number" "nupproj1	private-project-13" "$(grep '^nupproj1' "$PRIVATE_ALIASES_FILE")"

# 4. gh failure -> exit 3, old files untouched ------------------------------
cp "$PRIVATE_TERMS_FILE" "$WORK/terms.before"
cp "$PRIVATE_ALIASES_FILE" "$WORK/aliases.before"
STUB_GH_FAIL=1 run "$SCRIPT"
check "gh failure rc" 3 "$rc"
check "terms untouched after gh failure" 0 "$(cmp -s "$WORK/terms.before" "$PRIVATE_TERMS_FILE"; echo $?)"
check "aliases untouched after gh failure" 0 "$(cmp -s "$WORK/aliases.before" "$PRIVATE_ALIASES_FILE"; echo $?)"

# 5. thin list (below floor) -> exit 3, old files untouched -------------------
mkjson alphaproj betaproj gammaproj
run "$SCRIPT"
check "thin list rc" 3 "$rc"
check "terms untouched after thin list" 0 "$(cmp -s "$WORK/terms.before" "$PRIVATE_TERMS_FILE"; echo $?)"
run "$SCRIPT" --force
check "--force does not override the floor" 3 "$rc"

# 6. >30% drop -> exit 3; --force passes --------------------------------------
export PRIVATE_TERMS_MIN=3
mkjson alphaproj betaproj gammaproj deltaproj epsilonproj zetaproj etaproj1 thetaproj
run "$SCRIPT"
check "70% drop rc" 3 "$rc"
check "terms untouched after drop" 0 "$(cmp -s "$WORK/terms.before" "$PRIVATE_TERMS_FILE"; echo $?)"
run "$SCRIPT" --force
check "--force overrides the drop" 0 "$rc"
check "forced list written" 9 "$(grep -vc '^#' "$PRIVATE_TERMS_FILE")"
unset PRIVATE_TERMS_MIN

# 7. --dry-run writes nothing; usage error -> 2 ----------------------------------
cp "$PRIVATE_TERMS_FILE" "$WORK/terms.before"
mkjson "${FULL[@]}"
run "$SCRIPT" --dry-run
check "dry-run rc" 0 "$rc"
check "dry-run writes nothing" 0 "$(cmp -s "$WORK/terms.before" "$PRIVATE_TERMS_FILE"; echo $?)"
run "$SCRIPT" --bogus
check "usage rc" 2 "$rc"

# 8. sources b, c, d + filtering ---------------------------------------------------
mkdir -p "$WORK/roots/localroot/subone" "$WORK/roots/localroot/ab"
printf '%s\n' "$WORK/roots/localroot" > "$PRIVATE_TERMS_EXTRA_DIRS_FILE"
printf 'betatopic\thealth\nbadcatterm\tweather\n' > "$PRIVATE_TOPICS_FILE"
printf 'pathslug\n' > "$PRIVATE_PATHS_FILE"
mkjson "${FULL[@]}" the
rm -f "$PRIVATE_TERMS_FILE" "$PRIVATE_ALIASES_FILE"
run "$SCRIPT"
check "sources rc" 0 "$rc"
for t in localroot subone betatopic pathslug; do
  check "term from source present: $t" 1 "$(grep -cx "$t" "$PRIVATE_TERMS_FILE")"
done
check "short term dropped" 0 "$(grep -cx 'ab' "$PRIVATE_TERMS_FILE")"
check "stoplist term dropped" 0 "$(grep -cx 'the' "$PRIVATE_TERMS_FILE")"
check "bad-category topic skipped" 0 "$(grep -cx 'badcatterm' "$PRIVATE_TERMS_FILE")"
check "no leak (sources) in stdout" 0 "$(no_leak "$WORK/out" localroot subone betatopic pathslug badcatterm)"
check "no leak (sources) in stderr" 0 "$(no_leak "$WORK/err" localroot subone betatopic pathslug badcatterm)"

# 9. a stoplisted ordinary word that is also a private repo name is dropped -----
# Synthetic: one private repo literally named "jobs" plus 12 fake names.
rm -f "$PRIVATE_TERMS_EXTRA_DIRS_FILE" "$PRIVATE_TOPICS_FILE" "$PRIVATE_PATHS_FILE"  # section 8 wrote them
export PRIVATE_TERMS_FILE="$WORK/cfg9/private_terms.txt"
export PRIVATE_ALIASES_FILE="$WORK/cfg9/private_aliases.tsv"
mkjson jobs qxzdistinctfake "${FULL[@]}"
jobs_assertions() { # label script ; runs the section-9 assertions, echoes failures
  local label=$1 script=$2
  rm -rf "$WORK/cfg9"
  run "$script"
  check "$label rc" 0 "$rc"
  check "$label jobs absent" 0 "$(grep -cx 'jobs' "$PRIVATE_TERMS_FILE")"
  check "$label fake name present" 1 "$(grep -cx 'qxzdistinctfake' "$PRIVATE_TERMS_FILE")"
  check "$label body count" 14 "$(grep -vc '^#' "$PRIVATE_TERMS_FILE")"
}
jobs_assertions "stoplisted jobs:" "$SCRIPT"
mkjson jobs
run "$SCRIPT"
check "thin list with jobs still exits 3" 3 "$rc"

# 9b. falsification: the same assertions against a copy with jobs removed from
# the STOPLIST must go red (fail flag restored afterwards).
sed 's/ projects jobs "/ projects "/' "$SCRIPT" > "$WORK/nojobs.sh"
if cmp -s "$WORK/nojobs.sh" "$SCRIPT"; then echo "FAIL falsification mutation did not apply"; fail=1; fi
mkjson jobs qxzdistinctfake "${FULL[@]}"
saved_fail=$fail
fail=0
jobs_assertions "mutant:" "$WORK/nojobs.sh" > "$WORK/mutant.out"
mutant_red=$fail
fail=$saved_fail
check "falsification: script without jobs in STOPLIST goes red" 1 "$mutant_red"

if [ "$fail" = 0 ]; then echo "ALL PASS"; exit 0; else echo "SOME FAILED"; exit 1; fi
