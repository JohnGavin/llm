---
name: ellmer-cannot-use-max-subscription
description: ellmer R package cannot use a Claude Pro/Max subscription — needs a separate pay-per-token API key
metadata: 
  node_type: memory
  type: reference
  originSessionId: 4edf2ca8-4c7c-43d8-8eca-73de94efd730
---

`ellmer` (the tidyverse R LLM package) **cannot run on a Claude Max/Pro subscription**.
As of ellmer 0.4.0 there is NO subscription/OAuth provider — no `chat_claude_code()`,
no claude.ai-login path. `chat_claude()`/`chat_anthropic()` authenticate ONLY with a
pay-per-token `ANTHROPIC_API_KEY` (console.anthropic.com, billed separately from any
Max/Pro plan).

The Max subscription uses a different credential, `CLAUDE_CODE_OAUTH_TOKEN`, which is
first-party Claude Code only. Critically, **Anthropic blocked third-party harnesses
from using Max-subscription limits as of 2026-04-04** — proxy workarounds (CLIProxyAPI
etc.) now require Anthropic's pay-as-you-go "extra usage", so there is no free route.

Practical consequence for this project: any ellmer pilot/use needs a separately-funded
key. We have an `OPENAI_API_KEY` in the env but its account hit a billing 429 (no
credits). To use Claude via ellmer, fund an `ANTHROPIC_API_KEY` and call `chat_claude()`
(zero code change from `chat_openai()`).

Verified 2026-06-30 (ellmer reference + Anthropic auth docs) during the #696 ellmer
pilot ([[hook-pipefail-no-stderr]] sibling session). Re-verify if ellmer adds an OAuth
provider in a later release.
