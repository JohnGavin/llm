#!/usr/bin/env python3
# secret-exposure-scan: pattern-definitions -- this file legitimately embeds
# the credential-shaped regex literals it exists to detect. The detector-2/4
# self-reference exemption (see secret-exposure-scanning.md's "Self-Reference
# Exemption" section) skips literal-value matching for THIS file.
#
# cred_patterns.py — single source of truth for the "what does a literal
# credential look like in text" pattern list (llm#960 Part 3).
#
# WHY THIS FILE EXISTS
# ---------------------
# CRED_PATTERNS previously lived only inside secret_leak_guard.sh's embedded
# python heredoc (Rules 4 and 5). Adding a second guard for the `Artifact`
# tool needed the exact same pattern list; copying it into a second file
# would recreate the failure shape llm#958 was raised and fixed for — one
# logical thing (the credential-shape catalogue) defined in two places that
# WILL drift (add a vendor prefix to one copy, forget the other, and one
# guard silently stops catching a shape the other still catches).
#
# Both `secret_leak_guard.sh` (PreToolUse:Bash, Rules 4/5) and
# `artifact_secret_guard.sh` (PreToolUse:Artifact) import this module —
# never redefine CRED_PATTERNS locally. See either script's
# `sys.path.insert(...)` resolution comment for why the import path is
# derived from the CALLING script's own location (an env var it sets,
# resolved via `${BASH_SOURCE[0]%/*}`), never a hardcoded `~/.claude/...`
# path: `~/.claude/hooks/` is a symlink into the main checkout in
# production, so a hardcoded path would silently point at the main
# checkout's copy even when the calling script is under test inside a
# worktree (same rationale as HOOK_EVENT_EMIT_SCRIPT in
# secret_leak_guard.sh).
#
# IMPORT-SAFE: importing this module has no side effects — it only defines
# data and two small pure functions.
#
# Regression proof that duplication has not crept back in: see
# artifact_secret_guard.sh --selftest, the
# "CRED_PATTERNS entries defined in exactly one file under .claude/hooks/**"
# case — mirrors rotate_secret.sh's "each CONSUMERS_* name defined exactly
# once" check (llm#958) applied to this catalogue instead of the consumer map.

import re

# Literal credential token shapes. Order matters: more specific prefixes
# (sk-ant-) must be checked before their generic parents (sk-) so the
# reported description is the most useful one.
CRED_PATTERNS = [
    (r'ghp_[A-Za-z0-9]{20,}',            'GitHub personal access token (ghp_)'),
    (r'gho_[A-Za-z0-9]{20,}',            'GitHub OAuth token (gho_)'),
    (r'ghs_[A-Za-z0-9]{20,}',            'GitHub server-to-server token (ghs_)'),
    (r'github_pat_[A-Za-z0-9_]{20,}',    'GitHub fine-grained PAT (github_pat_)'),
    (r'sk-ant-[A-Za-z0-9\-_]{20,}',      'Anthropic API key (sk-ant-)'),
    (r'sk-[A-Za-z0-9]{20,}',             'API key (sk-...)'),
    (r'hf_[A-Za-z0-9]{20,}',             'HuggingFace token (hf_)'),
    (r'xoxb-[A-Za-z0-9\-]{10,}',         'Slack bot token (xoxb-)'),
    (r'xoxp-[A-Za-z0-9\-]{10,}',         'Slack user token (xoxp-)'),
    (r'AIza[A-Za-z0-9_\-]{30,}',         'Google API key (AIza)'),
    (r'AKIA[A-Z0-9]{16}',                'AWS access key ID (AKIA)'),
    (r'glpat-[A-Za-z0-9\-_]{15,}',       'GitLab personal access token (glpat-)'),
    (r'-----BEGIN[ A-Z]*PRIVATE KEY-----', 'PEM private key block'),
]


def redact(text):
    """Replace any CRED_PATTERNS-shaped literal with <REDACTED> — never log
    or echo a real credential."""
    out = text
    for pat, _ in CRED_PATTERNS:
        out = re.sub(pat, '<REDACTED>', out)
    return out


def find_credential(text):
    """Return (pattern, description) for the FIRST CRED_PATTERNS match found
    in `text`, or None if no pattern matches. Order-preserving — the same
    "more specific prefix first" ordering CRED_PATTERNS itself carries."""
    for pat, desc in CRED_PATTERNS:
        if re.search(pat, text):
            return pat, desc
    return None
