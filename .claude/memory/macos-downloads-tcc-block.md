---
name: macos-downloads-tcc-block
description: Bash tool cannot read ~/Downloads (macOS TCC); user must relocate files via the ! prefix
metadata: 
  node_type: memory
  type: reference
  originSessionId: 795fc0df-186f-44dc-b042-e97d0a67d842
---

The Claude Code Bash tool (sandboxed shell) **cannot read file *contents* under `~/Downloads`** on this Mac — `mv`/`cp` fail with `Operation not permitted` ("cannot open ... for reading"). This is macOS **TCC** (Transparency/Consent/Control) protecting the Downloads folder at the OS level, NOT the harness sandbox: it persists even with `dangerouslyDisableSandbox: true`. Metadata-only ops (`ls -la`, `stat`) DO work, which is misleading — the block is specifically on opening the bytes.

**How to apply:** when the user references a file in `~/Downloads` (e.g. "move this PDF into the repo"), do NOT attempt `mv`/`cp`/Read on it from Bash — it will fail. Instead, hand the user the exact command to run themselves via the `!` prefix, whose terminal has (or can be granted) Downloads access:
`! mv ~/Downloads/"file.pdf" ~/docs_gh/<repo>/<dest>/file.pdf`

Same applies to other TCC-protected dirs (Desktop, Documents) if they exhibit the same EPERM-on-read. Observed 2026-06-24 moving `Dexy loves R.pdf` into `llm/assets/` (llm#670). Related: [[hook-cwd-deletion]] (other environment-level Bash failure modes).
