# cmonitor execution inside nix-shell produces expected output

    Code
      head(sanitized_output, 10)
    Output
       [1] "these 376 derivations will be built:"                               
       [2] "  /nix/store/yl58kbkvd6cnqmxrh4s0xxj06caz16in-R-4.5.0.drv"          
       [3] "  /nix/store/01w73v5p0ga9w6xyil79ji7j993wpifm-r-DBI-1.2.3.drv"      
       [4] "  /nix/store/8lhzfp333v9f5bgw6c3b872hzyrxzm0v-r-cli-3.6.5.drv"      
       [5] "  /nix/store/cqrlljsl4rf8mbwswml9awryqmmzfwic-r-glue-1.8.0.drv"     
       [6] "  /nix/store/zwpg6vz1vc7v5b2r2k6ix8p8gczv3rvp-r-rlang-1.1.6.drv"    
       [7] "  /nix/store/xdizizxibxhxr40ml3wqq0zmpxwc1r8w-r-lifecycle-1.0.4.drv"
       [8] "  /nix/store/3ql1yi225lhlmlcb9q1kpry0h1nzrdjr-r-vctrs-0.6.5.drv"    
       [9] "  /nix/store/h3vxd9xv1h77r9gdrrv971grllmhsp85-r-generics-0.1.3.drv" 
      [10] "  /nix/store/n9wcafb7s13ylk2sjgldbs0p21bcrvbi-r-withr-3.0.2.drv"    

