# Plan: Output QA Defence-in-Depth for llmtelemetry

## Context

The llmtelemetry daily email and Shinylive dashboard have had repeated failures (wrong filenames, tibble-to-scalar bugs, missing day grouping) that only surfaced when the user inspected the output. The micromort project has a working 3-layer QA pattern (CI grep, targets QA, dev script) that catches error patterns in deployed HTML. We need to generalize this to llmtelemetry with two additions:

1. **Negative assertions** (micromort pattern): grep for known error strings
2. **Positive assertions** (new): verify that specific structural features exist in the output

All checks must be independent of Claude — hooks, targets, CI steps that run automatically.

## What Micromort Does (reference)

- **CI workflow** (`pkgdown.yaml:114-136`): curl deployed HTML, grep for 5 error patterns
- **Targets** (`plan_qa_gates.R:235-295`): `qa_deployed_html` target does same via `httr2`
- **Dev script** (`R/dev/verify_pkgdown_urls.R`): manual HTTP 200 check for ~50 URLs

## Approach: 4 Layers

### Layer 1: Email Self-Test (in send_daily_email.R)

Before sending, validate the assembled `email_body` HTML. Add before `blastula::smtp_send()`.

**Negative assertions** — grep email_body for error strings:
- `"Error in"`, `"Error:"`, `"NaN"`, `"NULL"`, `"invalid 'trim'"`, `"prettyNum"`, `"not found"`

**Positive assertions** — check structural features exist:
- `Time Block Activity` heading exists and appears before `Summary`
- Day group headers present (bold rows with date + "blocks)")
- `Daily Cost by Model` heading exists
- Model names present (opus/sonnet/haiku)
- `$/MTok` column present
- Dashboard link present
- At least 1 cost value (`$N.NN` format)

**QA comment markers** — invisible machine-readable tags in the HTML:
```html
<!-- QA:blocks_grouped_by_day=5 -->
<!-- QA:blocks_total=14 -->
<!-- QA:model_breakdown_days=5 -->
<!-- QA:models_found=opus-4-6,sonnet-4-6,haiku-4-5 -->
```

**Action on failure:** `cli::cli_abort()` — block the email. A broken email is worse than no email (misleading data, missing sections). The CI step goes red, user gets notified via GitHub Actions failure email instead. Save HTML to `/tmp/email_qa.html` for debugging before aborting.

### Layer 2: CI Workflow Step (in daily-report.yaml)

New step after `Send Report`:

```yaml
- name: Validate email output
  if: always()
  run: |
    [ ! -f /tmp/email_qa.html ] && exit 0
    ERRORS=0
    # Negative patterns
    for pat in "Error in" "Error:" "NaN" "NULL" "not found"; do
      COUNT=$(grep -ci "$pat" /tmp/email_qa.html || true)
      [ "$COUNT" -gt 0 ] && echo "::error::Email '$pat' ($COUNT)" && ERRORS=$((ERRORS+COUNT))
    done
    # Positive features
    for feat in "Time Block Activity" "Daily Cost by Model" "Summary" \
                "font-weight: bold" "MTok" "blocks)"; do
      grep -qi "$feat" /tmp/email_qa.html || { echo "::error::Missing: $feat"; ERRORS=$((ERRORS+1)); }
    done
    # Ordering check
    B=$(grep -n "Time Block Activity" /tmp/email_qa.html | head -1 | cut -d: -f1)
    S=$(grep -n ">Summary<" /tmp/email_qa.html | head -1 | cut -d: -f1)
    [ -n "$B" ] && [ -n "$S" ] && [ "$B" -gt "$S" ] && echo "::error::Blocks after Summary" && ERRORS=$((ERRORS+1))
    # QA markers
    grep -q "QA:blocks_grouped_by_day=" /tmp/email_qa.html || { echo "::error::No day-grouping marker"; ERRORS=$((ERRORS+1)); }
    grep -q "QA:model_breakdown_days=" /tmp/email_qa.html || { echo "::error::No model-breakdown marker"; ERRORS=$((ERRORS+1)); }
    [ $ERRORS -gt 0 ] && exit 1
    echo "Email QA passed"
```

### Layer 3: Dashboard Deploy Content QA (in deploy-dashboard.yaml)

Extend the existing "Verify deployment" step (line 130) to add content checks:

```bash
# Data file row counts
for f in ccusage_daily ccusage_blocks; do
  ROWS=$(curl -sf "${BASE}/data/${f}.json" | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  [ "$ROWS" = "0" ] && echo "::warning::${f}.json has 0 rows" || echo "OK: ${f}.json ($ROWS rows)"
done
# Blocks should have date field (day-grouped data)
HAS_DATE=$(curl -sf "${BASE}/data/ccusage_blocks.json" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print('startTime' in d[0] if d else 'empty')" 2>/dev/null)
[ "$HAS_DATE" != "startTime" ] && echo "::warning::blocks missing startTime field"
```

### Layer 4: Generalizable QA Script (new file)

**File:** `inst/scripts/qa_email_output.sh`

A standalone bash script that takes an HTML file path and runs all checks. Reusable by CI, hooks, and manual invocation.

```bash
#!/usr/bin/env bash
# qa_email_output.sh — validate email HTML output
# Usage: bash inst/scripts/qa_email_output.sh /tmp/email_qa.html
set -euo pipefail
FILE="${1:?Usage: qa_email_output.sh <html_file>}"
[ ! -f "$FILE" ] && echo "SKIP: $FILE not found" && exit 0
# ... all negative + positive + ordering + marker checks ...
```

## Files to Modify

| File | Action | Effort |
|------|--------|--------|
| `inst/scripts/send_daily_email.R` | Add QA assertions + HTML dump + QA markers | Medium |
| `inst/scripts/qa_email_output.sh` | **CREATE** — standalone bash QA script | Low |
| `.github/workflows/daily-report.yaml` | Add validation step calling qa_email_output.sh | Low |
| `.github/workflows/deploy-dashboard.yaml` | Extend verify step with content + row count checks | Low |

## Key Design Decisions

1. **Block-and-fail** for the email — broken email is worse than no email
2. **QA comment markers** (`<!-- QA:key=value -->`) are invisible but machine-greppable
3. **Positive assertions > negative only**: absence of "Error" doesn't verify day-grouping happened
4. **Same bash script at multiple layers**: email self-test saves HTML → CI calls `qa_email_output.sh` → same script usable locally
5. **Row count checks on deployed JSON**: catches empty/corrupt data files

## Verification

1. `parse("inst/scripts/send_daily_email.R")` succeeds
2. `bash inst/scripts/qa_email_output.sh /tmp/email_qa.html` passes
3. `gh workflow run "Daily LLM Report"` — QA step green
4. Deliberately break day grouping → CI QA step goes red
5. Dashboard deploy reports row counts for data files
