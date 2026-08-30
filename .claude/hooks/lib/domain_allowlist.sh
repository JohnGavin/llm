#!/usr/bin/env bash
# domain_allowlist.sh — shared trusted-domain allowlist for the
# external-code-zero-trust hooks (llm#194).
#
# SOURCED, NOT EXECUTED. This file defines data and pure functions only —
# no stdin read, no exit calls, no side effects at source time. Any script
# that sources it must NOT rely on `set -e` catching failures inside these
# functions in a way that would abort the sourcing script unexpectedly;
# both functions below are simple loops/substitutions with no external
# command that can fail unexpectedly.
#
# WHY THIS FILE EXISTS (llm#194 Layer 3 follow-up, 2026-08-30)
# --------------------------------------------------------------
# The domain allowlist previously lived only inside
# external_content_quarantine.sh's own ALLOWED_DOMAINS array (Layer 2).
# Layer 3 (edit_write_similarity_guard.sh) and its companion fingerprint
# capture hook (external_content_fingerprint.sh) need the EXACT SAME
# allowlist — a fetch from an allowlisted domain is trusted and must never
# be fingerprinted or flagged as a possible copy source. Defining the list
# twice would recreate the drift risk llm#958 was raised and fixed for:
# add a domain to one copy, forget the other, and the two hooks silently
# disagree about what counts as trusted. Same rationale as
# lib/cred_patterns.py (llm#960 Part 3) — one logical thing, one file.
#
# Resolution is the caller's job: each consuming script resolves this
# file's path relative to its OWN location
# (`"${BASH_SOURCE[0]%/*}/lib/domain_allowlist.sh"`), never a hardcoded
# `~/.claude/...` path — `~/.claude/hooks/` is a symlink into the main
# checkout in production, so a hardcoded path would silently point at the
# main checkout's copy even when the calling script is under test inside a
# worktree.

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION — edit this list to add/remove trusted domains
# ═══════════════════════════════════════════════════════════════════════════

# Hosts in this list are treated as trusted (no quarantine, no fingerprint,
# no similarity check). Subdomains are NOT automatically trusted — add them
# explicitly.
ALLOWED_DOMAINS=(
  # Anthropic — Claude documentation and API references
  "anthropic.com"
  "docs.anthropic.com"

  # GitHub — trusted for JohnGavin/* repos; raw content
  "github.com"
  "raw.githubusercontent.com"

  # Owner's own published domains
  "johngavin.github.io"
  "johngavin.r-universe.dev"

  # R ecosystem documentation
  "cran.r-project.org"
  "r-lib.github.io"
  "tidyverse.org"
  "tidyverse.github.io"
  "posit-dev.github.io"
  "quarto.org"
  "shiny.posit.co"
  "shinylive.io"
  "rstudio.github.io"
  "blogs.rstudio.com"
  "r-universe.dev"
  "docs.ropensci.org"
  "wlandau.github.io"
  "shikokuchuo.net"

  # Reference and learning
  "machinelearningmastery.com"
  "blog.r-hub.io"
  "www.r-bloggers.com"
  "forum.posit.co"
  "www.andrewheiss.com"
  "blog.vincentqiao.com"
  "www.tidy-finance.org"

  # Project-specific reference domains (finance, gov)
  "www.gov.uk"
  "www.fca.org.uk"

  # Self
  "puntofisso.net"
  "blog.stephenturner.us"
)

# ═══════════════════════════════════════════════════════════════════════════
# HELPER: extract host from URL
# ═══════════════════════════════════════════════════════════════════════════

extract_host_from_url() {
  local url="$1"
  # Strip protocol, then take first path component, then strip port/query
  printf '%s' "$url" | sed 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||' | cut -d'/' -f1 | cut -d':' -f1 | cut -d'?' -f1
}

# ═══════════════════════════════════════════════════════════════════════════
# HELPER: check if host is in the allowlist
# ═══════════════════════════════════════════════════════════════════════════

is_allowed_domain() {
  local host="$1"
  local domain
  for domain in "${ALLOWED_DOMAINS[@]}"; do
    if [ "$host" = "$domain" ]; then
      return 0
    fi
  done
  return 1
}
