## Summary

<!-- 1-3 bullet points describing what this PR does -->

## Changes

<!-- Files changed and why -->

## Test plan

<!-- How was this tested? -->

- [ ] `bash -n` each new script (syntax check)
- [ ] SELFTEST=1 passes for any new `.claude/scripts/*.sh`
- [ ] `devtools::test()` passes (if R package code changed)

## Reviewer checklist

- [ ] All related roborev findings ≥ HIGH severity are either closed (cited as `closes roborev #N`) or acked (`acks roborev #N --reason "…"`). See `bin/roborev_merge_gate.sh <pr#>`.

- [ ] If the session banner shows `ci:UNAVAILABLE` (or `ci:unknown`): this PR body states **CI unavailable** and lists which local gates were run and their result (see `.claude/rules/_companions/ci-outage-local-gates.md`). Auto-Merge cannot apply while CI is absent; merge stays Class C.

## Notes

<!-- Anything reviewers should know -->

🤖 Generated with [Claude Code](https://claude.com/claude-code)
