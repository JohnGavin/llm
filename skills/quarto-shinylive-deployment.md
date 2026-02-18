# CRITICAL: Quarto Shinylive Dashboard Deployment

## ⚠️ DEPLOYMENT TRAP - MUST READ

**THE PROBLEM THAT WASTES HOURS:**
When deploying Quarto Shinylive dashboards to GitHub Pages, changes appear to work locally but DON'T show up on the live site. You'll see old commits in the dashboard even after "successful" deployments.

## The Hidden Issue

**Quarto builds to `vignettes/articles/` but GitHub Pages deploys from `docs/`!**

If you don't copy the built files to `docs/`, your changes will NEVER deploy, no matter how many times you push.

## MANDATORY Deployment Workflow

```bash
# 1. Build the dashboard
quarto render vignettes/articles/dashboard.qmd

# 2. CRITICAL: Copy to docs/ directory
cp vignettes/articles/dashboard.html docs/articles/
cp -r vignettes/articles/dashboard_files docs/articles/

# 3. Verify the copy worked
grep "Dashboard created:" docs/articles/dashboard.html

# 4. Commit BOTH directories
git add vignettes/articles/dashboard.* docs/articles/dashboard.*
git commit -m "Build and deploy dashboard"

# 5. Push
git push origin main
```

## Common Mistakes That Break Deployment

❌ **WRONG**: Only committing `vignettes/` files
❌ **WRONG**: Assuming GitHub Actions copies files
❌ **WRONG**: Forgetting to copy support files (`dashboard_files/`)
❌ **WRONG**: Not checking if `docs/` was updated

✅ **RIGHT**: Always copy built files to `docs/` before committing

## How to Verify Deployment

1. **Check commit hash in dashboard**:
   ```bash
   curl -s https://[user].github.io/[repo]/articles/dashboard.html | grep "Git [a-f0-9]*"
   ```

2. **Check for timestamp** (if implemented):
   ```bash
   curl -s https://[user].github.io/[repo]/articles/dashboard.html | grep "Dashboard created:"
   ```

3. **Compare local vs deployed**:
   ```bash
   # Local version
   grep -o "Git [a-f0-9]*" docs/articles/dashboard.html

   # Deployed version (wait 5-7 min after push)
   curl -s https://[user].github.io/[repo]/articles/dashboard.html | grep -o "Git [a-f0-9]*"
   ```

## Red Flags Your Deployment Failed

- Dashboard shows old commit hash
- Changes don't appear after 10 minutes
- Package version shows "N/A"
- Timestamp doesn't update
- New features missing

## The Root Cause

GitHub Pages serves from `docs/` but Quarto builds to `vignettes/articles/`. Without an explicit copy step, your updates stay local.

## Prevention Checklist

Before every dashboard deployment:
- [ ] Built with `quarto render`
- [ ] Copied to `docs/articles/`
- [ ] Verified timestamp updated
- [ ] Checked git status shows `docs/` changes
- [ ] Committed BOTH directories

## Reference Issue

This wasted hours in the randomwalk project where changes were built and pushed but never deployed because `docs/` wasn't updated. See commit 41879c4 for the fix.

## Automation Script

Save this as `deploy_dashboard.sh`:
```bash
#!/bin/bash
set -e

echo "Building dashboard..."
quarto render vignettes/articles/dashboard_comprehensive.qmd

echo "Copying to docs..."
cp vignettes/articles/dashboard_comprehensive.html docs/articles/
cp -r vignettes/articles/dashboard_comprehensive_files docs/articles/ 2>/dev/null || true

echo "Verifying copy..."
if grep -q "Dashboard created:" docs/articles/dashboard_comprehensive.html; then
    echo "✓ Dashboard copied successfully"
else
    echo "✗ ERROR: Dashboard not copied!"
    exit 1
fi

echo "Ready to commit and push"
```

## REMEMBER

**If changes don't deploy, check `docs/` first!**