#!/usr/bin/env Rscript
# email_styles.R — Shared style constants and HTML helpers for all daily email senders.
#
# Source this file near the top of any send_*_email.R script:
#   source(file.path(dirname(normalizePath(sys.frame(1L)$ofile %||% "")), "email_styles.R"))
#
# Tracked in llm#447 + llm#448.

# ── Font sizes (bumped +2px across all surfaces — llm#448) ───────────────────

EMAIL_FONT_BODY     <- "14px"
EMAIL_FONT_SUBTITLE <- "13px"
EMAIL_FONT_FOOTER   <- "12px"
EMAIL_FONT_H2       <- "22px"
EMAIL_FONT_H3       <- "18px"

# ── Colour palette (dark-mode safe; matches llmtelemetry convention) ──────────

ACCENT_BLUE   <- "#4fc3f7"
ACCENT_GREEN  <- "#00d26a"
ACCENT_ORANGE <- "#ff9800"
ACCENT_PURPLE <- "#bb86fc"
DARK_BG       <- "#1a1a2e"
DARK_CARD     <- "#16213e"
DARK_ROW_ALT  <- "#0f3460"
DARK_TEXT     <- "#e8e8e8"
DARK_MUTED    <- "#a0a0a0"
DARK_BORDER   <- "#2a2a4a"

# ── collapsible_block() ────────────────────────────────────────────────────────
#
# Wraps an HTML body in a <details> block so the content is collapsed by default.
# Clicking the <summary> expands it. Compatible with Gmail web, Apple Mail,
# Apple Mail iOS, Outlook web. Outlook desktop strips <details> — the table
# remains visible (graceful degradation; no JS required).
#
# @param title         Section heading text (plain text, HTML-safe)
# @param summary_stats One-line stat string shown in the summary bar
#                      e.g. "Files changed: 19  •  Lines: +2868/-91"
# @param html_body     Full HTML content to collapse/expand
# @param open          If TRUE the <details> is expanded by default (open attribute).
#                      Default FALSE = collapsed on load. (#527)
# @return A length-1 character string containing the <details> block
collapsible_block <- function(title, summary_stats, html_body, open = FALSE) {
  details_attr <- if (open) " open" else ""
  sprintf(
    '<details%s style="margin: 12px 0;">
<summary style="cursor: pointer; padding: 8px 12px;
  background-color: %s; color: %s; font-size: %s; font-weight: bold;
  border-radius: 4px; list-style: none; -webkit-appearance: none;
  user-select: none;">
  %s &mdash; <span style="font-weight: normal; color: %s;">%s</span>
</summary>
<div style="margin-top: 8px;">%s</div>
</details>',
    details_attr,
    DARK_CARD, DARK_TEXT, EMAIL_FONT_BODY,
    title, ACCENT_GREEN, summary_stats,
    html_body
  )
}
