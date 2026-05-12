---
name: Shinylive WebR Issues
description: WebR bundled package version conflicts and workarounds for Shinylive dashboards
type: reference
originSessionId: 6acef2a1-f191-498a-9915-6690d780bd56
---
## WebR Package Version Mismatches (RECURRING)

WebR bundles specific package versions in its VFS. When the package repo has newer
packages that depend on newer versions of bundled packages, the preload scanner
downloads the newer packages but loads the bundled (older) version first, causing
namespace version conflicts.

| Date | Broken dep | Error | Fix |
|------|-----------|-------|-----|
| 2026-03 | munsell | `no package called 'munsell'` | `webr::install("munsell")` before ggplot2 |
| 2026-04 | rlang 1.1.6 (bundled) vs dplyr 1.2.1 (needs >=1.1.7) | `namespace 'rlang' 1.1.6 is already loaded, but >= 1.1.7 is required` | **Remove dplyr/echarts4r entirely. Use base R + JS ECharts from CDN.** |

### Why the rlang fix is different

The preload scanner **skips re-downloading bundled packages**. rlang 1.1.6 is bundled
in WebR's VFS — `webr::install("rlang")` and `library(rlang)` as first call do NOT
override it. The bundled version loads first, then dplyr/echarts4r/tidyr fail because
they need rlang >= 1.1.7.

**Failed approaches (2026-04-29, 7+ attempts):**
1. `webr::install("rlang")` before `library()` — preload ignores it
2. `library(rlang)` as first call — preload loads bundled 1.1.6 anyway
3. `library("plotly", character.only = TRUE)` — scanner detects function names too
4. Replace plotly with echarts4r — echarts4r also imports dplyr
5. Conditional version check — user code never runs because preload already failed

**Working solution (2026-04-30):**
- Remove ALL packages needing rlang >= 1.1.7: dplyr, tidyr, echarts4r
- Use base R for data manipulation (aggregate, merge, subset, etc.)
- Load ECharts.js from CDN via `tags$script(src = "...")`
- Render charts with `renderUI()` + inline JavaScript
- Keep: shiny, bslib, DT, jsonlite, lubridate (all compatible with rlang 1.1.6)

### Key insight

Almost every modern R visualization package (plotly, echarts4r, highcharter,
apexcharter) depends on either dplyr or rlang >= 1.1.7. The ONLY robust approach
is to use the JavaScript charting library directly from CDN, bypassing R package
dependencies entirely.

## Deployment Checklist

1. Build locally: `quarto render dashboard_shinylive.qmd`
2. Check service worker: `resources: - shinylive-sw.js` in YAML
3. Open in ACTUAL browser (not just curl) — incognito mode
4. Check F12 Console for errors (not Network tab)
5. Wait 60 seconds (initial WebR load is slow)
6. Clear service worker cache between deploys (Application > Service Workers > Unregister)
7. Test ALL tabs

## Service Worker Caching

Shinylive service workers cache aggressively. After deploying a new version:
- Cmd+Shift+R is NOT sufficient
- Must: DevTools > Application > Service Workers > Unregister > Clear site data
- Or: use incognito/private window
- Or: change port when testing locally

## When Shinylive Package Fails

1. Check if the package depends on dplyr or rlang >= 1.1.7
2. If yes: use the JavaScript equivalent from CDN instead
3. Never trust `webr::install()` to override bundled packages
4. Never trust `library()` order to fix bundled version conflicts
