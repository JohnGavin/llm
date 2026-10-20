#!/usr/bin/env bash
# Failing scheduled jobs arrive in the overnight email with their cause and a
# known/unknown class (.claude/scripts/lib/job_failure_lib.R, policy table
# .claude/state/job_failure_policy.tsv). Pattern: tests/test_scanner_triage.sh.
#
# Every case builds its own scratch plists, logs and policy tables in a temp
# dir and passes them explicitly, so it measures the fixture and never the live
# ~/.claude/logs, ~/Library/LaunchAgents or the shipped table (the shipped table
# is only checked for shape, in section J).
#
# The library is pure R (no DuckDB, no network). Without Rscript the test exits
# 3 (INDETERMINATE) with a visible message -- it does NOT claim a pass.
# Bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
LIB="${JOB_FAILURE_LIB:-$ROOT/.claude/scripts/lib/job_failure_lib.R}"   # override: mutation runs
POLICY="$ROOT/.claude/state/job_failure_policy.tsv"
EMAIL="$ROOT/.claude/scripts/send_overnight_self_review_email.R"

RSCRIPT="$(command -v Rscript || true)"
if [ -z "$RSCRIPT" ]; then
    echo "INDETERMINATE: Rscript not found -- job failure triage NOT exercised"
    exit 3
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/job_failure_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/run.R" <<'EOF'
args <- commandArgs(trailingOnly = TRUE)
source(args[[1L]])
shipped <- args[[2L]]
email   <- args[[3L]]
w <- args[[4L]]
n_ok <- 0L; n_bad <- 0L
chk <- function(desc, cond) {
  if (isTRUE(cond)) { n_ok <<- n_ok + 1L; cat("ok:", desc, "\n") }
  else { n_bad <<- n_bad + 1L; cat("FAIL:", desc, "\n") }
}
pdir <- file.path(w, "plists"); ldir <- file.path(w, "logs"); tdir <- file.path(w, "tables")
for (d in c(pdir, ldir, tdir)) dir.create(d, recursive = TRUE)

make_job <- function(label, out = NULL, err = NULL, plist = TRUE) {
  o <- file.path(ldir, paste0(label, ".out")); e <- file.path(ldir, paste0(label, ".err"))
  if (!is.null(out)) writeLines(out, o)
  if (!is.null(err)) writeLines(err, e)
  if (plist) {
    writeLines(c('<?xml version="1.0" encoding="UTF-8"?>', '<plist version="1.0"><dict>',
                 sprintf('<key>Label</key><string>%s</string>', label),
                 '<key>StandardOutPath</key>', sprintf('<string>%s</string>', o),
                 '<key>StandardErrorPath</key>', sprintf('<string>%s</string>', e),
                 '</dict></plist>'), file.path(pdir, paste0(label, ".plist")))
  }
}
HDR <- "job\tcause_regex\tclass\tissue\tnote"
make_table <- function(name, rows, header = HDR, comments = TRUE) {
  p <- file.path(tdir, name)
  writeLines(c(if (comments) "# fixture table", header, rows), p)
  p
}
failed <- function() list(bucket = "failed", label = "failed")
apply_job <- function(label, exit, tbl) {
  job_failure_apply(failed(), label, exit, job_failure_policy_read(tbl), pdir)
}

# The real line is 161+ chars with the real paths; a short /x/ path hid a 160-char
# cap cutting "unified.duckdb" one letter short (found on the real log, 2026-10-20).
LOCK <- 'Error: unable to open database "/Users/johngavin/.claude/logs/unified.duckdb": IO Error: Could not set lock on file "/Users/johngavin/.claude/logs/unified.duckdb": Conflicting lock is held in duckdb (PID 1)'

# ---- A. known cause, found only in stdout while stderr is empty ------------------
make_job("com.test.lock", out = c("INFO: start", LOCK, "Run Time (s): real 0.000"), err = character(0))
tblA <- make_table("a.tsv", c("com.test.lock\tCould not set lock on file\tknown\t42\tDuckDB lock held by another process"))
a <- apply_job("com.test.lock", 1L, tblA)
chk("A: known cause (stdout only, stderr empty) -> bucket known", identical(a$bucket, "known"))
chk("A: issue link embedded", identical(a$issue_url, "https://github.com/JohnGavin/llm/issues/42") && identical(a$issue_text, "#42"))
chk("A: one line carries the policy note and the log cause", grepl("DuckDB lock held", a$label, fixed = TRUE) && grepl("Could not set lock", a$label, fixed = TRUE))
t <- job_failure_tally(c("ok", a$bucket, "ok"))
chk("A: known job is NOT in the failed count (n_fail 0, n_known 1)", t$n_fail == 0L && t$n_known == 1L)

# A2. the SHIPPED table must classify the real-shaped lock line (not a fixture row)
make_job("com.claude.self-review-stage1", out = c("INFO: start", LOCK), err = character(0))
a2 <- apply_job("com.claude.self-review-stage1", 1L, shipped)
chk("A2: shipped table -> real-shaped lock line is known", identical(a2$bucket, "known"))

# ---- B. unknown cause stays in the headline, with its log line -------------------
make_job("com.test.new", out = c("INFO: start", "ERROR: brand new breakage in step 3"), err = character(0))
b <- apply_job("com.test.new", 1L, tblA)
chk("B: unknown cause -> stays failed", identical(b$bucket, "failed"))
chk("B: its log line is shown with the decision", grepl("brand new breakage", b$label, fixed = TRUE) && grepl("Decision:", b$label, fixed = TRUE))
chk("B: counted in the failed total", job_failure_tally(c("ok", b$bucket))$n_fail == 1L)

# ---- C. falsification: remove the policy row -> job moves back to the headline ----
tblC <- make_table("c.tsv", c("com.test.other\tsomething else\tknown\t9\tnot this job"))
c1 <- apply_job("com.test.lock", 1L, tblC)
chk("C: without its row the lock failure is failed again (falsification of A)", identical(c1$bucket, "failed"))
chk("C: and counts in the headline", job_failure_tally(c(c1$bucket))$n_fail == 1L)

# ---- D. empty / missing / unparseable table = INDETERMINATE, never all-known ------
bad_tables <- list(
  empty_file  = { p <- file.path(tdir, "d1.tsv"); file.create(p); p },
  header_only = make_table("d2.tsv", character(0)),
  comments    = { p <- file.path(tdir, "d3.tsv"); writeLines(c("# only", "# comments"), p); p },
  missing     = file.path(tdir, "does-not-exist.tsv"),
  bad_header  = make_table("d4.tsv", "com.test.lock\tlock\tknown\t42\tn", header = "job\tregex\tclass"),
  bad_class   = make_table("d5.tsv", "com.test.lock\tlock\talways-fine\t42\tn"),
  bad_regex   = make_table("d6.tsv", "com.test.lock\t[unclosed\tknown\t42\tn"),
  bad_issue   = make_table("d7.tsv", "com.test.lock\tlock\tknown\tabc\tn"),
  too_many    = make_table("d8.tsv", "com.test.lock\tlock\tknown\t42\tn\textra"),
  bad_exit    = make_table("d9.tsv", "com.test.lock\texit:12x\tknown\t42\tn")
)
for (nm in names(bad_tables)) {
  pr <- job_failure_policy_read(bad_tables[[nm]])
  chk(sprintf("D(%s): table is not ok (%s)", nm, pr$status), !identical(pr$status, "ok"))
  d <- apply_job("com.test.lock", 1L, bad_tables[[nm]])
  chk(sprintf("D(%s): job is NOT known", nm), !identical(d$bucket, "known"))
  chk(sprintf("D(%s): stays in the headline as INDETERMINATE with a reason", nm),
      identical(d$bucket, "failed") && grepl("INDETERMINATE", d$label, fixed = TRUE) && grepl("policy table", d$label, fixed = TRUE))
}

# ---- E. raw exit 124 + policy row exit:124 -> known, not 'disagree' ---------------
make_job("com.test.slow", out = c("scan started"), err = character(0))
tblE <- make_table("e.tsv", "com.test.slow\texit:124\tknown\t1435\tkilled at the time limit")
disagree <- function() list(bucket = "indeterminate", raw_vs_hb = TRUE,
                            label = "indeterminate — raw exit 124 vs heartbeat 'ok' disagree")
e <- job_failure_apply(disagree(), "com.test.slow", 124L, job_failure_policy_read(tblE), pdir)
chk("E: exit 124 + exit:124 row -> known", identical(e$bucket, "known") && grepl("killed at the time limit", e$label, fixed = TRUE))
chk("E: issue link", identical(e$issue_url, "https://github.com/JohnGavin/llm/issues/1435"))
e2 <- job_failure_apply(disagree(), "com.test.slow", "124", job_failure_policy_read(tblE), pdir)
chk("E: exit code as text '124' also matches", identical(e2$bucket, "known"))
e3 <- job_failure_apply(disagree(), "com.test.slow", 1L, job_failure_policy_read(tblE), pdir)
chk("E: a different exit code does not match (falsification) and the disagreement is left as it was", identical(e3, disagree()))
e4 <- job_failure_apply(disagree(), "com.test.slow", 124L, job_failure_policy_read(make_table("e2.tsv", "com.test.slow\tlock\tknown\t1\tn")), pdir)
chk("E: with no exit row the disagreement is unchanged (falsification)", identical(e4, disagree()))
e5 <- job_failure_apply(failed(), "com.test.slow", 124L, job_failure_policy_read(tblE), pdir)
chk("E: exit row also resolves a plainly failed job", identical(e5$bucket, "known"))
e6 <- job_failure_apply(list(bucket = "ok", label = "ok"), "com.test.slow", 124L, job_failure_policy_read(tblE), pdir)
chk("E: an ok job is never touched", identical(e6$bucket, "ok"))

# ---- F. plist missing / logs unreadable = INDETERMINATE, not human or known -------
make_job("com.test.noplist", out = c(LOCK), plist = FALSE)
f1 <- apply_job("com.test.noplist", 1L, make_table("f1.tsv", "com.test.noplist\tlock\tknown\t5\tn"))
chk("F: plist missing + regex-only row -> not known", !identical(f1$bucket, "known"))
chk("F: shown as INDETERMINATE with the reason", grepl("INDETERMINATE", f1$label, fixed = TRUE) && grepl("plist not found", f1$label, fixed = TRUE))
make_job("com.test.nologs")   # plist points at log files that do not exist
f2 <- apply_job("com.test.nologs", 1L, make_table("f2.tsv", "com.test.nologs\tlock\tknown\t5\tn"))
chk("F: logs unreadable + regex-only row -> not known, INDETERMINATE", !identical(f2$bucket, "known") && grepl("INDETERMINATE", f2$label, fixed = TRUE))
fa <- job_failure_assess("com.test.nologs", 1L, job_failure_policy_read(make_table("f3.tsv", "com.test.nologs\tlock\tknown\t5\tn")), pdir)
chk("F: assess class is 'indeterminate'", identical(fa$class, "indeterminate"))
make_job("com.test.quiet", out = c("all fine, nothing to report"), err = character(0))
fq <- job_failure_assess("com.test.quiet", 1L, job_failure_policy_read(tblA), pdir)
chk("F: logs readable but no error line -> unclassified human, not indeterminate", identical(fq$class, "human") && is.na(fq$cause))

# ---- G. a 'human' policy row keeps the job in the headline, with its issue --------
make_job("com.test.pub", out = c("ERROR: publish_roborev_data.sh failed (exit=1) — aborting email step"), err = character(0))
g <- apply_job("com.test.pub", 1L, make_table("g.tsv", "com.test.pub\tpublish_roborev_data\\.sh failed\thuman\t77\tno reason logged"))
chk("G: human row -> stays failed", identical(g$bucket, "failed"))
chk("G: shows tracking issue and link", grepl("tracked in #77", g$label, fixed = TRUE) && identical(g$issue_url, "https://github.com/JohnGavin/llm/issues/77"))
chk("G: self-heal row -> known bucket",
    identical(apply_job("com.test.lock", 1L, make_table("g2.tsv", "com.test.lock\tlock\tself-heal\t\tretries tomorrow"))$bucket, "known"))

# ---- H. cause line: last match, capped at 160, control characters removed --------
make_job("com.test.long", out = c("ERROR: first", paste0("ERROR: ", strrep("x", 300), "\033[31m\001tail")), err = character(0))
h <- job_failure_cause("com.test.long", pdir)
chk("H: last matching line wins, capped at 160 chars", h$status == "ok" && nchar(h$cause) <= 160 && grepl("^ERROR: x", h$cause))
make_job("com.test.ctl", out = c("ERROR: a\033[1mb\001c"), err = character(0))
hc <- job_failure_cause("com.test.ctl", pdir)
chk("H: control characters stripped", !grepl("[[:cntrl:]]", hc$cause))
make_job("com.test.both", out = c("ERROR: from stdout"), err = c("Error: from stderr"))
chk("H: both streams read, stderr is the later one", identical(job_failure_cause("com.test.both", pdir)$cause, "Error: from stderr"))
make_job("com.test.nul", out = character(0), err = character(0))
writeBin(c(charToRaw("ERROR: before nul\n"), as.raw(0), as.raw(c(0xff, 0xfe)), charToRaw("\nfailed: after nul\n")), file.path(ldir, "com.test.nul.out"))
hn <- job_failure_cause("com.test.nul", pdir)
chk("H: NUL and invalid UTF-8 bytes do not crash and the cause is found", hn$status == "ok" && grepl("after nul", hn$cause, fixed = TRUE))

# ---- I. only the tail of the log counts: an old error is not today's cause --------
make_job("com.test.stale", out = c(LOCK, rep("INFO: fine", 300)), err = character(0))
i1 <- apply_job("com.test.stale", 1L, make_table("i.tsv", "com.test.stale\tCould not set lock\tknown\t42\tn"))
chk("I: an error older than the last 200 lines is not matched -> not known", !identical(i1$bucket, "known"))

# ---- J. the shipped table: shape and seed rows ------------------------------------
sp <- job_failure_policy_read(shipped)
chk("J: shipped table parses", identical(sp$status, "ok"))
if (identical(sp$status, "ok")) {
  p <- sp$policy
  row_of <- function(job, rx) p[p$job == job & p$cause_regex == rx, , drop = FALSE]
  r1 <- row_of("com.claude.private-data-history-audit", "exit:124")
  chk("J: private-data-history-audit exit:124 is known, issue 1435", nrow(r1) == 1L && r1$class == "known" && r1$issue == "1435")
  r2 <- p[p$job == "com.claude.self-review-stage1", , drop = FALSE]
  chk("J: self-review-stage1 lock row is known with an issue", nrow(r2) == 1L && r2$class == "known" && grepl("^[0-9]+$", r2$issue) && grepl("Could not set lock on file", r2$cause_regex, fixed = TRUE))
  r3 <- p[p$job == "com.claude.roborev-daily-email", , drop = FALSE]
  chk("J: roborev-daily-email is human (stays in the headline) with an issue", nrow(r3) == 1L && r3$class == "human" && grepl("^[0-9]+$", r3$issue))
  chk("J: no row for the auto-merge sweep", !any(grepl("auto-merge", p$job, fixed = TRUE)))
  chk("J: the shipped lock regex matches the real error shape", grepl(r2$cause_regex, LOCK))
}

# ---- K. the email actually uses the library ---------------------------------------
src <- readLines(email, warn = FALSE)
chk("K: email sources job_failure_lib.R", any(grepl('lib", "job_failure_lib.R"', src, fixed = TRUE)))
chk("K: email routes rows through job_failure_apply and counts via job_failure_tally",
    any(grepl("job_failure_apply(", src, fixed = TRUE)) && any(grepl("job_failure_tally(", src, fixed = TRUE)))
chk("K: summary line carries the known count", any(grepl("%d need triage · %d known", src, fixed = TRUE)))

cat(sprintf("RESULT: %d passed, %d failed\n", n_ok, n_bad))
quit(status = if (n_bad == 0L) 0L else 1L)
EOF

OUT="$WORK/out.txt"
"$RSCRIPT" --vanilla "$WORK/run.R" "$LIB" "$POLICY" "$EMAIL" "$WORK" > "$OUT" 2>&1
RC=$?
grep -E '^(FAIL|RESULT)' "$OUT"
if [ "$RC" -ne 0 ]; then
    # an R error (not a failed check) is also not a pass
    grep -qE '^RESULT' "$OUT" || { echo "INDETERMINATE: the R harness did not finish:"; tail -n 15 "$OUT"; exit 3; }
    exit 1
fi
exit 0
