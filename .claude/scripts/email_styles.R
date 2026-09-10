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
# @param summary_color Colour for the summary-stats span. Default ACCENT_GREEN
#                      (unchanged behaviour for every existing caller). Pass a
#                      warning/danger colour when the summary itself reports a
#                      non-clean state -- llm#1145: a hardcoded green summary
#                      colour meant "1 failed · 0 unknown" read as reassuring
#                      regardless of content, so a real degradation (27 runs of
#                      an indeterminate cron job) sat unnoticed behind a green
#                      line for four weeks.
# @return A length-1 character string containing the <details> block
collapsible_block <- function(title, summary_stats, html_body, open = FALSE,
                               summary_color = ACCENT_GREEN) {
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
    title, summary_color, summary_stats,
    html_body
  )
}

# ── resolve_dashboard_links() / dashboard_cta_block() ─────────────────────────
#
# The llmtelemetry roborev dashboard was public via GitHub Pages until the
# repo was made private (2026-08-22) to stop it publishing another project's
# personal-finance data — the GH Pages site went offline as an accepted
# consequence.
#
# 2026-09-09 correction (llm#1123 follow-up): the previous default
# (_site/index.html) was never actually produced by anything running on this
# machine — that path is only ever written by CI (deploy-dashboard.yaml),
# which copies the rendered *general* project dashboard
# (dashboard_shinylive.qmd) there, not a roborev-specific page. Verified: the
# path did not exist locally when checked. The correct LOCAL target for a
# button labelled "View Full roborev Dashboard" is the roborev-specific
# vignette, vignettes/roborev_summary.qmd, which renders to a single
# self-contained HTML file (embed-resources: true — no companion _files/
# directory to break a file:// link). Regenerate it locally with:
#   inst/scripts/refresh_roborev_vignette_rds.R   # refresh data from unified.duckdb
#   quarto render vignettes/roborev_summary.qmd    # render (needs quarto + plotly + DT)
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
#   ROBOREV_DASHBOARD_LOCAL_PATH — where the rendered roborev vignette lives
#                                   on this machine (default: the llmtelemetry
#                                   checkout's rendered vignette HTML)
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
      file.path(Sys.getenv("HOME"), "docs_gh", "llmtelemetry", "vignettes", "roborev_summary.html")
    )
  )
}

# resolve_dashboard_href(): the single three-way branch (explicit override >
# local file:// link > repo URL fallback) that both dashboard_cta_block() and
# effective_dashboard_url() need. Extracted 2026-09-10 (roborev #10271,
# Medium) — the branch previously existed twice, in two different code
# shapes, with nothing enforcing that they stayed in sync; a future edit to
# one (e.g. a new override precedence) could silently desync the rendered
# button href from what effective_dashboard_url() reports as "effective".
#
# @param links list from resolve_dashboard_links()
# @return list(href = chr, local_exists = lgl) — local_exists is exposed
#   because dashboard_cta_block() needs it separately to pick which
#   explanatory note to render.
resolve_dashboard_href <- function(links) {
  local_exists <- is.null(links$explicit_url) && file.exists(links$local_path)
  href <- if (!is.null(links$explicit_url)) {
    links$explicit_url
  } else if (local_exists) {
    paste0("file://", links$local_path)
  } else {
    links$repo_url
  }
  list(href = href, local_exists = local_exists)
}

# dashboard_cta_block(): renders the "View Full roborev Dashboard" button.
#
# 2026-09-09 (llm#1123 follow-up, user request "fix the button to point to
# the html file on my macbook"): when no explicit override URL is set AND
# the local rendered vignette actually exists on THIS machine (checked at
# send-time via file.exists() — the email is generated on the same Mac it
# will be read on, so this is a real, not stale, check), the button href
# becomes file://<local_path> directly. When the file is absent (nobody has
# rendered it yet, or the email is somehow generated elsewhere), the button
# falls back to the private repo URL, same as before.
#
# Caveat, unresolved as of this change: major mail clients (Gmail included)
# are documented to strip file:// <a href> links outright. Whether that
# still applies to THIS button in THIS mail client (Gmail account, read via
# whatever app) has not been re-verified — the file:// path is used because
# it directly matches what was asked, but if it renders unclickable, the
# copyable <code> text below the button (present in both cases) is the
# reliable fallback: select and paste into a browser's address bar.
#
# @param accent_colour CTA button colour (e.g. ACCENT_BLUE)
# @return HTML string
dashboard_cta_block <- function(accent_colour) {
  links <- resolve_dashboard_links()
  resolved <- resolve_dashboard_href(links)
  href <- resolved$href
  local_exists <- resolved$local_exists

  changed_note <- if (is.null(links$explicit_url)) {
    fallback_line <- if (local_exists) {
      "The button above opens the locally rendered dashboard directly. If it
        doesn&#39;t open (some mail clients block file:// links), copy this
        path into a browser instead:"
    } else {
      "The public dashboard went offline when llmtelemetry was made private
        (2026-08-22) to stop it publishing another project&#39;s data. The
        button above opens the (now-private) repo instead &mdash; render the
        dashboard locally (inst/scripts/refresh_roborev_vignette_rds.R then
        quarto render vignettes/roborev_summary.qmd) to make the button open
        it directly next time, or open the expected path once rendered:"
    }
    sprintf(
      '<p style="color:%s; font-size:%s; margin:4px 0 12px 0;">
        %s<br>
        <code style="background-color:%s; color:%s; padding:2px 6px;
          border-radius:3px; font-size:%s; user-select:all;">%s</code>
      </p>',
      DARK_MUTED, EMAIL_FONT_SUBTITLE, fallback_line, DARK_CARD, ACCENT_GREEN,
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
# outside the HTML block itself (e.g. QA markers). Shares resolve_dashboard_href()
# with dashboard_cta_block() so the two can never silently desync (roborev #10271).
effective_dashboard_url <- function() {
  resolve_dashboard_href(resolve_dashboard_links())$href
}
