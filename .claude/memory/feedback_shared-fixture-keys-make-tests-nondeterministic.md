---
name: feedback_shared-fixture-keys-make-tests-nondeterministic
description: "Two tests writing rows under the same key tie on a second-resolution timestamp, so the assertion result depends on which row the tie returns"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b39cf87a-57ba-486e-a74d-aec69096ec3d
  modified: 2026-09-13T11:16:26.216Z
---

Two tests in `tests/test_launchd_run_record_timeout.sh` both ran the wrapper
under the label `test.timeout.notfired`. Each wrote a ledger row for that label
within the same clock second, and the assertion helper read
`ORDER BY started_at DESC LIMIT 1`. With equal timestamps the tie broke
arbitrarily: the authoring run reported 16/16, an independent verification run
reported 15/16 (`expected: unenforced / actual: ok`). Reproducing the case in
isolation showed the code under test was correct the whole time (llm#1190,
2026-09-13).

**Why:** the dangerous direction is the opposite one. The same tie could return
the other test's passing row while the behaviour under test was genuinely
broken, and the suite would report green. A test whose outcome depends on
insert timing is not testing the thing it names — the
[[verification-before-completion]] "a check you have never seen fail" trap, in
a form that CAN fail, just not for the stated reason.

**How to apply:** give every fixture case its own key — label, id, filename,
whatever the store is keyed by. Never share one across tests in the same suite.
When a suite passes for one runner and fails for another, suspect shared
fixture state before suspecting the environment, and reproduce the single case
in isolation before editing either side. Run an agent's new tests yourself
rather than accepting the reported count: this one was caught only because the
verification run happened to break the tie the other way.

Related: [[feedback_fixtures-hide-boundary-drift]], [[feedback_verify-causal-claims]]
