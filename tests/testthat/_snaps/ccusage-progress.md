# show_usage_progress output format is stable

    Code
      show_usage_progress(current = 25, limit = 50, label = "Test Progress")
    Message
      Test Progress [████████████████████░░░░░░░░░░░░░░░░░░░░] 50% ($25.00 / $50.00)

# show_daily_progress output format is stable

    Code
      show_daily_progress(daily_limit = 30, token_limit = 5e+05)
    Message
      
      -- Today's Usage --
      
      Today's Usage [████████████████████░░░░░░░░░░░░░░░░░░░░] 50% ($15.00 / $30.00)
      Tokens: [████████████████████████░░░░░░░░░░░░░░░░] 60% (300,000 / 500,000)

# get_block_history output format is stable

    Code
      get_block_history(days = 10)
    Message
      i No block activity in the last 10 days

