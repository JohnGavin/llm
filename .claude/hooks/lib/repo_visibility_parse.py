#!/usr/bin/env python3
"""repo_visibility_parse.py -- decide whether a Bash command makes a repo PUBLIC.

Used by .claude/hooks/repo_visibility_guard.sh (llm#1392). Reads the hook's JSON
payload on stdin and prints KEY=VALUE lines (no value ever contains a newline):

  TRANSITION=none      the command does not flip a repo to public
  TRANSITION=public    it does (or might: a visibility value that is not the
                       literal private/internal counts as public)
  TRANSITION=error     a cue word is present but the command could not be
                       understood; the caller must treat this as INDETERMINATE
  KIND=edit|create|api
  REPO=<owner/name | name | empty>   target as written in the command
  NEED_CWD=1           the command names no repo; use the working directory's
  SRC=<dir>            create only: the --source directory ("" = none given)
  UNKNOWN=1            the target repo could not be read from the command
  NOTE=<short reason>
  CWD=<payload cwd>

Forms covered: gh repo edit [REPO] --visibility V (flag before or after,
--accept-visibility-change-consequences), gh api <repos/O/R> with a visibility
field (-f/-F/--field/--raw-field) or --input body, gh repo create|new with
--public or with no visibility flag at all, the same inside bash -c / eval /
$(...) / xargs and after env, sudo, command, nohup, time, and compound lists.

Honest limits: a body read from a file or a pipe (--input) is only seen when the
word "visibility" appears in the same command; a script file or a shell
variable holding the command is not followed.

Never prints matched file content. No dependency beyond the standard library.
"""
import json
import os
import re
import sys

CUES = ("visibility", "--public")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
WRAPPERS = {"env", "sudo", "command", "nohup", "time", "exec", "nice", "timeout",
            "builtin", "xargs", "stdbuf"}
MAX_DEPTH = 4

EDIT_VALUE_FLAGS = {"--visibility", "-d", "--description", "-h", "--homepage",
                    "--default-branch", "--add-topic", "--remove-topic"}
CREATE_VALUE_FLAGS = {"-d", "--description", "-g", "--gitignore", "-h", "--homepage",
                      "-l", "--license", "-r", "--remote", "-s", "--source", "-t",
                      "--team", "-p", "--template"}
API_VALUE_FLAGS = {"-X", "--method", "-f", "--raw-field", "-F", "--field", "-H",
                   "--header", "--input", "-q", "--jq", "-t", "--template",
                   "--hostname", "--cache", "-p", "--preview"}


class Unparseable(Exception):
    pass


def tokenize(cmd):
    """Split a command line into segments of tokens.

    Returns (segments, heredoc_scripts). Quotes are honoured, an unquoted
    newline ; & | ( ) or backtick ends a segment, heredoc bodies are skipped
    unless the command feeds a shell (their text is returned for re-parsing).
    """
    segs = [[]]
    tok = []
    has = [False]
    pending = []          # (delimiter, strip_tabs, keep)
    scripts = []
    n = len(cmd)
    i = 0
    q = None

    def end_tok():
        if has[0]:
            segs[-1].append("".join(tok))
        del tok[:]
        has[0] = False

    def end_seg():
        end_tok()
        if segs[-1]:
            segs.append([])

    while i < n:
        c = cmd[i]
        if q == "'":
            if c == "'":
                q = None
            else:
                tok.append(c)
            i += 1
            continue
        if q == '"':
            if c == '"':
                q = None
            elif c == "\\" and i + 1 < n and cmd[i + 1] in '"\\$`':
                tok.append(cmd[i + 1])
                i += 1
            else:
                tok.append(c)
            i += 1
            continue
        if c == "'":
            q = "'"
            has[0] = True
        elif c == '"':
            q = '"'
            has[0] = True
        elif c == "\\":
            if i + 1 < n:
                if cmd[i + 1] != "\n":
                    tok.append(cmd[i + 1])
                    has[0] = True
                i += 1
        elif c in " \t\r":
            end_tok()
        elif c == "<" and cmd.startswith("<<", i) and not cmd.startswith("<<<", i):
            m = re.match(r"<<(-?)[ \t]*(?:'([^']*)'|\"([^\"]*)\"|([A-Za-z0-9_]+))", cmd[i:])
            if m:
                delim = m.group(2) or m.group(3) or m.group(4) or ""
                first = ""
                for t in segs[-1] + ([ "".join(tok) ] if has[0] else []):
                    if "=" in t and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
                        continue
                    first = os.path.basename(t)
                    break
                pending.append((delim, m.group(1) == "-", first in SHELLS))
                i += len(m.group(0))
                continue
            tok.append(c)
            has[0] = True
        elif c == "\n":
            end_seg()
            if pending:
                for delim, strip, keep in pending:
                    body = []
                    j = i + 1
                    found = False
                    while j <= n:
                        k = cmd.find("\n", j)
                        line = cmd[j:] if k < 0 else cmd[j:k]
                        cmp_line = line.lstrip("\t") if strip else line
                        j = n + 1 if k < 0 else k + 1
                        if cmp_line == delim:
                            found = True
                            break
                        body.append(line)
                    if keep:
                        scripts.append("\n".join(body))
                    i = j - 1 if found else n
                del pending[:]
        elif c in ";&|()`":
            end_seg()
        else:
            tok.append(c)
            has[0] = True
        i += 1
    if q:
        raise Unparseable("unbalanced quote")
    end_seg()
    return [s for s in segs if s], scripts


def split_flags(args, value_flags):
    """-> (list of (flag, value-or-None), positionals). Unknown flags are boolean."""
    flags, pos = [], []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            pos.extend(args[i + 1:])
            break
        if a.startswith("--") and "=" in a:
            k, v = a.split("=", 1)
            flags.append((k, v))
        elif a.startswith("-") and len(a) > 1:
            if a in value_flags and i + 1 < len(args):
                flags.append((a, args[i + 1]))
                i += 1
            else:
                flags.append((a, None))
        else:
            pos.append(a)
        i += 1
    return flags, pos


NAME = r"[A-Za-z0-9._-]+"


def norm_repo(arg):
    """owner/name, a bare name, or '' (unknown form). URL forms are unwrapped."""
    if not arg:
        return ""
    a = re.sub(r"^(https?://|git@)[^/:]+[/:]", "", arg)
    a = re.sub(r"\.git/?$", "", a).strip("/")
    if re.fullmatch(NAME + "/" + NAME, a) or re.fullmatch(NAME, a):
        return a
    return ""


def analyze_gh(args, whole):
    out = []
    while args and args[0].startswith("-"):
        args = args[2:] if args[0] in ("-R", "--repo", "--hostname") else args[1:]
    if len(args) >= 2 and args[0] == "repo" and args[1] == "edit":
        flags, pos = split_flags(args[2:], EDIT_VALUE_FLAGS)
        vis = [v for k, v in flags if k == "--visibility"]
        if not vis:
            return out
        if (vis[-1] or "").lower() in ("private", "internal"):
            return out
        repo = norm_repo(pos[0]) if pos else ""
        out.append({"kind": "edit", "repo": repo, "need_cwd": not pos,
                    "unknown": bool(pos) and not repo, "src": "",
                    "note": "gh repo edit --visibility %s" % (vis[-1] or "?")})
    elif len(args) >= 2 and args[0] == "repo" and args[1] in ("create", "new"):
        flags, pos = split_flags(args[2:], CREATE_VALUE_FLAGS)
        names = [k for k, _ in flags]
        if "--private" in names or "--internal" in names:
            if "--public" not in names:
                return out
        src = ""
        for k, v in flags:
            if k in ("-s", "--source"):
                src = v or ""
        note = "gh repo create --public" if "--public" in names else \
            "gh repo create without --private/--internal (gh does not default to private)"
        repo = norm_repo(pos[0]) if pos else ""
        out.append({"kind": "create", "repo": repo, "need_cwd": False,
                    "unknown": bool(pos) and not repo, "src": src, "note": note})
    elif args and args[0] == "api":
        flags, pos = split_flags(args[1:], API_VALUE_FLAGS)
        method = ""
        vis = None
        has_input = False
        for k, v in flags:
            if k in ("-X", "--method"):
                method = (v or "").upper()
            elif k in ("-f", "--raw-field", "-F", "--field") and v and "=" in v:
                fk, fv = v.split("=", 1)
                if fk == "visibility":
                    vis = fv
            elif k == "--input":
                has_input = True
        hit = False
        if vis is not None and vis.lower() not in ("private", "internal"):
            hit = True
        elif has_input and method in ("PATCH", "PUT", "POST") and "visibility" in whole:
            hit = True
        if not hit:
            return out
        ep = re.sub(r"[?#].*$", "", re.sub(r"^https?://[^/]+/", "", pos[0] if pos else "")).lstrip("/")
        m = re.fullmatch(r"repos/(" + NAME + r"|\{owner\})/(" + NAME + r"|\{repo\})/?", ep)
        repo, need_cwd, unknown = "", False, False
        if m and "{" in ep:
            need_cwd = True
        elif m:
            repo = m.group(1) + "/" + m.group(2)
        else:
            unknown = True
        out.append({"kind": "api", "repo": repo, "need_cwd": need_cwd,
                    "unknown": unknown, "src": "",
                    "note": "gh api visibility field" if vis is not None else "gh api --input body"})
    return out


def analyze_segment(tokens, whole, depth):
    out = []
    t = list(tokens)
    while t and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t[0]):
        t = t[1:]
    guard = 0
    while t and os.path.basename(t[0]) in WRAPPERS and guard < 8:
        guard += 1
        wrapper = os.path.basename(t[0])
        t = t[1:]
        while t and (t[0].startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t[0])
                     or (wrapper == "timeout" and re.fullmatch(r"[0-9.]+[smhd]?", t[0]))):
            t = t[1:]
    if not t:
        return out
    first = os.path.basename(t[0])
    if first in SHELLS:
        for idx, a in enumerate(t[1:], 1):
            if re.fullmatch(r"-[a-z]*c[a-z]*", a) and idx + 1 < len(t):
                out.extend(parse_command(t[idx + 1], depth + 1))
                break
    elif first == "eval":
        out.extend(parse_command(" ".join(t[1:]), depth + 1))
    elif first == "gh":
        out.extend(analyze_gh(t[1:], whole))
    # command substitutions that survived inside a quoted token
    for tk in t:
        for m in re.finditer(r"\$\(([^()]*)\)", tk):
            out.extend(parse_command(m.group(1), depth + 1))
    return out


def parse_command(cmd, depth=0):
    if depth > MAX_DEPTH:
        raise Unparseable("nesting too deep")
    segs, scripts = tokenize(cmd)
    out = []
    for s in segs:
        out.extend(analyze_segment(s, cmd, depth))
    for body in scripts:
        out.extend(parse_command(body, depth + 1))
    return out


def emit(**kw):
    for k, v in kw.items():
        print("%s=%s" % (k.upper(), str(v).replace("\n", " ")))


def main():
    cwd = ""
    try:
        d = json.load(sys.stdin)
        ti = d.get("tool_input") or {}
        cmd = ti.get("command") or d.get("command") or ""
        cwd = d.get("cwd") or ""
    except Exception:
        # Not JSON at all: nothing to analyse. The caller already looked for cue
        # words in the raw payload and only calls us when one is present.
        emit(transition="error", note="payload is not valid JSON")
        return
    if not isinstance(cmd, str):
        emit(transition="error", note="command is not a string", cwd=cwd)
        return
    if not (any(c in cmd for c in CUES) or re.search(r"repo\s+(create|new)", cmd)):
        emit(transition="none", cwd=cwd)
        return
    try:
        found = parse_command(cmd)
    except Unparseable as e:
        crude = re.search(r"gh\s+(repo\s+(edit|create|new)|api)\b", cmd) and \
            re.search(r"visibility|--public", cmd)
        if crude:
            emit(transition="error", note="cannot parse the command (%s)" % e, cwd=cwd)
        else:
            emit(transition="none", cwd=cwd)
        return
    if not found:
        emit(transition="none", cwd=cwd)
        return
    if len(found) > 1:
        emit(transition="error", note="more than one visibility change in one command; run them one per command", cwd=cwd)
        return
    f = found[0]
    emit(transition="public", kind=f["kind"], repo=f["repo"],
         need_cwd=1 if f["need_cwd"] else 0, src=f["src"],
         unknown=1 if f["unknown"] else 0, note=f["note"], cwd=cwd)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # never crash silently: the caller fails closed on this
        emit(transition="error", note="parser crashed: %s" % type(exc).__name__)
