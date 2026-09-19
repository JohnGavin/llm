---
name: browser-user-testing
description: "Use when testing deployed websites, pkgdown sites, Shiny apps, or dashboards using browser automation with user personas. Triggers: user testing, browser testing, persona testing, UX review, site walkthrough, pkgdown testing."
---
# Browser-Based User Testing with Personas

## Description

This skill enables automated user testing of deployed websites (pkgdown sites, Shiny apps, dashboards) using Claude's browser automation capabilities. The agent takes control of the browser, navigates the site as different user personas would, and generates a vignette report documenting the user experience.

## Purpose

Use this skill when:
- Testing a newly deployed pkgdown documentation site
- Validating a Shinylive or Shiny app in production
- Performing accessibility and usability reviews
- Generating user journey documentation
- Creating visual evidence of site functionality (GIF recordings)
- Testing responsive design across viewport sizes

## Prerequisites

1. **Claude-in-Chrome MCP Server** must be running
2. Chrome browser open with the MCP extension active
3. Target site must be deployed and accessible via URL

### Fallback: no Claude-in-Chrome MCP available (`puppeteer-core` + system Chrome)

The MCP server above is not always connected — verified live in a
2026-08-31/09-01 session (JohnGavin/llm#1132, micromort) where two prior
PRs had been "fixed" and verified only via `jsdom`-against-saved-HTML and
`curl`+`grep`, and both were wrong in production: `jsdom` cannot render
CSS, so it could not catch the layout/positioning bug that real
interaction in a real browser found immediately. `jsdom`-based checks
(see [`verify_html_artifact_js.sh`](../../scripts/verify_html_artifact_js.sh),
JohnGavin/llm#1129) are genuinely useful for "does the JS run and do click
handlers fire" claims, but they are not a substitute for this skill's
job — observing what a user actually sees. When the MCP is unavailable,
fall back to `puppeteer-core` driving the machine's own already-installed
Chrome (no bundled-browser download, so no multi-hundred-MB Chromium
fetch):

```bash
# Scratch dir only — never a project dependency (matches the
# jsdom/eslint discipline in verify_html_artifact_js.sh)
npm install --prefix /tmp/puppeteer-scratch --no-save puppeteer-core
```

```js
// worked example: launch, navigate, click, screenshot
// Chrome executable path is PLATFORM-SPECIFIC — this is the macOS path;
// on Linux it's typically /usr/bin/google-chrome or /usr/bin/chromium,
// on Windows `C:\Program Files\Google\Chrome\Application\chrome.exe`.
// Resolve it for the current machine rather than assuming macOS.
import puppeteer from "puppeteer-core";

const browser = await puppeteer.launch({
  executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  headless: "new",
});
const page = await browser.newPage();
await page.goto("https://example.github.io/package/", { waitUntil: "networkidle0" });
await page.click("a[data-page='p1']");        // real click, real layout engine
await page.screenshot({ path: "/tmp/after-click.png" });
const consoleErrors = [];
page.on("pageerror", (err) => consoleErrors.push(err.message));
await browser.close();
```

This is the same "load → interact → observe" discipline the rest of this
skill describes for the Claude-in-Chrome MCP path — the only difference is
which tool drives the browser. Prefer the MCP path when it is connected
(richer built-in tooling: GIF recording, `read_console_messages`,
`read_network_requests`); use this fallback rather than falling back
further to static analysis, which is what produced the wrong "fixed" PRs
in the origin incident. See `verification-before-completion`'s SPA/
client-rendered-page trap for the general principle this fallback exists
to satisfy.

## User Personas

Define personas based on your target audience. Common R package personas:

| Persona | Description | Testing Focus |
|---------|-------------|---------------|
| **Newcomer** | First-time visitor, no package knowledge | Navigation, Getting Started, README clarity |
| **Analyst** | Data scientist evaluating the package | Function reference, examples, vignettes |
| **Developer** | R developer integrating the package | API docs, source code links, GitHub integration |
| **Researcher** | Academic looking for methodology | Vignettes, citations, methodology explanations |
| **Mobile User** | Accessing on phone/tablet | Responsive design, touch navigation |

## Testing Workflow

### 1. Initialize Browser Session

```
# Get browser context
mcp__claude-in-chrome__tabs_context_mcp(createIfEmpty: true)

# Create new tab for testing
mcp__claude-in-chrome__tabs_create_mcp()

# Navigate to target site
mcp__claude-in-chrome__navigate(url: "https://username.github.io/package/", tabId: <id>)
```

### 2. Persona-Based Navigation Script

For each persona, execute a testing journey:

**Newcomer Persona:**
1. Land on homepage - screenshot
2. Scroll through README content
3. Click "Get Started" or installation section
4. Navigate to first vignette
5. Attempt to find a simple example

**Analyst Persona:**
1. Navigate to Reference section
2. Search for a specific function
3. Review function documentation
4. Check for runnable examples
5. Navigate to related functions

**Developer Persona:**
1. Check GitHub links work
2. Review NEWS/Changelog
3. Inspect pkgdown configuration
4. Check for contribution guidelines

### 3. Recording User Journeys

Use GIF recording to document the experience:

```
# Start recording
mcp__claude-in-chrome__gif_creator(action: "start_recording", tabId: <id>)

# Take initial screenshot
mcp__claude-in-chrome__computer(action: "screenshot", tabId: <id>)

# Perform navigation actions...
mcp__claude-in-chrome__computer(action: "scroll", scroll_direction: "down", tabId: <id>)
mcp__claude-in-chrome__computer(action: "left_click", coordinate: [x, y], tabId: <id>)

# Stop and export
mcp__claude-in-chrome__gif_creator(action: "stop_recording", tabId: <id>)
mcp__claude-in-chrome__gif_creator(action: "export", download: true, filename: "newcomer-journey.gif", tabId: <id>)
```

### 4. Accessibility Checks

```
# Read page structure
mcp__claude-in-chrome__read_page(tabId: <id>, filter: "interactive")

# Check for:
# - Proper heading hierarchy
# - Alt text on images
# - Keyboard navigability
# - Color contrast (visual inspection)
# - Mobile responsiveness

# Test different viewport sizes
mcp__claude-in-chrome__resize_window(width: 375, height: 812, tabId: <id>)  # iPhone
mcp__claude-in-chrome__resize_window(width: 768, height: 1024, tabId: <id>) # Tablet
mcp__claude-in-chrome__resize_window(width: 1920, height: 1080, tabId: <id>) # Desktop
```

### 5. Console Error Detection

```
# Check for JavaScript errors
mcp__claude-in-chrome__read_console_messages(tabId: <id>, onlyErrors: true)

# Check for failed network requests
mcp__claude-in-chrome__read_network_requests(tabId: <id>, urlPattern: "404")
```

## Vignette Report Template

Generate a report in this format:

```markdown
# User Testing Report: {Package Name}

**Site URL:** https://...
**Test Date:** YYYY-MM-DD
**Tester:** Claude Code (Automated)

## Executive Summary

Brief overview of findings across all personas.

## Persona: Newcomer

### Journey
1. Landed on homepage
2. [Screenshot/GIF]
3. Navigated to...

### Findings
- **Positive:** Clear installation instructions
- **Issue:** Get Started link not prominent
- **Recommendation:** Add call-to-action button

### Screenshots
![Homepage](./screenshots/newcomer-homepage.png)

## Persona: Analyst

[Similar structure...]

## Technical Issues

| Issue | Severity | Location | Details |
|-------|----------|----------|---------|
| Console error | High | /reference | TypeError in search.js |
| 404 | Medium | /articles | Missing image asset |

## Accessibility Audit

- [ ] Heading hierarchy correct
- [ ] Images have alt text
- [ ] Links are descriptive
- [ ] Mobile responsive
- [ ] Keyboard navigable

## Recommendations

1. Priority 1: Fix console errors
2. Priority 2: Improve mobile navigation
3. Priority 3: Add more examples

## Appendix: GIF Recordings

- [Newcomer Journey](./recordings/newcomer-journey.gif)
- [Analyst Journey](./recordings/analyst-journey.gif)
```

## Integration with R Package Workflow

Add to your CI/CD or post-deployment workflow:

```yaml
# .github/workflows/user-testing.yml (manual trigger)
name: User Testing Report

on:
  workflow_dispatch:
    inputs:
      site_url:
        description: 'URL to test'
        required: true

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Request Claude Code testing
        # This would trigger the testing via webhook/API
        # Actual implementation depends on your Claude Code setup
```

## Common Testing Scenarios

### pkgdown Site Testing

```
Focus areas:
- Homepage loads correctly
- Reference index is searchable
- All vignettes render
- Code examples have copy buttons
- Search functionality works
- GitHub corner link works
```

### Shinylive App Testing

```
Focus areas:
- WASM loads without errors (check console)
- Service worker initializes
- Inputs respond to interaction
- Outputs update correctly
- No infinite loading states
```

### Dashboard Testing

```
Focus areas:
- All charts render
- Filters work correctly
- Data loads within acceptable time
- Export functions work
- Mobile layout is usable
```

## Error Handling

If browser automation fails:
1. Check MCP extension is running
2. Verify site URL is accessible
3. Check for CORS or authentication requirements
4. Try refreshing the browser tab
5. Restart the MCP connection if needed
6. If the MCP genuinely cannot be connected this session, use the
   `puppeteer-core` + system-Chrome fallback above — do NOT fall back to
   static analysis (`curl`+`grep`, reading source) for a UI/layout claim;
   see the Prerequisites section and JohnGavin/llm#1132

## Related Skills

- `pkgdown-deployment` - Deploying the sites to test
- `shinylive-quarto` - Building Shinylive apps
- `verification-before-completion` - Ensuring quality before release
- `project-telemetry` - Tracking site metrics

## Example Invocation

```
User: "Test my pkgdown site at https://johngavin.github.io/randomwalk/
       as a newcomer and analyst persona, generate a report"

Claude: [Uses browser automation tools to:
         1. Navigate to site
         2. Execute persona journeys
         3. Capture screenshots/GIFs
         4. Check for errors
         5. Generate markdown report]
```
