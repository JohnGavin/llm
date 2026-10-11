#!/usr/bin/env bash
# public_repo_file_import_guard.sh -- Block putting a document, image or archive
# into a PUBLIC repo's working tree (privacy gate 4, JohnGavin/llm#1368).
# Hook: PreToolUse on Bash and on Write.
# Exit 2 = BLOCK (reason on stderr, plus a permissionDecision:"deny" JSON body
# on stdout). Exit 0 = allow.
#
# Why: the usual way a private document reaches a repo is a copy from a personal
# folder (Downloads, Desktop, iCloud, a private repo) into a public repo's
# working tree. The scanner gates (pre-commit, pre-push, CI, history audit; see
# .claude/rules/private-data-scanning.md) fire later; this fires at the moment of
# the copy, before the file is there to be committed by accident.
#
# What it checks
#   Bash : cp, mv, rsync, ditto, install, git add. The DESTINATION files are
#          derived (globs expanded, directories walked, `cd X &&` and
#          `git -C X` followed, `git add .` / `-A` enumerate untracked files).
#   Write: the target file_path.
#   A destination is blocked when ALL of:
#     1. it lies inside a git working tree (git rev-parse --show-toplevel);
#     2. that repo is PUBLIC, or visibility is UNKNOWN (lookup failed: unknown
#        counts as public, fail closed);
#     3. the file is a document format (the same list as private_data_scan.sh's
#        DOC_FORMAT_EXTS), an archive, or an image outside generated-figure
#        folders (man/figures, *_files/figure-html, docs/, _freeze/, pkgdown/);
#     4. its exact repo-relative path is not on that repo's
#        .claude/private_data_document_allowlist.txt ("<path> | <reason>").
#   A destination clearly outside any git repo is never blocked.
#
# Failure policy (checks-must-distinguish-unknown): a visibility lookup that
# errors, times out or returns anything but private/local_only/
# confidential_by_policy is treated as PUBLIC (block). An internal failure of the
# parser itself (python3 missing or crashing) fails OPEN and is logged: a broken
# guard must not wedge unrelated work. Known gaps (best effort, documented):
# redirections and tee, `ditto -x` extraction, archives unpacked by tar/unzip,
# variables in paths, and a command split across a subshell.
#
# Rename note: moving a document inside a public repo (mv docs/a.pdf docs/b.pdf)
# is also blocked unless allow-listed: the guard does not try to prove the source
# is a tracked, reviewed file.
#
# Test seams (env): PIG_VISIBILITY_CMD (executable called with the repo root,
# prints the classification), PIG_LOG_DIR.
#
# Self-test: bash public_repo_file_import_guard.sh --selftest

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$HOOK_DIR/../scripts/private_data_scan.sh"
# Fallback if the scanner cannot be read; a selftest case asserts it equals the
# scanner's DOC_FORMAT_EXTS so the two cannot drift silently.
DOC_EXTS_FALLBACK="pdf docx xlsx doc xls odt rtf eml msg"

_log() {
  local d="${PIG_LOG_DIR:-$HOME/.claude/logs}"
  mkdir -p "$d" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$d/public_repo_file_import_guard.log" 2>/dev/null || true
}

_doc_exts() {
  local line
  line="$(grep -m1 '^DOC_FORMAT_EXTS=' "$SCANNER" 2>/dev/null || true)"
  line="${line#DOC_FORMAT_EXTS=\"}"
  line="${line%\"*}"
  if [ -n "$line" ]; then printf '%s' "$line"; else printf '%s' "$DOC_EXTS_FALLBACK"; fi
}

# The parser. Reads the hook payload on stdin; prints
#   HIT<TAB>repo-root<TAB>repo-relative-path<TAB>kind
# one per offending destination file, or INTERNAL_ERROR<TAB>msg.
_parse_py() {
  cat <<'PYEOF'
import sys, os, json, re, glob, shlex, subprocess

DOC = set(os.environ.get('PIG_DOC_EXTS', '').split())
IMG = set('png jpg jpeg gif webp heic heif bmp tif tiff'.split())
ARC = set('zip tar gz tgz bz2 tbz2 xz txz zst 7z rar'.split())
MAXF = 500
IMG_EXEMPT = re.compile(r'(^|/)(docs|_freeze|pkgdown)/|(^|/)man/figures/|_files/figure-html/')


def kind(p):
    b = os.path.basename(p).lower()
    if '.' not in b:
        return None
    ext = b.rpartition('.')[2]
    if ext in DOC:
        return 'document'
    if ext in ARC:
        return 'archive'
    if ext in IMG:
        return 'image'
    return None


def run(args, timeout=10):
    return subprocess.run(args, capture_output=True, timeout=timeout)


def resolve(cwd, p):
    return os.path.normpath(os.path.join(cwd, os.path.expanduser(p)))


def remote(p):
    return bool(re.match(r'^[^/:]+:', p)) or p.startswith(('rsync://', 'ssh://'))


def toplevel_and_rel(path):
    d = os.path.dirname(path)
    anc = d
    while anc and not os.path.isdir(anc):
        parent = os.path.dirname(anc)
        if parent == anc:
            break
        anc = parent
    if not os.path.isdir(anc):
        return None
    r = run(['git', '-C', anc, 'rev-parse', '--show-toplevel'], 5)
    if r.returncode != 0:
        return None  # not in a work tree: clearly outside any repo
    top = os.path.realpath(r.stdout.decode('utf-8', 'replace').strip())
    tail = os.path.relpath(path, anc)
    target = os.path.join(os.path.realpath(anc), tail)
    rel = os.path.relpath(target, top)
    if rel.startswith('..') or rel == '.git' or rel.startswith('.git/'):
        return None
    return top, rel


_allow = {}


def allowed(top, rel):
    if top not in _allow:
        s = set()
        f = os.path.join(top, '.claude', 'private_data_document_allowlist.txt')
        try:
            with open(f, encoding='utf-8', errors='replace') as fh:
                for line in fh:
                    line = line.rstrip('\n')
                    if not line.strip() or line.startswith('#') or ' | ' not in line:
                        continue
                    p, r = line.split(' | ', 1)
                    p = p.strip()
                    if p and r.strip():
                        s.add(p)
        except OSError:
            pass
        _allow[top] = s
    return rel in _allow[top]


def walk_files(root):
    out = []
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d != '.git']
        for fn in fns:
            out.append(os.path.join(dp, fn))
            if len(out) >= MAXF:
                return out
    return out


def split_segments(cmd):
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        toks = cmd.split()
    segs, cur, i = [], [], 0
    while i < len(toks):
        t = toks[i]
        if t and all(c in ';&|()<>' for c in t):
            if '>' in t or '<' in t:
                if cur and cur[-1].isdigit():
                    cur.pop()
                i += 2  # skip the redirect target; the segment continues
                continue
            if cur:
                segs.append(cur)
                cur = []
        else:
            cur.append(t)
        i += 1
    if cur:
        segs.append(cur)
    return segs


VAL_OPTS = {
    'cp': {'-S', '--suffix'}, 'mv': {'-S', '--suffix'}, 'ditto': set(),
    'install': {'-m', '-o', '-g', '-S', '--mode', '--owner', '--group', '--suffix'},
    'rsync': {'-e', '--rsh', '--exclude', '--include', '--filter', '-f', '--exclude-from',
              '--include-from', '--files-from', '--port', '--rsync-path', '--log-file',
              '--backup-dir', '--partial-dir', '--temp-dir', '--compare-dest', '--link-dest',
              '--copy-dest', '--bwlimit', '--chmod', '--chown', '--max-size', '--min-size',
              '--timeout', '-B', '--block-size'},
}


def copy_candidates(verb, args, cwd):
    pos, tdir, dd, j = [], None, False, 0
    while j < len(args):
        a = args[j]
        if dd:
            pos.append(a)
        elif a == '--':
            dd = True
        elif a in ('-t', '--target-directory'):
            tdir = args[j + 1] if j + 1 < len(args) else None
            j += 1
        elif a.startswith('--target-directory='):
            tdir = a.split('=', 1)[1]
        elif a in VAL_OPTS[verb]:
            j += 1
        elif a.startswith('-') and len(a) > 1:
            pass
        else:
            pos.append(a)
        j += 1
    if verb == 'ditto' and any(a in ('-x', '-V') or re.match(r'^-[a-zA-Z]*x', a) for a in args if a.startswith('-')):
        return []  # extraction: destination contents unknown (documented gap)
    if tdir is not None:
        dest, srcs = tdir, pos
    else:
        if len(pos) < 2:
            return []
        dest, srcs = pos[-1], pos[:-1]
    if remote(dest) or not srcs:
        return []
    destp = resolve(cwd, dest)
    expanded = []
    for s in srcs:
        sp = resolve(cwd, s)
        g = [] if remote(s) else sorted(glob.glob(sp))
        if g:
            expanded += [(x, s.endswith('/')) for x in g]
        else:
            expanded.append((sp, s.endswith('/')))
    dir_dest = tdir is not None or dest.endswith('/') or os.path.isdir(destp) or len(expanded) > 1
    out = []
    for sp, slash in expanded:
        if os.path.isdir(sp):
            base = destp if (slash and verb == 'rsync') or not dir_dest else os.path.join(destp, os.path.basename(sp))
            for f in walk_files(sp):
                out.append((os.path.join(base, os.path.relpath(f, sp)), False))
        elif dir_dest:
            out.append((os.path.join(destp, os.path.basename(sp)), False))
        else:
            out.append((destp, False))
    return out


def git_candidates(args, cwd):
    k, gdir = 0, None
    while k < len(args):
        a = args[k]
        if a == '-C':
            gdir = args[k + 1] if k + 1 < len(args) else None
            k += 2
            continue
        if a in ('-c', '--git-dir', '--work-tree', '--namespace'):
            k += 2
            continue
        if a.startswith('-'):
            k += 1
            continue
        break
    if k >= len(args) or args[k] != 'add':
        return []
    rest = args[k + 1:]
    base = resolve(cwd, gdir) if gdir else cwd
    all_flag = any(a in ('-A', '--all') for a in rest)
    specs, dd = [], False
    for a in rest:
        if dd:
            specs.append(a)
        elif a == '--':
            dd = True
        elif a.startswith('-'):
            continue
        else:
            specs.append(a)

    def untracked(where, spec=None):
        cmd = ['git', '-C', where, 'ls-files', '-z', '--others', '--exclude-standard']
        if spec is not None:
            cmd += ['--', spec]
        r = run(cmd)
        if r.returncode != 0:
            return []
        names = [x for x in r.stdout.decode('utf-8', 'replace').split('\0') if x]
        return [(os.path.join(where, n), True) for n in names[:MAXF]]

    out = []
    if all_flag:
        t = run(['git', '-C', base, 'rev-parse', '--show-toplevel'], 5)
        if t.returncode == 0:
            out += untracked(t.stdout.decode('utf-8', 'replace').strip())
    for s in specs:
        p = resolve(base, s)
        if s in ('.', './') or os.path.isdir(p):
            out += untracked(base, s)
        else:
            g = sorted(glob.glob(p)) or [p]
            for x in g:
                if os.path.isdir(x):
                    out += untracked(base, os.path.relpath(x, base))
                elif os.path.exists(x):
                    out.append((x, True))
    return out


def candidates(payload):
    ti = payload.get('tool_input') or {}
    cwd = payload.get('cwd') or os.getcwd()
    if payload.get('tool_name') == 'Write' or ('file_path' in ti and 'command' not in ti):
        fp = ti.get('file_path') or ''
        return [(resolve(cwd, fp), False)] if fp else []
    cmd = ti.get('command') or payload.get('command') or ''
    out = []
    for seg in split_segments(cmd):
        i = 0
        while i < len(seg) and (re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', seg[i]) or
                                seg[i] in ('sudo', 'command', 'env', 'time', 'nohup', 'exec', 'builtin')):
            i += 1
        if i >= len(seg):
            continue
        verb, args = os.path.basename(seg[i]), seg[i + 1:]
        if verb == 'cd' and args and args[0] != '-':
            cwd = resolve(cwd, args[0])
        elif verb in VAL_OPTS:
            out += copy_candidates(verb, args, cwd)
        elif verb == 'git':
            out += git_candidates(args, cwd)
        if len(out) >= MAXF:
            break
    return out


def tracked(top, rel):
    r = run(['git', '-C', top, 'ls-files', '--error-unmatch', '--', rel], 5)
    return r.returncode == 0


def main():
    try:
        payload = json.loads(sys.stdin.read())
    except Exception:
        return
    if not isinstance(payload, dict):
        return
    seen = set()
    for path, from_git in candidates(payload):
        k = kind(path)
        if not k:
            continue
        tr = toplevel_and_rel(path)
        if not tr:
            continue
        top, rel = tr
        if (top, rel) in seen:
            continue
        seen.add((top, rel))
        if k == 'image' and IMG_EXEMPT.search(rel):
            continue
        if allowed(top, rel):
            continue
        if from_git and tracked(top, rel):
            continue
        print('HIT\t%s\t%s\t%s' % (top, rel, k))


try:
    main()
except Exception as e:  # parser failure: reported, caller fails open
    print('INTERNAL_ERROR\t%s' % e)
PYEOF
}

_visibility() {
  # $1 = repo root. Prints the classification; any failure prints "unknown".
  local out
  if [ -n "${PIG_VISIBILITY_CMD:-}" ]; then
    out="$(timeout 12 "$PIG_VISIBILITY_CMD" "$1" 2>/dev/null)" || out=""
  else
    out="$(timeout 12 bash "$HOOK_DIR/../scripts/repo_visibility.sh" classify "$1" 2>/dev/null)" || out=""
  fi
  out="${out%%$'\n'*}"
  case "$out" in
    public|private|local_only|confidential_by_policy|unknown) printf '%s' "$out" ;;
    *) printf 'unknown' ;;
  esac
}

main() {
  local payload
  payload="$(cat 2>/dev/null || true)"
  [ -n "$payload" ] || exit 0

  # ── fast path: pure bash, no subprocess ───────────────────────────────────
  local trigger=0
  if [[ "$payload" =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"Write\" ]]; then
    if [[ "$payload" =~ \"file_path\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
      local fp="${BASH_REMATCH[1]}" saved
      saved="$(shopt -p nocasematch)"
      shopt -s nocasematch
      case "$fp" in
        *.pdf|*.docx|*.xlsx|*.doc|*.xls|*.odt|*.rtf|*.eml|*.msg|*.png|*.jpg|*.jpeg|*.gif|*.webp|*.heic|*.heif|*.bmp|*.tif|*.tiff|*.zip|*.tar|*.gz|*.tgz|*.bz2|*.tbz2|*.xz|*.txz|*.zst|*.7z|*.rar) trigger=1 ;;
      esac
      eval "$saved"
    fi
  else
    case "$payload" in
      *"cp "*|*"mv "*|*rsync*|*ditto*|*"install "*) trigger=1 ;;
      *git*" add"*) trigger=1 ;;
    esac
  fi
  [ "$trigger" = 1 ] || exit 0

  # ── slow path: parse, then resolve repo + visibility ──────────────────────
  local hits
  hits="$(printf '%s' "$payload" | PIG_DOC_EXTS="$(_doc_exts)" python3 -c "$(_parse_py)" 2>/dev/null)" || {
    _log "INTERNAL python3 failed; allowing"
    exit 0
  }
  [ -n "$hits" ] || exit 0
  case "$hits" in
    *INTERNAL_ERROR*) _log "INTERNAL parser error: ${hits//$'\n'/ }; allowing"; exit 0 ;;
  esac

  local line top rel kind vis lines="" seen_tops="" blocked=0
  local vis_cache=""   # "top<TAB>vis" lines
  while IFS=$'\t' read -r _ top rel kind; do
    [ -n "$top" ] || continue
    vis="$(printf '%s\n' "$vis_cache" | awk -F'\t' -v t="$top" '$1==t{print $2; exit}')"
    if [ -z "$vis" ]; then
      vis="$(_visibility "$top")"
      vis_cache="${vis_cache}${top}"$'\t'"${vis}"$'\n'
    fi
    case "$vis" in
      private|local_only|confidential_by_policy) continue ;;
    esac
    blocked=$((blocked + 1))
    lines="${lines}  - ${kind}: ${rel}  (repo ${top}, visibility: ${vis}$([ "$vis" = unknown ] && printf ', treated as public'))"$'\n'
  done <<< "$hits"

  [ "$blocked" -gt 0 ] || exit 0

  _log "BLOCK n=$blocked $(printf '%s' "$lines" | tr '\n' ';' | cut -c1-300)"
  local reason
  reason="BLOCKED: putting a document, image or archive into a PUBLIC repo's working tree (llm#1368).
${lines}
These file types can hold personal data that no text scan sees. If the file is
genuinely meant to be published, add its exact repo-relative path to that
repo's .claude/private_data_document_allowlist.txt as '<path> | <reason>' and
retry. Otherwise keep it outside the repo or in a private one.
Rule: .claude/rules/private-data-scanning.md"
  printf '%s\n' "$reason" >&2
  python3 -c 'import json,sys
print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":sys.argv[1]}}))' "$reason" 2>/dev/null || true
  exit 2
}

# ─── self-test ───────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  T="$(mktemp -d /tmp/pig_selftest_XXXXXX)"
  export PIG_LOG_DIR="$T/logs"
  pass=0; fail=0
  SELF="${BASH_SOURCE[0]}"

  # Stub visibility: the repo's basename decides. Every call is recorded.
  cat > "$T/stubvis.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "${PIG_STUB_CALLS:?}"
case "$(basename "$1")" in
  pubrepo)  echo public ;;
  privrepo) echo private ;;
  unkrepo)  exit 1 ;;
  junkrepo) echo "weird-value" ;;
  *)        echo "${PIG_STUB_DEFAULT:-private}" ;;
esac
STUB
  chmod +x "$T/stubvis.sh"
  export PIG_STUB_CALLS="$T/calls.txt"; : > "$PIG_STUB_CALLS"
  export PIG_VISIBILITY_CMD="$T/stubvis.sh"

  for r in pubrepo privrepo unkrepo junkrepo; do
    mkdir -p "$T/$r"; git -C "$T/$r" init -q 2>/dev/null
  done
  mkdir -p "$T/plain" "$T/outside"
  : > "$T/outside/a.pdf"; : > "$T/outside/b.docx"; : > "$T/outside/c.xlsx"
  : > "$T/outside/p.png"; : > "$T/outside/z.zip"; : > "$T/outside/n.txt"; : > "$T/outside/d.csv"
  mkdir -p "$T/outside/folder"; : > "$T/outside/folder/inner.pdf"

  # _run NAME WANT-EXIT JSON  -> checks exit code
  _run() {
    local rc
    printf '%s' "$3" | bash "$SELF" >"$T/out.txt" 2>"$T/err.txt"; rc=$?
    if [ "$rc" = "$2" ]; then pass=$((pass+1)); echo "  PASS $1"
    else fail=$((fail+1)); echo "  FAIL $1 (exit $rc, want $2) stderr: $(head -c 200 "$T/err.txt")"; fi
  }
  # _bash NAME WANT CWD CMD ; _write NAME WANT PATH
  _bash()  { _run "$1" "$2" "$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$3" "$4")"; }
  _write() { _run "$1" "$2" "$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Write","cwd":"/tmp","tool_input":{"file_path":sys.argv[1],"content":"x"}}))' "$3")"; }

  echo "public_repo_file_import_guard selftest:"
  P="$T/pubrepo"; V="$T/privrepo"; U="$T/unkrepo"; O="$T/outside"

  # --- verbs into a public repo -------------------------------------------
  _bash "cp pdf into public repo blocks"          2 "$T" "cp $O/a.pdf $P/"
  _bash "cp to explicit file name blocks"         2 "$T" "cp $O/a.pdf $P/renamed.pdf"
  _bash "cp to nonexistent subdir blocks"         2 "$T" "cp $O/a.pdf $P/newdir/x.pdf"
  _bash "mv docx blocks"                          2 "$T" "mv $O/b.docx $P/"
  _bash "rsync xlsx blocks"                       2 "$T" "rsync -av $O/c.xlsx $P/"
  _bash "ditto pdf blocks"                        2 "$T" "ditto $O/a.pdf $P/a.pdf"
  _bash "install pdf blocks"                      2 "$T" "install -m 644 $O/a.pdf $P/"
  _bash "cp -t DIR blocks"                        2 "$T" "cp -t $P $O/a.pdf"
  _bash "glob source expands and blocks"          2 "$T" "cp $O/*.xlsx $P/"
  _bash "cp -r directory walks and blocks"        2 "$T" "cp -r $O/folder $P/"
  _bash "cd then relative cp blocks"              2 "$T" "cd $P && cp ../outside/a.pdf ."
  _bash "second command of a compound blocks"     2 "$T" "cp $O/n.txt $P/ && cp $O/a.pdf $P/"
  _bash "redirect fd does not shift the dest"     2 "$T" "cp $O/a.pdf $P/ 2>&1"
  _bash "env prefix and sudo are skipped"         2 "$T" "FOO=1 sudo cp $O/a.pdf $P/"
  # --- deny JSON ------------------------------------------------------------
  printf '%s' "{\"tool_name\":\"Bash\",\"cwd\":\"$T\",\"tool_input\":{\"command\":\"cp $O/a.pdf $P/\"}}" | bash "$SELF" >"$T/out.txt" 2>/dev/null
  if python3 -c 'import json,sys;d=json.load(open(sys.argv[1]))["hookSpecificOutput"];assert d["permissionDecision"]=="deny" and d["hookEventName"]=="PreToolUse" and "a.pdf" in d["permissionDecisionReason"]' "$T/out.txt" 2>/dev/null
  then pass=$((pass+1)); echo "  PASS deny JSON is valid and names the file"
  else fail=$((fail+1)); echo "  FAIL deny JSON ($(head -c 200 "$T/out.txt"))"; fi

  # --- visibility handling --------------------------------------------------
  _bash "private repo allows"                     0 "$T" "cp $O/a.pdf $V/"
  _bash "unknown visibility (lookup fails) blocks" 2 "$T" "cp $O/a.pdf $U/"
  mkdir -p "$T/junkrepo"
  _bash "garbage lookup output blocks"            2 "$T" "cp $O/a.pdf $T/junkrepo/"
  PIG_VISIBILITY_CMD="$T/does-not-exist" _bash "missing lookup command blocks" 2 "$T" "cp $O/a.pdf $P/"
  printf '#!/usr/bin/env bash\necho public\n' > "$T/allpublic.sh"; chmod +x "$T/allpublic.sh"
  PIG_VISIBILITY_CMD="$T/allpublic.sh" _bash "falsify: lookup says public for the private repo -> same command blocks" 2 "$T" "cp $O/a.pdf $V/"
  # --- outside any repo ------------------------------------------------------
  _bash "dest outside any repo allows"            0 "$T" "cp $O/a.pdf $T/plain/"
  _bash "dest in a not-yet-existing dir outside a repo allows" 0 "$T" "cp $O/a.pdf $T/plain/new/sub/a.pdf"
  _bash "remote rsync dest allows"                0 "$T" "rsync $O/a.pdf host:/srv/"
  # --- file types ------------------------------------------------------------
  _bash "txt allows"                              0 "$T" "cp $O/n.txt $P/"
  _bash "csv allows"                              0 "$T" "cp $O/d.csv $P/"
  _bash "image at repo root blocks"               2 "$T" "cp $O/p.png $P/"
  _bash "image in man/figures allows"             0 "$T" "cp $O/p.png $P/man/figures/"
  _bash "image in docs/ allows"                   0 "$T" "cp $O/p.png $P/docs/"
  _bash "image in x_files/figure-html allows"     0 "$T" "cp $O/p.png $P/report_files/figure-html/"
  _bash "image in _freeze allows"                 0 "$T" "cp $O/p.png $P/_freeze/"
  _bash "image in pkgdown allows"                 0 "$T" "cp $O/p.png $P/pkgdown/"
  _bash "archive blocks"                          2 "$T" "cp $O/z.zip $P/"
  _bash "a PDF in docs/ still blocks (exemption is images only)" 2 "$T" "cp $O/a.pdf $P/docs/"
  # --- allow-list -------------------------------------------------------------
  mkdir -p "$P/.claude"
  printf '%s\n' "# comment" "renamed.pdf | published methodology note, reviewed" "bare.pdf" "noreason.pdf | " > "$P/.claude/private_data_document_allowlist.txt"
  _bash "allow-listed path (with reason) allows"  0 "$T" "cp $O/a.pdf $P/renamed.pdf"
  _bash "bare allow-list line (no reason) allows nothing" 2 "$T" "cp $O/a.pdf $P/bare.pdf"
  _bash "empty reason allows nothing"             2 "$T" "cp $O/a.pdf $P/noreason.pdf"
  _bash "allow-list is exact-path, not by name"   2 "$T" "cp $O/a.pdf $P/sub/renamed.pdf"
  rm -f "$P/.claude/private_data_document_allowlist.txt"
  _bash "falsify: allow-list removed -> same command blocks" 2 "$T" "cp $O/a.pdf $P/renamed.pdf"
  # --- git add ----------------------------------------------------------------
  : > "$P/new.pdf"; : > "$P/keep.txt"
  _bash "git add explicit untracked pdf blocks"   2 "$P" "git add new.pdf"
  _bash "git -C add explicit pdf blocks"          2 "$T" "git -C $P add new.pdf"
  _bash "git add . with an untracked pdf blocks"  2 "$P" "git add ."
  _bash "git add -A with an untracked pdf blocks" 2 "$T" "git -C $P add -A"
  _bash "git add of a txt only allows"            0 "$P" "git add keep.txt"
  git -C "$P" -c user.email=a@b.c -c user.name=n add -f new.pdf >/dev/null 2>&1
  git -C "$P" -c user.email=a@b.c -c user.name=n commit -q -m seed >/dev/null 2>&1
  _bash "git add of an already tracked pdf allows" 0 "$P" "git add new.pdf"
  _bash "git add . with nothing untracked allows" 0 "$P" "git add ."
  : > "$V/new.pdf"
  _bash "git add pdf in a private repo allows"    0 "$V" "git add new.pdf"
  # --- Write tool -------------------------------------------------------------
  _write "Write pdf into public repo blocks"      2 "$P/out.pdf"
  _write "Write uppercase extension blocks"       2 "$P/OUT.PDF"
  _write "Write pdf into private repo allows"     0 "$V/out.pdf"
  _write "Write pdf outside any repo allows"      0 "$T/plain/out.pdf"
  _write "Write txt into public repo allows"      0 "$P/out.txt"
  _write "Write png into man/figures allows"      0 "$P/man/figures/x.png"
  _write "Write png at public root blocks"        2 "$P/x.png"
  # --- fast path ----------------------------------------------------------------
  : > "$PIG_STUB_CALLS"
  _bash "unrelated command allows"                0 "$P" "ls -la $P"
  _bash "npm install allows (verb matches, no file)" 0 "$P" "npm install left-pad"
  _bash "git status allows"                       0 "$P" "git status --short"
  _write "Write of .R allows"                     0 "$P/x.R"
  if [ ! -s "$PIG_STUB_CALLS" ]; then pass=$((pass+1)); echo "  PASS non-matching commands never reached the visibility lookup"
  else fail=$((fail+1)); echo "  FAIL visibility lookup ran for a non-matching command"; fi
  _run "empty payload allows"                     0 ''
  _run "malformed payload allows"                 0 'not json'
  _run "empty JSON object allows"                 0 '{}'
  # --- drift: document list equals the scanner's ----------------------------------
  scanner_exts="$(grep -m1 '^DOC_FORMAT_EXTS=' "$SCANNER" 2>/dev/null | sed 's/^DOC_FORMAT_EXTS="//; s/"$//')"
  if [ -n "$scanner_exts" ] && [ "$scanner_exts" = "$DOC_EXTS_FALLBACK" ] && [ "$(_doc_exts)" = "$scanner_exts" ]
  then pass=$((pass+1)); echo "  PASS document list matches private_data_scan.sh DOC_FORMAT_EXTS"
  else fail=$((fail+1)); echo "  FAIL document list drifted: scanner='$scanner_exts' fallback='$DOC_EXTS_FALLBACK'"; fi

  rm -rf "$T"
  echo "  ---"
  echo "  $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

main "$@"
