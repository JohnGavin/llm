# cmonitor execution inside nix-shell produces expected output

    Code
      head(sanitized_output, 10)
    Output
       [1] "Analyzing usage data to determine cost limits..."       
       [2] "P90 session limit calculated: N,NNN tokens"             
       [3] "╭────────────────────── Summary ──────────────────────╮"
       [4] "│ │"                                                    
       [5] "│  📊 Daily Usage Summary - YYYY-MM-DD to YYYY-MM-DD │" 
       [6] "│ │"                                                    
       [7] "│  Total Tokens: N,NNN │"                               
       [8] "│  Total Cost: $N,NNN.NN │"                             
       [9] "│  Entries: N,NNN │"                                    
      [10] "│ │"                                                    

