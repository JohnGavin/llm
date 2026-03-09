# Best Practices Reference

## Performance Optimization

### Fill Behavior

```markdown
## Row {.fill}
Content expands to fill space

## Row {.flow}
Content uses natural height
```

### Optimize Plot Sizing

```python
# Explicitly set figure sizes for matplotlib
plt.figure(figsize=(10, 6))

# Use responsive plots for interactive libraries
fig.update_layout(height=400, margin=dict(l=0, r=0, t=30, b=0))
```

### Lazy Load Data with Reactive Caching

```python
@reactive.calc
def filtered_data():
    # Only compute when inputs change
    return expensive_filter(df, input.filters())
```

## Code Organization

### Separate Data Processing

```python
#| context: setup
#| include: false
# Load and preprocess data once
import pandas as pd
df = pd.read_csv("data.csv")
df_processed = process_data(df)
```

### Modularize Components

```python
# utils.py
def create_value_box(value, title, color="primary"):
    return dict(
        value=value,
        title=title,
        color=color,
        icon="graph-up"
    )
```

## Error Handling

```python
#| error: true
try:
    fig = create_complex_plot(df)
    fig.show()
except Exception as e:
    print(f"Error creating plot: {e}")
    # Show fallback visualization
    simple_plot(df).show()
```

## Mobile Responsiveness

Enable scrolling for mobile-friendly layout:

```yaml
format:
  dashboard:
    scrolling: true
```

Apply responsive CSS (see `references/theming.md` for SCSS breakpoints).

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Cards not filling space | Add `#| fill: true` to cell options; check parent has `.fill` class |
| Plots cut off | Set explicit height: `fig.update_layout(height=400)` or enable `{scrolling="true"}` |
| Shiny inputs not working | Ensure `server: shiny` in YAML header; check reactive contexts |
| Tables too wide | Use `scrollX: true` in DT options; apply `responsive` class |
| Value boxes not displaying | Must return `dict` (Python) or `list` (R); include `#| content: valuebox` |
