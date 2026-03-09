# Troubleshooting

## Common Issues

1. **Site not rendering**
   - Check `_quarto.yml` syntax
   - Verify all referenced files exist
   - Run `quarto check` for diagnostics

2. **GitHub Pages 404**
   - Ensure `output-dir: docs` if publishing from docs/
   - Check GitHub Pages settings point to correct branch/folder
   - Verify `.nojekyll` file exists in output

3. **Search not working**
   - Ensure `search: true` in website config
   - Check JavaScript console for errors
   - Verify site URL is set for production

4. **Images not showing**
   - Use relative paths from document location
   - Include images in `resources:` if needed
   - Check case sensitivity on Linux/Mac

5. **Freeze not working**
   - Add `execute: freeze: auto` to `_quarto.yml`
   - Commit `_freeze/` directory to git
   - Don't gitignore the freeze directory
