# cmonitor execution inside nix-shell produces expected output

    Code
      head(sanitized_output, 10)
    Output
       [1] "unpacking 'https://github.com/rstats-on-nix/nixpkgs/archive/YYYY-MM-DD.tar.gz' into the Git cache..." 
       [2] "unpacking 'https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/%2A.tar.gz' into the Git cache..."
       [3] "these 389 derivations will be built:"                                                                 
       [4] "  /nix/store/yl58kbkvd6cnqmxrh4s0xxj06caz16in-R-4.5.0.drv"                                            
       [5] "  /nix/store/01w73v5p0ga9w6xyil79ji7j993wpifm-r-DBI-1.2.3.drv"                                        
       [6] "  /nix/store/8lhzfp333v9f5bgw6c3b872hzyrxzm0v-r-cli-3.6.5.drv"                                        
       [7] "  /nix/store/cqrlljsl4rf8mbwswml9awryqmmzfwic-r-glue-1.8.0.drv"                                       
       [8] "  /nix/store/zwpg6vz1vc7v5b2r2k6ix8p8gczv3rvp-r-rlang-1.1.6.drv"                                      
       [9] "  /nix/store/xdizizxibxhxr40ml3wqq0zmpxwc1r8w-r-lifecycle-1.0.4.drv"                                  
      [10] "  /nix/store/3ql1yi225lhlmlcb9q1kpry0h1nzrdjr-r-vctrs-0.6.5.drv"                                      

