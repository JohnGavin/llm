#!/usr/bin/env bash
# check_targets_tracks_own_package.sh — a targets pipeline that loads its OWN
# package must also TRACK that package's code (JohnGavin/llm#1295).
#
# The bug: `_targets.R` calls pkgload::load_all() / devtools::load_all() /
# library(<own pkg>) but sets neither `tar_option_set(imports = "<own pkg>")`
# nor calls `tar_source()`. targets then does not hash the package's
# functions, so editing one leaves every dependent target "up to date" and
# tar_make() prints `skipped pipeline` over stale results (seen in
# statues_named_john#105).
#
# WHY A SEPARATE SCRIPT (not a mode of check_targets_presence.sh): presence
# asks "is there a pipeline and does it parse?" and needs no R semantics beyond
# parse(); this asks "does the pipeline's code graph track the package?" and
# needs a parse-tree walk. Different question, different INDETERMINATE
# condition; a mode flag would entangle two exit-code tables. The presence
# script is still consulted (below) when _targets.R is absent.
#
# Exit codes (exit-code-conventions, llm#1140):
#   0 PASS            tracked (imports=/tar_source of R/), no own-package load, or
#                     project is not an R package (no DESCRIPTION)
#   1 FAIL            own package loaded without imports= or tar_source() of R/.
#                     Only ever returned together with a printed
#                     "FAIL untracked-own-package" verdict line.
#   2 usage error
#   3 INDETERMINATE   cannot decide: Rscript missing, a pipeline file does not
#                     parse, imports=/tar_source() path is a non-literal
#                     expression, part of the tree could not be analysed, or R
#                     crashed. The reason is printed.
#
# "Tracks its own package" = targets hashes the package's R/ code: either
# tar_option_set(imports = "<pkg>") or tar_source() of the R/ directory
# (no args, or a literal "R" / "R/..." path). tar_source("scripts") sources
# some other directory and does NOT track the package (llm#1334).
#
# Absent _targets.R: delegated verbatim to check_targets_presence.sh (PASS
# exempt / FAIL undeclared-absence), so the two checkers never disagree.
#
# SCOPE / KNOWN LIMITS (deliberate, not silent):
#  - Follows literal `source("file.R")` calls from _targets.R, recursively.
#    Dynamically built paths are not followed.
#  - A pipeline with a DESCRIPTION that sources R/ by hand and never loads the
#    package (no load_all/library) is out of scope: PASS. Tracking of
#    hand-sourced files is not checked here.
#  - Does not check that files targets read are format="file" (rule prose only).
#
# Usage:
#   check_targets_tracks_own_package.sh [project-dir]    # default: cwd
#   check_targets_tracks_own_package.sh --selftest

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELFTEST=0
TARGET_DIR="."

usage() {
    echo "Usage: $(basename "$0") [project-dir]" >&2
    echo "       $(basename "$0") --selftest" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        (--selftest) SELFTEST=1; shift ;;
        (-h|--help)  usage; exit 2 ;;
        (-*)         usage; exit 2 ;;
        (*)          TARGET_DIR="$1"; shift ;;
    esac
done

# R analysis. args: project-dir pkg-name. Prints one verdict line; exit 0/1/3.
read -r -d '' R_CODE <<'EOR'
args <- commandArgs(trailingOnly = TRUE)
dir <- args[1]; pkg <- args[2]
indet <- function(msg) { cat("INDETERMINATE:", msg, "\n"); quit(status = 3) }

# Any uncaught R error is INDETERMINATE (3), never Rscript's default exit 1,
# which would read as FAIL "own package untracked" (llm#1334 finding 1).
options(error = function() {
  cat("INDETERMINATE: R error in analysis: ", geterrmessage(), "\n")
  quit(status = 3, save = "no")
})

loads <- character(); tracked <- character(); unresolved <- character()
sourced <- character(); other_src <- character()

str_of <- function(e) if (is.character(e) && length(e) == 1L) e else if (is.symbol(e)) as.character(e) else NA_character_

collect_str <- function(e) {
  if (is.character(e)) return(e)
  if (is.call(e)) return(unlist(lapply(as.list(e), collect_str)))
  character()
}

is_empty_arg <- function(x) identical(x, quote(expr = ))

# tar_source() tracks the package iff it sources the package's R/ directory
# (default files = "R", or a literal "R" / "R/..." path). A literal path
# elsewhere does not; a non-literal path cannot be resolved (NA).
tar_source_tracks <- function(e) {
  nm <- names(e)
  pos <- seq_along(e)[-1]
  unnamed <- if (is.null(nm)) pos else pos[nm[pos] == ""]
  idx <- if (!is.null(nm) && "files" %in% nm) which(nm == "files")[1]
         else if (length(unnamed)) unnamed[1] else NA_integer_
  if (is.na(idx)) return(TRUE)
  arg <- e[[idx]]
  strs <- collect_str(arg)
  if (!length(strs)) return(NA)
  strs <- sub("^\\./", "", sub("/+$", "", strs))
  any(strs == "R" | startsWith(strs, "R/"))
}

walkerr <- character()

walk <- function(e, file) {
  if (is.call(e)) {
    f <- e[[1]]
    fn <- if (is.symbol(f)) as.character(f)
          else if (is.call(f) && length(f) == 3L && is.symbol(f[[1]]) &&
                   as.character(f[[1]]) %in% c("::", ":::"))
            as.character(f[[3]])[1] else ""
    a1 <- if (length(e) > 1L && !is_empty_arg(e[[2]])) str_of(e[[2]]) else NA_character_
    if (fn == "load_all") loads <<- c(loads, paste0(file, ": load_all()"))
    if (fn %in% c("library", "require", "requireNamespace") && identical(a1, pkg))
      loads <<- c(loads, paste0(file, ": ", fn, "(", pkg, ")"))
    if (fn == "tar_source") {
      ts <- tar_source_tracks(e)
      if (isTRUE(ts)) tracked <<- c(tracked, paste0(file, ": tar_source()"))
      else if (is.na(ts)) unresolved <<- c(unresolved, paste0(file, ": tar_source() path is non-literal"))
      else other_src <<- c(other_src, paste0(file, ": tar_source() of a non-R/ path"))
    }
    if (fn == "tar_option_set") {
      nm <- names(e)
      if (!is.null(nm) && "imports" %in% nm) {
        ie <- e[["imports"]]
        strs <- collect_str(ie)
        syms <- setdiff(all.names(ie), c("c", "list"))
        if (pkg %in% strs || pkg %in% syms) tracked <<- c(tracked, paste0(file, ": imports=", pkg))
        else if (length(syms) > 0L) unresolved <<- c(unresolved, paste0(file, ": imports= is non-literal (", paste(syms, collapse = ","), ")"))
      }
    }
    if (fn == "source" && !is.na(a1) && is.character(e[[2]])) sourced <<- c(sourced, e[[2]])
    for (i in seq_along(e)) if (!is_empty_arg(e[[i]])) walk_safe(e[[i]], file)
  } else if (is.pairlist(e) || is.expression(e) || is.list(e)) {
    for (i in seq_along(e)) if (!is_empty_arg(e[[i]])) walk_safe(e[[i]], file)
  }
}

# A subtree the walker cannot analyse is RECORDED, never dropped silently: the
# run ends INDETERMINATE rather than PASS-over-a-hole (llm#1334 finding 5).
walk_safe <- function(e, file) {
  tryCatch(walk(e, file), error = function(err)
    walkerr <<- c(walkerr, paste0(file, ": ", conditionMessage(err))))
}

queue <- file.path(dir, "_targets.R"); seen <- character()
while (length(queue)) {
  f <- queue[1]; queue <- queue[-1]
  if (f %in% seen) next
  seen <- c(seen, f)
  ex <- tryCatch(parse(f, keep.source = FALSE), error = function(e) e)
  if (inherits(ex, "error")) indet(paste0("cannot parse ", f, ": ", conditionMessage(ex)))
  sourced <- character()
  for (e in as.list(ex)) walk_safe(e, basename(f))
  for (s in sourced) {
    p <- file.path(dir, s)
    if (file.exists(p) && grepl("\\.[Rr]$", p)) queue <- c(queue, p)
  }
}

if (length(walkerr))
  indet(paste0("could not analyse part of the pipeline: ", paste(unique(walkerr), collapse = "; ")))

if (length(loads) && !length(tracked)) {
  if (length(unresolved)) indet(paste(unresolved, collapse = "; "))
  cat("FAIL untracked-own-package: loads own package '", pkg, "' (",
      paste(unique(loads), collapse = "; "),
      ") but no tar_option_set(imports = \"", pkg, "\") and no tar_source() of R/",
      if (length(other_src)) paste0(" (saw: ", paste(unique(other_src), collapse = "; "), ")"), " -- ",
      "edits to package code will not invalidate targets (llm#1295)\n", sep = "")
  quit(status = 1)
}
if (length(loads)) {
  cat("PASS tracked: own package '", pkg, "' loaded and tracked (",
      paste(unique(tracked), collapse = "; "), ")\n", sep = ""); quit(status = 0)
}
cat("PASS no-own-package-load: _targets.R (+ ", length(seen) - 1L,
    " sourced file(s)) never loads '", pkg, "' via load_all/library/require\n", sep = "")
quit(status = 0)
EOR

check_one() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        echo "USAGE-ERROR: not a directory: $dir"
        return 2
    fi
    if [ ! -f "$dir/DESCRIPTION" ]; then
        echo "PASS not-a-package: $dir has no DESCRIPTION (nothing to track; hand-sourced R/ pipelines are out of scope)"
        return 0
    fi
    if [ ! -f "$dir/_targets.R" ]; then
        "$SCRIPT_DIR/check_targets_presence.sh" "$dir"
        return $?
    fi
    local pkg
    pkg="$(sed -n 's/^Package:[[:space:]]*\([A-Za-z0-9.]*\).*/\1/p' "$dir/DESCRIPTION" | head -1)"
    if [ -z "$pkg" ]; then
        echo "INDETERMINATE: $dir/DESCRIPTION has no readable 'Package:' field"
        return 3
    fi
    if ! command -v Rscript >/dev/null 2>&1; then
        echo "INDETERMINATE: Rscript not on PATH — cannot parse $dir/_targets.R to look for load_all()/library($pkg)"
        return 3
    fi
    local rfile out rc=0
    rfile="$(mktemp "${TMPDIR:-/tmp}/tracks_own_pkg.XXXXXX")"
    printf '%s\n' "$R_CODE" > "$rfile"
    out="$(Rscript --vanilla "$rfile" "$dir" "$pkg" 2>&1)" || rc=$?
    rm -f "$rfile"
    # rc 1 is also Rscript's code for ANY uncaught R error, so it only counts as
    # FAIL when the analysis printed its own FAIL verdict line (llm#1334).
    if [ "$rc" -eq 1 ] && ! printf '%s\n' "$out" | grep -q '^FAIL untracked-own-package'; then
        echo "INDETERMINATE: Rscript exited 1 without a FAIL verdict (R crash?): $out"
        return 3
    fi
    case "$rc" in
        (0|1|3) echo "$out" ;;
        (*)     echo "INDETERMINATE: Rscript failed unexpectedly (rc=$rc): $out"; rc=3 ;;
    esac
    return "$rc"
}

selftest() {
    local tmp pass=0 fail=0 out rc
    tmp="$(mktemp -d)"
    ok(){ pass=$((pass+1)); echo "  PASS: $1"; }
    bad(){ fail=$((fail+1)); echo "  FAIL: $1"; }
    echo "check_targets_tracks_own_package.sh --selftest"
    if ! command -v Rscript >/dev/null 2>&1; then
        echo "  INDETERMINATE: Rscript not on PATH; selftest needs R"
        rm -rf "$tmp"; return 3
    fi
    mk() { mkdir -p "$tmp/$1"; printf 'Package: mypkg\nVersion: 0.1.0\n' > "$tmp/$1/DESCRIPTION"; cat > "$tmp/$1/_targets.R"; }
    expect() { # name want-rc want-regex dir
        out="$(check_one "$tmp/$4")"; rc=$?
        if [ "$rc" -eq "$2" ] && printf '%s' "$out" | grep -Eq "$3"; then ok "$1 -> rc=$rc"
        else bad "$1: want rc=$2 /$3/, got rc=$rc out=$out"; fi
    }

    mk f1 <<'EOS'
library(targets)
pkgload::load_all()
list(tar_target(x, mypkg::f()))
EOS
    expect "FALSIFIER load_all without imports must FAIL" 1 '^FAIL untracked-own-package' f1

    mk f2 <<'EOS'
library(targets)
library(mypkg)
list(tar_target(x, f()))
EOS
    expect "library(own pkg) without imports must FAIL" 1 '^FAIL' f2

    mk f3 <<'EOS'
library(targets)
devtools::load_all()
tar_option_set(imports = "mypkg")
list(tar_target(x, f()))
EOS
    expect "load_all + imports=\"mypkg\"" 0 '^PASS tracked' f3

    mk f4 <<'EOS'
library(targets)
load_all()
tar_option_set(imports = c("other", "mypkg"))
list()
EOS
    expect "load_all + imports=c(..., mypkg)" 0 '^PASS tracked' f4

    mk f5 <<'EOS'
library(targets)
library(mypkg)
tar_source()
list()
EOS
    expect "library + tar_source() (default dir R/ = the package code)" 0 '^PASS tracked' f5

    # llm#1334 finding 2: tar_source() only tracks the package when it sources R/.
    mk f5b <<'EOS'
library(targets)
library(mypkg)
tar_source("scripts")
list()
EOS
    expect "library + tar_source(\"scripts\") does NOT track R/ -> FAIL" 1 '^FAIL untracked-own-package' f5b

    mk f5c <<'EOS'
library(targets)
library(mypkg)
tar_source("R/")
list()
EOS
    expect "library + tar_source(\"R/\") tracks" 0 '^PASS tracked' f5c

    mk f5d <<'EOS'
library(targets)
library(mypkg)
tar_source(files = src_dirs)
list()
EOS
    expect "tar_source(non-literal) -> INDETERMINATE" 3 '^INDETERMINATE.*tar_source' f5d

    # llm#1334 finding 1: a callee shaped h(a)(b, c)(d) made an R `&&` error at
    # top level; that crash used to leave rc 1 (FAIL). It must not crash at all.
    mk c1 <<'EOS'
library(targets)
h(a)(b, c)(d)
list()
EOS
    expect "odd callee h(a)(b,c)(d) does not crash" 0 '^PASS no-own-package-load' c1

    # An empty argument (x[, 1]) must not crash the walker either.
    mk c2 <<'EOS'
library(targets)
y <- x[, 1]
f(, 2)
list()
EOS
    expect "empty call arguments do not crash" 0 '^PASS no-own-package-load' c2

    # llm#1334 finding 1 (wrapper): ANY R crash (Rscript rc 1, no verdict line)
    # is INDETERMINATE (3), never FAIL (1). Stand-in Rscript that dies like R.
    mkdir -p "$tmp/fakebin"
    printf '#!/bin/sh\necho "Error in foo(): boom" >&2\necho "Execution halted" >&2\nexit 1\n' > "$tmp/fakebin/Rscript"
    chmod +x "$tmp/fakebin/Rscript"
    out="$(PATH="$tmp/fakebin:$PATH" check_one "$tmp/f1")"; rc=$?
    if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q '^INDETERMINATE'; then ok "R crash (rc 1, no verdict) -> INDETERMINATE rc=3"
    else bad "R crash: want rc=3 INDETERMINATE, got rc=$rc out=$out"; fi

    mk f6 <<'EOS'
library(targets)
library(dplyr)
list(tar_target(x, 1))
EOS
    expect "no own-package load" 0 '^PASS no-own-package-load' f6

    mk f7 <<'EOS'
library(targets)
tar_option_set(imports = pkgs_var)
pkgload::load_all()
list()
EOS
    expect "non-literal imports= -> INDETERMINATE" 3 '^INDETERMINATE.*non-literal' f7

    mk f8 <<'EOS'
list(
  tar_target(x, 1 +
EOS
    expect "unparsable _targets.R -> INDETERMINATE" 3 '^INDETERMINATE: cannot parse' f8

    mk f9 <<'EOS'
library(targets)
source("R/tar_plans/plan.R")
list()
EOS
    mkdir -p "$tmp/f9/R/tar_plans"
    echo 'pkgload::load_all()' > "$tmp/f9/R/tar_plans/plan.R"
    expect "load_all inside a sourced plan file is found" 1 '^FAIL.*plan.R' f9

    mkdir -p "$tmp/n1"
    expect "no DESCRIPTION -> PASS not-a-package" 0 '^PASS not-a-package' n1

    mkdir -p "$tmp/n2"; printf 'Package: mypkg\n' > "$tmp/n2/DESCRIPTION"
    expect "DESCRIPTION but no _targets.R -> presence semantics (FAIL undeclared)" 1 '^FAIL undeclared-absence' n2

    mk n3 <<'EOS'
list()
EOS
    out="$(PATH="/usr/bin:/bin" check_one "$tmp/n3")"; rc=$?
    if command -v Rscript >/dev/null 2>&1 && [ "$(PATH="/usr/bin:/bin" command -v Rscript)" = "" ]; then
        if [ "$rc" -eq 3 ]; then ok "Rscript missing -> INDETERMINATE rc=3"; else bad "Rscript missing: rc=$rc out=$out"; fi
    else
        echo "  SKIP: Rscript is in /usr/bin or /bin; cannot narrow PATH to hide it"
    fi

    out="$(check_one "$tmp/nope")"; rc=$?
    if [ "$rc" -eq 2 ]; then ok "nonexistent dir -> usage rc=2"; else bad "usage: rc=$rc"; fi

    rm -rf "$tmp"
    echo "  $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

[ "$SELFTEST" -eq 1 ] && { selftest; exit $?; }

check_one "$TARGET_DIR"
exit $?
