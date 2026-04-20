# cmonitor execution inside nix-shell produces expected output

    Code
      head(sanitized_output, 10)
    Output
       [1] "Setup complete\\nTerminal wrapper: /Users/USER/.config/positron/nix-terminal-wrapper.sh\\nRSTUDIO_TERM_EXEC set to execute new shell with Nix environment.\\nAnalyzing usage data to determine cost limits..."
       [2] "P90 session limit calculated: 100,016 tokens"                                                                                                                                                                 
       [3] "╭────────────────────── Summary ──────────────────────╮"                                                                                                                                                      
       [4] "│                                                     │"                                                                                                                                                      
       [5] "│  📊 Daily Usage Summary - YYYY-MM-DD to YYYY-MM-DD  │"                                                                                                                                                      
       [6] "│                                                     │"                                                                                                                                                      
       [7] "│  Total Tokens: 6,899,364,916                        │"                                                                                                                                                      
       [8] "│  Total Cost: $13,536.29                             │"                                                                                                                                                      
       [9] "│  Entries: 36,203                                    │"                                                                                                                                                      
      [10] "│                                                     │"                                                                                                                                                      

