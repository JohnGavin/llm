#!/usr/bin/env bash
# private_term_hash_lib.sh -- shared tokeniser + HMAC for privacy layer L3
# (llm#1389). Sourced by private_terms_hashes.sh (owner helper) and
# private_term_hash_scan.sh (CI scanner) so both sides normalise identically.
# bash 3.2 compatible. Never prints a term or token on its own.
#
# Normalisation (the contract both sides share):
#   1. lowercase (ASCII), 2. every run of bytes outside [a-z0-9] is a token
#      boundary ('_' and non-ASCII bytes included), 3. a term or an n-gram of
#      consecutive tokens is joined with ONE space, 4. its digest is
#      HMAC-SHA256(salt, joined) as lowercase hex.
# This matches the L1 matcher (private_terms.sh: whole word, case-insensitive,
# boundary at non-alphanumerics, '_' as a separator). One deliberate
# difference: runs of punctuation/whitespace between tokens are all equivalent
# here ("alpha  beta" and "alpha-beta" both match the term "alpha beta"), so
# L3 is never stricter than L1 for terms made of plain words.

PTH_CANARY="zzcanary""privterm7q"
PTH_MAX_TOKENS_LIMIT=8

pth_hmac() {
  # $1 = salt, $2 = message. Prints hex digest.
  local out
  out="$(printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" 2>/dev/null)" || return 1
  printf '%s\n' "${out##* }"
}

pth_normalise() {
  # stdin lines -> lowercase, non-alphanumerics collapsed to single spaces
  LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9\n' ' ' \
    | awk '{ $1 = $1; print }'
}

pth_ngrams() {
  # $1 = max tokens N. stdin: "key<TAB>text" lines. stdout: "key<TAB>ngram"
  # for every n-gram of 1..N consecutive tokens within one line.
  LC_ALL=C awk -v N="$1" '
    {
      i = index($0, "\t")
      if (i == 0) next
      key = substr($0, 1, i - 1)
      txt = tolower(substr($0, i + 1))
      gsub(/[^a-z0-9]+/, " ", txt)
      m = split(txt, t, " ")
      for (s = 1; s <= m; s++) {
        g = ""
        for (n = 1; n <= N && s + n - 1 <= m; n++) {
          g = (n == 1) ? t[s] : g " " t[s + n - 1]
          if (t[s + n - 1] != "") print key "\t" g
        }
      }
    }'
}
