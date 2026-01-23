# Plan: Fix ccusage Progress Bar Implementation

## Problem Statement
Added 8 new functions to R/ccusage.R without following the 9-step workflow:
- No tests
- No documentation
- No branch/PR workflow
- Not integrated into vignettes
- No R CMD check validation

## Functions to Fix
1. `show_usage_progress()` - Display progress bar for LLM usage
2. `show_daily_progress()` - Daily usage progress bars
3. `show_weekly_progress()` - Weekly usage progress bar
4. `show_usage_dashboard()` - Combined dashboard
5. `get_current_block_window()` - Max5 5-hour block calculation
6. `calculate_block_usage()` - Block usage from ccusage data
7. `show_max5_block_status()` - Display Max5 block status
8. `get_block_history()` - Show recent block history

## Implementation Plan

### Phase 1: Setup
- [x] Create this plan document
- [ ] Create GitHub issue via gh::gh()
- [ ] Create branch with usethis::pr_init()
- [ ] Set up test infrastructure

### Phase 2: TDD - Write Tests First
- [ ] Create tests/testthat/test-ccusage-progress.R
- [ ] Write tests for progress bar formatting
- [ ] Write tests for daily/weekly calculations
- [ ] Write tests for Max5 block window logic
- [ ] Run tests - expect RED (failures)

### Phase 3: Documentation
- [ ] Add roxygen2 comments to all 8 functions
- [ ] Include @examples sections
- [ ] Document parameters and return values
- [ ] Run devtools::document()

### Phase 4: Fix Implementation
- [ ] Add input validation with checkmate
- [ ] Add error handling
- [ ] Ensure tests pass (GREEN)
- [ ] Add edge case handling

### Phase 5: Integration
- [ ] Update vignettes/telemetry.qmd to show progress bars
- [ ] Create example in README
- [ ] Ensure data files are committed for CI

### Phase 6: Validation
- [ ] Run devtools::test() - all pass
- [ ] Run devtools::check() - no errors/warnings
- [ ] Test manually with actual ccusage data
- [ ] Push to Cachix if needed

### Phase 7: PR Workflow
- [ ] Commit with gert
- [ ] Push with usethis::pr_push()
- [ ] Wait for CI to pass
- [ ] Merge with usethis::pr_merge_main()

## Success Criteria
- [ ] All 8 functions have tests with >80% coverage
- [ ] All functions have complete roxygen documentation
- [ ] R CMD check passes with no warnings
- [ ] Functions demonstrated in telemetry vignette
- [ ] PR merged via proper workflow

## Risk Mitigation
- If tests reveal design issues, refactor before proceeding
- If R CMD check fails, fix before pushing
- Keep existing working code as fallback

## Time Estimate
- Tests: 1 hour
- Documentation: 30 minutes
- Fixes: 30 minutes
- Integration: 30 minutes
- Total: ~2.5 hours