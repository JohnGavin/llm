---
name: npm-global-in-nix-shell
description: "Installing npm global packages inside the nix dev shell — read-only store prefix + root-owned ~/.npm cache, use --prefix + --cache"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 4854e9d1-4cc0-4a69-8d8d-03939c73c029
---

`npm install -g <pkg>` fails inside the nix dev shell: the global prefix resolves into the **read-only nix store** (`npm config get prefix` → `/nix/store/...-nodejs-*/`), so the write is denied. Separately, `~/.npm/_cacache` may contain **root-owned files** from a past `sudo npm` (EACCES on `mkdir`).

Working pattern (no sudo, isolated, pinned):

```
npm install -g --prefix ~/.npm-global --cache /tmp/<pkg>-npm-cache <pkg>@<pinned-version>
~/.npm-global/bin/<pkg> ...
```

- `--prefix ~/.npm-global` → writable user prefix; binary lands in `~/.npm-global/bin/`.
- `--cache /tmp/...` → sidesteps the root-owned `~/.npm` cache.
- Pin the version (#644 supply-chain vetting); isolated install, never the global shell.
- Tools that pull native builds / model weights (e.g. node-llama-cpp + GGUF) download to `~/.cache/<tool>/` — can be GBs; clean up via [[destructive-guard-blocks-rm]].

Observed 2026-06-27 installing `@tobilu/qmd@2.5.3` for the qmd spike (llm#686). Related nix-shell tooling gotchas: [[startup-cost-is-mcp-not-hook]].
