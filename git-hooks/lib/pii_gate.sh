# git-hooks/lib/pii_gate.sh -- shared by pre-commit and pre-push (llm#1365).
# POSIX sh; SOURCED, never executed. The caller must set PII_HOOKS_DIR to the
# directory holding the hook (resolved through symlinks).
#
# Why this exists: core.hooksPath is global and points at this directory, so git
# ignores every repo's own .git/hooks. The per-repo PII hooks written by
# private_data_git_hooks_install.sh therefore ran in 2 of 83 public-repo clones.
# These hooks make the gate run in every repo that uses the global path.
#
# Exit codes (exit-code-conventions): 0 pass, 1 FAIL (PII found), 2 usage error
# (we invoked the scanner wrongly), 3 INDETERMINATE (scanner missing / could not
# run / itself reported indeterminate). Any non-zero blocks: fail closed.
# Bypass is git's own --no-verify only (private-data-scanning.md, "Why no
# custom bypass"): there is deliberately no environment-variable kill switch.

PII_SCANNER="$PII_HOOKS_DIR/../.claude/scripts/private_data_scan.sh"

# pii_repo_root -> toplevel of the repo being operated on (gitdir when bare).
pii_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || git rev-parse --absolute-git-dir 2>/dev/null
}

# pii_scan HOOKNAME SCANNER-ARGS... -> runs the scanner against THIS repo.
# Returns 0 only for a genuine clean pass; prints why otherwise.
pii_scan() {
  _pii_hook=$1; shift
  if [ ! -f "$PII_SCANNER" ]; then
    printf >&2 '%s\n' \
      "" \
      "$_pii_hook BLOCKED (INDETERMINATE, exit 3): PII scanner not found:" \
      "  $PII_SCANNER" \
      "Failing closed. Restore it (git -C <llm checkout> pull) or, knowingly, bypass" \
      "with git's own --no-verify."
    return 3
  fi
  _pii_root=$(pii_repo_root) || _pii_root=""
  if [ -z "$_pii_root" ]; then
    printf >&2 '%s\n' "" \
      "$_pii_hook BLOCKED (INDETERMINATE, exit 3): could not resolve the repository root." \
      "Failing closed. Bypass knowingly with --no-verify."
    return 3
  fi
  REPO_ROOT="$_pii_root" bash "$PII_SCANNER" "$@"
  _pii_rc=$?
  case "$_pii_rc" in
    0) return 0 ;;
    1) printf >&2 '%s\n' "" \
         "$_pii_hook BLOCKED (exit 1) by private_data_scan.sh: PII detected, or the scanner" \
         "failed closed (e.g. missing deny-list). Review the findings above. Sanctioned" \
         "override for a false positive: git's own --no-verify."
       return 1 ;;
    2) printf >&2 '%s\n' "" \
         "$_pii_hook BLOCKED (usage error, exit 2): the hook invoked private_data_scan.sh wrongly." \
         "This is a bug in git-hooks/lib/pii_gate.sh; failing closed."
       return 2 ;;
    3) printf >&2 '%s\n' "" \
         "$_pii_hook BLOCKED (INDETERMINATE, exit 3): private_data_scan.sh could not give a" \
         "determinate answer (see above); absence of findings is not proof of clean." \
         "Failing closed. Sanctioned override: git's own --no-verify."
       return 3 ;;
    *) printf >&2 '%s\n' "" \
         "$_pii_hook BLOCKED (INDETERMINATE, exit 3): private_data_scan.sh exited $_pii_rc" \
         "unexpectedly. Failing closed."
       return 3 ;;
  esac
}

# pii_repo_hook HOOKNAME -> prints the path of the repo's OWN hook if one exists,
# is executable, and is not a file inside this hooks dir; else prints nothing.
# Uses --git-common-dir: `--git-path hooks` would just echo core.hooksPath back.
pii_repo_hook() {
  _pii_common=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
  _pii_cand="$_pii_common/hooks/$1"
  [ -f "$_pii_cand" ] && [ -x "$_pii_cand" ] || return 0
  _pii_cd=$(cd "$(dirname "$_pii_cand")" 2>/dev/null && pwd -P) || return 0
  _pii_hd=$(cd "$PII_HOOKS_DIR" 2>/dev/null && pwd -P) || return 0
  # .git/hooks symlinked to this directory would otherwise recurse forever.
  [ "$_pii_cd" != "$_pii_hd" ] || return 0
  printf '%s' "$_pii_cd/$1"
}

# pii_repo_hook_scans HOOKNAME -> 0 when the repo's own hook already runs
# private_data_scan (installer marker present), so we must not scan twice.
pii_repo_hook_scans() {
  _pii_rh=$(pii_repo_hook "$1")
  [ -n "$_pii_rh" ] || return 1
  grep -qF "private-data-scan $1 gate" "$_pii_rh" 2>/dev/null
}

# pii_chain HOOKNAME STDIN-FILE ARGS... -> runs the repo's own hook, if any, with
# the same arguments and (pre-push) the same stdin. Returns its exit status.
pii_chain() {
  _pii_name=$1; _pii_in=$2; shift 2
  _pii_rh=$(pii_repo_hook "$_pii_name")
  [ -n "$_pii_rh" ] || return 0
  if [ -n "$_pii_in" ]; then
    "$_pii_rh" "$@" < "$_pii_in"
  else
    "$_pii_rh" "$@"
  fi
}
