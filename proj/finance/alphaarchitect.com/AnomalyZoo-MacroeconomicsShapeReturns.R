# Downloads
# FRED-QD macro data (quarterly)
# OSAP anomaly portfolios (monthly)
# Fama–French 6 factors (monthly)
# q⁵ factors (monthly)

# Aligns everything to a common quarterly panel in the spirit of the paper:
# Monthly returns → quarterly returns (compounded)

# Joins with FRED-QD by year-quarter

# Leaves you with a tibble ready for three-pass / cross-sectional regressions.

# You’ll probably want to tweak:
# the exact anomaly set used,
# the sample window, and
# which q-factors / FF factors are included.

# install.packages(c("tidyverse", "lubridate", "BVAR", "tidyfinance"))
# tidyfinance will in turn pull frenchdata if needed

library(tidyverse)
library(lubridate)
library(BVAR)        # for fred_qd dataset :contentReference[oaicite:0]{index=0}
library(tidyfinance) # for OSAP, FF, q-factors helpers :contentReference[oaicite:1]{index=1}

############################################################
## 1. FRED-QD: quarterly macro data
############################################################
# BVAR ships a snapshot of FRED-QD as 'fred_qd' (1959Q1–2018Q4 in this version) :contentReference[oaicite:2]{index=2}
data("fred_qd")

# fred_qd is a ts / mts. Convert to a tidy tibble with a quarterly date
fred_qd_tbl <- fred_qd |>
  as_tibble() |>
  mutate(
    # index is 1959Q1 start; extract dates from ts attributes
    date_q = as.yearqtr(time(fred_qd)),              # zoo::as.yearqtr if zoo is loaded
    date_q = as.Date(date_q)                         # convert to Date (quarter-end)
  )

# Keep a subset of macro series for illustration
# (In the paper you’d use the full set and then shrink/select.)
macro_vars <- fred_qd_tbl |>
  select(date_q, starts_with("RPI"), starts_with("INDPRO"))  # example subset

############################################################
## 2. OSAP anomalies: monthly long-short portfolios
############################################################
# tidyfinance::download_data_osap() pulls OSAP from Google Sheets :contentReference[oaicite:3]{index=3}
# This particular sheet is a wide LS-anomaly return panel (monthly)
osap_raw <- download_data_osap(
  start_date = "1965-01-01",
  end_date   = "2024-12-31"
)

# Inspect the structure once interactively:
# glimpse(osap_raw)

# Assume osap_raw has columns: date, and many anomaly return columns (e.g., acc, mom, ...),
# already in decimal returns (not percentages). If they’re in percent, divide by 100.

# For illustration pick a small set of anomalies
anomaly_names <- c("acc", "mom", "ni", "rvar_capm")  # change to whatever you want

osap_anoms_m <- osap_raw |>
  select(date, all_of(intersect(anomaly_names, names(osap_raw)))) |>
  mutate(
    date = as.Date(date)
  )

############################################################
## 3. Fama–French 6 factors (monthly)
############################################################
# tidyfinance::download_data_factors() wraps frenchdata + cleaning :contentReference[oaicite:4]{index=4}
ff6_m <- download_data_factors(
  type       = "factors_ff_6_monthly",   # "Mkt_RF", "SMB", "HML", "RMW", "CMA", "Mom"
  start_date = "1965-01-01",
  end_date   = "2024-12-31"
)

# Result is a tibble with date, rf, mkt_excess, and factor columns
# Check names:
# names(ff6_m)

############################################################
## 4. q⁵ factors (monthly, Global-q)
############################################################
# tidyfinance also wraps the Global-q factor library :contentReference[oaicite:5]{index=5}
q5_m <- download_data_factors_q(
  type       = "factors_q5_monthly",     # q⁵ monthly factors
  start_date = "1965-01-01",
  end_date   = "2024-12-31"
)

# Again, you’ll get date, rf, mkt_excess, and q factors. Inspect:
# names(q5_m)

############################################################
## 5. Align everything to a common monthly panel
############################################################

# First, merge FF6 and q5 to a single factor panel
factors_m <- ff6_m |>
  full_join(q5_m, by = "date", suffix = c("_ff6", "_q5"))

# Then join anomalies
panel_m <- osap_anoms_m |>
  left_join(factors_m, by = "date")

# At this stage:
# - panel_m is monthly
# - columns: date, anomaly returns, FF6 factors, q5 factors, rf, etc.

############################################################
## 6. Convert returns to quarterly to match FRED-QD
############################################################
# We want quarterly *excess* returns on anomalies and (optionally) on factor-mimicking portfolios.
# Simplest: compound within calendar quarters.

# Helper: compound (1+r) within group, minus 1
compound_ret <- function(r) prod(1 + r, na.rm = TRUE) - 1

panel_q <- panel_m |>
  mutate(
    quarter = floor_date(date, unit = "quarter")
  ) |>
  group_by(quarter) |>
  summarise(
    across(
      .cols = all_of(anomaly_names),
      .fns  = compound_ret,
      .names = "{.col}_ret_q"
    ),
    # For factor returns, you can also compound or sum (depending on whether
    # you treat them as returns vs. premia). Here we compound for consistency:
    across(
      .cols = setdiff(names(factors_m), "date"),
      .fns  = compound_ret,
      .names = "{.col}_q"
    ),
    .groups = "drop"
  ) |>
  rename(date_q = quarter)

############################################################
## 7. Join quarterly returns with quarterly macro factors
############################################################

panel_q_macro <- panel_q |>
  inner_join(macro_vars, by = "date_q")

# Now:
# - panel_q_macro has one row per quarter
# - Columns:
#   - anomaly_ret_q: quarterly anomaly returns
#   - factor*_q: quarterly factor returns / premia
#   - macro variables from FRED-QD

############################################################
## 8. Example: first-pass time-series regressions
##    (quarterly anomaly excess returns on macro factors)
############################################################

# For illustration, take one anomaly and one macro subset:
first_pass_data <- panel_q_macro |>
  select(
    date_q,
    acc_ret_q,
    # Example macro regressors (rename to something short if you like)
    starts_with("RPI"), starts_with("INDPRO")
  ) |>
  drop_na()

# Simple OLS of acc_ret_q on macro vars (no lags, no shrinkage)
first_pass_fit <- lm(
  acc_ret_q ~ . - date_q,
  data = first_pass_data
)

summary(first_pass_fit)

# Extract fitted betas (first-pass “factor loadings”)
beta_hat <- coef(first_pass_fit)
beta_hat

############################################################
## 9. Example structure for a three-pass panel
############################################################
# In a full replication you would:
# 1) Run a first-pass regression for *each* anomaly j to get beta_j
# 2) Collect beta_j into a matrix B (anomalies × factors)
# 3) Compute mean anomaly returns (per quarter or overall)
# 4) Run cross-sectional regressions:
#      mean_ret_j = lambda' * beta_j + error_j
#    to estimate risk prices λ.

# Skeleton for looping over anomalies:
anomaly_cols_q <- paste0(anomaly_names, "_ret_q")

first_pass_betas <- map_dfr(
  anomaly_cols_q,
  ~ {
    formula_str <- paste(.x, "~", paste(names(macro_vars)[-1], collapse = " + "))
    fit <- lm(as.formula(formula_str), data = panel_q_macro)
    tibble(
      anomaly = .x,
      term    = names(coef(fit)),
      beta    = coef(fit)
    )
  }
)

# 'first_pass_betas' is a tidy table of betas that you can reshape
# into a wide matrix for the second/third pass asset-pricing tests.


# Exact factor sets & sample window
# The script uses placeholder anomaly names and a 1965–2024 window. 
# You’ll want to line up the start date and anomaly subset 
# with whatever the paper actually uses.

# Quarterly alignment choices
# I’ve used calendar quarters and compounded returns within each quarter 
# to match the FRED-QD quarterly frequency. 
# If the paper uses a slightly different convention 
# (e.g. simple sums for factor premia, or lagging macro variables by one quarter), 
# you can adjust the group_by() / summarise() block accordingly.

# which exact anomaly list and macro subset you want to match from the paper?
#		specialise the script to those names and 
#		add the second/third-pass regressions in explicit matrix form.


