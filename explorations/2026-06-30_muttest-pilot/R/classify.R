# classify_score: Categorise a numeric score into grade bands.
# Intentionally simple function with multiple branches for mutation testing.
#
# @param score numeric: score in [0, 100]
# @return character: "distinction", "merit", "pass", or "fail"
#
# Branches (mutation targets):
#   < 0          -> stop() with error
#   [0, 50)      -> "fail"
#   [50, 70)     -> "pass"
#   [70, 85)     -> "merit"
#   [85, 100]    -> "distinction"
classify_score <- function(score) {
  if (!is.numeric(score) || length(score) != 1L) {
    stop("score must be a single numeric value")
  }
  if (score < 0 || score > 100) {
    stop("score must be in [0, 100]")
  }
  if (score < 50) {
    return("fail")
  }
  if (score < 70) {
    return("pass")
  }
  if (score < 85) {
    return("merit")
  }
  "distinction"
}
