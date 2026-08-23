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

# ── resolve_dashboard_links() / dashboard_cta_block() ─────────────────────────
#
# The llmtelemetry roborev dashboard was public via GitHub Pages until the
# repo was made private (2026-08-22) to stop it publishing another project's
# personal-finance data — the GH Pages site went offline as an accepted
# consequence. The dashboard itself still exists: Quarto renders it LOCALLY
# to _site/index.html inside the llmtelemetry checkout.
#
# Nothing here is hardcoded to that one incident. Every piece is
# env-overridable, so a FUTURE visibility change (site goes public again,
# moves host, repo renamed) is a config edit, not a code hunt:
#   ROBOREV_DASHBOARD_URL        — explicit override; if set, wins outright
#                                   (e.g. point back at a restored public URL
#                                   without touching any script)
#   ROBOREV_DASHBOARD_REPO_URL   — the GitHub repo, for owner-authenticated
#                                   browsing when the site itself isn't
#                                   published (default: the llmtelemetry repo)
#   ROBOREV_DASHBOARD_LOCAL_PATH — where the rendered site lives on this
#                                   machine (default: the llmtelemetry
#                                   checkout's Quarto _site/ output)
#
# @return list(explicit_url = chr|NULL, repo_url = chr, local_path = chr)
resolve_dashboard_links <- function() {
  explicit_url <- Sys.getenv("ROBOREV_DASHBOARD_URL", "")
  list(
    explicit_url = if (nzchar(explicit_url)) explicit_url else NULL,
    repo_url = Sys.getenv(
      "ROBOREV_DASHBOARD_REPO_URL",
      "https://github.com/JohnGavin/llmtelemetry"
    ),
    local_path = Sys.getenv(
      "ROBOREV_DASHBOARD_LOCAL_PATH",
      file.path(Sys.getenv("HOME"), "docs_gh", "llmtelemetry", "_site", "index.html")
    )
  )
}

# dashboard_cta_block(): renders the "View Full roborev Dashboard" button
# plus, when no explicit override URL is set, a one-line explanation of why
# the button now points at the (private) repo instead of the old published
# site, and the locally-rendered path as SELECTABLE TEXT rather than a
# file:// <a href>. Major mail clients (Gmail included) strip file:// links
# outright — a link that renders but can't be followed is barely better than
# the 404 it replaces, so the path is shown as copyable <code> text instead.
#
# @param accent_colour CTA button colour (e.g. ACCENT_BLUE)
# @return HTML string
dashboard_cta_block <- function(accent_colour) {
  links <- resolve_dashboard_links()
  href  <- if (!is.null(links$explicit_url)) links$explicit_url else links$repo_url

  changed_note <- if (is.null(links$explicit_url)) {
    sprintf(
      '<p style="color:%s; font-size:%s; margin:4px 0 12px 0;">
        The public dashboard went offline when llmtelemetry was made private
        (2026-08-22) to stop it publishing another project&#39;s data. The
        button above opens the (now-private) repo instead &mdash; or open the
        locally rendered site at:<br>
        <code style="background-color:%s; color:%s; padding:2px 6px;
          border-radius:3px; font-size:%s; user-select:all;">%s</code>
      </p>',
      DARK_MUTED, EMAIL_FONT_SUBTITLE, DARK_CARD, ACCENT_GREEN,
      EMAIL_FONT_SUBTITLE, links$local_path
    )
  } else ""

  sprintf(
    '<div style="margin: 16px 0;">
  <a href="%s"
     style="display:inline-block; padding:10px 20px; background-color:%s;
            color:#1a1a2e; text-decoration:none; border-radius:4px;
            font-weight:bold; font-size:13px;">
    View Full roborev Dashboard
  </a>
</div>
%s',
    href, accent_colour, changed_note
  )
}

# effective_dashboard_url(): the single URL that dashboard_cta_block() will
# actually render as the button href — for callers that need the same value
# outside the HTML block itself (e.g. QA markers).
effective_dashboard_url <- function() {
  links <- resolve_dashboard_links()
  if (!is.null(links$explicit_url)) links$explicit_url else links$repo_url
}
