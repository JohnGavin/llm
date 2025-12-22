# =============================================================================
# Nix Environment Configuration for R Development
# =============================================================================
#
# ⚠️  CRITICAL WARNING: NEVER USE QUOTE CHARACTERS IN DOCUMENTATION COMMENTS ⚠️
# The Nix parser interprets quotes EVEN IN COMMENTS as syntax elements!
# ❌ FORBIDDEN in documentation: Double quotes, single quotes, backticks
# ✅ ALLOWED in documentation: Use angle brackets <text> or plain descriptive text
# ℹ️  NOTE: Commented-out R code with quotes is OK (not passed to Nix parser)
# See: NIX_COMMENT_QUOTE_FIX.md for the recurring bug this causes
#
# ⚠️ CRITICAL: Before editing shell_hook section (lines ~358-470), read:
#    NIX_ESCAPING_RULES.md - Documents recurring Nix syntax error with dollar-HOME
#
# This file generates default.nix using the rix package.
# =============================================================================
#
# DOCUMENTATION OF POST-PROCESSING FIXES (2025-12-09)
#
# The following R code applies post-processing patches to the generated `default.nix`
# to address specific build and dependency issues with the 'ahead' package and its
# dependencies ('ForecastComb', 'misc'). These issues arise from a combination of
# `rix` behavior, Nix's strict evaluation, and package inter-dependencies.
#
# --- Fix 4: Fix 'ahead' package attribute missing error ---
# ISSUE: `rix` generated `inherit (pkgs.rPackages) ... ahead ...` inside the
#        `ForecastComb` derivation in `default.nix`. However, 'ahead' is defined
#        as a local GitHub package derivation, not within `pkgs.rPackages`.
#        This caused a Nix evaluation error: "attribute 'ahead' missing".
# SOLUTION: The post-processing script now comments out any occurrences of 'ahead'
#           within `inherit (pkgs.rPackages)` blocks in `default.nix`,
#           specifically targeting the `ForecastComb` derivation.
#
# --- Fix 5: Patch ForecastComb DESCRIPTION to remove 'ahead' dependency ---
# ISSUE: Even after Fix 4, `ForecastComb` failed to build because its `DESCRIPTION`
#        file (from its GitHub source) listed 'ahead' as a dependency. This created
#        a circular dependency (ahead -> ForecastComb -> ahead) and also meant
#        `ForecastComb` expected 'ahead' to be available, which it wasn't during its
#        build phase.
# SOLUTION: A `postPatch` attribute is injected into the `ForecastComb` derivation
#           in `default.nix`. This `postPatch` uses `sed` to remove all mentions
#           of 'ahead' from `ForecastComb`'s `DESCRIPTION` file during the Nix build,
#           effectively breaking the circular dependency at the build level.
#
# --- Fix 6: Add 'misc' to ForecastComb dependencies ---
# ISSUE: `ForecastComb` attempted to dynamically install the 'misc' package from
#        GitHub during its `.onLoad` function or package startup. This violates
#        Nix's sandboxing rules (no network access during build) and resulted in an
#        "SSL certificate problem" error.
# SOLUTION: 'misc' is explicitly added to `ForecastComb`'s `propagatedBuildInputs`
#           in `default.nix`. This ensures 'misc' is present in the R library path
#           when `ForecastComb` is built, preventing `ForecastComb` from trying to
#           install it dynamically.
#
# --- Fix 7: Clean up stale binaries in 'ahead' package ---
# ISSUE: The 'ahead' package source repository contained pre-compiled binaries
#        (`ahead.so`) for `x86_64` architecture. When building on `arm64` (Apple Silicon),
#        Nix's `R CMD INSTALL` tried to load this incompatible binary, leading to
#        an "incompatible architecture" error. The `make` phase reported "nothing to do",
#        indicating a lack of fresh compilation, suggesting old binaries were present.
# SOLUTION: A `preConfigure` attribute is injected into the 'ahead' derivation in
#           `default.nix`. This `preConfigure` command uses `find` to delete all
#           `*.so` and `*.o` files from the source directory *before* the build
#           process starts, forcing a clean compilation for the correct architecture.
# =============================================================================

# mkdir nix_setup && cd nix_setup
# ./default.sh
# Rscript --vanilla default_sym.R
# nix-store --gc
#  rm -rf /private/tmp/nix-shell-* && nix-collect-garbage -d

### Startup with rix only
# nix-shell --pure --expr "$(curl -sl https://raw.githubusercontent.com/b-rodrigues/rix/master/inst/extdata/default.nix)"
# --vanilla else ~/.Rprofile is run
# R --vanilla -e "source('./default_sym.R')"   && cat default.nix

# https://ropensci.r-universe.dev/articles/rix/c-using-rix-to-build-project-specific-environments.html
# nix-shell default.nix --run "Rscript -e 'targets::tar_make()'"

library(rix)

r_pkgs = c(
  # https://thierrymoudiki.github.io//blog/2025/12/07/r/forecasting/ARIMA-Pricing
  # https://github.com/techtonique/ahead
  # https://github.com/Techtonique/esgtoolkit
  # "forecast", "targets", "tarchetypes", # "ahead", "esgtoolkit", 
  # statues named john ~/docs_gh/claude_rix/statues_named_john/PLAN_what.md
  "gender", "chromote", "sf", "WikidataQueryServiceR", "WikidataR", "leaflet", "osmdata", "dplyr", "ggplot2", "httr", "knitr", "purrr", "rmarkdown", "rvest", "sf", "stringr", "tarchetypes", "targets", "testthat", "tibble",

  # https://cran.r-project.org/web/packages/treasury/index.html
  "treasury", 
  # # https://b-rodrigues.github.io/rixpress_demos/rbc/index.html
  # "rixpress",
  # # https://brodrigues.co/posts/2025-05-13-test_rixpress.html
  "igraph", "ggdag", "visNetwork", # for rixexpress / rxp_ga / export_nix_archive 
  # # https://jebyrnes.github.io/bayesian_sem/bayesian_sem.html
  # # "lavaan", "brms", "piecewiseSEM", "rstan", "rstanarm", "tidybayes", "dplyr", "tidyr", "purrr",
  # "emmeans", "readr", "broom", "broom.mixed", "ggdag", "dagitty", "ggplot2", "patchwork", 
  # # https://freerangestats.info/blog/2025/05/17/animated-population-pyramids
  # "tidyverse", "rsdmx", "scales", "janitor", "ISOcodes", "glue", # "spcstyle",
  # # https://geocompx.org/post/2025/sml-bp2/
  # "caret", "CAST", "blockCV", "sf", "terra", "ranger", # "test_metrics", 
  # # "btw", # btw requires "chromote", 
  # # "ggbot2", # https://blog.stephenturner.us/p/voice-control-ggplot2-with-ggbot2
  # # https://posit-conf-2025.github.io/llm/setup.html
  # "askpass","base64enc","beepr","brio","bsicons","digest","dotenv","dplyr",
  #   "ellmer", "forcats","fs", "ggplot2", "here", "leaflet", "magick", "mcptools",
  #   "purrr", "ragnar","reactable", "readr", "scales", "tidyr", "vitals", "watcher", "weathR",
  # # "shiny", # "rstudio/shiny", # remove "rstudio/" to use shiny from CRAN
  # # "bslib", # "rstudio/bslib", # remove "rstudio/" to use bslib from CRAN
  # # "posit-dev/querychat/pkg-r",
  # # "posit-dev/shinychat/pkg-r",
  # # "querychat", 
  # "shinychat",
  # # https://www.simonpcouch.com/blog/2025-05-07-gemini-2-5-pro-new/
  # # https://blog.stephenturner.us/p/r-production-ai
  # # "shinychat", "chores", "gander", "mall", # "ragnar", "ellmer", 
  # # # "bslib",
  "shinylive", 
  # # https://www.ncbi.nlm.nih.gov/geo/geo2r/?acc=GSE181063
  # # "BiocManager", "GEOquery", "limma", "umap",
  # # https://blogs.rstudio.com/ai/posts/2023-07-12-hugging-face-integrations/
  # # "hfhub", # "tok",
  # # https://blog.djnavarro.net/posts/2025-07-05_quarto-syntax-from-r/
  # # "quartose", "babynames", 
  # # https://blog.djnavarro.net/posts/2025-08-02_box-cox-power-exponential/
  # # "readr", "dplyr", "tidyr", "tibble", "ggplot2", "moments", "gamlss.dist", 
  # # https://blog.djnavarro.net/posts/2025-01-08_using-targets/
  # # "legendry", "fs", "docopt", 
  # # "tidyverse", "forecast", "prophet", "nixtlar", 
  # # 'dplyr', 'ggplot2', 'stringr', 'tidyverse', 'matrixcalc', 'LaplacesDemon', # for Dirichlet distribution
  # #'diagram',
  # # https://openpharma.github.io/brms.mmrm/articles/usage.html
  # # "brms.mmrm", "mmrm", "rbmi", 
  # # https://greta-stats.org/articles/get_started
  # # "greta", 
  # # https://aistudio.google.com/prompts/17ToVyFkPf5-SNAvb5ZOZa0eugD80rc23 / https://registry.opendata.aws/mmrf-commpass/
  # "aws.s3", "survival", "survminer", "ComplexHeatmap", "maftools",
  # # https://www.youtube.com/watch?v=skLmOuNjqEU
  # #"ellmer", "shinychat", "shiny", "paws.common", "magick", "beepr", 
  #   # list( # a repo but not a package
  #   # package_name = "rmedicine2025",
  #   # repo_url = "https://github.com/jcheng5/rmedicine-2025",
  #   # commit = "ade6c6e94b0a469ed2ac8cc8e5ecc0dfbad33bb1"),
  # # "ggiraph", "sf", "giscoR", 
  # # https://statisticaloddsandends.wordpress.com/2025/01/30/downloading-datasets-from-our-world-in-data-in-r/
  # # https://icu-hsuzuki.github.io/da4r/owid.html
  # # "owidapi", "owidR", 
  # # https://erikgahner.dk/2019/a-guide-to-getting-international-statistics-into-r/
  # # "WDI", "Rilostat", "OECD", "eurostat", "owidR", # "WHO", 
  # # https://geekcologist.wordpress.com/2025/05/27/the-dynamics-of-the-gentle-way-exploring-judo-attack-combinations-as-networks-in-r/
  # # "igraph", "ggplot2", "dplyr", "tidyr", "RColorBrewer", "bipartite", "bbmle", "influential", "visNetwork", 
  #   # https://geocompx.org/post/2025/sml-bp3/
  #   # recipes::recipe parsnip::rand_forest workflows::workflow rsample::vfold_cv tune::fit_resamples 
  # # "terra", "sf", "ranger", "spatialsample", "waywiser", "vip",
  # # https://www.bioconductor.org/packages/release/bioc/vignettes/AlphaMissenseR/inst/doc/introduction.R
  # #   https://www.bioconductor.org/packages/release/bioc/vignettes/AlphaMissenseR/inst/doc/introduction.html
  #   # "BiocManager", "GenomicRanges", "AnnotationHub", "AlphaMissenseR", "ensembldb", 
  # # https://www.kenkoonwong.com/blog/amr/
  # "Biostrings", "BiocManager", "ape", 
  # https://bioconductor.org/packages/release/bioc/html/DECIPHER.html # "DECHIPER", 
  # https://bdsr.stephenturner.us/handouts/r-survival-cheatsheet.pdf
  #  "survminer", "survival", "RTCGA", "RTCGA.clinical", "RTCGA.mRNA", "ggtree",
  # https://ropensci.r-universe.dev/articles/rix/z-bleeding_edge.html
  #   https://docs.ropensci.org/rix/articles/d1-installing-r-packages-in-a-nix-environment.html#package-installation-issues
  # "arrow", "sf", "igraph", "bioconductor?", "rstan",
  # http://www.pivottabler.org.uk/articles/v14-shiny.html
  "shiny", 
  # "htmlwidgets", "pivottabler", 
  # "webshot2", # for shiny inside .qmd 
  "shinydashboard", "DT", "plotly", "crew", "lubridate", "future", 
  "future.apply", "shinyjs", "purrr", "munsell", 
  "future", "promises", "furrr",  "jsonlite",
  # "missing_async", # "missing", 

  # "progress", 
  "dplyr",# "vctrs", "purrr", "tibble", "tidyr", 

  # https://www.interactivebrokers.com/campus/ibkr-quant-news/yfscreen-yahoo-finance-screener-in-r-and-python/
  # "yfscreen", "yfinance?"
  # pkgs |> sapply(FUN = library, character.only = T)
  # https://www.infoworld.com/article/2262502/plot-in-r-with-echarts4r.html
  # "echarts4r", "dplyr", "RColorBrewer", "paletteer", "data.table", "dplyr",
  # Gerber statistic https://github.com/RcppCore/rcpp-gallery/blob/gh-pages/src/2023-02-05-Combining-R-with-Cpp-and-Fortran.Rmd
  # "Rcpp", "RcppArmadillo", "rbenchmark", "data.table",
  # https://r.iresmi.net/posts/2025/osm_wikidata/
  # https://r.iresmi.net/posts/2025/data_centers/?utm_source=the-r-data-scientist&utm_medium=email&utm_campaign=the-r-data-scientist-04-11-2025
  # "osmdata", "WikidataR", "sf", "leaflet", # "mixedlang", 
  # # https://r.iresmi.net/posts/2025/ridgelines/
  # "elevatr", "rnaturalearth", "terra", "ggplot2", "ggridges", 
  # # remotes::install_github("ropensci/rnaturalearthhires")
  # # https://freerangestats.info/blog/2025/04/26/imf-weo-updates
  # # IMF World Economic Outlook
  # # "readxl", "tidyverse", "rsdmx", "patchwork", "scales", "ggrepel",
  # # "gander",
  # # https://www.rdatagen.net/post/2025-05-20-planning-for-a-three-arm-trial-with-a-nested-intervention/
  # "simstudy", "data.table", "survival", "coxme", "broom", 
  # https://www.rdatagen.net/post/2025-02-11-estimating-a-bayesian-proportional-hazards-model/
  # "simstudy", "data.table", "survival", "survminer", # "cmdstanr",
  # "sf",
  # "brms", # needs gettext else 'intl' mac error
  # https://github.com/NicChr/timeplyr
  # "timeplyr", "tidyverse", "fastplyr", "nycflights13", "lubridate",
  # https://blog.r-hub.io/2025/02/13/lazy-meanings/
  #"bench", "future", "data.table", "dtplyr", "duckplyr", "RSQLite",
  # https://borkar.substack.com/p/r-workflows-with-duckdb?r=2qg9ny
  "arrow", "duckdb", "dplyr", "dbplyr", 
  "ggraph", "igraph", # https://discindo.org/posts/2025-09-20-r-ducklake/
  # # https://github.com/jcheng5/pharma-sidebot
  # # "DBI", "duckdb", "fastmap", "fontawesome", "ggridges", "here", "plotly", "reactable", "shiny", # "hadley/elmer", "jcheng5/shinychat",
  # "checkglobals", # https://github.com/JorisChau/checkglobals
  # "DiagrammeR",
  # # "gtools", # "Rmpfr",
  "reticulate", # forces python to be included?
  # https://github.com/b-rodrigues/nix_targets_pipeline/tree/master
  #   nix::tar_nix_ga (targets GH action)
  # # https://www.jumpingrivers.com/blog/sparkline-reactable/
  # # "reactable", "sparkline",
  # # https://www.seascapemodels.org/rstats/2025/03/15/LMs-in-R-with-ellmer.html
  "tidyfinance", "tidymodels", "tidyquant", "Quandl", "ggtext", "riingo", "ggdist", 
  # https://cran.r-project.org/web/packages/Riex/vignettes/iex_stocks_and_market_data.html
  # https://github.com/TheEliteAnalyst/Riex
  # "Riex", 
  # https://datageeek.com/2025/05/26/forecasting-msci-europe-index-post-trump-tariff-announcement/
  # https://datageeek.com/2025/07/14/nested-forecasting-analyzing-the-relationship-between-the-dollar-and-stock-market-trends/
  # https://datageeek.com/2025/09/09/bagged-neural-networks-will-bayrous-resignation-affect-the-stoxx-600-index/
  # https://datageeek.com/2025/09/05/ensemble-model-for-gold-futures/
  # "tseries", "modeltime", "modeltime.ensemble", "baguette", "modeltime.h2o", "timetk", "earth", "kernlab", "tsibble", "ggh4x", 
  # # dev stuff?
  "mcptools", 
  "ollamar", 
  "attachment", # attachment::att_amend_desc()  # Auto-detect package usage
  # https://drjohnrussell.com/posts/2025-08-20-Scottish-Munros/
  "tidytuesdayR", "sf", "rnaturalearth", "ggview", # rnaturalearthhires
  # https://pacha.dev/blog/2025/08/28/ukmaps/
  # https://pacha.dev/blog/2025/08/30/
  # install_github("pachadotdev/ukmaps") 
  "mirai", "nanonext", 
  "targets", "gittargets", "crew", "autometric", "tarchetypes", "visNetwork", 
  "ggplot2", "tidyverse", "tidyselect", "pins", 
  "pkgdown", "rmarkdown", "knitr", # vignette rendering
  # "bayesianrvfl", "mlbench",
  # "mlr3verse",
  "polite", # (for ethical scraping)
  "dplyr", "stringr", "lubridate", "janitor", 
  # "tidyplots", # "tidyheatmaps",
  "keyring", "air", "withr", # "flir", "lintr", 
  "units", "logger", 
  # "tidyRSS", # "tidygeoRSS", # => sf geospatial
  # "pak", "pacman",
  "cli", 
  "quarto",
  "here", "available",
  # Error while sourcing R profile file at path '/Users/johngavin/.Rprofile':
  "devtools", "spelling", "gert", "gh", "usethis", # NB devtools will also install usethis
  "styler",
  # https://jcarroll.com.au/2025/09/13/i-vibe-coded-an-r-package/
  'testthat', 'httptest', 'covr', 
  # for nix-shell --pure ...
  "rix"
  ) |>
  unique() |>
  sort()

# spot check for dev pkgs 
pkgs_test <- c('usethis', 'devtools', 'gh', 'gert', 'logger', 'dplyr', 'duckdb', 'targets', "visNetwork", 'testthat') 
pkgs_missing <- pkgs_test[!(pkgs_test %in% r_pkgs)]
if (length(pkgs_missing)) print(pkgs_missing)

gh_pkgs <- rlang::list2(
  # NULL
  # # https://brodrigues.co/posts/2025-03-20-announcing_rixpress.html
  # list(
  #   package_name = "rixpress",
  #   repo_url = "https://github.com/b-rodrigues/rixpress",
  #   commit = "a84b454add46df00deaf061fd158ff262248daac"),
  # # https://www.rdatagen.net/post/2025-02-11-estimating-a-bayesian-proportional-hazards-model/
  # list(
  #   package_name = "cmdstanr",
  #   repo_url = "https://github.com/stan-dev/cmdstanr",
  #   commit = "edccf2d2f6449e7d80626a3ee6cc93845e82915b"
  # ),
  # https://posit.co/blog/custom-chat-app/
  #list(
  #  package_name = "ellmer",
  #  repo_url = "https://github.com/tidyverse/ellmer",
  #  commit = "afde3cb59280a7af6f88db5e7fa9a0070da83ee3"),
  # https://posit-conf-2025.github.io/llm/setup.html
    # "posit-dev/querychat/pkg-r",
    # "posit-dev/shinychat/pkg-r",
  # list(
  #   package_name = "querychat",
  #   repo_url = "https://github.com/posit-dev/querychat/pkg-r",
  #   # repo_url = "https://github.com/posit-dev/querychat/tree/main/pkg-r",
  #   commit = "14c86227da5bfe5991a6f9361945b7edd15ae3ac"),
  # list(
  #   package_name = "shinychat",
  #   # repo_url = "https://posit-dev.r-universe.dev/shinychat", 
  #   repo_url = "https://github.com/posit-dev/shinychat/tree/main/pkg-r",
  #   commit = "b80b8ba3978de94ffdb0eea700ca38a84d8ae32d"),
  # MOVED to local_r_pkgs for active development - always uses latest local code
  # list(
  #   package_name = "randomwalk",
  #   repo_url = "https://github.com/johngavin/randomwalk",
  #   commit = "87e513a0a272c0fde2f25b3cd1683123a93465fd"
  # ),
  # https://insightsengineering.github.io/roxy.shinylive/main/
  list(
    package_name = "roxy.shinylive", 
    repo_url = "https://github.com/insightsengineering/roxy.shinylive",
    commit = "c8a1967b0cb79a6bc6a0eab331bd80c57401d371"  # Latest as of 2025-12-09
  ),
  # https://github.com/Techtonique/esgtoolkit
  list(
    package_name = "esgtoolkit", 
    repo_url = "https://github.com/techtonique/esgtoolkit",
    # branch = "main"  # rix doesn't support branch properly, use commit
    commit = "0a9ad8ed1d52de4a66a997dc48e930aa49560a2b"  # Latest as of 2025-12-09
  ),
  #   # https://github.com/techtonique/ahead
  list(
    package_name = "ahead", 
    repo_url = "https://github.com/techtonique/ahead",
    # branch = "main"  # rix doesn't support branch properly, use commit
    commit = "290c76194890faa629de57a29e17a2dce95a9cbe"  # Latest as of 2025-12-09
  ),
  list(
    package_name = "btw", # requires chromote
    repo_url = "https://github.com/posit-dev/btw",
    # 1 Aug 8af117d916d4e4c41c70b8d8ada1f912ea15ad98
    # 19 Oct bd5fc3e3f4759287c00a257ab03ccdc3e829558c
    # 3 Nov 692db86d23d1ff9d19d32802588b91c294d01c10
    # 26 Nov c562575f01790b38a512ed199345aef695424e48
    # branch = "main"  # rix doesn't support branch properly, use commit
    commit = "c562575f01790b38a512ed199345aef695424e48"  # Latest as of 2025-11-26
  ),
  # https://github.com/tidyverse/vitals
  # https://www.simonpcouch.com/blog/2025-05-07-gemini-2-5-pro-new/
  # list(
  #   package_name = "vitals",
  #   repo_url = "https://github.com/tidyverse/vitals",
  #   commit = "68a312ff93f21f1cff090b4e303f18536ba77e5f"),
  # list(
  #   package_name = "kuzco",
  #   repo_url = "https://github.com/frankiethull/kuzco",
  #   commit = "e246feaa0737ff5efe6d8fde06e3848a9fb0dd12"),
  # # list(
  # #   package_name = "chores",
  # #   repo_url = "https://github.com/simonpcouch/chores",
  # #   commit = "9f47541e2930adb42db4470851239e75e8e67c7f"),
  # # list(
  # #   package_name = "gander",
  # #   repo_url = "https://github.com/simonpcouch/gander",
  # #   commit = "fd04d9aaff510a6a5b6755bd2813669324a26d8f"),
  # # high resolution naturalearth data for rnaturalearth
  # list(
  #   package_name = "rnaturalearthhires",
  #   repo_url = "https://github.com/ropensci/rnaturalearthhires",
  #   commit = "e4736f636baa1c013d77d2ba028dd5bc334defee"),
  # https://www.seascapemodels.org/rstats/2025/03/17/LLMs-in-R-tool-use.html
  #  ocean data from the IMOS BlueLink database.
  #  # /nix/store/pbkhxcwbkn6rp2xzprprw5lzj3dwz56g-r-RNetCDF-2.9-2.drv fails
  # list(
  #    package_name = "remora",
  #    repo_url =  "https://github.com/IMOS-AnimalTracking/remora/",
  #    commit = "f461f826799133c6c599ba624c2b093058d03884"),
  #  list(
  #    package_name = "housing",
  #    repo_url = "https://github.com/rap4all/housing/",
  #    commit = "1c860959310b80e67c41f7bbdc3e84cef00df18e"),
)


# For `nix-env`, `nix-build`, `nix-shell` add to ~/.config/nixpkgs/config.nix
# { allowUnfree = true; }
# To temporarily allow unfree packages,
# export NIXPKGS_ALLOW_UNFREE=1
Sys.setenv("NIXPKGS_ALLOW_UNFREE"=1)
system_pkgs <- c(
  "locale", "direnv", "jq", 
  "nodejs", 
  # "tinytex", 
  "curlMinimal", 
  "nano", 
  # https://jebyrnes.github.io/bayesian_sem/bayesian_sem.html
  # "stanc", 
  "cmdstan", 
  # "python312", # "python312Packages\\.statsmodels",
  # "glibcLocales",
  # "nix",
  # https://positron.posit.co/rstudio-rproj-file.html#use-an-application-launcher
    # https://www.andrewheiss.com/blog/2025/07/22/positron-open-with-finder/
    # "raycast", 
  # "podman", 
  "duckdb", "tree", 
  "awscli2",
  "bc", # calculator
  "htop", "btop", 
  "typst", 
  "copilot-cli", 
  "gemini-cli",
  #   nix search nixpkgs codex
  "codex", # overrides $PATH (which git from /opt/homebrew does not permissions inside nix - use npm installed codex)
  "claude-code", # https://blog.stephenturner.us/p/positron-assistant-copilot-chat-agent
  "ollama",
  "cacert", # CA certs / trusted TLS/SSL root certs
  # echo $SSL_CERT_FILE ; echo $NIX_SSL_CERT_FILE
  # "radianWrapper",
  "gh", "git", # "node", "npm", 
  "gnupg", 
  "toybox", # coreutils-full # else 'which' etc is missing with nix-shell --pure
  # translation tools - gettext
  #   else brms 'intl' error libintl-dev
  "gettext",
  "quarto", "pandoc", # ?
  # 'pdflatex' is needed to make vignettes but is missing on your system.
  "texliveBasic",
  "less", # pager needs less
  # , "gmp", "mpfr"
    # --- Julia ---
  "unzip",      # Solves "unzip: command not found"
  "libiconv",   # Often a good idea on macOS for various tools, helps with character encoding.
  "gcc", "libgcc", # "gccNGPackages_15.libgfortran", "gfortran15", 
  # TODO: the dot is not allowed use underscore?
  # "llvmPackages.openmp", # for `libomp` Issue: devtools::check() is failing due to ld: library not found for -lomp in the Nix environment.
  # For the "xcode-select" issue:
  # There isn't a Nix package that *is* `xcode-select`.
  # We need to provide the underlying tools. `stdenv` (which `rix` should use for Julia)
  # already does this for the compilation of Julia itself.
  # If a script *still* calls `xcode-select`, it's a script issue.
  #
  # `pkgs.darwin.XCRun` provides the `xcrun` command, which is often used by scripts
  # that also interact with Xcode tools. Adding it might help if the script
  # falls back to `xcrun` or uses it after an `xcode-select` check.
  # "darwin.XCRun"
  #
  # `pkgs.cctools` (contains linker, assembler) and `pkgs.clang` (the compiler) are
  # fundamental. On macOS, these are typically part of `stdenv` (`pkgs.clangStdenv`).
  # `rix` should ensure Julia is built with this. Explicitly adding them to `system_pkgs`
  # might make them available in the top-level shell if `rix`'s Julia setup script
  # (not Julia's Nix build, but a script `rix` runs) needs them directly in the PATH
  # and isn't inheriting them properly.
  # However, start without these two explicitly, as `darwin.XCRun` and `stdenv` should cover most cases.
  # "cctools",
  "clang"
  # "libevdev", "libevdevc" # 
  # --- END Julia ---

  ) |>
  unique() |>
  sort()

# shellHook as string
# Crucially,
#   use single quotes *inside* the string, and
#   double quotes around the entire string,
# because we're going to be embedding this inside a Nix string later.
shell_hook <- r"(
# =============================================================================
# SHELL HOOK: Critical setup for Nix environment with Positron integration
# =============================================================================
#
# CRITICAL ESCAPING RULES - THIS HAS BROKEN MULTIPLE TIMES
#
# ⚠️  CRITICAL WARNING: NEVER USE QUOTE CHARACTERS IN DOCUMENTATION COMMENTS ⚠️
# The Nix parser interprets quotes EVEN IN COMMENTS as syntax elements!
# ❌ FORBIDDEN in documentation: Double quotes, single quotes, backticks
# ✅ ALLOWED in documentation: Use angle brackets <text> or plain descriptive text
# ℹ️  NOTE: Commented-out R code with quotes is OK (not passed to Nix parser)
# See: NIX_COMMENT_QUOTE_FIX.md for details on this recurring bug
#
# DETAILED DOCUMENTATION: See NIX_ESCAPING_RULES.md in this directory
#
# This R raw string becomes a Nix shellHook string in default.nix.
# The Nix shellHook uses DOUBLE QUOTES <shellHook = ...>, NOT single quotes.
#
# ESCAPING RULES:
# 1. In this R raw string: Use $HOME directly (no backslash).
# 2. In default.nix: Keep $HOME unescaped and unquoted in paths.
# 3. Avoid backslash-dollar because it creates a literal $HOME at runtime.
#
# CORRECT (in R raw string):     mkdir -p $HOME/.config/positron
# GENERATES (in default.nix):    mkdir -p $HOME/.config/positron
# IN NIX SHELL (runtime):        mkdir -p /Users/username/.config/positron
#
# WRONG: mkdir -p with escaped dollar or quoted escaped dollar path
#    → Generates: mkdir -p with literal $HOME or invalid Nix syntax
#    → Result: literal $HOME directory or parse failure
#
# WHY: Backslash-dollar blocks shell expansion. Use plain $HOME instead.
#
# HISTORICAL ISSUES FIXED:
# 1. sed command trying to read R_LIBS_USER from non-existent path
#    - Problem: $NIX_SHELL_PATH points to shell script, not directory
#    - Solution: Removed sed command entirely, R_LIBS_USER set by Nix
#    - Lines removed by post-processing in this file (search for Fix 3)
#
# 2. .nix-session.log file creation failing
#    - Problem: touch \\$HOME/.nix-session.log had double backslash
#    - When eval'd by default.sh, \\$ becomes \$ which doesn't expand
#    - Solution: Removed these lines entirely as they're not critical
#
# 3. Arrow keys not working in interactive shell
#    - Problem: Readline config created but user's shell (zsh) ignored it
#    - Solution: default.sh detects user's actual shell and applies appropriate config
#    - See default.sh lines 94-95 and 231-247 for implementation
#
# 4. ⚠️ CRITICAL: Nix syntax error unexpected invalid token (2025-11-28)
#    - Problem: Comments containing quote characters cause Nix parse errors
#    - In default.nix comments with quotes like <shellHook = <...>> break parser
#    - Nix parser interprets quotes in comments as syntax elements
#    - Solution: Replace all quotes in comments with angle brackets < >
#    - Applies to ALL comments - avoid single quotes, double quotes, backticks
#    - This bug has recurred multiple times - DO NOT add quotes back to comments!
# =============================================================================

# 1. Create the temporary wrapper script in a stable location
# Use inline expansion to avoid creating literal $WRAPPER_* files
valid_home=1
case $HOME in
  ''|*'$'*) valid_home=0 ;;
  /*) ;;
  *) valid_home=0 ;;
esac

user_ok=0
case $USER in
  ''|*'$'*) user_ok=0 ;;
  *) if [ -d /Users/$USER ]; then user_ok=1; fi ;;
esac

if [ $valid_home -ne 1 ] && [ $user_ok -eq 1 ]; then
  HOME=/Users/$USER
  export HOME
  valid_home=1
fi

if [ $valid_home -ne 1 ]; then
  printf '%s\n' 'Skipping Positron wrapper setup due to invalid HOME.'
else
  mkdir -p $HOME/.config/positron

# The derivation output path from nix-build is stored at the GC root symlink.
# We read the absolute path of the built environment from this symlink.
NIX_SHELL_PATH=$(readlink /Users/johngavin/docs_gh/rix.setup/nix-shell-root)
if [ -z \"$NIX_SHELL_PATH\" ]; then
    # Fallback to current $out if the symlink is missing (though it should not be here)
    NIX_SHELL_PATH=\"$out\" 
fi

cat > $HOME/.config/positron/nix-terminal-wrapper.sh <<EOF
#!/bin/bash

printf '%s\n' 'Activating Nix shell environment...'

# 1. Source the Nix profile script from the *built derivation*.
# The path variable has been substituted here by the outer shell, so this line is a clean source command
# This command is the CRITICAL step that sets PATH, man pages, and other environment variables.
# This is also a shell command, equivalent to the source builtin
# Recommended fix for default.R (line ~204)
# This command is the CRITICAL step that sets PATH, man pages, and other environment variables.
true && source $NIX_SHELL_PATH/etc/profile.d/nix-shell.sh


# 2. Run environment activation hooks (if defined by Nix)
if declare -f __start_nix_shell_environment > /dev/null; then
    __start_nix_shell_environment
fi

# 3. Fix R Console Libraries: Ensure R finds the Nix-built packages.
# The R_LIB_PATH variable must still be escaped to prevent outer shell expansion here.
# DISABLED: This path doesn't exist - NIX_SHELL_PATH is the shell script, not a directory
# R_LIB_PATH=\`sed -n '/R_LIBS_USER/{s/R_LIBS_USER=\"//; s/\"//; p; q}' $NIX_SHELL_PATH/etc/R/Rprofile.site\`
# export R_LIBS_USER=$R_LIB_PATH
# R_LIBS_USER should already be set by the Nix environment

# 4. Final confirmation before launch
printf '%s\n' 'Nix environment fully sourced.'

# 5. Ensure readline is configured for history navigation
# Create a temporary .bashrc for this session with readline settings
echo '# Nix shell readline configuration' > ~/.nix-shell-bashrc
echo 'set -o emacs' >> ~/.nix-shell-bashrc
echo 'bind \"\\e[A\": history-search-backward\"' >> ~/.nix-shell-bashrc
echo 'bind \"\\e[B\": history-search-forward\"' >> ~/.nix-shell-bashrc
echo 'bind \"\\e[C\": forward-char\"' >> ~/.nix-shell-bashrc
echo 'bind \"\\e[D\": backward-char\"' >> ~/.nix-shell-bashrc
echo '' >> ~/.nix-shell-bashrc
echo '# Source user bashrc if it exists' >> ~/.nix-shell-bashrc
echo 'if [ -f ~/.bashrc ]; then source ~/.bashrc; fi' >> ~/.nix-shell-bashrc

# 6. Launch the interactive shell with custom bashrc
# exec replaces the current process with the new shell, making it the final terminal session.
exec /usr/bin/env bash --rcfile ~/.nix-shell-bashrc -i

EOF

# 2. Make the script executable and export path for RStudio/Positron
chmod +x $HOME/.config/positron/nix-terminal-wrapper.sh
export RSTUDIO_TERM_EXEC=$HOME/.config/positron/nix-terminal-wrapper.sh
fi

# 3. Disable user Makevars to prevent Homebrew path conflicts
# User's ~/.R/Makevars may contain Homebrew-specific paths (e.g., /opt/homebrew/opt/libomp)
# These conflict with Nix-provided libraries. Setting R_MAKEVARS_USER to /dev/null
# disables user Makevars, ensuring R uses only Nix environment for compilation.
export R_MAKEVARS_USER=/dev/null

# IMPORTANT: Removed logic to modify ~/.zshrc or ~/.bashrc to prevent infinite recursion.

# === Other standard Nix shell setup ===
export PATH=/Users/johngavin/docs_gh/llm/bin:$PATH
unset CI
printf '%s\\n' 'Setup complete'
printf 'Terminal wrapper: %s\\n' $RSTUDIO_TERM_EXEC
printf 'RSTUDIO_TERM_EXEC set to execute new shell with Nix environment.\\n'
)"


# R --quiet --no-save -e 'installed.packages()[grep(\\"^(gh|gert|usethis|logger)$\\", installed.packages()[,\\"Package\\"]), c(\\"Package\\", \\"Version\\")]'

# ~/.gemini/ or ./.env GEMINI_API_KEY=REDACTED
#  unset CI && which gemini && gemini
#The gemini CLI tool you are using is located at
#  /nix/store/127yg7h9j1q6fnc4s7j8ahvfzj05802a-gemini-cli-0.11.3/bin/gemini. This
#   indicates it is version 0.11.3.
# FAIL which gemini fails inside nix
# FAIL /opt/homebrew/bin/gemini inside nix runs but typing NOT visible
# FAIL export TERM=xterm-256color ; /opt/homebrew/bin/gemini typing NOT visible
# PASS run "nix run nixpkgs/master#gemini-cli " from zsh on mac 
#     (i.e. not inside a nix shell) then text that I type IS visible
#     how to do this with default.nix
# nix run nixpkgs/master#gemini-cli
# npx @google/gemini-cli # if in a nix env
# "npx @google/gemini-cli" runs inside the nix shell but the text that I type is still not visible. If I run "nix run nixpkgs/master#gemini-cli " from a zsh shell on my mac (i.e. not inside a nix shell) then gemini runs and the text that I type is visible. Does "npx @google/gemini-cli" run gemini version that is installed on my mac via homebrew or does it run gemini as installed by nix? how can I confirm which version is running?
#"
#   paste0(
#     "export CPATH='${pkgs.gmp.dev}/include:${pkgs.mpfr.dev}/include:$CPATH'\n",
#     "export LIBRARY_PATH='${pkgs.gmp.out}/lib:${pkgs.mpfr.out}/lib:$LIBRARY_PATH'\n",
#     "      echo 'R environment ready with GMP and MPFR.'\n"
#   ))
# #"
# (shell_hook <- paste0(c("unset R_LIBS_USER", "export R_LIBS_USER='.'")[2], "; export R_LIBS=''"))
  # echo $SSL_CERT_FILE ; echo $NIX_SSL_CERT_FILE

# https://yohann-data.fr/posts/pkg_dev_python/
py_conf = list(
  py_version = "3.12",
  # yfscreen::data_filters  |> tibble()  |> tail() |> glimpse()
  py_pkgs = c("yfinance", # import "yfscreen" fails?
    # https://codecut.ai/deep-dive-into-duckdb-data-scientists/
    "duckdb", "utils", 
    "statsmodels", "polars", "great-tables",
    # https://datageeek.com/2025/10/14/integrating-python-forecasting-with-rs-tidyverse/
    # "sklearn", "nnetsauce", "cybooster", 
    # https://blog.stephenturner.us/p/uv-part-3-python-in-r-with-reticulate
    # https://gist.github.com/stephenturner/2e7ee7443645b7048aa8338d79c55d04
    "scipy", "tf-keras", # "keras", 
    "jax",
    "sympy", "transformers", "torch"
    , "pybigwig"
    , "uv" # https://posit-conf-2025.github.io/llm/setup.html
    , "pynng", # https://www.tidyverse.org/blog/2025/09/nanonext-1-7-0/#python--r-interoperability-example
    # https://shiny.posit.co/blog/posts/shiny-side-of-llms-part-2/
    #, "dotenv" # , "chatlas", 
    # https://b-rodrigues.github.io/rixpress_demos/rbc/index.html
    "pandas", "scikit-learn", "xgboost", "pyarrow"
  ) |>
  unique() |>
  sort()
)
# reticulate::py_require(packages = c( py_conf$py_pkgs, "git+https://github.com/jasonjfoster/screen.git@main#subdirectory=python"), python_version = ">3.12", exclude_newer = "2025-05-18", action = 'set') ; py_require()

  
jl_conf = list(
  # https://b-rodrigues.github.io/rixpress_demos/rbc/index.html
  jl_version = "lts",
  jl_pkgs = c(
    "Distributions", # For creating random shocks
    "DataFrames", # For structuring the output
    "Arrow", # For saving the data in a cross-language format
    "Random"
    # c("TidierData", "GLM")
  )
)

tex_pkgs = c("amsmath", "ninecolors", "apa7", "scalerel", "threeparttable", "threeparttablex", 
    "endfloat", "environ", "multirow", "tcolorbox", "pdfcol", "tikzfill", "fontawesome5", 
    "framed", "newtx", "fontaxes", "xstring", "wrapfig", "tabularray", "siunitx", 
    "fvextra", "geometry","setspace", "fancyvrb", "anyfontsize") |>
  unique() |>
  sort()

(latest <- available_dates() |> sort() |> tail(2) |> head(1))
  # library(dplyr) ; available_df() |> tibble() |> arrange(desc(date)) |> head(5) |> glimpse()
rix(
  date = c(latest, "2025-11-24", "2025-11-03", "2025-11-01", "2025-08-18")[3],
  # or  r_ver = "4.4.3" or r_ver = "latest-upstream"?
  project_path = ".",
  overwrite = TRUE,
  # message_type = c("simple", "verbose", "quiet⁠")[2],
  r_pkgs = r_pkgs,
  # py_conf = py_conf,
  # jl_conf = jl_conf,
  # tex_pkgs = tex_pkgs,
  system_pkgs = system_pkgs,
  git_pkgs = gh_pkgs,
  # Install from local directory - always uses latest code
  # local_r_pkgs: Vector of characters, 
  # paths to local packages to install.
  # These packages need to be in the ‘.tar.gz’ or ‘.zip’ formats
  # and must be in the same folder as the generated "default.nix" file.
  # local_r_pkgs = c(
  #   "/Users/johngavin/docs_gh/claude_rix/random_walk/DESCRIPTION"
  # ),
  ide = c("positron", "rstudio")[1]
  , shell_hook = shell_hook
  #shell_hook = " export R_LIBS_USER=."
)

cli::cli_alert_info("Generated default.nix using rix.")

# --- Post-process default.nix ---
nix_file_path <- "default.nix"
content <- readLines(nix_file_path)
new_content <- c() # To build the modified content line by line

# --- Fix 1: Comment out problematic "if (getRversion() ... S7;" lines ---
indices_to_comment_s7 <- grep("^\\s*if\\s*\\(getRversion\\(\\)\\s*<\\s*4_3_0\\)\\s*S7;", content)

if (length(indices_to_comment_s7) > 0) {
  cli::cli_alert_info(paste("Found", length(indices_to_comment_s7), "S7 'if' lines to comment out."))
  # This rebuilds the content list
  processed_content_s7_fix <- character(0)
  for(i in seq_along(content)) {
    if (i %in% indices_to_comment_s7) {
      original_if_line <- content[i] # Use content[i] as it's the original from readLines
      indentation <- regmatches(original_if_line, regexpr("^\\s*", original_if_line))
      processed_content_s7_fix <- c(processed_content_s7_fix, 
                                    paste0(indentation, "#<- ", trimws(original_if_line))) # Commented line
      processed_content_s7_fix <- c(processed_content_s7_fix, 
                                    paste0(indentation, ";")) # Add the semicolon line
    } else {
      processed_content_s7_fix <- c(processed_content_s7_fix, content[i])
    }
  }
  content <- processed_content_s7_fix # Update content with S7 fixes
  cli::cli_alert_success("Processed S7 'if' lines (commented + added semicolon).")
}


# --- Fix 2: Correct buildInputs line ---
build_inputs_line_idx <- grep("^\\s*buildInputs\\s*=\\s*\\[", content)

if (length(build_inputs_line_idx) == 1) {
  old_line <- content[build_inputs_line_idx]
  cli::cli_alert_info(paste("Found buildInputs line:", trimws(old_line)))
  
  indentation_bi <- regmatches(old_line, regexpr("^\\s*", old_line))
  commented_old_line <- paste0(indentation_bi, "#<- ", trimws(old_line))

  inner_content_match <- regmatches(old_line, regexec("\\[(.*)\\]", old_line))

  if (length(inner_content_match) > 0 && length(inner_content_match[[1]]) == 2) {
    elements_str <- inner_content_match[[1]][2]
    all_elements <- strsplit(trimws(elements_str), "\\s+")[[1]]
    all_elements <- all_elements[nzchar(all_elements)] # Remove empty strings if any

    known_list_vars <- c("rpkgs", "pyconf", "system_packages", "texpkgs")
    
    direct_derivations <- setdiff(all_elements, known_list_vars)
    # Ensure list_vars_in_use preserves the order from all_elements
    list_vars_in_use <- intersect(all_elements, known_list_vars) 
    
    # Reconstruct the buildInputs string correctly
    new_parts <- c()
    if (length(direct_derivations) > 0) {
      new_parts <- c(new_parts, paste0("[ ", paste(direct_derivations, collapse = " "), " ]"))
    }

    if (length(list_vars_in_use) > 0) {
      new_parts <- c(new_parts, list_vars_in_use)
    }
    
    new_build_inputs_content <- paste(new_parts, collapse = " ++ ")

    if (nzchar(new_build_inputs_content)) {
      new_line <- paste0(indentation_bi, "buildInputs = ", new_build_inputs_content, ";")
      
      # Replace the old line with the commented old line and the new line
      # This requires careful list manipulation or rebuilding the content list.
      # Easiest to rebuild if other modifications (like S7) might shift indices.
      
      temp_content_bi_fix <- character(0)
      for(i in seq_along(content)) {
        if (i == build_inputs_line_idx) {
          temp_content_bi_fix <- c(temp_content_bi_fix, commented_old_line, new_line)
        } else {
          temp_content_bi_fix <- c(temp_content_bi_fix, content[i])
        }
      }
      content <- temp_content_bi_fix # Update content with buildInputs fixes

      cli::cli_alert_success(paste("Patched buildInputs. Old line commented, new line added:", trimws(new_line)))
    } else {
      cli::cli_alert_warning("Could not determine new buildInputs content. File not changed for buildInputs.")
    }
  } else {
    cli::cli_alert_warning("Could not parse buildInputs content. File not changed for buildInputs.")
  }
} else {
  cli::cli_alert_warning("buildInputs line not found or found multiple times. File not changed for buildInputs.")
}

# --- Fix 3: Remove problematic sed/R_LIB_PATH lines entirely ---
# ISSUE: sed command tried to extract R_LIBS_USER from Rprofile.site
# Problem: $NIX_SHELL_PATH points to the shell script (/nix/store/xxx-nix-shell),
#          not a directory structure containing etc/R/Rprofile.site
# Error was: "sed: /nix/store/.../nix-shell/etc/R/Rprofile.site: Not a directory"
# Solution: Remove these lines entirely - R_LIBS_USER is already set by Nix environment
content <- content[!grepl("R_LIB_PATH.*sed.*Rprofile|export R_LIBS_USER.*R_LIB_PATH", content)]
cli::cli_alert_success("Removed problematic sed and R_LIB_PATH lines.")

# --- Fix 4: Fix 'ahead' package attribute missing error ---
# ISSUE: rix generates 'inherit (pkgs.rPackages) ... ahead ...' inside ForecastComb
# but ahead is defined locally, not in pkgs.rPackages.
# This causes "error: attribute 'ahead' missing".
# Solution: Comment out 'ahead' inside the inherit block. 
# We assume ForecastComb doesn't strictly need ahead to build, or if it does, 
# it creates a circular dependency (ahead -> ForecastComb -> ahead) which is worse.
ahead_idx <- grep("^\\s+ahead\\s*$", content)
# Ensure we don't comment out the definition "ahead ="
ahead_usage_idx <- ahead_idx[!grepl("=", content[ahead_idx])]

if (length(ahead_usage_idx) > 0) {
  for (idx in ahead_usage_idx) {
    # Check if inside an inherit block (simple heuristic: indented significantly)
    if (grepl("^\\s{6,}", content[idx])) {
       content[idx] <- paste0(
         regmatches(content[idx], regexpr("^\\s*", content[idx])), 
         "# ", 
         trimws(content[idx])
       )
    }
  }
  cli::cli_alert_success(paste("Commented out", length(ahead_usage_idx), "usages of 'ahead' in inherit blocks."))
}

# --- Fix 5: Patch ForecastComb DESCRIPTION to remove 'ahead' dependency ---
# ISSUE: ForecastComb lists 'ahead' in DESCRIPTION, causing build failure 
# ("dependency 'ahead' is not available") because we removed it from inputs 
# to fix the circular dependency/attribute missing error.
# Solution: Use postPatch to remove 'ahead' from DESCRIPTION file during build.
fc_name_idx <- grep('name = "ForecastComb";', content)
if (length(fc_name_idx) == 1) {
  indent <- regmatches(content[fc_name_idx], regexpr("^\\s*", content[fc_name_idx]))
  # Inject postPatch line after the name line
  # We use a crude sed to remove 'ahead' occurrences. 
  # Note: Nix strings need escaping for quotes.
  post_patch_line <- paste0(indent, 'postPatch = "sed -i \'s/ahead//g\' DESCRIPTION";')
  
  # Insert the line
  content <- append(content, post_patch_line, after = fc_name_idx)
  cli::cli_alert_success("Injected postPatch to remove 'ahead' from ForecastComb DESCRIPTION.")
}

# --- Fix 6: Add 'misc' to ForecastComb dependencies ---
# ISSUE: ForecastComb tries to install 'misc' from GitHub during .onLoad
# causing "SSL peer certificate" error and violating sandbox.
# Solution: Add 'misc' to ForecastComb's propagatedBuildInputs so it's present at build time.
fc_name_idx_fix6 <- grep('name = "ForecastComb";', content)
if (length(fc_name_idx_fix6) == 1) {
   # Find start of propagatedBuildInputs AFTER the ForecastComb name line
   prop_start_idx <- grep("propagatedBuildInputs =", content)
   prop_start_idx <- prop_start_idx[prop_start_idx > fc_name_idx_fix6][1]
   
   if (!is.na(prop_start_idx)) {
     # Find the closing "};" for this block
     # It should be the first "};" after the start index
     closing_brace_idx <- grep("^\\s*};", content)
     closing_brace_idx <- closing_brace_idx[closing_brace_idx > prop_start_idx][1]
     
     if (!is.na(closing_brace_idx)) {
       # Replace "};" with "} ++ [ misc ];"
       if (!grepl("misc", content[closing_brace_idx])) {
           content[closing_brace_idx] <- sub("};", "} ++ [ misc ];", content[closing_brace_idx])
           cli::cli_alert_success("Added 'misc' to ForecastComb dependencies.")
       }
     }
   }
}

# --- Fix 7: Clean up stale binaries in 'ahead' package ---
# ISSUE: 'ahead' source seems to contain pre-compiled x86_64 binaries (*.so)
# causing "incompatible architecture" error on arm64 (Apple Silicon).
# Solution: Remove *.so and *.o files before configuring/building.
ahead_def_idx <- grep('name = "ahead";', content)
if (length(ahead_def_idx) == 1) {
  indent <- regmatches(content[ahead_def_idx], regexpr("^\\s*", content[ahead_def_idx]))
  # Inject preConfigure line
  pre_config_line <- paste0(indent, 'preConfigure = "find . -name \'*.so\' -delete; find . -name \'*.o\' -delete;";')
  
  # Insert the line
  content <- append(content, pre_config_line, after = ahead_def_idx)
  cli::cli_alert_success("Injected preConfigure to clean up binaries in 'ahead' package.")
}

# --- Write the fully modified content back to the file ---
writeLines(content, nix_file_path)
cli::cli_alert_info(paste0("Modifications written to '", nix_file_path, "'."))

cli::cli_alert_info("R script finished.")

# cannot pass rev number to rix::rix
#   so file is not cached?
# cli::cli_inform("restart (all packages) (env ./default.nix + positron)")
# nix_build() # project_path = ".")
# system('
#   nix-shell \\
#     --pure \\
#     --keep GITHUB_PAT \\
#     --argstr myVar "some value" \\
#     --command \\
#     " \
#         positron ; echo $myVar ; return ; echo $myVar ; \
#     " \
#     default.nix
# ')
# nix-shell --pure
# which R && which positron # toybox else 'which' fails on mac M2! cos --pure
# R -e ' pacman::p_load(c( "dplyr", "usethis" # else nix-shell --pure ... && R --vanilla
#   ), character.only = TRUE )
