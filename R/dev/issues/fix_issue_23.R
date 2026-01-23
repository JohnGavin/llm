# Fix for issue #23: Add tests and documentation for ccusage progress functions
# URL: https://github.com/JohnGavin/llm/issues/23
# Date: 2026-01-22

# Session setup
library(devtools)
library(testthat)
library(usethis)

# Commands executed:

# 1. Create test infrastructure
use_testthat()

# 2. Create test file
use_test('ccusage-progress')

# 3. Document functions
document()

# 4. Run tests
test()

# 5. Run R CMD check
check()
