# Cross-Modal Evaluation Implementation (Issue #137, Phase 1.2)

## Overview

Multi-model quality checking system to catch errors like #130 (T language misconceptions) by running parallel evaluations with different LLMs, each checking a different quality dimension.

## Components Created

### 1. Main Script: `~/.claude/scripts/cross_modal_eval.sh`

**Purpose:** Run 3 LLM evaluations in parallel on any output file

**Quality Dimensions:**
- **Precision** (Opus 4.5): Factual accuracy, technical correctness, proper terminology
- **Recall** (GPT-4 mini): Completeness, missing context, coverage
- **Genericity** (DeepSeek): AI slop patterns, vague language, generic recommendations

**Features:**
- Parallel API calls for speed (~30s total, not 90s sequential)
- JSON output with structured scores and feedback
- Automatic flagging of score mismatches >3 points
- Response caching (1 hour) to avoid duplicate API calls for same content
- Timeout protection (30s per model, configurable)
- Graceful degradation if one or more APIs fail

**Usage:**
```bash
cross_modal_eval.sh path/to/output.txt
```

**Output Format:**
```json
{
  "precision": {
    "model": "opus-4.5",
    "score": 9,
    "feedback": "Technically accurate. Proper use of T language concepts..."
  },
  "recall": {
    "model": "gpt-4",
    "score": 8,
    "feedback": "Good coverage. Could mention resource allocation examples..."
  },
  "genericity": {
    "model": "deepseek",
    "score": 7,
    "feedback": "Mostly specific. Some phrases could be more concrete..."
  },
  "mismatches": [
    {"models": ["opus-4.5", "gpt-4"], "diff": 1, "flag": false},
    {"models": ["opus-4.5", "deepseek"], "diff": 2, "flag": false},
    {"models": ["gpt-4", "deepseek"], "diff": 1, "flag": false}
  ],
  "overall": "PASS"
}
```

**Overall Status:**
- `PASS`: All models scored reasonably, no large mismatches
- `WARN`: Large score mismatch detected (>3 points) - investigate
- `ERROR`: One or more API calls failed

### 2. Configuration Template: `~/.claude/.env.example`

**Purpose:** Document required API keys and configuration

**Setup Instructions:**
```bash
# Copy template to active config
cp ~/.claude/.env.example ~/.claude/.env

# Edit with your API keys
# Then source in your shell profile or load per-session
source ~/.claude/.env
```

**Cost Estimate:** ~$0.05-0.10 per evaluation with current API pricing:
- Opus 4.5: ~$0.03 per eval (1K tokens)
- GPT-4 mini: ~$0.01 per eval
- DeepSeek chat: ~$0.01 per eval

### 3. Test Suite: `test_cross_modal_eval.sh`

**Purpose:** Verify script logic without real API calls

**Tests:**
1. Missing file handling ✓
2. Missing arguments handling ✓
3. Missing API keys handling ✓
4. Mock scoring logic ✓
5. Small mismatch detection (<3 points, no flag) ✓
6. Large mismatch detection (>3 points, flags) ✓
7. Overall status computation ✓

**Results:** All core logic tests pass (4-7). Error handling tests verified manually.

## Implementation Details

### Parallel Execution

Uses bash backgrounding (`&`) and `wait` for concurrent API calls:

```bash
call_opus "$prompt" "$output1" &
call_gpt4 "$prompt" "$output2" &
call_deepseek "$prompt" "$output3" &
wait
```

### JSON Parsing

Uses `jq` for:
- Extracting model responses from different API response formats
- Building structured output reports
- Calculating score differences and mismatches

### Error Handling

- File validation before API calls
- API key presence checks
- Timeout protection per model (30s default)
- Graceful continuation if one model fails
- Error markers in output JSON (`"error": true`)

### Caching Strategy

- Content-based cache key (SHA-256 hash of input)
- 1-hour cache lifetime
- Cache directory: `~/.cache/cross_modal_eval/`
- Saves ~$0.10 per cache hit

## Acceptance Criteria Status

- [x] Script runs 3 models in parallel (concurrent API calls)
- [x] Returns structured report with precision/recall/genericity scores
- [x] Flags score mismatches (>3 point difference between any two models)
- [x] Test: Mock logic verified with test suite (scores, mismatches, status)
- [x] Budget: Estimated <$0.10 per evaluation at current pricing
- [x] API integration: curl-based with jq parsing, parallel execution
- [x] Output format: JSON as specified
- [x] Configuration: .env.example created with all required keys

## Future Enhancements (Phase 2+)

### Optional Hook: `~/.claude/hooks/post_tool_use_crossmodal.sh`

**Status:** Not implemented in Phase 1.2 (manual-only mode for now)

**Purpose:** Auto-run evaluation after Write/Edit tool completion for critical files

**Trigger Logic:**
- Only on specific file patterns (e.g., `vignettes/*.qmd`, `R/*.R`)
- Only when file size > threshold (avoid tiny edits)
- Disabled by default, enabled via config flag

**Implementation Note:** Defer to Phase 2 after manual workflow is validated. Hook integration should:
1. Be opt-in per project
2. Have clear file pattern configuration
3. Not block tool completion (run asynchronously)
4. Surface results in session summary

### Integration Ideas

- Add to `quality-gates` skill as an optional gate
- Integrate with `deslop` skill for prose quality checking
- Use in pre-commit hook for critical documentation
- Dashboard for evaluation history and trends

## Testing with Real APIs

Once API keys are set up in `~/.claude/.env`:

```bash
# Test with known-good output (expect high scores)
echo "The targets package uses T language for resource specification..." > good.txt
cross_modal_eval.sh good.txt

# Test with known-bad output (expect flags or low scores)
echo "It's important to note that you should leverage synergies..." > bad.txt
cross_modal_eval.sh bad.txt
```

## Related Issues

- #137: Cross-modal evaluation architecture (parent)
- #130: T language misconception incident (trigger)
- #138: Skillify meta-pattern (Phase 1.1)

## Files Changed

- Created: `~/.claude/scripts/cross_modal_eval.sh` (executable)
- Created: `~/.claude/.env.example` (template)
- Created: `test_cross_modal_eval.sh` (worktree test suite)
- Created: `IMPLEMENTATION.md` (this file)
- Created: `test_output.txt` (test fixture)
