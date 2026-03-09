# Layout Patterns Reference

## Navigation Structure

```yaml
format:
  dashboard:
    title: "Multi-Page Dashboard"
    pages:
      - id: overview
        title: "Overview"
      - id: details
        title: "Details"
    nav-buttons:
      - icon: github
        href: https://github.com/yourrepo
      - text: "Help"
        href: help.html
```

## Row-Based Layout (Default)

```markdown
## Row {height=60%}
Content fills 60% of vertical space

## Row {height=40%}
Content fills 40% of vertical space
```

## Column-Based Layout

```markdown
---
format:
  dashboard:
    orientation: columns
---

## Column {width=65%}
Content fills 65% of horizontal space

## Column {width=35%}
Content fills 35% of horizontal space
```

## Tabsets

```markdown
## Row {.tabset}

### Tab 1
Content for tab 1

### Tab 2
Content for tab 2
```

## Fill vs Flow Behavior

```markdown
## Row {.fill}
Content expands to fill space

## Row {.flow}
Content uses natural height
```

## Cards

### Auto-Generated Cards

Every code cell automatically becomes a card. Control with cell options:

```python
#| title: My Chart Title
#| padding: 0px
#| expandable: false
#| fill: true
```

### Manual Cards

```markdown
::: {.card title="Custom Card"}
This is a manually created card with markdown content.
:::
```

## Sidebars

### Global Sidebar

```markdown
# {.sidebar}

## Filters

Select date range and categories for analysis.

```{python}
# Input controls here
```
```

### Inline Sidebar

```markdown
## Row

### Column {.sidebar width="250px"}

Input controls here

### Column

Main content here
```

## Toolbars

### Global Toolbar

```markdown
# {.toolbar}

Horizontal inputs across top

```{python}
# Controls here
```
```

### Card Toolbar

```python
#| content: card-toolbar

# Dropdown or control widgets
```

## Multi-Page Dashboard Example

```markdown
---
title: "Analytics Platform"
format:
  dashboard:
    orientation: columns
---

# Overview {orientation="rows"}

## Row
Overview content here

# Details {scrolling="true"}

## Column
Detailed analysis here

# Settings

## Column
Configuration options here
```
