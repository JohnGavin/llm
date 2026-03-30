# cmonitor execution inside nix-shell produces expected output

    Code
      head(sanitized_output, 10)
    Output
      [1] "unpacking 'https://github.com/rstats-on-nix/nixpkgs/archive/YYYY-MM-DD.tar.gz' into the Git cache..."                                                                                                                                                 
      [2] "unpacking 'https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/%2A.tar.gz' into the Git cache..."                                                                                                                                                
      [3] "these 2 paths will be fetched (1.16 MiB download, 8.50 MiB unpacked):"                                                                                                                                                                                
      [4] "  /nix/store/my9bsdsfxcaxkb400i4xvvh1ahb8pybs-bash-interactive-5.3p9"                                                                                                                                                                                 
      [5] "  /nix/store/mpcnipkr755v2qpmldawfz23mib1sl3c-readline-8.3p3"                                                                                                                                                                                         
      [6] "copying path '/nix/store/mpcnipkr755v2qpmldawfz23mib1sl3c-readline-8.3p3' from 'https://cache.nixos.org'..."                                                                                                                                          
      [7] "copying path '/nix/store/my9bsdsfxcaxkb400i4xvvh1ahb8pybs-bash-interactive-5.3p9' from 'https://cache.nixos.org'..."                                                                                                                                  
      [8] "Setup complete\\nTerminal wrapper: /Users/USER/.config/positron/nix-terminal-wrapper.sh\\nRSTUDIO_TERM_EXEC set to execute new shell with Nix environment.\\n\033[38;5;19mAnalyzing usage data to determine cost limits\033[0m\033[38;5;19m...\033[0m"

