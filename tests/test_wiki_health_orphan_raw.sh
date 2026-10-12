#!/usr/bin/env bash
# Test for the orphan-raw check (check 4) of .claude/scripts/wiki_health_check.sh
# (llm#1397). /tmp fixtures only; the real knowledge hub is never touched.
# All names are synthetic.
#
# SCRIPT may be overridden (WIKI_HEALTH_SCRIPT=...) to run the same cases
# against an older copy and watch the red cases go red.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${WIKI_HEALTH_SCRIPT:-$ROOT/.claude/scripts/wiki_health_check.sh}"
WORK=$(mktemp -d)
WORK=$(cd -P "$WORK" && pwd -P)
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home"   # the script writes a stamp under $HOME on a clean run
mkdir -p "$HOME"

fail=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then echo "PASS $1 ($3)"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi
}

# A hub: wiki with one valid note citing raw/cited.md; raw with that file.
mkhub() { # dir
  local h="$1"
  rm -rf "$h"
  mkdir -p "$h/wiki" "$h/raw"
  cat > "$h/wiki/INDEX.md" <<'EOF'
# Index
- [note](note.md)
EOF
  : > "$h/wiki/LOG.md"
  cat > "$h/wiki/note.md" <<'EOF'
---
title: Note
canonical_question: Q?
status: active
fresh_until: 2999-01-01
consensus_level: direct
sources:
  - raw/cited.md
---
# Note

## Sources
- raw/cited.md
EOF
  echo cited > "$h/raw/cited.md"
}
run() { # hub ; sets rc and OUT
  OUT=$(bash "$SCRIPT" "$1/wiki" 2>"$WORK/err")
  rc=$?
}
orphan_count() { printf '%s\n' "$OUT" | sed -n 's/^Orphan raw files: *//p'; }

H="$WORK/hub"

# Baseline: clean hub.
mkhub "$H"; run "$H"
check "baseline clean exit" 0 "$rc"
check "baseline orphan count" 0 "$(orphan_count)"

# (a) uncited .txt in a raw subfolder -> orphan (red), then green once cited.
mkhub "$H"; mkdir -p "$H/raw/sub"; echo x > "$H/raw/sub/talk.txt"
run "$H"
check "(a) uncited sub/.txt -> warn exit" 1 "$rc"
check "(a) uncited sub/.txt -> count" 1 "$(orphan_count)"
printf '\n- raw/sub/talk.txt\n' >> "$H/wiki/note.md"
run "$H"
check "(a) cited sub/.txt -> clean exit" 0 "$rc"
check "(a) cited sub/.txt -> count" 0 "$(orphan_count)"

# (b) sidecars never reported.
mkhub "$H"; mkdir -p "$H/raw/sub"
echo x > "$H/raw/sub/talk.meta.yml"; echo x > "$H/raw/sub/talk.provenance"
run "$H"
check "(b) sidecars ignored exit" 0 "$rc"
check "(b) sidecars ignored count" 0 "$(orphan_count)"

# (c) _-prefixed folders ignored, at any depth.
mkhub "$H"; mkdir -p "$H/raw/b/_duplicates" "$H/raw/_off-channel-noise"
echo x > "$H/raw/b/_duplicates/d.txt"; echo x > "$H/raw/_off-channel-noise/n.vtt"
run "$H"
check "(c) _folders ignored exit" 0 "$rc"
check "(c) _folders ignored count" 0 "$(orphan_count)"

# (d) allow-list: no reason -> exit 2; with reason -> excluded.
mkhub "$H"; mkdir -p "$H/raw/braindumps"; echo x > "$H/raw/braindumps/a.md"
printf '# comment line\n\nbraindumps/\n' > "$H/raw/.orphan-ignore"
run "$H"
check "(d) entry without reason -> usage error" 2 "$rc"
printf 'braindumps/  #\n' > "$H/raw/.orphan-ignore"
run "$H"
check "(d) empty reason -> usage error" 2 "$rc"
printf '# comment line\n\nbraindumps/  # input to /braindump, not a wiki source\n' > "$H/raw/.orphan-ignore"
run "$H"
check "(d) entry with reason -> clean exit" 0 "$rc"
check "(d) entry with reason -> count" 0 "$(orphan_count)"
# exact-path entry covers only that file
echo x > "$H/raw/braindumps/b.md"
printf 'braindumps/a.md  # one-off\n' > "$H/raw/.orphan-ignore"
run "$H"
check "(d) exact entry leaves sibling orphan" 1 "$(orphan_count)"

# (e) unreadable raw/ -> INDETERMINATE exit 3, never "0 orphans".
mkhub "$H"; mkdir -p "$H/raw/sub"; echo x > "$H/raw/sub/talk.txt"
chmod 000 "$H/raw"
run "$H"
rc_unreadable=$rc
chmod 755 "$H/raw"
if [ "$(id -u)" = "0" ]; then
  echo "SKIP (e) running as root: chmod 000 does not block reads"
else
  check "(e) unreadable raw/ -> exit 3" 3 "$rc_unreadable"
fi
# unreadable subfolder also indeterminate
mkhub "$H"; mkdir -p "$H/raw/sub"; echo x > "$H/raw/sub/talk.txt"
chmod 000 "$H/raw/sub"
run "$H"
rc_sub=$rc
chmod 755 "$H/raw/sub"
[ "$(id -u)" = "0" ] || check "(e) unreadable raw/sub -> exit 3" 3 "$rc_sub"

echo
if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$fail"
