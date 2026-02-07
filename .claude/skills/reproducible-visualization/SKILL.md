# Reproducible Data Visualization & Reporting

This skill enforces strict adherence to the "Ten Simple Rules for Reproducible Computational Research" (Sandve et al., 2013), specifically refining Rules 7, 8, and 9 for R/Quarto projects.

## Rule 7: Data Behind Plots (Mandatory)

**Requirement:** Every plot must be backed by accessible raw data and generated via the `targets` pipeline.

1.  **No Inline Plotting:** NEVER use `ggplot()`, `plot_ly()`, or `plot()` directly inside a vignette chunk.
    *   **Bad:**
        ```r
        ggplot(data, aes(x, y)) + geom_point()
        ```
    *   **Good:**
        ```r
        # In R/tar_plans/plan_plots.R
        tar_target(plot_trends, generate_trend_plot(data))
        
        # In vignette
        tar_read(plot_trends)
        ```

2.  **Hidden Data Table:** Immediately after every plot, display the source data in a hidden-by-default table (using `DT` or `reactable`).
    ```r
    # Vignette chunk
    tar_read(plot_trends)
    
    # Next chunk (code-fold: true)
    tar_read(data_trends) |>
      create_dt(caption = "Raw data for trend plot")
    ```

## Rule 8: Hierarchical Analysis Output

**Requirement:** Structure outputs (Dashboards, Tabsets) logically to allow drilling down.

1.  **Logical Ordering:**
    *   **Categorical Tabs:** If tabs represent levels of a factor (e.g., "North", "South", "East", "West"), they must follow the factor level order, not alphabetical (unless coincidental).
    *   **Sequential Tabs:** If tabs imply a sequence (Step 1, Step 2), order them chronologically.
    
2.  **Dashboard Hierarchy:**
    *   **Page 1 (Summary):** High-level KPIs, aggregate trends.
    *   **Page 2 (Detail):** Drill-down by category/region.
    *   **Page 3 (Diagnostics):** Data quality, missing values, outliers.

## Rule 9: Connect Text to Results

**Requirement:** Narrative must be dynamically linked to data values.

1.  **Descriptive Captions:** Every plot/table MUST have a caption that:
    *   Starts with a **single sentence summary** rephrasing the Title, Subtitle, X-axis, Y-axis, and Legend.
    *   **Example:** "Figure 1: Scatter plot showing the positive correlation between Engine Displacement (x-axis) and Highway MPG (y-axis), colored by Vehicle Class."

2.  **Top 5 Summary:** The caption or immediate text must summarize the "Top 5" (or relevant subset).
    *   **Example:** "The top 5 most efficient models are: Honda Civic (42 mpg), Toyota Corolla (40 mpg)..."

3.  **Inline Code (The "Golden Rule"):** NEVER hardcode numbers.
    *   **Bad:** "The average cost was $42.50."
    *   **Good:** "The average cost was `r dollar(mean(data$cost))`."
    *   **Implementation:** Use a list/tibble of summary stats generated in the pipeline (`tar_target(stats_summary, ...)`) and `tar_read()` it for inline values.

## Implementation Workflow

1.  **Define Targets:** Create targets for `data`, `plot`, and `summary_stats`.
2.  **Render Vignette:** Use `tar_read()` to pull these artifacts.
3.  **Audit:** Review the HTML to ensure every plot has a data table and every number in the text is dynamic.
