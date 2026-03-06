# cmonitor execution inside nix-shell produces expected output

    Code
      head(sanitized_output, 10)
    Output
       [1] "Setup complete\\nTerminal wrapper: /Users/USER/.config/positron/nix-terminal-wrapper.sh\\nRSTUDIO_TERM_EXEC set to execute new shell with Nix environment.\\n\033[38;5;19mAnalyzing usage data to determine cost limits\033[0m\033[38;5;19m...\033[0m"
       [2] "\033[38;5;19mP90 session limit calculated: \033[0m\033[1;38;5;19m72\033[0m\033[38;5;19m,\033[0m\033[1;38;5;19m837\033[0m\033[38;5;19m tokens\033[0m"                                                                                                  
       [3] "╭────────────────────── Summary ──────────────────────╮"                                                                                                                                                                                              
       [4] "│                                                     │"                                                                                                                                                                                              
       [5] "│  📊 Daily Usage Summary - YYYY-MM-DD to YYYY-MM-DD  │"                                                                                                                                                                                              
       [6] "│                                                     │"                                                                                                                                                                                              
       [7] "│  Total Tokens: 2,048,742,729                        │"                                                                                                                                                                                              
       [8] "│  Total Cost: $4,259.20                              │"                                                                                                                                                                                              
       [9] "│  Entries: 23,578                                    │"                                                                                                                                                                                              
      [10] "│                                                     │"                                                                                                                                                                                              

