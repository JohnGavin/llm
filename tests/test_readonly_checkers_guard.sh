#!/usr/bin/env bash
# tests/test_readonly_checkers_guard.sh -- guard for .claude/state/readonly_checkers.txt (llm#1471).
#
# WHAT THIS IS, HONESTLY: a HEURISTIC BACKSTOP. It reads each listed script as
# text and flags commands that could change something outside a temp file. It
# cannot prove a script read-only: it does not execute anything, does not follow
# `source`d files, calls to other scripts, variable-held command names, or the
# body of an interpreter (python, Rscript, perl ...; those are simply refused).
# THE CONTROL IS THE OWNER'S SIGNATURE ON THE LIST: adding or removing an entry
# is Class C (explicit owner "merge"). This test only catches an obvious
# mutation sneaking into an already-listed script, and a bad list entry.
#
# Modes:
#   (default)            1. self-test: fixture scripts must turn the scanner RED for
#                           every mutating class and GREEN for clean scripts, and the
#                           list checks must behave (empty list = INDETERMINATE);
#                        2. scan every script on the list (--list, default the real one).
#   --no-selftest        skip step 1 (used by the self-test on itself)
#   --list FILE          list to check          (default .claude/state/readonly_checkers.txt)
#   --root DIR           repo root for listed paths (default: this checkout)
#   --scan FILE...       scan only these files (no list, no self-test). The sweep uses
#                        this on the PR-head content of each changed listed script.
#
# What counts as a violation (outside comments; quoted text is NOT excused, so
# a mutating word at a command position inside a string is flagged too):
#   rm      unless every target is a variable assigned only from `mktemp`
#           (or a path under one), e.g. rm -f "$tmp" or rm -rf "$dir/x"
#   mv, cp  mv: every operand temp-held; cp: the destination temp-held
#   gh      close merge edit comment create delete reopen review ... ; gh api with
#           -X/--method/-f/-F/--field/--input
#   git     push commit reset checkout clean rebase merge stash add rm mv restore
#           switch pull fetch ... ; branch -d/-D/-m ; worktree add/remove/prune
#   launchctl chmod chown chgrp kill pkill killall sudo eval source/. ln rmdir
#           truncate dd rsync scp install unlink shred wget crontab ssh osascript
#           defaults; shells (bash -c, sh script, | sh); interpreters
#   curl    -X/--request/-d/--data*/-F/-T/-O, or -o to a non-temp file
#   sed -i / --in-place; find -delete; awk system() or print > file
#   duckdb/sqlite3/psql/mysql: any INSERT UPDATE DELETE DROP CREATE ALTER TRUNCATE
#           ATTACH COPY ... anywhere in a file that invokes one of them
#   redirects > >> &> >| >(...) and tee: only to /dev/null, /dev/stderr, /dev/stdout,
#           a mktemp-held variable (or a path under one), or a stderr/stdout dup
#           (>&2, 2>&1). `mkdir`/`touch` follow the same rule.
# ONE built-in exception, because the first listed checker needs it: a "liveness
# stamp" at $HOME/.claude/logs/stamps/<name>.stamp (written with > and its
# directory made with mkdir). Nothing else under $HOME is allowed. Editing this
# exception is Class C like the rest of this file.
#
# Exit codes (.claude/rules/exit-code-conventions.md):
#   0  every check passed
#   1  a check failed (a violation, a missing or symlinked listed script, a bad list
#      entry, or a self-test case that did not behave)
#   2  usage error
#   3  INDETERMINATE: the list is unreadable or holds no entry (a guard that passes
#      on an empty list is worse than none), or a scanned file is unreadable
# Portable: bash 3.2, BSD and GNU awk/grep.
set -u

SELF="${BASH_SOURCE[0]}"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
LIST="$ROOT/.claude/state/readonly_checkers.txt"
MODE="list"; SELFTEST=1; SCAN_FILES=""
usage() { echo "usage: test_readonly_checkers_guard.sh [--no-selftest] [--list FILE] [--root DIR] | --scan FILE..." >&2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --no-selftest) SELFTEST=0; shift ;;
    --list) if [ $# -lt 2 ]; then usage; exit 2; fi; LIST="$2"; shift 2 ;;
    --root) if [ $# -lt 2 ]; then usage; exit 2; fi; ROOT="$2"; shift 2 ;;
    --scan) MODE="scan"; shift
            while [ $# -gt 0 ]; do SCAN_FILES="$SCAN_FILES
$1"; shift; done ;;
    -h|--help) usage; exit 2 ;;
    *) echo "USAGE-ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
if [ "$MODE" = "scan" ] && [ -z "$SCAN_FILES" ]; then echo "USAGE-ERROR: --scan needs at least one file" >&2; usage; exit 2; fi

W="$(mktemp -d "${TMPDIR:-/tmp}/ro_guard.XXXXXX")" || { echo "INDETERMINATE: mktemp failed" >&2; exit 3; }
trap 'rm -rf "$W"' EXIT

# ---- the scanner (awk) -------------------------------------------------------------
cat > "$W/scan.awk" <<'AWKEOF'
# Reads one script, prints "<line>\t<class>\t<text>" per violation.
BEGIN {
  SQ = sprintf("%c", 39); DQ = "\""; SOH = sprintf("%c", 1); nbad = 0
  KW = "if|then|do|else|elif|while|until|xargs|sudo|exec|command|env|time|nohup|-exec|-execdir|-ok"
  PATHP = "[^[:space:];&|(){}`\"']*/"
  PFX = "(^|[;&|({`!)]|[$][(]|(trap|eval|-c)[[:space:]]+[\"']|(^|[[:space:]])(" KW ")[[:space:]])[[:space:]]*(" PATHP ")?"
  SFX = "([[:space:]]|$|;)"
}
{ rawl[NR] = $0 }

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function flag(k, cls) { printf "%d\t%s\t%s\n", LN[k], cls, substr(trim(RAWL[k]), 1, 100); nbad++ }

# strip a trailing comment, tracking quote state (global q) across lines
function strip(s,   out, i, c, p, len) {
  len = length(s); out = ""
  if (q == "" && s ~ /^[ \t]*#/) return ""
  for (i = 1; i <= len; i++) {
    c = substr(s, i, 1)
    if (q == "") {
      if (c == "\\") { out = out c substr(s, i + 1, 1); i++; continue }
      if (c == SQ || c == DQ) { q = c; out = out c; continue }
      if (c == "#") {
        p = (i == 1) ? " " : substr(s, i - 1, 1)
        if (p ~ /[ \t;&|(]/) break
      }
      out = out c
    } else {
      if (c == "\\" && q == DQ) { out = out c substr(s, i + 1, 1); i++; continue }
      if (c == q) q = ""
      out = out c
    }
  }
  return out
}

# temp-held variable: assigned only from mktemp whose template stays under a temp dir
function mk_ok(rhs,   t, k, arr, na, tok) {
  t = rhs; sub(/^["']?(\$\(|`)[ \t]*(command[ \t]+)?mktemp/, "", t); sub(/[)`].*$/, "", t)
  na = split(t, arr, /[ \t]+/)
  for (k = 1; k <= na; k++) {
    tok = arr[k]; gsub(/["']/, "", tok)
    if (tok == "" || tok ~ /^-/) continue
    if (tok ~ /\.\./) return 0
    if (tok ~ /^(\$TMPDIR|\$\{TMPDIR|\/tmp\/|\/private\/tmp\/|\/var\/folders\/)/) continue
    if (tok ~ /^[$\/]/) return 0
  }
  return 1
}
function collect(s,   rest, nm, pre, rhs) {
  rest = s
  while (match(rest, /[A-Za-z_][A-Za-z0-9_]*=/)) {
    nm = substr(rest, RSTART, RLENGTH - 1)
    pre = (RSTART == 1) ? " " : substr(rest, RSTART - 1, 1)
    rhs = substr(rest, RSTART + RLENGTH)
    rest = rhs
    if (pre !~ /[ \t;&|({]/) continue
    if (rhs ~ /^["']?(\$\(|`)[ \t]*(command[ \t]+)?mktemp([ \t]|\)|`|"|$)/) {
      if (mk_ok(rhs)) good[nm] = 1; else badv[nm] = 1
    } else if (rhs ~ /^(""|''|[ \t;&|)]|$)/) {
      # empty initialisation: harmless
    } else badv[nm] = 1
  }
}
function is_temp(tok,   nm) {
  gsub(/["']/, "", tok)
  if (tok ~ /\.\./) return 0
  if (tok ~ /^\$\{[A-Za-z_][A-Za-z0-9_]*\}(\/.*)?$/) { nm = substr(tok, 3); sub(/\}.*$/, "", nm) }
  else if (tok ~ /^\$[A-Za-z_][A-Za-z0-9_]*(\/.*)?$/) { nm = substr(tok, 2); sub(/[^A-Za-z0-9_].*$/, "", nm) }
  else return 0
  return ((nm in good) && !(nm in badv)) ? 1 : 0
}
function is_stamp(tok) {
  gsub(/["']/, "", tok)
  return (tok ~ /^\$(\{HOME\}|HOME)\/\.claude\/logs\/stamps(\/[A-Za-z0-9_.-]*\.stamp)?$/) ? 1 : 0
}
function is_sink(tok) {
  gsub(/["']/, "", tok)
  if (tok == "/dev/null" || tok == "/dev/stderr" || tok == "/dev/stdout") return 1
  return (is_temp(tok) || is_stamp(tok)) ? 1 : 0
}

# next occurrence of a command name at a command position in CR; sets ARGS (the
# rest of that command, cut at ; & | ) or at the closing quote of a quoted body)
function nextcmd(names,   re, m, dq, p) {
  re = PFX "(" names ")" SFX
  if (!match(CR, re)) return 0
  m = substr(CR, RSTART, RLENGTH)
  CR = SOH substr(CR, RSTART + RLENGTH)
  ARGS = substr(CR, 2)
  dq = ""
  if (match(m, /["']/)) dq = substr(m, RSTART, 1)
  if (dq != "") { p = index(ARGS, dq); if (p > 0) ARGS = substr(ARGS, 1, p - 1) }
  sub(/[;&|)`<>].*$/, "", ARGS)
  NA = split(ARGS, A, /[ \t]+/)
  return 1
}

function flagify(k, s, names, cls) { CR = s; while (nextcmd(names)) { flag(k, cls); return } }

function check_git(k, s,   j, t, sub1, nxt, hit) {
  CR = s
  while (nextcmd("git")) {
    sub1 = ""; hit = 0
    for (j = 1; j <= NA; j++) {
      t = A[j]; gsub(/["']/, "", t)
      if (t == "") continue
      if (t == "-C" || t == "-c" || t == "--git-dir" || t == "--work-tree" || t == "--namespace") { j++; continue }
      if (t ~ /^-/) continue
      sub1 = t; nxt = j; break
    }
    if (sub1 ~ /^(push|commit|reset|checkout|clean|rebase|merge|stash|add|rm|mv|restore|switch|pull|fetch|clone|init|cherry-pick|revert|tag|am|apply|update-ref|gc|prune|filter-branch|config|notes|replace)$/) hit = 1
    else if (sub1 == "branch" || sub1 == "worktree" || sub1 == "remote" || sub1 == "submodule" || sub1 == "reflog") {
      for (j = nxt + 1; j <= NA; j++) {
        t = A[j]; gsub(/["']/, "", t)
        if (sub1 == "branch" && t ~ /^(-d|-D|-m|-M|-c|-C|-u|--delete|--move|--copy|--set-upstream-to.*|--unset-upstream|--force|-f)$/) hit = 1
        if (sub1 == "worktree" && t ~ /^(add|remove|prune|move|lock|unlock|repair)$/) hit = 1
        if (sub1 == "remote" && t ~ /^(add|remove|rm|rename|set-url|set-head|prune|update)$/) hit = 1
        if (sub1 == "submodule" && t ~ /^(add|update|init|sync|deinit)$/) hit = 1
        if (sub1 == "reflog" && t ~ /^(expire|delete)$/) hit = 1
      }
    }
    if (hit) { flag(k, "git"); return }
  }
}
function check_gh(k, s,   j, t, api, wr) {
  CR = s
  while (nextcmd("gh")) {
    api = 0; wr = 0
    for (j = 1; j <= NA; j++) {
      t = A[j]; gsub(/["']/, "", t)
      if (t == "api") api = 1
      if (t ~ /^(close|merge|edit|comment|create|delete|reopen|review|ready|lock|unlock|rename|archive|fork|sync|set|remove|rerun|enable|disable|cancel|login|logout|upload|install|upgrade|clone|transfer|pin|unpin|develop)$/) wr = 1
      if (api && (t ~ /^(-X|--method|-f|-F|--field|--raw-field|--input)$/ || t ~ /^-X./ || t ~ /^--method=/)) wr = 1
    }
    if (wr) { flag(k, "gh"); return }
  }
}
function check_curl(k, s,   j, t, nt) {
  CR = s
  while (nextcmd("curl")) {
    for (j = 1; j <= NA; j++) {
      t = A[j]; gsub(/["']/, "", t)
      if (t ~ /^(-X|--request|-d|--data|--data-raw|--data-binary|--data-urlencode|-F|--form|-T|--upload-file|-O|--remote-name)$/ || t ~ /^-X./ || t ~ /^--(request|data[a-z-]*|form|upload-file)=/) { flag(k, "curl"); return }
      if (t == "-o" || t == "--output") { nt = A[j + 1]; if (!is_sink(nt)) { flag(k, "curl"); return } }
    }
  }
}
function check_sed(k, s,   j, t) {
  CR = s
  while (nextcmd("sed")) {
    for (j = 1; j <= NA; j++) {
      t = A[j]; gsub(/["']/, "", t)
      if (t ~ /^-[A-Za-z]*i[A-Za-z.]*$/ || t ~ /^--in-place/) { flag(k, "sed-i"); return }
    }
  }
}
function check_find(k, s,   j, t) {
  CR = s
  while (nextcmd("find")) {
    for (j = 1; j <= NA; j++) {
      t = A[j]; gsub(/["']/, "", t)
      if (t == "-delete" || t ~ /^-fprint/ || t == "-fls") { flag(k, "find-delete"); return }
    }
  }
}
function check_targets(k, s, name, cls, mode,   j, n, ok, last) {
  # mode "all": every operand sink-or-temp; "last": last operand temp; "stampok": temp or stamp
  CR = s
  while (nextcmd(name)) {
    n = 0; ok = 1; last = ""
    for (j = 1; j <= NA; j++) {
      if (A[j] == "") continue
      if (A[j] ~ /^-/) {
        if (mode == "last" && A[j] ~ /^(-t|--target-directory.*)$/) ok = 0
        continue
      }
      n++; last = A[j]
      if (mode == "all" && !is_temp(A[j])) ok = 0
      if (mode == "stampok" && !(is_temp(A[j]) || is_stamp(A[j]))) ok = 0
      if (mode == "tee" && !is_sink(A[j])) ok = 0
    }
    if (mode == "last") { if (!is_temp(last)) ok = 0 }
    if (mode != "tee" && n == 0) ok = 0
    if (!ok) { flag(k, cls); return }
  }
}

# redirections outside quotes, $(( )), (( )) and [[ ]]
function check_redirects(k, s, q0,   len, p, c, qq, arith, dbr, j, nxt, tgt, tq, ch) {
  len = length(s); qq = q0; arith = 0; dbr = 0
  for (p = 1; p <= len; p++) {
    c = substr(s, p, 1)
    if (qq != "") {
      if (c == "\\" && qq == DQ) { p++; continue }
      if (c == qq) qq = ""
      continue
    }
    if (c == "\\") { p++; continue }
    if (c == SQ || c == DQ) { qq = c; continue }
    if (substr(s, p, 2) == "((") { arith++; p++; continue }
    if (arith > 0 && substr(s, p, 2) == "))") { arith--; p++; continue }
    if (arith > 0) continue
    if (substr(s, p, 2) == "[[" && substr(s, p, 3) != "[[:") { dbr++; p++; continue }
    if (dbr > 0 && substr(s, p, 2) == "]]") { dbr--; p++; continue }
    if (dbr > 0) continue
    if (c != ">") continue
    j = p + 1
    if (substr(s, j, 1) == "(") { flag(k, "redirect"); p = j; continue }
    if (substr(s, j, 1) == ">") j++
    if (substr(s, j, 1) == "|") j++
    if (substr(s, j, 1) == "&") {
      nxt = substr(s, j + 1, 1)
      if (nxt ~ /[0-9-]/) { p = j + 1; continue }
      j++
    }
    while (substr(s, j, 1) ~ /[ \t]/) j++
    tgt = ""; tq = ""
    while (j <= length(s)) {
      ch = substr(s, j, 1)
      if (tq == "") {
        if (ch ~ /[ \t;&|()<>]/) break
        if (ch == SQ || ch == DQ) tq = ch
      } else if (ch == tq) tq = ""
      tgt = tgt ch; j++
    }
    if (!is_sink(tgt)) flag(k, "redirect")
    p = j - 1
  }
}

END {
  # ---- logical lines: continuation joined, heredoc bodies marked ----
  nl = 0; hd = ""; q = ""; i = 1
  while (i <= NR) {
    line = rawl[i]; ln = i; i++
    if (hd != "") {
      chk = line; if (hdtab) sub(/^\t+/, "", chk)
      if (chk == hd) { hd = ""; continue }
      nl++; LG[nl] = line; RAWL[nl] = line; LN[nl] = ln; HB[nl] = hdq ? 2 : 1; Q0[nl] = ""
      continue
    }
    nl++; Q0[nl] = q
    s = strip(line)
    while (s ~ /\\$/ && i <= NR) { sub(/\\$/, " ", s); s = s " " strip(rawl[i]); i++ }
    LG[nl] = s; RAWL[nl] = line; LN[nl] = ln; HB[nl] = 0
    if (match(s, /<<-?[ \t]*["']?[A-Za-z_][A-Za-z0-9_]*["']?/) && (RSTART == 1 || substr(s, RSTART - 1, 1) != "<")) {
      tok = substr(s, RSTART, RLENGTH)
      hdtab = (tok ~ /^<<-/)
      hdq = (tok ~ /["']/)
      gsub(/^<<-?[ \t]*/, "", tok); gsub(/["']/, "", tok)
      hd = tok
    }
  }
  for (k = 1; k <= nl; k++) if (HB[k] != 2) collect(LG[k])
  for (k = 1; k <= nl; k++) {
    if (HB[k] == 2) continue
    s = LG[k]
    if (HB[k] == 1 && s !~ /[$][(]|`/) continue
    if (s ~ /^[ \t]*$/) continue
    check_targets(k, s, "rm", "rm", "all")
    check_targets(k, s, "mv", "mv", "all")
    check_targets(k, s, "cp", "cp", "last")
    check_targets(k, s, "mkdir|touch", "mkdir", "stampok")
    check_targets(k, s, "tee", "tee", "tee")
    check_git(k, s); check_gh(k, s); check_curl(k, s); check_sed(k, s); check_find(k, s)
    flagify(k, s, "launchctl", "launchctl")
    flagify(k, s, "chmod", "chmod")
    flagify(k, s, "chown|chgrp", "chown")
    flagify(k, s, "kill|pkill|killall", "kill")
    flagify(k, s, "eval", "eval")
    flagify(k, s, "source|\\.", "source")
    flagify(k, s, "bash|sh|zsh|dash|ksh", "shell")
    flagify(k, s, "python[0-9.]*|Rscript|perl|ruby|node|php|osascript|lua", "interpreter")
    flagify(k, s, "ln|rmdir|truncate|dd|rsync|scp|install|unlink|shred|wget|crontab|ssh|defaults|sudo|disown", "mutating-command")
    if (s ~ /(^|[^A-Za-z0-9_])system[ \t]*\(/) flag(k, "system-call")
    if (s ~ /awk/ && match(s, /(print|printf)[^|;]*[^-=!<>|]>>?[ \t]*["$A-Za-z\/]/)) {
      if (substr(s, RSTART + RLENGTH - 1) !~ /^"?\/dev\/(null|stderr|stdout)/) flag(k, "awk-redirect")
    }
    check_redirects(k, s, Q0[k])
  }
  # ---- SQL writes anywhere in a file that invokes a database client ----
  db = 0
  for (k = 1; k <= nl; k++) {
    if (HB[k] == 2) continue
    CR = LG[k]
    if (nextcmd("duckdb|sqlite3|psql|mysql|mariadb")) db = 1
  }
  if (db) for (k = 1; k <= nl; k++) {
    s = toupper(LG[k])
    if (s ~ /(^|[^A-Z0-9_])(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|TRUNCATE|ATTACH|COPY|MERGE|GRANT|REVOKE|VACUUM)([^A-Z0-9_]|$)/ || LG[k] ~ /(^|[ \t"'])\.(output|once|import|shell|system|backup|save|restore)([ \t]|$)/) flag(k, "db-write")
  }
}
AWKEOF

# scan_one FILE -> prints violation lines to stdout; returns 0 clean, 1 violations, 3 unreadable
scan_one() {
  local f="$1" out="$W/scan.out"
  if [ ! -r "$f" ] || [ -d "$f" ]; then echo "unreadable: $f" >&2; return 3; fi
  if ! awk -f "$W/scan.awk" "$f" > "$out" 2>"$W/scan.err"; then
    echo "INDETERMINATE: the scanner failed on $f: $(head -c 200 "$W/scan.err")" >&2
    return 3
  fi
  if [ -s "$out" ]; then cat "$out"; return 1; fi
  return 0
}

# ---- list checking -----------------------------------------------------------------
# check_list LIST ROOT -> prints findings; returns 0 / 1 / 3
check_list() {
  local list="$1" root="$2" entries="$W/entries" e f rc bad=0 ind=0 n=0
  if [ ! -r "$list" ]; then echo "INDETERMINATE: list not readable: $list" >&2; return 3; fi
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$list" | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' > "$entries"
  if [ ! -s "$entries" ]; then echo "INDETERMINATE: $list holds no entry; nothing was checked (an empty list must never read as a pass)" >&2; return 3; fi
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    n=$((n + 1))
    case "$e" in
      /*|*..*|*[!A-Za-z0-9_./-]*) echo "FAIL: invalid list entry (absolute, '..' or odd characters): $e"; bad=$((bad + 1)); continue ;;
    esac
    case "$e" in
      .claude/scripts/*.sh|bin/*.sh) ;;
      *) echo "FAIL: entry outside .claude/scripts/ and bin/ or not a .sh file: $e"; bad=$((bad + 1)); continue ;;
    esac
    f="$root/$e"
    if [ -L "$f" ]; then echo "FAIL: listed script is a symlink: $e"; bad=$((bad + 1)); continue; fi
    if [ ! -f "$f" ]; then echo "FAIL: listed script is missing: $e"; bad=$((bad + 1)); continue; fi
    scan_one "$f" > "$W/found" 2>"$W/found.err"; rc=$?
    case "$rc" in
      0) echo "ok: $e" ;;
      1) echo "FAIL: $e has a mutating command:"; sed 's/^/    /' "$W/found"; bad=$((bad + 1)) ;;
      *) echo "INDETERMINATE: $e could not be scanned"; ind=$((ind + 1)) ;;
    esac
  done < "$entries"
  if [ "$bad" -gt 0 ]; then return 1; fi
  if [ "$ind" -gt 0 ]; then return 3; fi
  return 0
}

# ---- scan mode ---------------------------------------------------------------------
if [ "$MODE" = "scan" ]; then
  bad=0; ind=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    scan_one "$f" > "$W/found" 2>/dev/null; rc=$?
    case "$rc" in
      0) ;;
      1) echo "FAIL: $f"; sed 's/^/    /' "$W/found"; bad=$((bad + 1)) ;;
      *) echo "INDETERMINATE: $f"; ind=$((ind + 1)) ;;
    esac
  done <<EOF
$SCAN_FILES
EOF
  if [ "$bad" -gt 0 ]; then exit 1; fi
  if [ "$ind" -gt 0 ]; then exit 3; fi
  echo "scan: clean"
  exit 0
fi

# ---- self-test: the guard must be able to go red, and green -------------------------
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
FX="$W/fx"; mkdir -p "$FX"

red() {  # name class  (script text on stdin)
  cat > "$FX/$1.sh"
  local out rc
  out="$(scan_one "$FX/$1.sh" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | awk -F'\t' -v c="$2" '$2==c{f=1} END{exit !f}'; then ok; else bad "$1: expected RED class '$2', got rc=$rc: $out"; fi
}
green() {  # name  (script text on stdin)
  cat > "$FX/$1.sh"
  local out rc
  out="$(scan_one "$FX/$1.sh" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ]; then ok; else bad "$1: expected GREEN, got rc=$rc: $out"; fi
}

if [ "$SELFTEST" -eq 1 ]; then
  # -- RED: one fixture per mutating pattern ------------------------------------------
  red rm_abs rm <<'EOF'
rm -f /etc/hosts
EOF
  red rm_home rm <<'EOF'
rm -rf "$HOME/cache"
EOF
  red rm_unheld rm <<'EOF'
tmp=/var/data/x
rm -f "$tmp"
EOF
  red rm_other_var rm <<'EOF'
tmp=$(mktemp)
rm -f "$other"
EOF
  red rm_reassigned rm <<'EOF'
t=$(mktemp)
t=/etc/passwd
rm "$t"
EOF
  red rm_dotdot rm <<'EOF'
d=$(mktemp -d)
rm -rf "$d/../.."
EOF
  red rm_mktemp_abs_template rm <<'EOF'
t=$(mktemp /etc/foo.XXXXXX)
rm -f "$t"
EOF
  red rm_no_target rm <<'EOF'
rm -f
EOF
  red rm_xargs rm <<'EOF'
ls | xargs rm
EOF
  red rm_after_and rm <<'EOF'
[ -f x ] && rm x
EOF
  red rm_in_trap_untemp rm <<'EOF'
trap 'rm -f "$stuff"' EXIT
EOF
  red rm_abs_path_cmd rm <<'EOF'
/bin/rm -f x
EOF
  red find_delete find-delete <<'EOF'
find . -name '*.tmp' -delete
EOF
  red mv_file mv <<'EOF'
mv a b
EOF
  red mv_from_nontemp mv <<'EOF'
d=$(mktemp -d)
mv /etc/x "$d/x"
EOF
  red cp_nontemp cp <<'EOF'
cp a /etc/b
EOF
  red cp_target_dir cp <<'EOF'
d=$(mktemp -d)
cp -t /etc "$d/a"
EOF
  for v in close merge edit comment create delete reopen; do
    red "gh_$v" gh <<EOF
gh pr $v 12 --repo o/r
EOF
  done
  red gh_api_X gh <<'EOF'
gh api -X DELETE repos/o/r/issues/1
EOF
  red gh_api_method gh <<'EOF'
gh api repos/o/r/issues --method POST
EOF
  red gh_api_field gh <<'EOF'
gh api repos/o/r/issues -f title=x
EOF
  red gh_api_XPOST gh <<'EOF'
gh api -XPOST repos/o/r/issues
EOF
  for v in push commit reset checkout clean rebase merge stash add pull fetch; do
    red "git_$v" git <<EOF
git $v origin main
EOF
  done
  red git_C_push git <<'EOF'
git -C "$dir" push origin main
EOF
  red git_c_commit git <<'EOF'
git -c user.name=x commit -m y
EOF
  red git_branch_D git <<'EOF'
git branch -D old
EOF
  red git_worktree_remove git <<'EOF'
git worktree remove /x
EOF
  red launchctl launchctl <<'EOF'
launchctl kickstart gui/501/com.x
EOF
  red chmod chmod <<'EOF'
chmod 600 file
EOF
  red chown chown <<'EOF'
chown me file
EOF
  red kill kill <<'EOF'
kill -9 "$pid"
EOF
  red pkill kill <<'EOF'
pkill -f thing
EOF
  red curl_X curl <<'EOF'
curl -X POST https://example.invalid/x
EOF
  red curl_data curl <<'EOF'
curl -d a=b https://example.invalid/x
EOF
  red curl_output_file curl <<'EOF'
curl -s -o out.bin https://example.invalid/x
EOF
  red sed_i sed-i <<'EOF'
sed -i 's/a/b/' file
EOF
  red sed_i_bak sed-i <<'EOF'
sed -i.bak 's/a/b/' file
EOF
  red sed_ni sed-i <<'EOF'
sed -ni 's/a/b/p' file
EOF
  red sed_in_place sed-i <<'EOF'
sed --in-place 's/a/b/' file
EOF
  red duckdb_insert db-write <<'EOF'
duckdb db.duckdb -c "INSERT INTO t VALUES (1);"
EOF
  red duckdb_heredoc_update db-write <<'EOF'
duckdb db.duckdb <<'SQL'
update t set a = 1;
SQL
EOF
  red duckdb_multiline_delete db-write <<'EOF'
duckdb db.duckdb -c "
  SELECT 1;
  DELETE FROM t;
"
EOF
  red sqlite_drop db-write <<'EOF'
sqlite3 x.db "DROP TABLE t"
EOF
  red sqlite_create db-write <<'EOF'
sqlite3 x.db "create table t(a)"
EOF
  red duckdb_alter db-write <<'EOF'
duckdb x.db -c "ALTER TABLE t ADD COLUMN b INT"
EOF
  red redirect_file redirect <<'EOF'
echo x > out.txt
EOF
  red redirect_append redirect <<'EOF'
echo x >> out.txt
EOF
  red redirect_nonstamp_home redirect <<'EOF'
date > "$HOME/.claude/logs/other.log"
EOF
  red redirect_stamp_dotdot redirect <<'EOF'
date > "$HOME/.claude/logs/stamps/../../x.stamp"
EOF
  red redirect_both redirect <<'EOF'
cmd &> out.txt
EOF
  red redirect_clobber redirect <<'EOF'
cmd >| out.txt
EOF
  red redirect_in_subshell redirect <<'EOF'
x=$(cmd > out.txt)
EOF
  red redirect_proc_subst redirect <<'EOF'
cmd > >(cat)
EOF
  red redirect_unheld_var redirect <<'EOF'
out=/tmp/fixed
echo x > "$out"
EOF
  red redirect_stderr_to_file redirect <<'EOF'
cmd 2> err.txt
EOF
  red tee_file tee <<'EOF'
echo x | tee out.txt
EOF
  red mkdir_other mkdir <<'EOF'
mkdir -p /var/data/x
EOF
  red touch_other mkdir <<'EOF'
touch x
EOF
  red eval_cmd eval <<'EOF'
eval "$cmd"
EOF
  red source_file source <<'EOF'
source ./helper.sh
EOF
  red dot_source source <<'EOF'
. ./helper.sh
EOF
  red bash_c shell <<'EOF'
bash -c "do thing"
EOF
  red pipe_sh shell <<'EOF'
echo x | sh
EOF
  red python_inline interpreter <<'EOF'
python3 -c 'print(1)'
EOF
  red rscript_inline interpreter <<'EOF'
Rscript -e 'cat(1)'
EOF
  red awk_system system-call <<'EOF'
awk 'BEGIN { system("true") }'
EOF
  red awk_print_file awk-redirect <<'EOF'
awk '{ print $1 > "out.txt" }' in.txt
EOF
  red ln_cmd mutating-command <<'EOF'
ln -s a b
EOF
  red dd_cmd mutating-command <<'EOF'
dd if=a of=b
EOF
  red sudo_cmd mutating-command <<'EOF'
sudo true
EOF
  red continuation_hides_verb gh <<'EOF'
gh pr \
  merge 1
EOF
  red heredoc_unquoted_cmdsub rm <<'EOF'
cat <<EOT
$(rm -f /etc/x)
EOT
EOF
  red after_heredoc_body rm <<'EOF'
cat <<'EOT'
harmless text
EOT
rm -f /etc/x
EOF
  red after_trailing_comment_line rm <<'EOF'
echo ok # comment
rm -f /etc/x
EOF

  # -- GREEN: clean and tricky-but-fine scripts ----------------------------------------
  green clean_read <<'EOF'
#!/usr/bin/env bash
set -u
echo "hello"
grep -c x file
printf '%s\n' a b
awk -F'\t' '$1 > 3 {print $2}' file
sort -u file | wc -l
EOF
  green tmp_rm_trap <<'EOF'
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
echo x > "$tmp"
rm -f "$tmp"
EOF
  green tmp_two_vars_trap <<'EOF'
a=$(mktemp)
b=$(mktemp)
trap 'rm -f "$a" "$b"' EXIT
find . -type f -print > "$a" 2>/dev/null
EOF
  green tmp_dir_ops <<'EOF'
d=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")
trap 'rm -rf "$d"' EXIT
cp /etc/hosts "$d/h"
mv "$d/h" "$d/h2"
cat x | tee "$d/log" >/dev/null
rm -rf "$d/sub"
mkdir -p "$d/sub"
EOF
  green tmp_backtick <<'EOF'
t=`mktemp`
rm -f "$t"
EOF
  green tmp_local <<'EOF'
f() { local t; t=$(mktemp); echo x > "$t"; rm -f "$t"; }
EOF
  green devnull_and_dups <<'EOF'
cmd >/dev/null 2>&1
cmd 2>/dev/null
echo err >&2
echo err 1>&2
cmd > /dev/stderr
echo x >&2 | cat
EOF
  green comparisons_not_redirects <<'EOF'
[ "$a" \> "$b" ] && echo gt
[[ $a > $b ]] && echo gt
if (( x > y )); then echo gt; fi
n=$(( a > b ))
echo "a > b"
echo 'redirect > not real'
EOF
  green quoted_class_chars <<'EOF'
grep -E '[[:space:]]+>' file
case "$x" in [[:digit:]]*) echo d ;; esac
EOF
  green gh_read_only <<'EOF'
gh pr view 1 --repo o/r --json state
gh pr list --state open --json number
gh api repos/o/r/pulls/1 --jq .state
gh api repos/o/r/pulls/1/files --paginate --jq '.[].filename'
gh issue list --label "bug"
gh auth status
EOF
  green git_read_only <<'EOF'
git -C "$d" status --short
git log --oneline
git diff --no-ext-diff HEAD~1
git rev-parse --abbrev-ref HEAD
git branch --list
git branch --show-current
git worktree list
git ls-files
git show HEAD
EOF
  green duckdb_read_only <<'EOF'
duckdb -readonly db.duckdb -c "SELECT count(*) FROM t WHERE a > 1;"
EOF
  green sed_no_in_place <<'EOF'
sed -n 's/a/b/p' file
sed -E -e 's/x/y/' file
cat f | sed 's/^/  /'
EOF
  green curl_get <<'EOF'
curl -s https://example.invalid/x
curl -s -o /dev/null -w '%{http_code}' https://example.invalid/x
EOF
  green comments_hold_bad_words <<'EOF'
# rm -rf / and git push and gh pr merge and chmod 777 are only comments
echo ok # rm -rf /
echo "don't" # kill -9 1
EOF
  green quoted_heredoc_is_data <<'EOF'
cat <<'EOT'
rm -rf /
git push
EOT
echo done
EOF
  green stamp_exception <<'EOF'
mkdir -p "${HOME}/.claude/logs/stamps"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.claude/logs/stamps/wiki-health-pulse.stamp"
EOF
  green continuation_ok <<'EOF'
echo a \
  b
EOF
  green english_in_strings <<'EOF'
echo "please install the thing and kill the noise"
echo "we create a report; then update later"
EOF

  # -- the list checks ---------------------------------------------------------------
  LR="$W/lroot"; mkdir -p "$LR/.claude/scripts" "$LR/bin"
  printf '#!/usr/bin/env bash\necho hi\n' > "$LR/.claude/scripts/clean.sh"
  printf '#!/usr/bin/env bash\nrm -rf /etc/x\n' > "$LR/.claude/scripts/dirty.sh"
  ln -s clean.sh "$LR/.claude/scripts/link.sh"
  run_list() {  # list-file ; sets LRC
    bash "$SELF" --no-selftest --list "$1" --root "$LR" >"$W/list.out" 2>"$W/list.err"; LRC=$?
  }
  printf '# only comments\n\n' > "$W/l_empty"
  run_list "$W/l_empty"
  if [ "$LRC" -eq 3 ]; then ok; else bad "an empty list must be INDETERMINATE (3), got $LRC"; fi
  : > "$W/l_zero"
  run_list "$W/l_zero"
  if [ "$LRC" -eq 3 ]; then ok; else bad "a zero-byte list must be INDETERMINATE (3), got $LRC"; fi
  run_list "$W/does-not-exist"
  if [ "$LRC" -eq 3 ]; then ok; else bad "a missing list must be INDETERMINATE (3), got $LRC"; fi
  printf '.claude/scripts/clean.sh\n' > "$W/l_ok"
  run_list "$W/l_ok"
  if [ "$LRC" -eq 0 ]; then ok; else bad "a clean listed script must pass (0), got $LRC: $(cat "$W/list.out")"; fi
  printf '.claude/scripts/clean.sh\n.claude/scripts/dirty.sh\n' > "$W/l_dirty"
  run_list "$W/l_dirty"
  if [ "$LRC" -eq 1 ] && grep -q 'dirty.sh has a mutating command' "$W/list.out"; then ok; else bad "a dirty listed script must fail (1), got $LRC"; fi
  printf '.claude/scripts/gone.sh\n' > "$W/l_missing"
  run_list "$W/l_missing"
  if [ "$LRC" -eq 1 ] && grep -q 'missing' "$W/list.out"; then ok; else bad "a missing listed script must fail (1), got $LRC"; fi
  printf '.claude/scripts/link.sh\n' > "$W/l_link"
  run_list "$W/l_link"
  if [ "$LRC" -eq 1 ] && grep -q 'symlink' "$W/list.out"; then ok; else bad "a symlinked listed script must fail (1), got $LRC"; fi
  for badentry in '../outside.sh' '/etc/x.sh' '.claude/hooks/x.sh' 'R/foo.R' '.claude/scripts/a b.sh' '.claude/scripts/*.sh'; do
    printf '%s\n' "$badentry" > "$W/l_bad"
    run_list "$W/l_bad"
    if [ "$LRC" -eq 1 ]; then ok; else bad "bad list entry '$badentry' must fail (1), got $LRC"; fi
  done
  # --scan mode
  bash "$SELF" --scan "$LR/.claude/scripts/clean.sh" >/dev/null 2>&1; LRC=$?
  if [ "$LRC" -eq 0 ]; then ok; else bad "--scan of a clean file: $LRC"; fi
  bash "$SELF" --scan "$LR/.claude/scripts/clean.sh" "$LR/.claude/scripts/dirty.sh" >/dev/null 2>&1; LRC=$?
  if [ "$LRC" -eq 1 ]; then ok; else bad "--scan with a dirty file: $LRC"; fi
  bash "$SELF" --scan "$LR/no-such-file.sh" >/dev/null 2>&1; LRC=$?
  if [ "$LRC" -eq 3 ]; then ok; else bad "--scan of an unreadable file must be 3, got $LRC"; fi
  bash "$SELF" --scan >/dev/null 2>&1; LRC=$?
  if [ "$LRC" -eq 2 ]; then ok; else bad "--scan without files must be 2, got $LRC"; fi
  bash "$SELF" --bogus >/dev/null 2>&1; LRC=$?
  if [ "$LRC" -eq 2 ]; then ok; else bad "bad flag must be 2, got $LRC"; fi

  # -- falsify the falsifiers: a scanner that finds nothing must be caught -------------
  # An awk program that prints nothing makes every red case fail; the red() helper must notice.
  cp "$W/scan.awk" "$W/scan.awk.real"
  : > "$W/scan.awk"
  printf 'rm -rf /etc/x\n' > "$FX/neutered.sh"
  scan_one "$FX/neutered.sh" >/dev/null 2>&1; nrc=$?
  cp "$W/scan.awk.real" "$W/scan.awk"
  if [ "$nrc" -eq 0 ]; then ok; else bad "falsification setup: the neutered scanner should find nothing (rc=$nrc)"; fi
  scan_one "$FX/neutered.sh" >/dev/null 2>&1; rrc=$?
  if [ "$rrc" -eq 1 ]; then ok; else bad "restored scanner must flag 'rm -rf /etc/x' (rc=$rrc)"; fi

  echo "self-test: PASS=$PASS FAIL=$FAIL"
  if [ "$FAIL" -ne 0 ]; then echo "FAIL: guard self-test failed; the real list was NOT trusted"; exit 1; fi
fi

# ---- the real list ---------------------------------------------------------------------
check_list "$LIST" "$ROOT"
rc=$?
case "$rc" in
  0) echo "readonly checkers guard: PASS"; exit 0 ;;
  1) echo "readonly checkers guard: FAIL"; exit 1 ;;
  *) echo "readonly checkers guard: INDETERMINATE"; exit 3 ;;
esac
