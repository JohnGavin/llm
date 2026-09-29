#!/usr/bin/env bash
# tests/test_pulse_wrappers_wait_for_dns.sh
#
# Regression test (llm#1274 follow-up, 2026-09-28 incident):
# bin/launchd-recorders/config-pulse and bin/launchd-recorders/knowledge-pulse
# both exec'd nix-shell directly with no DNS wait, while six other cron
# scripts already gate their network work via
# .claude/scripts/wait_for_resolvable_host.sh. Both jobs fired at 09:17 on
# 2026-09-28 (shortly after wake) and died with:
#   "unable to download 'https://github.com/rstats-on-nix/nixpkgs/archive/
#    2026-02-02.tar.gz': Could not resolve host: github.com"
# (nix-shell evaluation of default.nix fetches the pinned nixpkgs tarball
# over the network -- it dies before the wrapped script ever runs).
#
# This suite asserts, both statically (syntax + text/order) and
# behaviorally (by extracting the wrapper's inner `/bin/bash -c '...'`
# command and substituting fixture stand-ins for the real absolute paths
# it references), that:
#   1. Both wrapper files are syntactically valid bash.
#   2. Both reference wait_for_resolvable_host.sh BEFORE nix-shell.
#   3. The wait is '&&'-chained to the nix-shell exec (a failed wait must
#      short-circuit, not just precede, the nix-shell call).
#   4. A failing DNS wait aborts BEFORE nix-shell runs, with a non-zero
#      exit (fail loudly, not a silent skip -- launchd_run_record.sh
#      records that non-zero exit in its runs ledger).
#   5. A succeeding DNS wait proceeds to nix-shell.
#
# Exits 0 if all tests pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# These are the exact absolute paths the wrapper files hardcode (they are
# NOT worktree-relative -- every bin/launchd-recorders/* wrapper hardcodes
# the main checkout path, matching the launchd plists that invoke them by
# absolute path). Substituted out for fixtures in the behavioral sub-test
# below regardless of which checkout this test itself runs from.
REAL_WAIT_SCRIPT="/Users/johngavin/docs_gh/llm/.claude/scripts/wait_for_resolvable_host.sh"
REAL_NIX_SHELL="/nix/var/nix/profiles/default/bin/nix-shell"

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d /tmp/test_pulse_dns_gate_XXXXXX)"
cleanup() { rm -rf "${TMPDIR_ROOT}"; }
trap cleanup EXIT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 -- ${2:-}"; FAIL=$((FAIL + 1)); }

for wrapper in config-pulse knowledge-pulse; do
  WRAPPER_FILE="${REPO_ROOT}/bin/launchd-recorders/${wrapper}"

  if [ ! -f "${WRAPPER_FILE}" ]; then
    fail "${wrapper}: wrapper file exists" "not found at ${WRAPPER_FILE}"
    continue
  fi

  # ── 1. bash -n ─────────────────────────────────────────────────────────
  if bash -n "${WRAPPER_FILE}" 2>/dev/null; then
    pass "${wrapper}: bash -n"
  else
    fail "${wrapper}: bash -n"
  fi

  CONTENT="$(cat "${WRAPPER_FILE}")"

  # ── 2. references both the DNS-wait helper and nix-shell ────────────────
  if printf '%s' "${CONTENT}" | grep -qF "wait_for_resolvable_host.sh"; then
    pass "${wrapper}: references wait_for_resolvable_host.sh"
  else
    fail "${wrapper}: references wait_for_resolvable_host.sh" "not found in wrapper content"
  fi
  if printf '%s' "${CONTENT}" | grep -qF "nix-shell"; then
    pass "${wrapper}: references nix-shell"
  else
    fail "${wrapper}: references nix-shell" "not found in wrapper content"
  fi

  # ── 3. DNS wait precedes nix-shell, byte-offset order ────────────────────
  # Comments may mention "nix-shell" in prose before the real invocation
  # (explaining the wait's purpose), so strip full-line comments first and
  # compare positions only within the executable content.
  EXEC_ONLY="$(printf '%s\n' "${CONTENT}" | grep -vE '^[[:space:]]*#')"
  wait_pos="$(printf '%s' "${EXEC_ONLY}" | grep -bo "wait_for_resolvable_host.sh" | head -1 | cut -d: -f1)"
  nix_pos="$(printf '%s' "${EXEC_ONLY}" | grep -bo "nix-shell" | head -1 | cut -d: -f1)"
  if [ -n "${wait_pos}" ] && [ -n "${nix_pos}" ] && [ "${wait_pos}" -lt "${nix_pos}" ]; then
    pass "${wrapper}: DNS wait precedes nix-shell invocation"
  else
    fail "${wrapper}: DNS wait precedes nix-shell invocation" "wait_pos=${wait_pos} nix_pos=${nix_pos}"
  fi

  # ── 4. '&&'-chained (a failed wait short-circuits, not merely precedes) ──
  if printf '%s' "${CONTENT}" | grep -qE 'wait_for_resolvable_host\.sh[^&]*&&'; then
    pass "${wrapper}: DNS wait is && -chained (failure blocks nix-shell)"
  else
    fail "${wrapper}: DNS wait is && -chained (failure blocks nix-shell)"
  fi

  # ── 5. Behavioral: extract the exact inner command run via
  # /bin/bash -c '...' and substitute fixture stand-ins for the real
  # absolute helper/nix-shell paths, so a DNS-wait failure is PROVEN to
  # short-circuit before nix-shell runs -- not merely asserted by grep.
  #
  # roborev #1292 review (10656 Low): the prior extraction used a
  # line-anchored greedy sed pattern (`^.*'...'$`), which only works because
  # the wrapper's inner command happens to be the last thing on a single
  # physical line. Reformatting it across multiple lines, or adding an
  # embedded quote, would silently change what gets captured (or fail
  # extraction entirely, which this function does still catch below --
  # the fragility was in what a REFORMAT could do, not in a missing check).
  # Flatten the whole file to one line first (so line boundaries can't
  # matter), then use bash parameter-expansion suffix/prefix stripping
  # instead of a regex: `${FLAT#*pattern}` strips the SHORTEST prefix up to
  # the first "/bin/bash -c '" (unambiguous -- there is exactly one), and
  # `${after%\'*}` strips the SHORTEST suffix starting at a `'`, which bash
  # resolves to the LAST quote in the string (shortest-suffix-match anchors
  # as late as possible) -- i.e. the closing quote of the outer '...', same
  # result as before but independent of line layout.
  FLAT_CONTENT="$(printf '%s' "${CONTENT}" | tr '\n' ' ')"
  case "${FLAT_CONTENT}" in
    *"/bin/bash -c '"*)
      after="${FLAT_CONTENT#*/bin/bash -c \'}"
      inner="${after%\'*}"
      ;;
    *)
      inner=""
      ;;
  esac
  if [ -z "${inner}" ]; then
    fail "${wrapper}: could not extract inner /bin/bash -c command for behavioral test" "content=${CONTENT}"
    continue
  fi

  WRAPPER_TMP="${TMPDIR_ROOT}/${wrapper}"
  mkdir -p "${WRAPPER_TMP}"
  FAKE_WAIT="${WRAPPER_TMP}/fake_wait.sh"
  FAKE_NIX="${WRAPPER_TMP}/fake_nix_shell"
  MARKER="${WRAPPER_TMP}/nix_ran"

  cat > "${FAKE_WAIT}" <<'EOF'
#!/usr/bin/env bash
exit "${FAKE_WAIT_EXIT:-0}"
EOF
  chmod +x "${FAKE_WAIT}"

  cat > "${FAKE_NIX}" <<EOF
#!/usr/bin/env bash
touch "${MARKER}"
exit 0
EOF
  chmod +x "${FAKE_NIX}"

  test_cmd="${inner//${REAL_WAIT_SCRIPT}/${FAKE_WAIT}}"
  test_cmd="${test_cmd//${REAL_NIX_SHELL}/${FAKE_NIX}}"

  if [ "${test_cmd}" = "${inner}" ]; then
    fail "${wrapper}: fixture substitution changed nothing (paths did not match real hardcoded paths)" "inner=${inner}"
    continue
  fi

  # -- DNS wait FAILS -> nix-shell must NOT run, exit must be non-zero
  rm -f "${MARKER}"
  FAKE_WAIT_EXIT=2 bash -c "${test_cmd}" >/dev/null 2>&1
  rc=$?
  if [ "${rc}" -ne 0 ] && [ ! -e "${MARKER}" ]; then
    pass "${wrapper}: DNS-wait failure aborts before nix-shell, exits non-zero (rc=${rc})"
  else
    fail "${wrapper}: DNS-wait failure aborts before nix-shell, exits non-zero" \
      "rc=${rc} marker_exists=$( [ -e "${MARKER}" ] && echo yes || echo no )"
  fi

  # -- DNS wait SUCCEEDS -> nix-shell (fake) DOES run
  rm -f "${MARKER}"
  FAKE_WAIT_EXIT=0 bash -c "${test_cmd}" >/dev/null 2>&1
  if [ -e "${MARKER}" ]; then
    pass "${wrapper}: DNS-wait success proceeds to nix-shell"
  else
    fail "${wrapper}: DNS-wait success proceeds to nix-shell" "marker missing"
  fi
done

# ── 6. Timing relationship: the DNS wait's own timeout budget must stay
# strictly BELOW each label's launchd-timeouts.txt bound (roborev #1292
# review, 10656 Medium). The DNS wait now runs INSIDE
# launchd_run_record.sh's per-label timeout bound -- if the two coincide (or
# the wait's budget exceeds the outer bound), a clean DNS-wait timeout and
# the outer bound killing the whole unit become indistinguishable (they fire
# at the same instant, or the outer kill fires first), defeating the "fail
# loudly with a clean DNS-wait failure" design these wrappers' own header
# comments describe. Reads the DNS wait's default straight from
# wait_for_resolvable_host.sh (not hardcoded) so this stays correct if that
# default ever changes.
DNS_DEFAULT_TIMEOUT="$(grep -oE 'WAIT_FOR_HOST_TIMEOUT:-[0-9]+' "${REPO_ROOT}/.claude/scripts/wait_for_resolvable_host.sh" | head -1 | grep -oE '[0-9]+$')"
DNS_DEFAULT_TIMEOUT="${DNS_DEFAULT_TIMEOUT:-120}"

for wrapper_label in com.claude.config-pulse com.claude.knowledge-pulse; do
  bound="$(grep -E "^${wrapper_label}[[:space:]]" "${REPO_ROOT}/.claude/state/launchd-timeouts.txt" | awk '{print $2}')"
  if [ -z "${bound}" ]; then
    fail "${wrapper_label}: has a launchd-timeouts.txt bound" "no entry found in .claude/state/launchd-timeouts.txt"
    continue
  fi
  if [ "${DNS_DEFAULT_TIMEOUT}" -lt "${bound}" ]; then
    pass "${wrapper_label}: DNS-wait budget (${DNS_DEFAULT_TIMEOUT}s) < launchd-timeouts.txt bound (${bound}s)"
  else
    fail "${wrapper_label}: DNS-wait budget (${DNS_DEFAULT_TIMEOUT}s) < launchd-timeouts.txt bound (${bound}s)" \
      "DNS wait budget must stay strictly below the outer timeout bound, else a DNS timeout and an outer-bound kill are indistinguishable"
  fi
done

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
