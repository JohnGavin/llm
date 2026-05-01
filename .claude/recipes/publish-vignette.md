# Recipe: Publish a Vignette

## Steps

### 1. Write
Use `~/.claude/templates/new-wiki-page.md` or create `.qmd` in `vignettes/`.

### 2. Render locally
```bash
nix-shell /path/to/project/default.nix --run "quarto render vignettes/my-vignette.qmd"
```

### 3. Browser test
Open rendered HTML in browser. Check:
- All plots render (no blank charts)
- Tables display correctly
- Links work
- Alt text present on figures (`fig-alt`)

### 4. Quality gate
```bash
~/.claude/scripts/r_code_check.sh R/
# Score must be >= 80 for production vignettes
```

### 5. Deploy
```bash
git add vignettes/ && git commit -m "feat: add my-vignette"
git push  # CI handles pkgdown/GitHub Pages deploy
```

### 6. Verify deployment
```bash
curl -sI https://username.github.io/package/articles/my-vignette.html | head -3
# Should return HTTP 200
```

### 7. Post-deploy
- Clear browser cache / service worker if Shinylive
- Check F12 console for errors
- Test on mobile viewport
