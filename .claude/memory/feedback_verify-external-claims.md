---
name: verify-external-claims
description: "Don't assert an external tool's internals/capabilities from its name or marketing — read the source/docs first, or say explicitly that it's unverified"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 795fc0df-186f-44dc-b042-e97d0a67d842
---

When asked about an external tool (msgvault), I twice characterised its internals ("data model is messages", "reshaping fights the tool") from its name/marketing before reading any source. Verification later confirmed the claim — but the order was backwards, and the user had to push twice ("are you sure?", "why isn't a .md just a message?") before I actually read the code.

**Why:** Asserting-then-verifying erodes trust and risks shipping a wrong architectural claim into an issue or decision. A confident-sounding but unchecked claim is worse than "I haven't verified yet" because it looks authoritative.

**How to apply:** Before making any architectural or capability claim about an external tool, read its source/docs FIRST (gh api on the repo, README, the relevant package). If I have NOT verified, label the claim explicitly as unverified rather than stating it as fact. This is the external-tool extension of the global `NEVER speculate` / [[systematic-debugging]] discipline — quote the evidence (file, function) when the claim lands. Use `gh api repos/<owner>/<repo>/contents/<path>` to read source when a vendor site blocks WebFetch.
