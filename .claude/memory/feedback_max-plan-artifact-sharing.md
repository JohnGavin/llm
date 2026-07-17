---
name: feedback_max-plan-artifact-sharing
description: Individual Max plan CANNOT share claude.ai artifacts by link; needs Teams/Enterprise
metadata: 
  node_type: memory
  type: feedback
  originSessionId: a955edbd-fbad-4790-8266-631f50fa6314
---

On an individual Max (5×/20×) subscription the claude.ai artifact **Share button is inactive** — you cannot share an artifact URL with anyone. Sending the URL to a recipient (subscriber or not) grants them NO access. Native artifact sharing requires a **Teams or Enterprise** workspace.

**Why:** Confirmed by the user 2026-07-10 — they sent a Kerry/Connemara travel artifact URL to a non-subscriber, the recipient had no access, and the share button was disabled. This corrects a prior WRONG claim (mine) that individual Max allows "share-by-link (anyone with the URL can view)".

**How to apply:** To share a self-contained Claude artifact with someone on individual Max, do NOT rely on the artifact URL. Instead extract the artifact's self-contained HTML (WebFetch the artifact URL returns the full HTML shell) and deliver it out-of-band:
- **1-person, private (best):** email the `.html` file as an attachment — it opens in any browser, no account/subscription needed; only that person has it. Or share via Drive/Dropbox scoped to their specific email.
- **Clickable rendered link:** host the self-contained HTML on GitHub Pages / Netlify — but that is public (unlisted at best), not per-person private.

Ties to [[startup-cost-is-mcp-not-hook]] only loosely; relevant to the capability-registry artifact automation (llm#766 regenerates the self-contained HTML file precisely so it can be hosted anywhere).
