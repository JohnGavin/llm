#!/usr/bin/env bash
# tests/test_repo_visibility_gate.sh -- acceptance and falsification of the
# private -> public gate (llm#1392, parent llm#1382).
#
# Acceptance (the issue's): a visibility change attempted on a scratch repo with
# a planted canary is refused; with the canary gone AND a fresh clean audit on
# record it is allowed; a stale record, a record for an older tip, a record with
# findings, a missing term list and a missing ledger are each refused
# (INDETERMINATE for the last two).
#
# Hermetic: every repo is synthetic under a mktemp dir; HOME, git config, ledger,
# deny-list, term list and acknowledgement directory are pinned to it; `gh` is a
# fake on PATH that only logs (the test asserts it is never called); no network;
# no real repository is touched; every name is synthetic. The canary is built
# from two literals so this file never contains it.
#
# GATE_TREE (default: this checkout) selects the tree whose hook and helper are
# exercised, so the same suite can be pointed at an older or a mutated tree.
#
# Falsification (a green result only means something if red was reachable): three
# mutated COPIES of the hook/helper -- tip check skipped, fail-open on error,
# environment bypass re-enabled -- must each let the matching case through.
#
# Exit: 0 all pass, 1 any failure, 3 INDETERMINATE (a required tool is missing).
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
GATE_TREE="${GATE_TREE:-$ROOT}"
SCANNER_REAL="$ROOT/.claude/scripts/private_data_scan.sh"
SCHEMA="$ROOT/.claude/scripts/housekeeping_schema_init.sql"
for tool in git duckdb python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "INDETERMINATE: $tool not on PATH"; exit 3; }
done
[ -f "$GATE_TREE/.claude/hooks/repo_visibility_guard.sh" ] || { echo "INDETERMINATE: no hook in $GATE_TREE"; exit 3; }

WORK="$(mktemp -d)"; WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"; mkdir -p "$HOME/.config"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export UNIFIED_DB_PATH="$WORK/ledger.duckdb"
export PRIVATE_TERMS_FILE="$WORK/terms.txt"
export PRIVATE_VALUES_FILE="$WORK/pv.env"
export SCANNER="$SCANNER_REAL"
export REPO_PUBLIC_ACK_DIR="$WORK/ack"
unset PRIVATE_DATA_SCAN_VISIBILITY REPO_PUBLISH_AUDIT_MAX_AGE_HOURS REPO_PUBLIC_OK \
      REPO_PUBLISH_AUDIT_CMD REPO_VISIBILITY_PARSER REPO_ROOT PRIVATE_TERMS_MAX_AGE_DAYS
printf 'K=unrelated_value_for_denylist_presence\n' > "$PRIVATE_VALUES_FILE"; chmod 600 "$PRIVATE_VALUES_FILE"

CANARY="zzcanary""privterm7q"
OUT="$WORK/out.txt"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/gh.log"
exit 1
EOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
rc_is() { # label want got
  if [ "$3" = "$2" ]; then ok "$1 (exit $3)"; else bad "$1 (want exit $2, got $3; out: $(tr '\n' ' ' < "$OUT" | cut -c1-260))"; fi
}
out_has() { # label pattern
  if grep -q -- "$2" "$OUT"; then ok "$1"; else bad "$1 (no '$2' in: $(tr '\n' ' ' < "$OUT" | cut -c1-260))"; fi
}
out_lacks() { # label pattern
  if grep -q -- "$2" "$OUT"; then bad "$1 ('$2' present)"; else ok "$1"; fi
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
days_ago_iso() { date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ; }
mkterms() { # FILE GENERATED-ISO TERM...
  local f="$1" gen="$2"; shift 2
  { printf '# private_terms v1 generated=%s count=%s\n' "$gen" "$#"; for t in "$@"; do printf '%s\n' "$t"; done; } > "$f"
}
mkterms "$PRIVATE_TERMS_FILE" "$(now_iso)" "$CANARY" "alphaproj"

# --- scratch repo with the planted canary --------------------------------------
R="$WORK/repo"; mkdir -p "$R"
git -C "$R" init -q -b main
git -C "$R" config user.email t@example.invalid
git -C "$R" config user.name T
git -C "$R" remote add origin https://github.com/synth-owner/synth-repo.git
printf 'note: %s was here\n' "$CANARY" > "$R/f.txt"
git -C "$R" add -A
git -c core.hooksPath=/dev/null -C "$R" commit -qm "add note"
KEY="synth-owner/synth-repo"

# --- ledger (the real schema file builds it) -------------------------------------
if duckdb -init /dev/null "$UNIFIED_DB_PATH" < "$SCHEMA" > "$WORK/schema.out" 2>&1; then
  ok "housekeeping_schema_init.sql builds the sandbox ledger"
else
  bad "schema did not apply: $(head -3 "$WORK/schema.out")"
fi

HOOK_REL=".claude/hooks/repo_visibility_guard.sh"
AUDIT_REL=".claude/scripts/repo_publish_audit.sh"
XENV=()
hook() { # CMD [CWD] [TREE] -> rc ; output in $OUT
  local cmd="$1" cwd="${2:-$R}" tree="${3:-$GATE_TREE}" json
  json="$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$cmd" "$cwd")"
  printf '%s' "$json" | env ${XENV[@]+"${XENV[@]}"} bash "$tree/$HOOK_REL" > "$OUT" 2>&1
  echo $?
}
audit() { # MODE... -> rc ; output in $OUT   (uses the tree under test)
  env ${XENV[@]+"${XENV[@]}"} bash "$GATE_TREE/$AUDIT_REL" "$@" > "$OUT" 2>&1
  echo $?
}
age_ledger() { duckdb -init /dev/null "$UNIFIED_DB_PATH" -c "UPDATE private_data_history_unit_state SET last_full_scan_epoch = last_full_scan_epoch + $1" >/dev/null 2>&1; }

EDIT="gh repo edit $KEY --visibility public --accept-visibility-change-consequences"

echo "== 1. planted canary: refused ================================================"
rc="$(hook "$EDIT")"; rc_is "canary repo, no record: edit refused" 2 "$rc"
out_has "  says there is no recorded audit" "NO_RECORD"
out_has "  names the audit command" "repo_publish_audit.sh"
out_has "  names the owner acknowledgement command" "printf"
out_lacks "  never prints the canary" "$CANARY"
out_lacks "  never prints the other private term" "alphaproj"
rc="$(hook "gh repo edit $KEY --visibility \"\$SOME_VAR\"")"; rc_is "visibility given by a variable counts as public: refused without a record" 2 "$rc"
rc="$(audit --record --repo "$KEY" --dir "$R")"; rc_is "record audit of the canary repo reports findings" 1 "$rc"
out_has "  private-term rule fired through the audit path" "rule=private-term"
out_lacks "  audit output never prints the canary" "$CANARY"
rc="$(hook "$EDIT")"; rc_is "canary repo with a FAIL record: edit refused" 2 "$rc"
out_has "  says the record has findings" "FINDINGS"
[ ! -s "$WORK/gh.log" ] && ok "the fake gh was never called (no flip attempted)" || bad "gh was called: $(cat "$WORK/gh.log")"
[ -z "$(ls -A "$WORK/ack" 2>/dev/null)" ] && ok "the hook created no acknowledgement file" || bad "an acknowledgement file appeared"

echo "== 2. canary removed AND fresh clean audit: allowed ========================="
git -C "$R" checkout -q --orphan clean
git -C "$R" rm -rfq .
echo "all clear" > "$R/f.txt"; git -C "$R" add -A
git -c core.hooksPath=/dev/null -C "$R" commit -qm "squashed"
git -C "$R" branch -D main -q
git -C "$R" branch -m main
git -C "$R" reflog expire --expire=now --all
git -C "$R" gc -q --prune=now
rc="$(hook "$EDIT")"; rc_is "history rewritten, no new audit: still refused (record is for older refs)" 2 "$rc"
out_has "  says the record is for other refs" "TIP_MISMATCH"
rc="$(audit --record --repo "$KEY" --dir "$R")"; rc_is "record audit of the clean repo passes" 0 "$rc"
out_has "  audit says PASS" "RESULT=PASS"
rc="$(hook "$EDIT")"; rc_is "fresh clean record: allowed" 0 "$rc"
rc="$(hook "gh repo edit --visibility public $KEY")"; rc_is "flag before the repo: allowed" 0 "$rc"
rc="$(hook "gh repo edit --visibility=public")"; rc_is "no repo named, cwd origin used: allowed" 0 "$rc"
rc="$(hook "gh api -X PATCH repos/$KEY -f visibility=public")"; rc_is "gh api -f: allowed" 0 "$rc"
rc="$(hook "gh api repos/$KEY -X PATCH -F visibility=public")"; rc_is "gh api -F: allowed" 0 "$rc"
rc="$(hook "gh api repos/{owner}/{repo} --method PATCH --field=visibility=public")"; rc_is "gh api with placeholders resolves via cwd origin: allowed" 0 "$rc"
rc="$(hook "gh repo create $KEY --public --source=$R --push")"; rc_is "gh repo create --source: allowed" 0 "$rc"
rc="$(hook "cd $R && bash -c 'gh repo edit $KEY --visibility public'")"; rc_is "wrapped in cd && bash -c: allowed" 0 "$rc"

echo "== 3. refusals that must stay refusals ======================================"
age_ledger -90000
rc="$(hook "$EDIT")"; rc_is "stale record (25 h): refused" 2 "$rc"
out_has "  says STALE" "STALE"
XENV=(REPO_PUBLISH_AUDIT_MAX_AGE_HOURS=48)
rc="$(hook "$EDIT")"; rc_is "  same record inside a 48 h window: allowed (window is env-overridable)" 0 "$rc"
XENV=()
age_ledger 90000
rc="$(hook "$EDIT")"; rc_is "  record restored: allowed again" 0 "$rc"

git -C "$R" tag synth-tag
rc="$(hook "$EDIT")"; rc_is "a new tag after the audit: refused (every ref counts)" 2 "$rc"
out_has "  says TIP_MISMATCH" "TIP_MISMATCH"
git -C "$R" tag -d synth-tag >/dev/null
rc="$(hook "$EDIT")"; rc_is "  tag removed, refs identical again: allowed" 0 "$rc"
echo "more" >> "$R/f.txt"; git -C "$R" add -A
git -c core.hooksPath=/dev/null -C "$R" commit -qm "newer tip"
rc="$(hook "$EDIT")"; rc_is "record for an older tip (new commit since): refused" 2 "$rc"
out_has "  says TIP_MISMATCH" "TIP_MISMATCH"

echo "== 4. owner acknowledgement (the only override) ============================="
TIP="$(env bash "$GATE_TREE/$AUDIT_REL" --fingerprint --dir "$R" 2>/dev/null)"
XENV=(REPO_PUBLIC_OK=1)
rc="$(hook "$EDIT")"; rc_is "REPO_PUBLIC_OK=1 no longer allows anything" 2 "$rc"
XENV=()
mkdir -p "$WORK/ack"
printf '%s' "0000000000000000000000000000000000000000000000000000000000000000" > "$WORK/ack/synth-owner__synth-repo"
rc="$(hook "$EDIT")"; rc_is "acknowledgement for another tip: refused" 2 "$rc"
printf '%s\n' "$TIP" > "$WORK/ack/synth-owner__synth-repo"
rc="$(hook "$EDIT")"; rc_is "acknowledgement of this exact tip: allowed" 0 "$rc"
echo "again" >> "$R/f.txt"; git -C "$R" add -A
git -c core.hooksPath=/dev/null -C "$R" commit -qm "tip moves after the acknowledgement"
rc="$(hook "$EDIT")"; rc_is "acknowledgement expires on a new commit: refused" 2 "$rc"
rm -f "$WORK/ack/synth-owner__synth-repo"
printf '%s' "$TIP" > "$WORK/ack_target"
ln -s "$WORK/ack_target" "$WORK/ack/synth-owner__synth-repo"
rc="$(hook "$EDIT")"; rc_is "an acknowledgement that is a symlink is not honoured" 2 "$rc"
rm -f "$WORK/ack/synth-owner__synth-repo"
rc="$(hook "gh repo create nosrc-synth --public")"; rc_is "gh repo create with no --source: refused (no local history)" 2 "$rc"
printf 'no-local-source' > "$WORK/ack/nosrc-synth"
rc="$(hook "gh repo create nosrc-synth --public")"; rc_is "  with the owner acknowledgement no-local-source: allowed" 0 "$rc"
rm -f "$WORK/ack/nosrc-synth"
rc="$(hook "gh repo create nosrc-synth2")"; rc_is "gh repo create with no visibility flag: treated as public, refused" 2 "$rc"

# re-establish a clean current record for the INDETERMINATE cases
rc="$(audit --record --repo "$KEY" --dir "$R")"; rc_is "re-record the current tip" 0 "$rc"
rc="$(hook "$EDIT")"; rc_is "  allowed with the new record" 0 "$rc"

echo "== 5. INDETERMINATE: errors never become permission ========================="
cp "$PRIVATE_TERMS_FILE" "$WORK/terms.keep"
rm -f "$PRIVATE_TERMS_FILE"
rc="$(hook "$EDIT")"; rc_is "term list missing: refused" 2 "$rc"
out_has "  says INDETERMINATE" "INDETERMINATE"
: > "$PRIVATE_TERMS_FILE"
rc="$(hook "$EDIT")"; rc_is "term list empty: refused" 2 "$rc"
out_has "  says INDETERMINATE" "INDETERMINATE"
mkterms "$PRIVATE_TERMS_FILE" "$(days_ago_iso 31)" "$CANARY" "alphaproj"
rc="$(hook "$EDIT")"; rc_is "term list 31 days old: refused" 2 "$rc"
out_has "  says INDETERMINATE" "INDETERMINATE"
cp "$WORK/terms.keep" "$PRIVATE_TERMS_FILE"
mv "$PRIVATE_VALUES_FILE" "$WORK/pv.keep"
rc="$(hook "$EDIT")"; rc_is "deny-list file missing: refused" 2 "$rc"
out_has "  says INDETERMINATE" "INDETERMINATE"
mv "$WORK/pv.keep" "$PRIVATE_VALUES_FILE"
rc="$(hook "$EDIT")"; rc_is "inputs restored: allowed again" 0 "$rc"

mv "$UNIFIED_DB_PATH" "$WORK/ledger.keep"
rc="$(hook "$EDIT")"; rc_is "ledger missing: refused" 2 "$rc"
out_has "  says INDETERMINATE" "INDETERMINATE"
printf 'this is not a database' > "$UNIFIED_DB_PATH"
rc="$(hook "$EDIT")"; rc_is "ledger unreadable: refused" 2 "$rc"
out_has "  says INDETERMINATE" "INDETERMINATE"
rm -f "$UNIFIED_DB_PATH"
duckdb -init /dev/null "$UNIFIED_DB_PATH" -c "CREATE TABLE unrelated(x INTEGER)" >/dev/null 2>&1
rc="$(hook "$EDIT")"; rc_is "ledger without the table: refused" 2 "$rc"
out_has "  says INDETERMINATE" "INDETERMINATE"
rm -f "$UNIFIED_DB_PATH"; mv "$WORK/ledger.keep" "$UNIFIED_DB_PATH"
rc="$(hook "$EDIT")"; rc_is "ledger restored: allowed again" 0 "$rc"

XENV=(REPO_PUBLISH_AUDIT_CMD="$WORK/no_such_audit.sh")
rc="$(hook "$EDIT")"; rc_is "audit script missing: refused" 2 "$rc"
out_has "  says INDETERMINATE" "INDETERMINATE"
XENV=(REPO_VISIBILITY_PARSER="$WORK/no_such_parser.py")
rc="$(hook "$EDIT")"; rc_is "parser missing: refused" 2 "$rc"
out_has "  says INDETERMINATE" "INDETERMINATE"
XENV=()
NOGIT="$WORK/nogit"; mkdir -p "$NOGIT"
rc="$(hook "gh repo edit --visibility public" "$NOGIT")"; rc_is "target not in the command and cwd is not a repo: refused" 2 "$rc"
out_has "  says INDETERMINATE" "INDETERMINATE"
rc="$(hook "gh repo edit other-owner/other-repo --visibility public")"; rc_is "target differs from the clone in cwd: refused" 2 "$rc"
out_has "  says INDETERMINATE" "INDETERMINATE"
NOORIGIN="$WORK/noorigin"; mkdir -p "$NOORIGIN"; git -C "$NOORIGIN" init -q -b main
rc="$(hook "gh repo edit --visibility public" "$NOORIGIN")"; rc_is "cwd repo without an origin: refused" 2 "$rc"

echo "== 6. everything else passes untouched ======================================"
for c in "git status --short" "gh pr list" "gh repo view $KEY --json visibility" \
         "gh repo edit $KEY --visibility private" "gh repo create foo --private" \
         "gh repo create foo --internal" "gh api repos/$KEY -X PATCH -f visibility=private" \
         "gh repo edit $KEY --description \"visibility public\"" \
         "git commit -m \"docs: gh repo edit o/r --visibility public is gated\"" \
         "grep -rn visibility README.md"; do
  rc="$(hook "$c")"; rc_is "allowed: $c" 0 "$rc"
done
XENV=(REPO_PUBLISH_AUDIT_CMD="$WORK/no_such_audit.sh" REPO_VISIBILITY_PARSER="$WORK/no_such_parser.py")
rc="$(hook "git status")"; rc_is "an unrelated command is unaffected even when the audit and parser are broken" 0 "$rc"
XENV=()

echo "== 7. the scheduled paths run the same audit ================================"
if grep -q 'PRIVATE_DATA_SCAN_VISIBILITY=public' "$ROOT/.claude/scripts/repo_visibility_diff.sh"; then
  ok "repo_visibility_diff.sh runs its history audit as a public repo (private-term rule armed)"
else
  bad "repo_visibility_diff.sh does not force the public-repo scan"
fi
if grep -q 'PRIVATE_DATA_SCAN_VISIBILITY=public' "$ROOT/.claude/scripts/private_data_history_audit.sh"; then
  ok "private_data_history_audit.sh --all-public runs its scanner as a public repo"
else
  bad "private_data_history_audit.sh does not force the public-repo scan"
fi

echo "== 8. falsification: mutated copies must go wrong ==========================="
mutant() { # NAME -> prints dir of a fresh copy of the tree under test
  local d="$WORK/mut/$1"
  mkdir -p "$d/.claude/hooks/lib" "$d/.claude/scripts"
  cp "$GATE_TREE/.claude/hooks/repo_visibility_guard.sh" "$d/.claude/hooks/"
  cp "$GATE_TREE/.claude/hooks/lib/repo_visibility_parse.py" "$GATE_TREE/.claude/hooks/lib/run_bounded.sh" "$d/.claude/hooks/lib/"
  cp "$GATE_TREE/$AUDIT_REL" "$d/.claude/scripts/"
  printf '%s' "$d"
}
changed() { # label before after : the mutation must have changed the file
  if cmp -s "$2" "$3"; then bad "$1: mutation did not change the file -- falsification is vacuous"; return 1; fi
  return 0
}
M1="$(mutant skip_tip)"
sed 's/\[ "\$r_ref" != "\$FP" \]/[ "x" != "x" ]/' "$GATE_TREE/$AUDIT_REL" > "$M1/$AUDIT_REL"
if changed "skip the tip check" "$GATE_TREE/$AUDIT_REL" "$M1/$AUDIT_REL"; then
  # The record is made BY the mutant (the script hash is part of the record), then
  # the tip moves: only the tip check separates "older tip" from "current tip".
  rc="$(env bash "$M1/$AUDIT_REL" --record --repo "$KEY" --dir "$R" >"$OUT" 2>&1; echo $?)"; rc_is "mutant records the current tip" 0 "$rc"
  echo "tip moves again" >> "$R/f.txt"; git -C "$R" add -A
  git -c core.hooksPath=/dev/null -C "$R" commit -qm "tip for the falsification runs"
  rc="$(hook "$EDIT" "$R" "$GATE_TREE")"; rc_is "genuine tree: record for an older tip is refused" 2 "$rc"
  rc="$(hook "$EDIT" "$R" "$M1")"
  if [ "$rc" = 0 ]; then ok "falsified: with the tip check skipped the older-tip record is wrongly ALLOWED"; else bad "tip-check mutant still refused (exit $rc): the older-tip case cannot go red"; fi
fi

M2="$(mutant fail_open)"
sed 's/^    \*) _indet "\${detail:-the audit check failed.*$/    *) return 0 ;;/' "$GATE_TREE/$HOOK_REL" > "$M2/$HOOK_REL"
if changed "fail open on error" "$GATE_TREE/$HOOK_REL" "$M2/$HOOK_REL"; then
  mv "$UNIFIED_DB_PATH" "$WORK/ledger.keep"
  rc="$(hook "$EDIT" "$R" "$GATE_TREE")"; rc_is "genuine tree: missing ledger is refused" 2 "$rc"
  rc="$(hook "$EDIT" "$R" "$M2")"
  if [ "$rc" = 0 ]; then ok "falsified: failing open turns the missing-ledger case into ALLOWED"; else bad "fail-open mutant still refused (exit $rc): the missing-ledger case cannot go red"; fi
  mv "$WORK/ledger.keep" "$UNIFIED_DB_PATH"
fi

M3="$(mutant env_bypass)"
awk '{print} /^  KIND="\$\(_field KIND\)"; DIR=""/{print "  [ \"${REPO_PUBLIC_OK:-0}\" = \"1\" ] && return 0"}' "$GATE_TREE/$HOOK_REL" > "$M3/$HOOK_REL"
if changed "re-enable the env bypass" "$GATE_TREE/$HOOK_REL" "$M3/$HOOK_REL"; then
  XENV=(REPO_PUBLIC_OK=1)
  rc="$(hook "$EDIT" "$R" "$GATE_TREE")"; rc_is "genuine tree: REPO_PUBLIC_OK=1 changes nothing" 2 "$rc"
  rc="$(hook "$EDIT" "$R" "$M3")"
  if [ "$rc" = 0 ]; then ok "falsified: with the bypass re-enabled the same command is wrongly ALLOWED"; else bad "bypass mutant still refused (exit $rc): the bypass case cannot go red"; fi
  XENV=()
fi

echo
echo "repo_visibility_gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
