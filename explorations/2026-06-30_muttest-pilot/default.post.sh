#!/usr/bin/env bash
# =============================================================================
# default.post.sh — re-apply four manual Nix patches after every rix regen.
# =============================================================================
# Usage: ./default.post.sh  (run from any directory; resolves own path via BASH_SOURCE)
#
# Regen + patch sequence (nix-agent-shell-protocol Form A subshell):
#   (cd /path/to/this/dir && nix-shell ~/docs_gh/llm/default.nix --run "Rscript default.R")
#   /path/to/this/dir/default.post.sh
#
# Idempotent: each of the four patches is guarded by grep -q so re-running
# is a no-op — the file is not written unless the patch marker is absent.
# Requires: bash, python3 (stdlib only).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIX_FILE="${SCRIPT_DIR}/default.nix"

if [[ ! -f "${NIX_FILE}" ]]; then
    echo "ERROR: default.nix not found at ${NIX_FILE}" >&2
    exit 1
fi

_applied=0
_skipped=0

_report() { echo "  [$1] $2"; }

echo "==> default.post.sh: patching ${NIX_FILE}"
echo ""

# -----------------------------------------------------------------------------
# Patch 1 — buildInputs: list concatenation (++ instead of nested literal)
# -----------------------------------------------------------------------------
# rix generates:  buildInputs = [ muttest rpkgs system_packages ];
# Required:       buildInputs = [ muttest ] ++ rpkgs ++ system_packages;
#
# rpkgs and system_packages are both lists; nesting them in [ ] creates a
# nested list which Nix rejects.  The ++ operator concatenates lists.
# Marker: "] ++ rpkgs ++ system_packages"
# -----------------------------------------------------------------------------
if grep -qF "] ++ rpkgs ++ system_packages;" "${NIX_FILE}"; then
    _report "skip" "Patch 1: buildInputs concatenation — already applied"
    _skipped=$((_skipped + 1))
else
    _report "apply" "Patch 1: fixing buildInputs from nested literal to ++ concatenation"
    python3 - "${NIX_FILE}" << 'PYEOF'
import sys, re
nix = sys.argv[1]
c = open(nix).read()
c = re.sub(
    r'buildInputs\s*=\s*\[\s*muttest\s+rpkgs\s+system_packages\s*\]\s*;',
    'buildInputs = [ muttest ] ++ rpkgs ++ system_packages;',
    c
)
open(nix, 'w').write(c)
PYEOF
    _report "done" "Patch 1 applied"
    _applied=$((_applied + 1))
fi

# -----------------------------------------------------------------------------
# Patch 2 — doCheck = false on the muttest buildRPackage derivation
# -----------------------------------------------------------------------------
# rix omits doCheck; the default is true, which triggers R CMD check.
# muttest's Suggests (covr, cucumber, purrr, stringr) are absent in this
# minimal environment, so R CMD check fails.
# Insertion point: after the closing }; of the src = pkgs.fetchgit { } block.
# Marker: "doCheck = false"
# -----------------------------------------------------------------------------
if grep -q "doCheck = false;" "${NIX_FILE}"; then
    _report "skip" "Patch 2: doCheck = false — already present"
    _skipped=$((_skipped + 1))
else
    _report "apply" "Patch 2: adding doCheck = false to muttest derivation"
    python3 - "${NIX_FILE}" << 'PYEOF'
import sys, re
nix = sys.argv[1]
c = open(nix).read()
# Match the sha256 line and the closing }; of the fetchgit block.
# Group 2 captures the indentation before }; for consistent alignment.
c = re.sub(
    r'(sha256\s*=\s*"[^"]+"\s*;\s*\n(\s*)\};\s*\n)',
    lambda m: (
        m.group(1)
        + m.group(2) + '# Suggests not in minimal env; package installs and loads correctly\n'
        + m.group(2) + 'doCheck = false;\n'
    ),
    c,
    count=1
)
open(nix, 'w').write(c)
PYEOF
    _report "done" "Patch 2 applied"
    _applied=$((_applied + 1))
fi

# -----------------------------------------------------------------------------
# Patch 3 — digest and usethis in propagatedBuildInputs of muttest derivation
# -----------------------------------------------------------------------------
# Both are in r_pkgs in default.R, so rix normally includes them.
# This guard verifies presence and adds them if a stale default.R omitted them.
# digest:  used by PackageCopyStrategy (undeclared dep in muttest DESCRIPTION)
# usethis: loaded by nix fixupPhase namespace verification chain
# Marker: "digest" anywhere in the file
# -----------------------------------------------------------------------------
if grep -q "digest" "${NIX_FILE}"; then
    _report "skip" "Patch 3: digest in propagatedBuildInputs — already present"
    _skipped=$((_skipped + 1))
else
    _report "apply" "Patch 3: adding digest and usethis to propagatedBuildInputs"
    python3 - "${NIX_FILE}" << 'PYEOF'
import sys, re
nix = sys.argv[1]
c = open(nix).read()

def _inject_digest_usethis(m):
    block = m.group(0)
    if 'digest' not in block:
        block = re.sub(
            r'(inherit\s*\(pkgs\.rPackages\)\s*\n)',
            r'\1          digest\n          usethis\n',
            block,
            count=1
        )
    return block

c = re.sub(
    r'propagatedBuildInputs\s*=\s*builtins\.attrValues\s*\{[^}]*\}',
    _inject_digest_usethis,
    c,
    flags=re.DOTALL
)
open(nix, 'w').write(c)
PYEOF
    _report "done" "Patch 3 applied"
    _applied=$((_applied + 1))
fi

# -----------------------------------------------------------------------------
# Patch 4 — MANUAL PATCHES comment block before the 'let' keyword
# -----------------------------------------------------------------------------
# rix regenerates the rix-call comment header but drops all hand-edits.
# This block documents what default.post.sh re-applies, making the hand-edit
# history visible to anyone reading default.nix without running the script.
# Marker: "MANUAL PATCHES (applied after rix generation):"
# -----------------------------------------------------------------------------
if grep -qF "MANUAL PATCHES (applied after rix generation):" "${NIX_FILE}"; then
    _report "skip" "Patch 4: MANUAL PATCHES comment block — already present"
    _skipped=$((_skipped + 1))
else
    _report "apply" "Patch 4: inserting MANUAL PATCHES comment block before 'let'"
    python3 - "${NIX_FILE}" << 'PYEOF'
import sys, re
nix = sys.argv[1]
c = open(nix).read()

comment = (
    "# MANUAL PATCHES (applied after rix generation):\n"
    "#   1. buildInputs: [ muttest rpkgs system_packages ] ->\n"
    "#      [ muttest ] ++ rpkgs ++ system_packages (fixes nested list Nix error)\n"
    "#   2. muttest derivation: doCheck = false\n"
    "#      (Suggests not in minimal env: covr, cucumber, purrr, stringr)\n"
    "#   3. digest and usethis in propagatedBuildInputs\n"
    "#      (undeclared/transitive deps of muttest not in its DESCRIPTION)\n"
    "#   4. This comment block documenting the patches\n"
)

c = re.sub(r'^(let\b)', comment + r'\1', c, count=1, flags=re.MULTILINE)
open(nix, 'w').write(c)
PYEOF
    _report "done" "Patch 4 applied"
    _applied=$((_applied + 1))
fi

echo ""
echo "==> ${_applied} patch(es) applied, ${_skipped} skipped."
