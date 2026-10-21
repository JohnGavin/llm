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

# ---- L. self-heal rows: cause lines the old pattern could not see ------------------
# config-pulse logs "network: DNS not up after 146s" (no error-like word at all), and a
# capitalised "Failed to open archive" was missed by the lowercase/uppercase variants.
if (identical(sp$status, "ok")) {
  p <- sp$policy
  for (j in c("com.claude.config-pulse", "com.claude.knowledge-pulse")) {
    r <- p[p$job == j, , drop = FALSE]
    chk(sprintf("L: shipped table has exactly one self-heal row for %s with no issue", j),
        nrow(r) == 1L && r$class == "self-heal" && !nzchar(r$issue) && nzchar(r$note))
    for (line in c("network: DNS not up after 146s", "error: unable to download 'https://cache.nixos.org/x.narinfo'",
                   "error: Failed to open archive (Unrecognized archive format)")) {
      make_job(j, out = c("INFO: start", line), err = character(0))
      a <- apply_job(j, 1L, shipped)
      chk(sprintf("L: %s '%s' -> self-heal (known bucket, not failed)", j, substr(line, 1, 30)),
          identical(a$bucket, "known") && grepl("^self-heal", a$label))
    }
    make_job(j, out = c("INFO: start", "network: DNS is fine"), err = character(0))
    chk(sprintf("L: %s a different line is NOT self-heal (falsification)", j),
        !identical(apply_job(j, 1L, shipped)$bucket, "known"))
  }
}
tblL <- make_table("l.tsv", "com.test.heal\tDNS not up\tself-heal\t\ttransient network")
make_job("com.test.heal", out = c("network: DNS not up after 146s"), err = character(0))
chk("L: a self-heal row with an EMPTY issue is accepted by the reader", identical(job_failure_policy_read(tblL)$status, "ok"))
chk("L: the cause pattern finds 'DNS not up' (and reports it)", identical(job_failure_cause("com.test.heal", pdir)$cause, "network: DNS not up after 146s"))

# ---- M. retry outcomes: parse, run, overlay, note -------------------------------------
ln <- c("RETRY\tcom.test.a\trecovered", "RETRY\tcom.test.b\tstill-failing", "noise", "RETRY\tcom.test.c\twould-retry")
pr <- job_failure_retry_parse(ln)
chk("M: parse keeps RETRY lines only, label and outcome", nrow(pr) == 3L && identical(pr$label, c("com.test.a", "com.test.b", "com.test.c")))
chk("M: parse of nothing is an empty frame, not an error", nrow(job_failure_retry_parse(character(0))) == 0L)
runner <- function(lines, status = 0L) function(args) structure(lines, status = status)
tmp_script <- file.path(w, "fake_retry.sh"); writeLines("exit 0", tmp_script)
r0 <- job_failure_retry_run(tmp_script, apply = TRUE, runner = runner(ln[1:2], 1L))
chk("M: exit 1 (a retried job still fails) is a determinate result with its outcomes", identical(r0$status, "ok") && nrow(r0$outcomes) == 2L)
r3 <- job_failure_retry_run(tmp_script, apply = TRUE, runner = runner("INDETERMINATE: policy table not usable (empty)", 3L))
chk("M: exit 3 is INDETERMINATE and carries the reason", identical(r3$status, "indeterminate") && grepl("policy table not usable", r3$note, fixed = TRUE))
r2 <- job_failure_retry_run(tmp_script, apply = TRUE, runner = runner(character(0), 2L))
chk("M: any other exit code is INDETERMINATE, never ok", identical(r2$status, "indeterminate") && nzchar(r2$note))
rmiss <- job_failure_retry_run(file.path(w, "no_such_script.sh"), apply = TRUE, runner = runner(character(0), 0L))
chk("M: a missing retry script is INDETERMINATE, never ok", identical(rmiss$status, "indeterminate") && grepl("not found", rmiss$note, fixed = TRUE))
rn <- job_failure_retry_run(tmp_script, apply = TRUE, runner = function(args) stop("boom"))
chk("M: a runner that errors is INDETERMINATE, never ok", identical(rn$status, "indeterminate"))
chk("M: the note is empty when the retry ran fine and non-empty when INDETERMINATE",
    identical(job_failure_retry_note(r0), "") && nzchar(job_failure_retry_note(r3)) && grepl("INDETERMINATE", job_failure_retry_note(r3), fixed = TRUE))
chk("M: no retry result at all also produces a note (cannot be silently omitted)", nzchar(job_failure_retry_note(NULL)))
kn  <- list(bucket = "known", label = "self-heal — transient (log: DNS not up)", issue_url = "", issue_text = "")
r0 <- list(status = "ok", outcomes = pr, note = "")
ov1 <- job_failure_retry_overlay(kn, "com.test.a", r0)
chk("M: a recovered job becomes ok, so it is not reported", identical(ov1$bucket, "ok") && grepl("recovered", ov1$label, fixed = TRUE))
ov2 <- job_failure_retry_overlay(kn, "com.test.b", r0)
chk("M: a job that still fails after its retry is FAILED and says 'retried once'",
    identical(ov2$bucket, "failed") && grepl("retried once", ov2$label, fixed = TRUE) && grepl("DNS not up", ov2$label, fixed = TRUE))
chk("M: falsification: a job with no retry outcome is left exactly as it was", identical(job_failure_retry_overlay(kn, "com.test.z", r0), kn))
chk("M: falsification: would-retry (report-only) changes nothing", identical(job_failure_retry_overlay(kn, "com.test.c", r0), kn))
chk("M: falsification: an ok job is never touched", identical(job_failure_retry_overlay(list(bucket = "ok", label = "ok"), "com.test.a", r0), list(bucket = "ok", label = "ok")))
chk("M: no retry state leaves the row alone", identical(job_failure_retry_overlay(kn, "com.test.a", NULL), kn))
tl <- job_failure_tally(c(ov1$bucket, ov2$bucket, "ok"))
chk("M: tally counts the still-failing job as failed and the recovered one as ok", tl$n_fail == 1L && tl$n_known == 0L)

# ---- N. the email runs the retry BEFORE it builds the table and says so when it cannot ---
chk("N: email calls job_failure_retry_run and the overlay", any(grepl("job_failure_retry_run(", src, fixed = TRUE)) && any(grepl("job_failure_retry_overlay(", src, fixed = TRUE)))
chk("N: email only passes --apply outside dry-run (apply = !dry_run)", any(grepl("apply = !dry_run", src, fixed = TRUE)))
chk("N: email prints the retry note via job_failure_retry_note", any(grepl("job_failure_retry_note(", src, fixed = TRUE)))
i_run <- grep("job_failure_retry_run(", src, fixed = TRUE)[[1L]]
i_q   <- grep("cron_health <- safe_query(", src, fixed = TRUE)[[1L]]
i_int <- grep("interpret_cron_row <- function", src, fixed = TRUE)[[1L]]
chk("N: the retry runs before the cron rows are read and interpreted", i_run < i_int && i_run < i_q)

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
