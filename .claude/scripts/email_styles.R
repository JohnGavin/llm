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
# 2026-09-24 (user: "the dashboard button is not working. fix it or remove
# it"): the clickable button was REMOVED for the no-override case. Two
# independent reasons, both present since the button shipped and neither
# ever verified:
#   1. file:// hrefs are documented to be stripped by major mail clients
#      (Gmail included). The 2026-09-09 change above flagged this as an
#      unresolved caveat and shipped it anyway; it was never re-verified.
#   2. The repo-URL fallback (https://github.com/JohnGavin/llmtelemetry) is
#      a PRIVATE repo with no GitHub Pages since 2026-08-22 — it never
#      rendered the dashboard, only GitHub's own repo-listing page.
#      Verified 404: `gh api repos/JohnGavin/llmtelemetry/pages` and
#      https://johngavin.github.io/llmtelemetry/roborev_summary.html.
# Refs llm#1123 (flagged the button as still 404ing).
#
# Current behaviour of dashboard_cta_block():
#   - ROBOREV_DASHBOARD_URL set to an http(s) URL: renders a real, clickable
#     button to that URL (works in every mail client — this is the ONLY case
#     that still renders an <a href>).
#   - Otherwise: no button, no href of any kind. Plain text names the local
#     rendered path and, from file.info()$mtime, how stale it is — so a
#     reader can judge whether the data is trustworthy before copying the
#     path into a browser. Absent-file and stale-file are both said
#     explicitly rather than silently assumed fresh (never claim fresh when
#     the file could not be stat'd — checks-must-distinguish-unknown).
#
# Every piece remains env-overridable:
#   ROBOREV_DASHBOARD_URL        — explicit http(s) override; if set, wins
#                                   outright and renders a real button
#                                   (e.g. point back at a restored public URL
#                                   without touching any script)
#   ROBOREV_DASHBOARD_LOCAL_PATH — where the rendered roborev vignette lives
#                                   on this machine (default: the llmtelemetry
#                                   checkout's rendered vignette HTML)
# ROBOREV_DASHBOARD_REPO_URL was removed 2026-09-24 — it only ever fed the
# now-deleted repo-URL fallback described above.
#
# @return list(explicit_url = chr|NULL, local_path = chr)
resolve_dashboard_links <- function() {
  explicit_url <- Sys.getenv("ROBOREV_DASHBOARD_URL", "")
  list(
    explicit_url = if (nzchar(explicit_url)) explicit_url else NULL,
    local_path = Sys.getenv(
      "ROBOREV_DASHBOARD_LOCAL_PATH",
      file.path(Sys.getenv("HOME"), "docs_gh", "llmtelemetry", "vignettes", "roborev_summary.html")
    )
  )
}

# resolve_dashboard_href(): the single branch (explicit http(s) override >
# no clickable target) that both dashboard_cta_block() and
# effective_dashboard_url() need. Extracted 2026-09-10 (roborev #10271,
# Medium) — the branch previously existed twice, in two different code
# shapes, with nothing enforcing that they stayed in sync; a future edit to
# one (e.g. a new override precedence) could silently desync the rendered
# button href from what effective_dashboard_url() reports as "effective".
#
# 2026-09-24: no longer constructs a file:// href, and no longer falls back
# to the (private, dashboard-less) repo URL — see the block comment above
# resolve_dashboard_links() for why both were removed. An override is only
# treated as a clickable button when it is http(s); anything else (unset,
# or a non-http(s) scheme) means there is no clickable target at all.
#
# @param links list from resolve_dashboard_links()
# @return list(href = chr|NULL, is_button = lgl) — href is NULL and
#   is_button is FALSE whenever there is no clickable target; callers must
#   not render an <a> in that case.
resolve_dashboard_href <- function(links) {
  is_button <- !is.null(links$explicit_url) && grepl("^https?://", links$explicit_url)
  list(
    href = if (is_button) links$explicit_url else NULL,
    is_button = is_button
  )
}

# dashboard_cta_block(): renders the roborev dashboard block — a real button
# when ROBOREV_DASHBOARD_URL is an http(s) override, otherwise plain text
# naming the local rendered path and its staleness. See the block comment
# above resolve_dashboard_links() for the 2026-09-24 removal of the file://
# button and the repo-URL fallback (neither ever worked: mail clients strip
# file:// hrefs, and the repo has been private with no GitHub Pages since
# 2026-08-22).
#
# @param accent_colour CTA button colour (e.g. ACCENT_BLUE) — used only when
#   an http(s) override renders a real button.
# @return HTML string
dashboard_cta_block <- function(accent_colour) {
  links <- resolve_dashboard_links()
  resolved <- resolve_dashboard_href(links)

  if (resolved$is_button) {
    return(sprintf(
      '<div style="margin: 16px 0;">
  <a href="%s"
     style="display:inline-block; padding:10px 20px; background-color:%s;
            color:#1a1a2e; text-decoration:none; border-radius:4px;
            font-weight:bold; font-size:13px;">
    View Full roborev Dashboard
  </a>
</div>',
      resolved$href, accent_colour
    ))
  }

  local_path <- links$local_path
  render_cmd <- paste0(
    "inst/scripts/refresh_roborev_vignette_rds.R &amp;&amp; ",
    "quarto render vignettes/roborev_summary.qmd"
  )

  status_html <- if (!file.exists(local_path)) {
    sprintf(
      'not rendered on this machine &mdash; render it with:<br>
      <code style="background-color:%s; color:%s; padding:2px 6px;
        border-radius:3px; font-size:%s;">%s</code>',
      DARK_CARD, ACCENT_GREEN, EMAIL_FONT_SUBTITLE, render_cmd
    )
  } else {
    # file.info()$mtime is a real filesystem stat, not a cached/assumed
    # value -- age is computed from it directly so "fresh" is never claimed
    # when the file could not be checked (checks-must-distinguish-unknown).
    mtime <- file.info(local_path)$mtime
    age_days <- floor(as.numeric(difftime(Sys.time(), mtime, units = "days")))
    rendered_line <- sprintf(
      "Last rendered: %s (%d day%s ago)",
      format(mtime, "%Y-%m-%d"), age_days, if (age_days == 1) "" else "s"
    )
    if (age_days > 2) {
      sprintf(
        '%s &mdash; <strong style="color:%s;">stale</strong>. Re-render with:<br>
        <code style="background-color:%s; color:%s; padding:2px 6px;
          border-radius:3px; font-size:%s;">%s</code>',
        rendered_line, ACCENT_ORANGE, DARK_CARD, ACCENT_GREEN,
        EMAIL_FONT_SUBTITLE, render_cmd
      )
    } else {
      rendered_line
    }
  }

  sprintf(
    '<p style="color:%s; font-size:%s; margin:4px 0 12px 0;">
      Dashboard (local file &mdash; mail clients cannot open file links;
      copy the path into a browser):<br>
      <code style="background-color:%s; color:%s; padding:2px 6px;
        border-radius:3px; font-size:%s; user-select:all;">%s</code><br>
      %s
    </p>',
    DARK_MUTED, EMAIL_FONT_SUBTITLE, DARK_CARD, ACCENT_GREEN,
    EMAIL_FONT_SUBTITLE, local_path, status_html
  )
}

# effective_dashboard_url(): the single string reported in the QA marker
# (see send_roborev_email.R) for the same target dashboard_cta_block()
# rendered -- kept in sync via resolve_dashboard_href() so the two can never
# silently desync (roborev #10271). 2026-09-24: the no-override case no
# longer has a clickable href, so this now returns:
#   - the http(s) override, if ROBOREV_DASHBOARD_URL is set to one
#   - else the local path (no file:// prefix), if it exists on this machine
#   - else the literal string "none"
# @return character(1) — never NULL, always a length-1 string.
effective_dashboard_url <- function() {
  links <- resolve_dashboard_links()
  resolved <- resolve_dashboard_href(links)
  if (resolved$is_button) return(resolved$href)
  if (file.exists(links$local_path)) return(links$local_path)
  "none"
}
