---
name: feedback_nix-shell-portability
description: Nix shell provides GNU utils that differ from macOS — use Claude Code tools or portable patterns
type: feedback
---

Nix shell puts GNU coreutils on PATH, replacing macOS equivalents. macOS-specific tools (`launchctl`, `ps`, `lsof`, `osascript`, `pmset`, `defaults`, `sw_vers`) are **not on the nix-shell PATH at all** — invoking them without an absolute path returns "command not found".

**Why:** Three incidents:
1. `grep -oP` (Perl regex) — not supported by nix GNU grep. Fixed: use `sed` instead.
2. `sed -i ''` (macOS in-place edit) — GNU sed interprets `''` as filename. Fixed: use Edit tool.
3. **2026-05-13** — `launchctl list 2>&1 | grep -i roborev` returned EMPTY (looked like "no plists loaded"). Real cause: bare `launchctl` was not on PATH, shell printed `command not found` to stderr (captured by `2>&1`), then `grep` matched no lines. The pipe **silently swallows the upstream failure** — the grep output looks identical to a successful command that produced no matches. Fixed by using `/bin/launchctl list`. Real check showed all 6 plists actually loaded — wasted 10 minutes on a wrong diagnosis.

**Related lesson 2026-05-13:** a launchd-managed daemon has its OWN PATH from the plist's `EnvironmentVariables.PATH` — completely independent of the interactive shell. If the daemon's PATH lists `/usr/local/bin` first and an old Homebrew/legacy tool is there (e.g. `/usr/local/bin/node` v18.15.0), the daemon picks the old version even when the interactive shell happily uses a newer one from `/opt/homebrew/bin`. Diagnostic: `/bin/launchctl print gui/$(id -u)/<label> | grep PATH`, then test the binary with that exact PATH. Don't conclude "X is broken on this machine" from an interactive-shell test alone — always reproduce the daemon's PATH.

**Related lesson 2026-05-14 — launchd uses bash 3.2:** scripts launched via launchd run under `/bin/bash` (macOS system bash 3.2.57), not the interactive shell's bash. **`mapfile`/`readarray` and `declare -A` (assoc arrays) do not exist in bash 3.2.** Symptom: `line N: mapfile: command not found` in `~/.claude/logs/<job>.err`, with last exit code = 127. Test scripts that launchd will run with `/bin/bash -n script.sh` (syntax check) AND `/bin/bash script.sh` (actual run) before bootstrapping the plist. Portable substitutes: replace `mapfile -t arr < <(cmd)` with `arr=(); while IFS= read -r l; do arr+=("$l"); done < <(cmd)`. Same family as the daemon-PATH lesson: don't conclude a script works because it runs in YOUR shell — reproduce the launchd-equivalent environment. **Fix applied 2026-05-16 (#153):** `roborev_poll_merges.sh` additionally exhibited state-T (SIGTSTP) stall on every launchd cycle — bash 3.2's `set -eo pipefail` + process substitution `< <(cmd)` interacted with launchd's job-control setup and the poller stopped itself on launch, requiring manual SIGCONT. Resolution (option B from #153): changed shebang to absolute path `/opt/homebrew/bin/bash` (bash 5.3.9), sidestepping the bash 3.2 ecosystem entirely. The fix is permanent — pin any launchd-driven script to Homebrew bash when it uses bash 4+ features or process substitution.

**Defensive pattern when running macOS-specific tools from a nix shell:**

```bash
# Wrong — silent failure in pipes:
launchctl list | grep roborev          # may produce empty output even if loaded

# Right — absolute path:
/bin/launchctl list | grep roborev

# Or with a guard:
LC=/bin/launchctl
[ -x "$LC" ] || LC=$(command -v launchctl) || { echo "no launchctl"; exit 1; }
"$LC" list | grep roborev
```

**When the upstream command in a pipe might be missing, ALWAYS:**
1. Use the absolute path (`/bin/launchctl`, `/bin/ps`, `/usr/sbin/lsof`), OR
2. Run the upstream command alone first to confirm exit 0, THEN pipe.

**How to apply:**

| Tool | macOS | GNU (nix) | Portable Alternative |
|------|-------|-----------|---------------------|
| `sed -i` | `sed -i '' 's/old/new/'` | `sed -i 's/old/new/'` | **Use Claude Code Edit tool** |
| `grep -oP` | Works (Perl regex) | Not available | Use `sed -n 's/.../\1/p'` or `grep -oE` |
| `grep -P` | Works | Not available | Use `grep -E` (extended regex) |
| `stat -f '%Sm'` | macOS format | Not available | Use `Rscript -e 'file.mtime()'` |
| `date -j` | macOS date | Not available | Use `date -d` or `Rscript -e 'Sys.time()'` |
| `ps aux` | Available | Not in nix PATH | Use `/bin/ps aux` |
| `lsof` | Available | Not in nix PATH | Use `/usr/sbin/lsof` |
| `launchctl` | Available | Not in nix PATH | Use `/bin/launchctl` |
| `osascript` | Available | Not in nix PATH | Use `/usr/bin/osascript` |
| `pmset` | Available | Not in nix PATH | Use `/usr/bin/pmset` |
| `defaults` | Available | Not in nix PATH | Use `/usr/bin/defaults` |
| `sw_vers` | Available | Not in nix PATH | Use `/usr/bin/sw_vers` |
| `pbcopy` / `pbpaste` | Available | Not in nix PATH | Use `/usr/bin/pbcopy` etc. |
| `say` | Available | Not in nix PATH | Use `/usr/bin/say` |

**Rule of thumb:** For file edits, ALWAYS prefer Claude Code's Edit/Write tools over sed/awk in Bash. For data extraction, prefer R (`Rscript -e '...'`) over shell tools — R is always available and portable in the nix shell.
