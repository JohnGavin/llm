#!/usr/bin/env bash
# verify_html_artifact_js.sh — DOM-executing click-through verification for
# generated interactive HTML artifacts (JohnGavin/llm#1129).
#
# ORIGIN: the `tennis` project's "Tennis Trends" dashboard shipped a
# top-level <script> that threw an uncaught ReferenceError on load. Every
# page-nav click, tab click, and <details> disclosure silently did nothing
# because the script aborted before wiring up any click handlers. `node
# --check` (syntax only) and a structural tag-balance check both passed,
# because NEITHER executes the page's JS. This script is the "run it and
# click things" tier that check_qmd_fence_parity.sh-style structural checks
# structurally cannot be — see verification-before-completion's Five Traps
# Type A ("a check that cannot go red is not a check").
#
# WHAT THIS DOES NOT PROVE: this script proves "the JS runs without an
# uncaught error, and the click handlers this script found actually fire
# and produce their expected state change." It does NOT prove a page LOOKS
# right — jsdom does not render CSS, so a layout/positioning bug (content
# reappearing in the wrong place after a scroll, an element overlapping
# another) is invisible to this tool by construction. That is a different,
# complementary check — see verification-before-completion's SPA/
# client-rendered-page trap and browser-user-testing's puppeteer-core
# fallback for real-browser layout verification (JohnGavin/llm#1132).
#
# WHAT IT CHECKS, per invocation:
#   1. Extracts every inline <script> block (skips external `src=`,
#      skips non-JS `type=` values such as application/json).
#   2. Runs eslint's `no-undef` rule (in-process, via the ESLint 8 Linter
#      API — not the CLI) against each block with `env: browser` and any
#      caller-declared globals — sweeps for EVERY undefined identifier in
#      one pass, not just the one that happens to throw first.
#   3. Loads the real file in jsdom with `runScripts: "dangerously"`,
#      capturing every uncaught JS error via a VirtualConsole listener
#      registered BEFORE construction (jsdom executes inline scripts
#      synchronously during HTML parsing — a listener attached after
#      construction misses errors that already fired).
#   4. Clicks every element matched by the configured page-nav / tab /
#      details selectors (defaults: `[data-page]`, `[data-tab]`,
#      `details > summary`), asserting the configured target actually
#      receives its expected state change (a class for nav/tab, the `open`
#      attribute for details). Uses `el.click()`, not
#      `dispatchEvent(new Event("click"))` — jsdom only runs an element's
#      native "activation behavior" (e.g. toggling <details>) via `.click()`.
#
# EXIT CODES (per exit-code-conventions.md's 4-state table, JohnGavin/llm#1140):
#   0  PASS          — 0 eslint findings, 0 uncaught runtime errors, every
#                       matched interactive element produced its expected
#                       state change (a determinate positive)
#   1  FAIL           — at least one of the above did not hold (a
#                       determinate negative — the check DID reach a verdict)
#   2  USAGE-ERROR    — bad args, --help, html file/--config file missing
#   3  INDETERMINATE  — node/npm unavailable and jsdom/eslint are not
#                       already cached, npm install failed (no network),
#                       or the node harness crashed for an unrelated reason
#                       (per checks-must-distinguish-unknown: an
#                       environment failure must NEVER read as a pass)
#
# NEVER a project dependency: jsdom/eslint are npm-installed into a
# throwaway cache directory (~/.cache/verify_html_artifact_js/ by default,
# `--no-save`), never added to any project's package.json/DESCRIPTION —
# matching the ad-hoc verification discipline from the origin incident.
#
# USAGE:
#   verify_html_artifact_js.sh [options] <html-file>
#   verify_html_artifact_js.sh --selftest
#
# OPTIONS:
#   --globals a,b,c        Comma-separated list of extra known globals for
#                          the eslint no-undef sweep (e.g. names your build
#                          injects as inline <script> globals)
#   --nav-attr NAME        data-* attribute marking page-nav elements
#                          (default: data-page). Each matched element's
#                          attribute VALUE is used as an element id to
#                          look up the target that should gain --nav-class.
#   --nav-class NAME       Class asserted on the nav target after click
#                          (default: active)
#   --tab-attr NAME        Same idea as --nav-attr, for tab buttons
#                          (default: data-tab)
#   --tab-class NAME       Class asserted on the tab target after click
#                          (default: active)
#   --details-selector CSS  Selector for details-disclosure triggers
#                            (default: "details > summary"); asserts the
#                            closest ancestor <details> element's `open`
#                            attribute becomes true after click
#   --extra-selectors CSS[,CSS...]
#                          Additional selectors to click with a best-effort
#                          "did this click raise a NEW uncaught error"
#                          assertion (no state-change assertion — use
#                          --config for that)
#   --config PATH          JSON file for fully custom interactions, merged
#                          with the flags above. Schema:
#                            {
#                              "globals": ["myGlobal1", "myGlobal2"],
#                              "interactions": [
#                                { "selector": ".thing[data-x]",
#                                  "targetAttr": "data-x",
#                                  "assertClass": "open" },
#                                { "selector": ".close-btn",
#                                  "targetSelector": ".modal",
#                                  "assertOpenAttr": true }
#                              ]
#                            }
#                          Each interaction entry clicks every element
#                          matched by `selector`; the target is resolved
#                          via `targetAttr` (attribute value used as an
#                          id lookup), `targetSelector` (nearest ancestor
#                          or, failing that, first document match), or the
#                          clicked element itself if neither is given.
#                          `assertOpenAttr: true` checks the `open`
#                          attribute; otherwise `assertClass` (default
#                          "active") is checked on the target.
#   --cache-dir DIR        Override the jsdom/eslint install cache
#                          (default: ~/.cache/verify_html_artifact_js/
#                          jsdom-<ver>_eslint-<ver>)
#   --no-cache             Force a fresh npm install even if the cache
#                          directory already looks populated
#   --selftest             Run the built-in fixture tests: a clean PASS
#                          fixture, a broken FAIL fixture, a USAGE-ERROR
#                          case, and two INDETERMINATE cases (no node;
#                          npm missing with an empty cache)
#   -h, --help             This message (exit 2, per exit-code-conventions:
#                          --help is a usage-error exit)
#
# JohnGavin/llm#1129

set -uo pipefail

JSDOM_VERSION="${VERIFY_HTML_JS_JSDOM_VERSION:-29.1.1}"
ESLINT_VERSION="${VERIFY_HTML_JS_ESLINT_VERSION:-8.57.1}"
DEFAULT_CACHE_DIR="$HOME/.cache/verify_html_artifact_js/jsdom-${JSDOM_VERSION}_eslint-${ESLINT_VERSION}"

SELFTEST=0
HTML_FILE=""
GLOBALS=""
NAV_ATTR="data-page"
NAV_CLASS="active"
TAB_ATTR="data-tab"
TAB_CLASS="active"
DETAILS_SELECTOR="details > summary"
EXTRA_SELECTORS=""
CONFIG_FILE=""
CACHE_DIR="${VERIFY_HTML_JS_CACHE_DIR:-$DEFAULT_CACHE_DIR}"
NO_CACHE=0

usage() {
    cat <<'EOF' >&2
Usage: verify_html_artifact_js.sh [options] <html-file>
       verify_html_artifact_js.sh --selftest

See the script header for the full option list and the --config JSON schema.
Common options: --globals a,b,c  --nav-attr NAME  --nav-class NAME
                 --tab-attr NAME  --tab-class NAME  --details-selector CSS
                 --extra-selectors CSS[,CSS...]  --config PATH
                 --cache-dir DIR  --no-cache
EOF
}

require_value() {
    # $1 = flag name, $2 = remaining arg count after the flag
    if [ "$2" -lt 1 ]; then
        echo "USAGE-ERROR: $1 requires a value" >&2
        usage
        exit 2
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        (--selftest) SELFTEST=1; shift ;;
        (--globals) require_value "$1" "$(($#-1))"; GLOBALS="$2"; shift 2 ;;
        (--nav-attr) require_value "$1" "$(($#-1))"; NAV_ATTR="$2"; shift 2 ;;
        (--nav-class) require_value "$1" "$(($#-1))"; NAV_CLASS="$2"; shift 2 ;;
        (--tab-attr) require_value "$1" "$(($#-1))"; TAB_ATTR="$2"; shift 2 ;;
        (--tab-class) require_value "$1" "$(($#-1))"; TAB_CLASS="$2"; shift 2 ;;
        (--details-selector) require_value "$1" "$(($#-1))"; DETAILS_SELECTOR="$2"; shift 2 ;;
        (--extra-selectors) require_value "$1" "$(($#-1))"; EXTRA_SELECTORS="$2"; shift 2 ;;
        (--config) require_value "$1" "$(($#-1))"; CONFIG_FILE="$2"; shift 2 ;;
        (--cache-dir) require_value "$1" "$(($#-1))"; CACHE_DIR="$2"; shift 2 ;;
        (--no-cache) NO_CACHE=1; shift ;;
        (-h|--help) usage; exit 2 ;;
        (--) shift; break ;;
        (-*) echo "USAGE-ERROR: unknown option: $1" >&2; usage; exit 2 ;;
        (*) HTML_FILE="$1"; shift ;;
    esac
done

# write_harness — emit the node harness verbatim (single-quoted heredoc, no
# bash expansion) to the given path. Idempotent; cheap to re-run every
# invocation, so the harness is never a second file this script's own
# write-scope would need to track separately.
write_harness() {
    cat > "$1" <<'HARNESS_EOF'
// verify_html_artifact_js_harness.mjs — written at runtime by
// verify_html_artifact_js.sh into its cache dir. Not committed; regenerated
// (idempotently, overwritten) on every invocation. See JohnGavin/llm#1129.
//
// Positional argv (all required except configFile, which may be ""):
//   1 htmlFile           path to the HTML artifact to verify
//   2 globalsCsv         comma-separated extra eslint no-undef globals ("" ok)
//   3 navAttr            data-* attribute marking page-nav elements
//   4 navClass           class asserted on the nav target after click
//   5 tabAttr            data-* attribute marking tab elements
//   6 tabClass           class asserted on the tab target after click
//   7 detailsSelector    CSS selector for details-disclosure triggers
//   8 extraSelectorsCsv  comma-separated extra selectors, error-only check ("" ok)
//   9 configFile         optional JSON file path ("" ok) — see parent script header
//
// Exit codes: 0 PASS, 1 FAIL, 2 usage error, 3 INDETERMINATE (jsdom could not
// even construct a DOM for this file — HTML5 parsing is very permissive, so
// this is expected to be rare; a missing node/npm is caught by the parent
// bash script BEFORE this harness is ever invoked).

import fs from "node:fs";
import { Linter } from "eslint";
import { JSDOM, VirtualConsole } from "jsdom";

function usageError(msg) {
    console.error(`USAGE-ERROR: ${msg}`);
    process.exit(2);
}

const [
    htmlFile,
    globalsCsv = "",
    navAttr = "data-page",
    navClass = "active",
    tabAttr = "data-tab",
    tabClass = "active",
    detailsSelector = "details > summary",
    extraSelectorsCsv = "",
    configFile = "",
] = process.argv.slice(2);

if (!htmlFile) usageError("no html file given");
if (!fs.existsSync(htmlFile)) usageError(`file not found: ${htmlFile}`);

let html;
try {
    // Whole-file read, never readline (portable-build-artifacts Part 5):
    // this harness only ever READS the artifact, never rewrites it, so the
    // long-line-splitting hazard that rule documents does not apply to this
    // step — but the discipline of never assuming line boundaries in a file
    // that may embed large generated assets still applies to how it's read.
    html = fs.readFileSync(htmlFile, "utf8");
} catch (e) {
    usageError(`could not read ${htmlFile}: ${e.message}`);
}

let config = {};
if (configFile) {
    try {
        config = JSON.parse(fs.readFileSync(configFile, "utf8"));
    } catch (e) {
        usageError(`could not parse --config ${configFile}: ${e.message}`);
    }
}

const globals = {};
for (const g of globalsCsv.split(",").map((s) => s.trim()).filter(Boolean)) {
    globals[g] = "readonly";
}
for (const g of config.globals || []) {
    globals[g] = "readonly";
}

const extraSelectors = extraSelectorsCsv
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);

const customInteractions = config.interactions || [];

// --- Step 1: extract <script> blocks (skip external src=, skip non-JS type=) ---
const scriptRe = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
const scripts = [];
let m;
while ((m = scriptRe.exec(html)) !== null) {
    const attrs = m[1];
    const body = m[2];
    if (/\bsrc\s*=/i.test(attrs)) continue; // external script — nothing inline to lint/execute here
    const typeMatch = attrs.match(/\btype\s*=\s*["']?([^"'\s>]+)/i);
    let isModule = false;
    if (typeMatch) {
        const t = typeMatch[1].toLowerCase();
        if (t === "module") {
            isModule = true;
        } else if (!["text/javascript", "application/javascript", "text/babel"].includes(t)) {
            continue; // e.g. application/json, application/ld+json — not executable JS
        }
    }
    if (body.trim().length === 0) continue;
    scripts.push({ body, isModule });
}

// --- Step 2: eslint no-undef sweep — one Linter.verify() per script block ---
// (in-process API, not the CLI — avoids a per-block subprocess + temp file)
const linter = new Linter();
const lintFindings = [];
scripts.forEach((s, i) => {
    const messages = linter.verify(s.body, {
        env: { browser: true, es2021: true },
        parserOptions: { ecmaVersion: 2022, sourceType: s.isModule ? "module" : "script" },
        rules: { "no-undef": "error" },
        globals,
    });
    messages.forEach((msg) => {
        lintFindings.push(`script#${i} line ${msg.line}: ${msg.message}`);
    });
});

// --- Step 3: jsdom execute + click-through ---
const runtimeErrors = [];
const vc = new VirtualConsole();
// MUST be registered before `new JSDOM(...)` — jsdom executes inline
// scripts synchronously during HTML parsing, so a listener attached after
// construction misses errors that already fired (verified empirically).
vc.on("jsdomError", (err) => {
    runtimeErrors.push(err && err.message ? err.message : String(err));
});

let dom;
try {
    dom = new JSDOM(html, { runScripts: "dangerously", virtualConsole: vc, resources: undefined });
} catch (e) {
    console.error(`INDETERMINATE: jsdom could not construct a DOM for ${htmlFile}: ${e.message}`);
    process.exit(3);
}

const { window } = dom;
const { document } = window;

function describeEl(el) {
    const snippet = el.outerHTML || el.tagName || "?";
    return snippet.length > 90 ? snippet.slice(0, 90) + "…" : snippet;
}

const interactionResults = [];

function assertClassOnTarget(el, attrName, className) {
    const targetId = el.getAttribute(attrName);
    if (!targetId) return { ok: false, note: `no ${attrName} attribute value on element` };
    const target = document.getElementById(targetId);
    if (!target) return { ok: false, note: `no element with id="${targetId}" found` };
    const before = target.classList.contains(className);
    el.click(); // NOT dispatchEvent(new Event("click")) — only .click() runs
    // native "activation behavior" (e.g. <details> toggling) in jsdom.
    const after = target.classList.contains(className);
    return { ok: after, note: `#${targetId}.${className} before=${before} after=${after}` };
}

document.querySelectorAll(`[${navAttr}]`).forEach((el) => {
    interactionResults.push({ kind: "nav", el: describeEl(el), ...assertClassOnTarget(el, navAttr, navClass) });
});

document.querySelectorAll(`[${tabAttr}]`).forEach((el) => {
    interactionResults.push({ kind: "tab", el: describeEl(el), ...assertClassOnTarget(el, tabAttr, tabClass) });
});

document.querySelectorAll(detailsSelector).forEach((el) => {
    const details = el.closest("details");
    if (!details) {
        interactionResults.push({ kind: "details", el: describeEl(el), ok: false, note: "no ancestor <details> element" });
        return;
    }
    const before = details.open;
    el.click();
    const after = details.open;
    interactionResults.push({ kind: "details", el: describeEl(el), ok: after === true, note: `open before=${before} after=${after}` });
});

extraSelectors.forEach((sel) => {
    document.querySelectorAll(sel).forEach((el) => {
        const before = runtimeErrors.length;
        el.click();
        const after = runtimeErrors.length;
        interactionResults.push({
            kind: "extra",
            el: describeEl(el),
            ok: after === before,
            note: after > before ? "click raised a new uncaught error" : "no new uncaught error",
        });
    });
});

customInteractions.forEach((cfg) => {
    let els = [];
    try {
        els = Array.from(document.querySelectorAll(cfg.selector));
    } catch (e) {
        interactionResults.push({ kind: "custom", el: cfg.selector, ok: false, note: `invalid selector: ${e.message}` });
        return;
    }
    els.forEach((el) => {
        let target = el;
        if (cfg.targetAttr) {
            const id = el.getAttribute(cfg.targetAttr);
            target = id ? document.getElementById(id) : null;
        } else if (cfg.targetSelector) {
            target = el.closest(cfg.targetSelector) || document.querySelector(cfg.targetSelector);
        }
        if (!target) {
            interactionResults.push({ kind: "custom", el: describeEl(el), ok: false, note: "target not found" });
            return;
        }
        const check = () =>
            cfg.assertOpenAttr ? target.hasAttribute("open") : target.classList.contains(cfg.assertClass || "active");
        const before = check();
        el.click();
        const after = check();
        interactionResults.push({ kind: "custom", el: describeEl(el), ok: after === true, note: `before=${before} after=${after}` });
    });
});

const failedInteractions = interactionResults.filter((r) => !r.ok);

console.log(
    `RESULT_LINE scripts=${scripts.length} lintFindings=${lintFindings.length} ` +
        `runtimeErrors=${runtimeErrors.length} interactions=${interactionResults.length} ` +
        `interactionFails=${failedInteractions.length}`
);
console.log(JSON.stringify({ lintFindings, runtimeErrors, interactionResults }, null, 2));

if (lintFindings.length > 0 || runtimeErrors.length > 0 || failedInteractions.length > 0) {
    process.exit(1);
}
process.exit(0);
HARNESS_EOF
}

# ensure_tooling — verify node is available, and that jsdom/eslint are
# installed into CACHE_DIR (installing them if necessary and npm is
# available). Prints its own INDETERMINATE message and returns 3 on any
# failure; never silently proceeds without a working harness.
ensure_tooling() {
    if ! command -v node >/dev/null 2>&1; then
        echo "INDETERMINATE: node not on PATH — cannot execute JS runtime checks"
        return 3
    fi

    mkdir -p "$CACHE_DIR"

    if [ "$NO_CACHE" -eq 1 ]; then
        rm -rf "$CACHE_DIR/node_modules"
    fi

    if [ ! -d "$CACHE_DIR/node_modules/jsdom" ] || [ ! -d "$CACHE_DIR/node_modules/eslint" ]; then
        if ! command -v npm >/dev/null 2>&1; then
            echo "INDETERMINATE: npm not on PATH and jsdom@${JSDOM_VERSION}/eslint@${ESLINT_VERSION} are not cached at $CACHE_DIR — cannot install verification tooling"
            return 3
        fi
        if ! npm install --prefix "$CACHE_DIR" --cache "$CACHE_DIR/.npm-cache" --no-save --silent \
            "jsdom@${JSDOM_VERSION}" "eslint@${ESLINT_VERSION}" >"$CACHE_DIR/.install.log" 2>&1; then
            echo "INDETERMINATE: npm install of jsdom@${JSDOM_VERSION}/eslint@${ESLINT_VERSION} failed (no network? see $CACHE_DIR/.install.log)"
            tail -5 "$CACHE_DIR/.install.log" 2>/dev/null | sed 's/^/  /'
            return 3
        fi
    fi

    write_harness "$CACHE_DIR/harness.mjs"
    return 0
}

# run_check — the whole pipeline for one html file. Prints a one-line
# PASS:/FAIL:/USAGE-ERROR:/INDETERMINATE: summary (plus findings detail on
# FAIL) and returns the matching exit code.
run_check() {
    local html_file="$1"

    if [ -z "$html_file" ]; then
        echo "USAGE-ERROR: no html file given"
        return 2
    fi
    if [ ! -f "$html_file" ]; then
        echo "USAGE-ERROR: file not found: $html_file"
        return 2
    fi
    if [ -n "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
        echo "USAGE-ERROR: --config file not found: $CONFIG_FILE"
        return 2
    fi

    ensure_tooling
    local trc=$?
    if [ "$trc" -ne 0 ]; then
        return "$trc"
    fi

    local out rc
    out="$(node "$CACHE_DIR/harness.mjs" \
        "$html_file" "$GLOBALS" "$NAV_ATTR" "$NAV_CLASS" "$TAB_ATTR" "$TAB_CLASS" \
        "$DETAILS_SELECTOR" "$EXTRA_SELECTORS" "$CONFIG_FILE" 2>&1)"
    rc=$?

    case "$rc" in
        0)
            local summary
            summary="$(printf '%s\n' "$out" | grep '^RESULT_LINE ' | head -1 | sed 's/^RESULT_LINE //')"
            echo "PASS: $html_file — $summary"
            ;;
        1)
            local summary
            summary="$(printf '%s\n' "$out" | grep '^RESULT_LINE ' | head -1 | sed 's/^RESULT_LINE //')"
            echo "FAIL: $html_file — $summary"
            printf '%s\n' "$out" | grep -v '^RESULT_LINE '
            ;;
        2)
            printf '%s\n' "$out"
            ;;
        3)
            printf '%s\n' "$out"
            ;;
        *)
            echo "INDETERMINATE: $html_file — harness exited unexpectedly (rc=$rc)"
            printf '%s\n' "$out"
            rc=3
            ;;
    esac
    return "$rc"
}

# ---------------------------------------------------------------------------
# Selftest fixtures — mirror the origin incident exactly: a top-level
# <script> that references an undeclared identifier before wiring any click
# handlers (both eslint no-undef and the jsdom runtime-error capture must
# catch it), versus the same markup with a correctly-wired script.
# ---------------------------------------------------------------------------

write_fixture_clean() {
    cat > "$1" <<'FIXTURE_EOF'
<!doctype html>
<html>
<head><meta charset="utf-8"><title>clean fixture</title></head>
<body>
  <nav><a href="#p1" data-page="p1" id="nav-p1">Page 1</a></nav>
  <section id="p1" class="page"></section>

  <div class="tabs"><button class="tab" data-tab="tabA" id="tab-a">A</button></div>
  <div id="tabA" class="tab-panel"></div>

  <details id="disc1"><summary>More</summary><p>Detail body</p></details>

  <script>
  document.getElementById("nav-p1").addEventListener("click", function () {
    document.getElementById("p1").classList.add("active");
  });
  document.getElementById("tab-a").addEventListener("click", function () {
    document.getElementById("tabA").classList.add("active");
  });
  </script>
</body>
</html>
FIXTURE_EOF
}

write_fixture_broken() {
    cat > "$1" <<'FIXTURE_EOF'
<!doctype html>
<html>
<head><meta charset="utf-8"><title>broken fixture</title></head>
<body>
  <nav><a href="#p1" data-page="p1" id="nav-p1">Page 1</a></nav>
  <section id="p1" class="page"></section>

  <div class="tabs"><button class="tab" data-tab="tabA" id="tab-a">A</button></div>
  <div id="tabA" class="tab-panel"></div>

  <details id="disc1"><summary>More</summary><p>Detail body</p></details>

  <script>
  pageIds.forEach(function (id) {
    document.getElementById("nav-" + id).addEventListener("click", function () {
      document.getElementById(id).classList.add("active");
    });
  });
  document.getElementById("tab-a").addEventListener("click", function () {
    document.getElementById("tabA").classList.add("active");
  });
  </script>
</body>
</html>
FIXTURE_EOF
}

selftest() {
    local tmp pass=0 fail=0
    tmp="$(mktemp -d)"
    ok(){ pass=$((pass+1)); echo "  PASS: $1"; }
    bad(){ fail=$((fail+1)); echo "  FAIL: $1"; }
    echo "verify_html_artifact_js.sh --selftest"

    if ! command -v node >/dev/null 2>&1; then
        echo "  SKIP: all states need node on PATH (not available in this shell)"
        rm -rf "$tmp"
        echo "  0 passed, 0 failed (skipped — no node)"
        return 0
    fi

    # State 1: clean fixture, nav+tab+details all wired -> PASS (exit 0).
    write_fixture_clean "$tmp/clean.html"
    local out rc
    out="$(run_check "$tmp/clean.html")"; rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^PASS' \
        && printf '%s' "$out" | grep -q 'lintFindings=0' \
        && printf '%s' "$out" | grep -q 'runtimeErrors=0' \
        && printf '%s' "$out" | grep -q 'interactionFails=0'
    then
        ok "state 1: clean fixture -> PASS (exit 0), 0 findings/0 errors/0 interaction fails"
    else
        bad "state 1: expected PASS/exit0/all-zero, got rc=$rc out=$out"
    fi

    # State 2: broken fixture — THE BUG THIS SCRIPT EXISTS TO CATCH. A
    # top-level ReferenceError (undeclared `pageIds`) must be caught by
    # BOTH the eslint no-undef sweep AND the jsdom runtime-error capture,
    # and the nav+tab click handlers that never got registered must fail
    # their state-change assertion (matching the origin incident's exact
    # symptom: clicks silently do nothing). The details element is native
    # and unaffected by the aborted script, so exactly 1 of 3 interactions
    # succeeds.
    write_fixture_broken "$tmp/broken.html"
    out="$(run_check "$tmp/broken.html")"; rc=$?
    if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^FAIL' \
        && printf '%s' "$out" | grep -q 'lintFindings=1' \
        && printf '%s' "$out" | grep -q 'runtimeErrors=1' \
        && printf '%s' "$out" | grep -q 'interactionFails=2'
    then
        ok "state 2 (llm#1129 bug): broken fixture -> FAIL (exit 1), 1 lint finding, 1 runtime error, 2/3 interactions failed"
    else
        bad "state 2 (THE llm#1129 BUG): expected FAIL/exit1 with 1 lint/1 runtime/2 interaction-fails, got rc=$rc out=$out — a PASS here reproduces the original incident"
    fi

    # Usage error: nonexistent file -> exit 2.
    out="$(run_check "$tmp/does-not-exist.html")"; rc=$?
    if [ "$rc" -eq 2 ]; then
        ok "usage error: nonexistent html file -> exit 2"
    else
        bad "usage error: expected exit2, got rc=$rc out=$out"
    fi

    # INDETERMINATE (a): node itself unavailable -> exit 3. Narrow PATH for
    # this one call only (bash scopes a leading assignment to the command/
    # function it prefixes — see check_targets_presence.sh's identical
    # pattern for Rscript).
    out="$(PATH="/usr/bin:/bin" run_check "$tmp/clean.html")"; rc=$?
    if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -qi '^INDETERMINATE.*node not on PATH'; then
        ok "indeterminate (a): node unavailable -> INDETERMINATE (exit 3), never a false pass"
    else
        bad "indeterminate (a): expected INDETERMINATE/exit3 mentioning node, got rc=$rc out=$out"
    fi

    # INDETERMINATE (b): node present, npm absent, cache empty -> exit 3.
    # This is the specific "npm/network access unavailable" degrade path
    # JohnGavin/llm#1129 asks for, distinct from (a) above (node missing
    # entirely). Build a PATH containing only a symlink to the real node
    # binary — no npm anywhere on it — and point at a fresh cache dir so
    # the install step is actually reached rather than skipped via a warm
    # cache from an earlier run in this same selftest.
    local real_node nodebin_dir empty_cache
    real_node="$(command -v node)"
    nodebin_dir="$(mktemp -d)"
    ln -s "$real_node" "$nodebin_dir/node"
    empty_cache="$(mktemp -d)"
    out="$(PATH="$nodebin_dir" CACHE_DIR="$empty_cache" \
        run_check "$tmp/clean.html" 2>&1)"; rc=$?
    if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -qi '^INDETERMINATE.*npm not on PATH'; then
        ok "indeterminate (b): npm unavailable + empty cache -> INDETERMINATE (exit 3), never a false pass"
    else
        bad "indeterminate (b): expected INDETERMINATE/exit3 mentioning npm, got rc=$rc out=$out"
    fi
    rm -rf "$nodebin_dir" "$empty_cache"

    rm -rf "$tmp"
    echo "  $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

if [ "$SELFTEST" -eq 1 ]; then
    selftest
    exit $?
fi

run_check "$HTML_FILE"
exit $?
