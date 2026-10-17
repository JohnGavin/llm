-- secret_scan_new_findings.sql (llm#1458 part 2)
--
-- The ONE definition of "a NEW secret_exposure_scan finding": a row of the
-- given run whose (detector, file, line, name) tuple is absent from every
-- other secret_exposure_scan run in the 7 days before that run. Matching is
-- tuple-based, not count-based, because the job alternates runs of different
-- scope, so a count delta is meaningless.
--
-- Shared by scanner_triage.sh (decides what to fix/file) and
-- send_overnight_self_review_email.R (decides what needs the owner), so the
-- two can never disagree about what is new. Both substitute @RUN_ID@ with a
-- run id they have already restricted to [A-Za-z0-9._:-].
SELECT f.detector, f.file_path, coalesce(nullif(f.line_num, ''), '-') AS line_num, f.name
FROM secret_scan_findings f
WHERE f.run_id = '@RUN_ID@' AND NOT EXISTS (
  SELECT 1 FROM secret_scan_findings g
  JOIN housekeeping_runs r ON r.id = g.run_id
  WHERE r.task = 'secret_exposure_scan' AND g.run_id <> '@RUN_ID@'
    AND r.started_at < (SELECT started_at FROM housekeeping_runs WHERE id = '@RUN_ID@')
    AND r.started_at >= (SELECT started_at FROM housekeeping_runs WHERE id = '@RUN_ID@') - INTERVAL 7 DAY
    AND g.detector = f.detector AND g.file_path = f.file_path
    AND coalesce(g.line_num, '') = coalesce(f.line_num, '') AND g.name = f.name)
