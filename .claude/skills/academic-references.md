# Academic References Skill

## Purpose
Standards for citing academic papers, defining mathematical terms, and linking to sources in vignettes and documentation.

## When to Apply
- Writing vignettes with mathematical equations
- Citing academic papers or books
- Making scientific claims that require evidence

## Reference Style (MANDATORY)

### In-Text Citations with Hover Popups

**Use Quarto footnote syntax** for all academic references:

```markdown
This was discovered by Smith et al.^[Smith, J., & Jones, K. (2020). [Title of paper](https://doi.org/10.xxxx/xxxxx). *Journal Name*, 42(3), 123-145.]
```

This renders as a superscript number with hover popup showing the full citation.

**Do NOT use numbered reference lists** like `[1]`, `[2]` at the end. All references should be inline footnotes.

### Reference Format

Each footnote citation MUST include:
1. **Authors** (last name, initials)
2. **Year** in parentheses
3. **Title** as a clickable link to DOI or publisher URL
4. **Journal/Book** in italics
5. **Volume/Issue/Pages**

Example:
```markdown
^[Witten Jr, T. A., & Sander, L. M. (1981). [Diffusion-limited aggregation](https://journals.aps.org/prl/abstract/10.1103/PhysRevLett.47.1400). *Physical Review Letters*, 47(19), 1400.]
```

## Mathematical Notation (MANDATORY)

### Define All Symbols

After EVERY equation, include a definition list explaining each symbol:

```markdown
$$M(R) \sim R^{D_f}$$

where:

- $M(R)$ is the **mass** (total number of particles) within radius $R$
- $R$ is the **radial distance** from the cluster center
- $D_f$ is the **fractal dimension** ($\approx 1.71$ for 2D DLA)
- $\sim$ denotes **scaling behavior** (proportionality in the asymptotic limit)
```

### Common Symbols to Always Define

| Symbol | Definition |
|--------|------------|
| $\nabla$ | Gradient operator (in 2D: $\nabla = (\partial/\partial x, \partial/\partial y)$) |
| $\nabla^2$ | Laplacian operator (in 2D: $\nabla^2 = \partial^2/\partial x^2 + \partial^2/\partial y^2$) |
| $\sim$ | Scaling behavior / asymptotic proportionality |
| $\propto$ | Proportional to |
| $\mathbf{r}$ | Position vector |
| $t$ | Time (discrete step or continuous) |

## Linking Strategy (MANDATORY)

### Link Key Terms to Authoritative Sources

1. **Wikipedia** for general concepts:
   ```markdown
   [Brownian motion](https://en.wikipedia.org/wiki/Brownian_motion)
   ```

2. **Project Wiki** for package-specific concepts:
   ```markdown
   [screening effect](https://github.com/USER/REPO/wiki/DLA-Theory#screening-effect)
   ```

3. **DOI links** for papers (preferred over journal URLs):
   ```markdown
   [Title](https://doi.org/10.xxxx/xxxxx)
   ```

### When to Link

- First occurrence of a technical term
- Claims that need evidence
- Concepts readers might need background on

## Git SHA Links (MANDATORY)

When displaying git commit SHAs, ALWAYS make them clickable:

```r
sha_link <- sprintf("[%s](https://github.com/USER/REPO/commit/%s)", sha_short, sha_full)
```

## Checklist Before Commit

- [ ] All academic citations use footnote syntax `^[...]`
- [ ] Each citation includes clickable link to paper
- [ ] All equation symbols defined in "where:" list
- [ ] Key terms linked to Wikipedia or wiki on first use
- [ ] Git SHAs are clickable links
- [ ] No orphaned `[1]`, `[2]` style reference lists
