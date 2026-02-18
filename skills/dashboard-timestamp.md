# Dashboard Timestamp Requirement

## Mandatory for All Dashboards

**CRITICAL**: Every dashboard MUST include a creation timestamp showing when it was built.

### Requirements

1. **Position**: Bottom of first/main page
2. **Format**: "Dashboard created: YYYY-MM-DD HH:MM:SS UTC"
3. **Update**: Must update on every build (use `Sys.time()`)
4. **Visibility**: Should be clearly visible but not intrusive

### Implementation Pattern

#### For Shiny/Shinylive dashboards:
```r
# Add to UI at bottom of main content
tags$div(
  style = "margin-top: 20px; padding-top: 10px; border-top: 1px solid #ddd;
           font-size: 11px; color: #666; text-align: right;",
  paste("Dashboard created:", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"))
)
```

#### For Quarto dashboards:
```markdown
---
Dashboard created: `r format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC")`
---
```

#### For HTML dashboards:
```html
<div style="position: fixed; bottom: 10px; right: 10px; font-size: 10px; color: #666;">
  Dashboard created: <!-- Insert timestamp via template -->
</div>
```

### Why This Matters

1. **Version Control**: Know exactly when a dashboard was built
2. **Cache Busting**: Users can verify they're seeing the latest version
3. **Debugging**: Track deployment issues when changes don't appear
4. **Compliance**: Some organizations require timestamp on generated content

### Verification

Always check that:
- Timestamp appears on deployed version
- Timestamp updates with each build
- Format is consistent across all dashboards

### Reference Implementation

See: `randomwalk/vignettes/articles/dashboard_comprehensive.qmd`

```r
tags$div(
  style = "margin-top: 20px; padding-top: 10px; border-top: 1px solid #ddd;
           font-size: 11px; color: #666; text-align: right;",
  paste("Dashboard created:", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"))
)
```