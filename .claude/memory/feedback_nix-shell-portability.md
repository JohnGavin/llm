---
name: feedback_nix-shell-portability
description: Nix shell provides GNU utils that differ from macOS — use Claude Code tools or portable patterns
type: feedback
---

Nix shell puts GNU coreutils on PATH, replacing macOS equivalents. Several commands behave differently.

**Why:** Two incidents:
1. `grep -oP` (Perl regex) — not supported by nix GNU grep. Fixed: use `sed` instead.
2. `sed -i ''` (macOS in-place edit) — GNU sed interprets `''` as filename. Fixed: use Edit tool.

**How to apply:**

| Tool | macOS | GNU (nix) | Portable Alternative |
|------|-------|-----------|---------------------|
| `sed -i` | `sed -i '' 's/old/new/'` | `sed -i 's/old/new/'` | **Use Claude Code Edit tool** |
| `grep -oP` | Works (Perl regex) | Not available | Use `sed -n 's/.../\1/p'` or `grep -oE` |
| `grep -P` | Works | Not available | Use `grep -E` (extended regex) |
| `stat -f '%Sm'` | macOS format | Not available | Use `Rscript -e 'file.mtime()'` |
| `date -j` | macOS date | Not available | Use `date -d` or `Rscript -e 'Sys.time()'` |
| `ps aux` | Available | Not in nix PATH | Use `/bin/ps aux` |
| `lsof` | Available | Not in nix PATH | Use full path `/usr/sbin/lsof` |
| `launchctl` | Available | Not in nix PATH | Use `/bin/launchctl` |

**Rule of thumb:** For file edits, ALWAYS prefer Claude Code's Edit/Write tools over sed/awk in Bash. For data extraction, prefer R (`Rscript -e '...'`) over shell tools — R is always available and portable in the nix shell.
