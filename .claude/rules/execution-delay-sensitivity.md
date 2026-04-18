---
paths:
  - "R/plan_*backtest*.R"
  - "R/plan_*oos*.R"
  - "R/*backtest*.R"
  - "R/*pnl*.R"
---
# Rule: Execution Delay Sensitivity

## When This Applies
Any backtest that assumes immediate execution (trade at the signal time).

## CRITICAL: Alpha Decays with Delay

A strategy backtested with t+0 execution may fail at t+1 or t+2.
Measuring alpha decay reveals whether the edge is real (persistent)
or spurious (speed-dependent).

## Mandatory: Delayed-Execution Test

Every backtest MUST include a `qa_execution_delay` target that re-runs
P&L with 1-5 period delays and reports the alpha decay curve.

### For Financial Strategies

```r
tar_target(qa_execution_delay, {
  delays <- 0:5  # t+0 through t+5

  purrr::map_dfr(delays, function(d) {
    # Re-run backtest with d-day execution delay
    pnl <- run_backtest(signals, prices, execution_delay = d)
    tibble::tibble(
      delay_days = d,
      roi_pct = pnl$roi,
      sharpe = pnl$sharpe,
      n_trades = pnl$n_trades
    )
  })
}, cue = tar_cue(mode = "always"))
```

### For Sports Betting

In football betting, "execution delay" means using odds from an earlier
snapshot rather than closing odds:

```r
tar_target(qa_execution_delay, {
  # Compare P&L at closing odds vs odds N days before match
  # If closing-only strategy works but early-bet doesn't, the edge
  # comes from late information the bettor can't reliably capture.

  delays <- c(0, 1, 3, 7)  # hours/days before match

  purrr::map_dfr(delays, function(d) {
    bets <- evaluate_with_odds_at_cutoff(predictions, odds_snapshots, cutoff_hours = d)
    tibble::tibble(
      cutoff_hours = d,
      roi_pct = round(100 * sum(bets$net) / sum(bets$stake), 1),
      n_bets = nrow(bets)
    )
  })
})
```

## Alpha Decay Curve

Plot ROI or Sharpe vs execution delay. A robust strategy shows a
**gradual** decline. A fragile strategy shows a **cliff** at t+1.

| Decay pattern | Interpretation | Action |
|---------------|---------------|--------|
| Gradual (t+5 still positive) | Real edge, execution-robust | Deploy with confidence |
| Cliff at t+1 (t+0 positive, t+1 negative) | Speed-dependent edge | Need sub-second execution or abandon |
| Flat (same at all delays) | Edge is structural, not temporal | Ideal — not speed-sensitive |
| Increasing with delay | Contrarian signal (mean-reversion) | Investigate — may be real |

## Exit Conditions (Multi-Period Strategies)

For strategies that hold positions over time (not single-event bets):

1. **Define exit conditions BEFORE entering** — the definition is fixed
   and known in advance, even if conditions themselves are adaptive
2. **Test exits separately** — a good entry with bad exits destroys value
3. **Types of exits:**
   - Stop-loss (fixed or trailing)
   - Profit target
   - Time-based (exit after N periods regardless)
   - Signal reversal (model flips direction)

```r
# Define exit rules as a configuration, not inline logic
exit_rules <- list(
  stop_loss_pct = 0.02,        # 2% adverse move
  profit_target_pct = 0.05,    # 5% favorable move
  max_holding_days = 10L,      # Time-based exit
  signal_reversal = TRUE       # Exit when model flips
)
```

## Point-in-Time Data

Use point-in-time data to avoid revision bias. Macro announcements,
corporate earnings, and sports statistics are revised after initial
release. The backtest must use the **data available at decision time**,
not the revised data.

This is a specific case of `look-ahead-bias-prevention` rule's
"within-fold bet-time" leakage type.

## Red Flags

| Signal | Problem |
|--------|---------|
| Only t+0 execution tested | Unknown alpha decay |
| Strategy requires sub-hour execution | Impractical for retail |
| No exit rules defined | Implicit "hold forever" assumption |
| Using revised data (not point-in-time) | Revision bias inflates backtest |
| Alpha half-life < 1 day | Edge is real but uncapturable at scale |

## Related Rules

- `look-ahead-bias-prevention` — temporal leakage at feature level
- `backtest-robustness` — test across parameters AND execution delays
- `position-sizing-guardrails` — sizing must account for execution slippage
- `half-life-decay` — correct exponential decay formula for alpha measurement
