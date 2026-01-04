#' Visualise Search Results
#' 
#' @param data Data frame from mcp_search.
#' @param x_col Column for X axis (default: "date").
#' @param y_col Column for Y axis (default: "popularity").
#' @param color_col Column for color mapping (default: "genre").
#' @return A ggplot object.
#' @importFrom rlang .data
#' @export
vanda_visualise <- function(data, x_col = "date", y_col = "popularity", color_col = "genre") {
  ggplot2::ggplot(data, ggplot2::aes(.data[[x_col]], .data[[y_col]], color = .data[[color_col]])) +
    ggplot2::geom_point(size = 3, alpha = 0.8) +
    ggplot2::theme_minimal() +
    ggplot2::labs(
      title = "V&A Collection Analysis",
      subtitle = paste(y_col, "by", x_col),
      x = x_col, 
      y = y_col
    )
}