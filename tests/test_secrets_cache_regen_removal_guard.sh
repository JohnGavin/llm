#!/usr/bin/env bash
# Reproduce the llm#1024 loss against the guarded script, using a fake bws.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$REPO_ROOT/.claude/scripts/secrets_cache_regen.sh"
T=$(mktemp -d); pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  PASS: $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL: $1"; }

# Fake bws: BWS has CACHIX but NOT SIGNAL_ACCOUNT — the exact 2026-08-25 state.
mkdir -p "$T/bin"
cat > "$T/bin/bws" <<'EOS'
#!/usr/bin/env bash
cat <<'ENVOUT'
GMAIL_USERNAME=u
GMAIL_APP_PASSWORD=p
REPORT_RECIPIENT=r
ROBOREV_DASHBOARD_URL=d
OPENAI_API_KEY=o
openai_secret_key=o2
HF_TOKEN=h
HUGGING_FACE_HUB_TOKEN=h2
HUGGINGFACE_API_TOKEN=h3
GOOGLE_API_KEY=g
GEMINI_API_KEY=g2
FRED_API_KEY=f
AlphaVantage_API_KEY=a
DOCKER_PSWD=d2
CACHIX_AUTH_TOKEN=newtoken
ENVOUT
EOS
chmod +x "$T/bin/bws"

# Current cache: has SIGNAL_ACCOUNT, lacks CACHIX — pre-incident state.
cat > "$T/secrets.env" <<'EOS'
GMAIL_USERNAME=u
GMAIL_APP_PASSWORD=p
REPORT_RECIPIENT=r
ROBOREV_DASHBOARD_URL=d
OPENAI_API_KEY=o
openai_secret_key=o2
HF_TOKEN=h
HUGGING_FACE_HUB_TOKEN=h2
HUGGINGFACE_API_TOKEN=h3
GOOGLE_API_KEY=g
GEMINI_API_KEY=g2
FRED_API_KEY=f
AlphaVantage_API_KEY=a
DOCKER_PSWD=d2
SIGNAL_ACCOUNT=+12025550111
EOS
chmod 600 "$T/secrets.env"
cp "$T/secrets.env" "$T/secrets.env.orig"

export PATH="$T/bin:$PATH"
export BWS_ACCESS_TOKEN="fake"

# 1. Default: must REFUSE and change nothing.
out="$(bash "$S" --apply --cache-file "$T/secrets.env" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "REFUSED"; then
  ok "refuses by default when a key would be deleted"
else
  bad "did not refuse (rc=$rc)"
fi
printf '%s' "$out" | grep -q "SIGNAL_ACCOUNT" && ok "names the key that would be lost" || bad "did not name the key"
printf '%s' "$out" | grep -q "bws_set_secret.sh SIGNAL_ACCOUNT" && ok "prints the exact remedy command" || bad "no remedy command"
if diff -q "$T/secrets.env" "$T/secrets.env.orig" >/dev/null; then
  ok "cache is untouched after refusal"
else
  bad "cache was modified despite refusal"
fi

# 2. --allow-removals: must proceed and say so.
out2="$(bash "$S" --apply --allow-removals --cache-file "$T/secrets.env" 2>&1)"; rc2=$?
if [ "$rc2" -eq 0 ] && printf '%s' "$out2" | grep -q "PROCEEDING WITH REMOVALS"; then
  ok "--allow-removals proceeds and announces the deletions"
else
  bad "--allow-removals did not proceed (rc=$rc2)"
fi
grep -q '^SIGNAL_ACCOUNT=' "$T/secrets.env" && bad "key survived --allow-removals" || ok "key deleted only with --allow-removals"
grep -q '^CACHIX_AUTH_TOKEN=' "$T/secrets.env" && ok "new key installed" || bad "new key missing"

# 3. Churn line must expose an add+delete that leaves the count unchanged.
printf '%s' "$out2" | grep -qE 'Churn: *\+1 / -1' && ok "churn line shows +1/-1 where the total is unchanged" || bad "churn line missing or wrong"

# 4. No removals -> no refusal (guard must not block normal runs).
out3="$(bash "$S" --apply --cache-file "$T/secrets.env" 2>&1)"; rc3=$?
if [ "$rc3" -eq 0 ] && ! printf '%s' "$out3" | grep -q "REFUSED"; then
  ok "a run with no removals is unaffected"
else
  bad "guard blocked a run with no removals (rc=$rc3)"
fi

echo "  $pass passed, $fail failed"
rm -rf "$T"
[ "$fail" -eq 0 ]
