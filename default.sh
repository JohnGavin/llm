#!/bin/bash
# =============================================================================
# Nix Environment Setup Script with Persistent GC Root
# =============================================================================
#
# PURPOSE: Builds and activates a reproducible Nix environment with:
# - Persistent garbage collection (GC) root to prevent package deletion
# - Positron IDE integration
# - Proper shell configuration (bash/zsh) with arrow key support
#
# USAGE:
#   rm -f ~/docs_gh/rix.setup/nix-shell-root && caffeinate -i ~/docs_gh/rix.setup/default.sh
#
# HISTORICAL ISSUES FIXED (2025-11-26):
#
# 1. sed error: "Not a directory" when accessing Rprofile.site
#    - Root cause: shellHook tried to run sed on $NIX_SHELL_PATH/etc/R/Rprofile.site
#    - Problem: $NIX_SHELL_PATH points to shell script, not directory structure
#    - Solution: Removed sed command from shellHook in default.R (Fix 3)
#    - Fixed in: default.R line 653-660
#
# 2. .nix-session.log error: "$HOME/.nix-session.log: No such file or directory"
#    - Root cause: Double backslash escaping (\\$HOME) in shellHook
#    - Problem: When eval'd, \\$HOME becomes \$HOME which doesn't expand
#    - Solution: Removed log file lines from shellHook in default.R
#    - Fixed in: default.R shell_hook section (removed touch/date lines)
#
# 3. Arrow keys not working (showing ^[[A ^[[B instead of navigating history)
#    - Root cause: Nix sets $SHELL to bash, but user runs zsh
#    - Problem: Bash readline config created, but zsh needs different bindings
#    - Solution: Save user's actual shell BEFORE Nix changes $SHELL (line 94-95)
#              - Detect shell type and apply appropriate config (line 231-247)
#              - For zsh: Use bindkey commands in ~/.nix-shell-zshrc
#              - For bash: Use bind commands in ~/.nix-shell-bashrc
#    - Key insight: Must save $SHELL before sourcing Nix environment!
#
# 4. ⚠️ CRITICAL: Nix syntax error "unexpected invalid token" (2025-11-28)
#    - Root cause: Quoted paths with backslash-dollar in default.nix
#    - Problem: mkdir -p "\$HOME/.config" is INVALID in Nix double-quoted strings
#    - Error: "syntax error, unexpected invalid token, expecting ';'"
#    - Why: Nix double-quoted strings cannot contain \$ (backslash-dollar combo)
#    - Solution: Remove quotes from paths: mkdir -p $HOME/.config (NO quotes)
#    - In default.R: Use \\$HOME without quotes: mkdir -p \\$HOME/.config
#    - Affected lines in default.R: mkdir, cat >, chmod, export RSTUDIO_TERM_EXEC
#    - This bug has recurred MULTIPLE times - quotes break Nix syntax!
#    - See default.R lines 363-408 for detailed escaping rules
#
# CRITICAL VARIABLES:
# - USER_ACTUAL_SHELL: Saved before Nix changes $SHELL (line 95)
# - GC_ROOT_PATH: Symlink protecting Nix packages from garbage collection
# - NIX_STORE_PATH: Actual path to built Nix shell in /nix/store
# =============================================================================

# Define paths
PROJECT_PATH="/Users/johngavin/docs_gh/llm"
GC_ROOT_PATH="$PROJECT_PATH/nix-shell-root"
NIX_FILE="$PROJECT_PATH/default.nix"

# Debug mode: set DEBUG=true to enable verbose output
DEBUG=${DEBUG:-false}
debug() { [ "$DEBUG" = "true" ] && echo "[DEBUG] $*"; }

# Validate HOME path: must be non-empty, absolute, and not contain literal '$'
is_valid_home() {
    case "$1" in
        "") return 1 ;;      # Empty
        *'$'*) return 1 ;;   # Contains literal $
        /*) return 0 ;;      # Absolute path - valid
        *) return 1 ;;       # Relative path
    esac
}

# Normalize HOME to avoid literal $HOME paths inside the repo.
sanitize_home() {
    if ! is_valid_home "$HOME"; then
        if [ -n "$USER" ] && [ -d "/Users/$USER" ]; then
            export HOME="/Users/$USER"
            debug "Fixed invalid HOME, set to $HOME"
        fi
    fi
}

sanitize_home

# Export environment variables BEFORE any Nix operations
export NIXPKGS_ALLOW_BROKEN=1 
export NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1
export NIXPKGS_ALLOW_UNFREE=1
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}"
export CURL_CA_BUNDLE="${CURL_CA_BUNDLE:-/etc/ssl/cert.pem}"

echo -e "\n=== STEP 1: Generate default.nix from default.R (if needed) ==="

# Determine if default.nix needs regeneration
NEED_REGEN=false

# Check 1: default.nix doesn't exist
if [ ! -f "$NIX_FILE" ]; then
    echo "default.nix does not exist."
    NEED_REGEN=true
# Check 2: default.nix exists but is empty
elif [ ! -s "$NIX_FILE" ]; then
    echo "default.nix exists but is empty."
    NEED_REGEN=true
# Check 3: default.R is newer than default.nix
elif [ "$PROJECT_PATH/default.R" -nt "$NIX_FILE" ]; then
    echo "default.R has been modified since default.nix was generated."
    NEED_REGEN=true
# Check 4: default.R shellHook changes not reflected in default.nix
elif /usr/bin/grep -q "bin.old" "$PROJECT_PATH/default.R" && ! /usr/bin/grep -q "bin.old" "$NIX_FILE"; then
    echo "default.R and default.nix PATH hook are out of sync."
    NEED_REGEN=true
# Check 5: default.nix still contains escaped PATH that breaks runtime PATH
elif /usr/bin/grep -Fq 'export PATH=/Users/johngavin/docs_gh/llm/bin:\\$PATH' "$NIX_FILE"; then
    echo "default.nix still contains escaped PATH that breaks PATH at runtime."
    NEED_REGEN=true
# Check 6: default.nix exists but has invalid Nix syntax
elif ! nix-instantiate --parse "$NIX_FILE" > /dev/null 2>&1; then
    echo "default.nix has invalid Nix syntax."
    NEED_REGEN=true
else
    echo "default.nix is up to date."
fi

if [ "$NEED_REGEN" = true ]; then
    echo "Regenerating default.nix from default.R..."
    # Note: Removed --pure flag to ensure nix commands remain available to rix package
    # This is needed because rix checks for nix-shell availability when processing GitHub packages
    if ! nix-shell \
        --keep PATH \
        --keep TMPDIR \
        --keep CACHIX_AUTH_TOKEN \
        --keep GITHUB_PAT \
        --keep SSL_CERT_FILE \
        --keep CURL_CA_BUNDLE \
        --keep NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM \
        --keep NIXPKGS_ALLOW_UNFREE \
        --expr "let pkgs = import <nixpkgs> {}; in pkgs.mkShell { buildInputs = [ pkgs.R pkgs.rPackages.rix pkgs.rPackages.cli pkgs.rPackages.curl pkgs.curlMinimal pkgs.cacert ]; }" \
        --command "cd \"$PROJECT_PATH\" && \
            Rscript \
            --vanilla \
            \"$PROJECT_PATH/default.R\" \
            --args GITHUB_PAT=$GITHUB_PAT" \
        --cores 4 \
        --quiet; then
        echo "ERROR: Step 1 failed - Rscript default.R returned an error."
        echo "Fix the error in default.R and try again."
        exit 1
    fi

    # Verify regeneration succeeded
    if [ ! -s "$NIX_FILE" ]; then
        echo "ERROR: default.nix regeneration failed (file is empty or missing)."
        exit 1
    fi
fi

echo -e "\n=== STEP 2: Build shell and create persistent GC root ==="

# Build the shell derivation and create GC root symlink atomically
# The -o flag creates the symlink AND protects from garbage collection
echo "cachix use rstats-on-nix # BEFORE nix-build"
cachix use rstats-on-nix

echo "Starting nix-build '$NIX_FILE' ..."
if ! time nix-build "$NIX_FILE" \
    -A shell \
    -o "$GC_ROOT_PATH" \
    --cores 8 \
    --quiet; then
    echo "ERROR: Step 2 failed - nix-build returned an error."
    exit 1
fi

if [ ! -L "$GC_ROOT_PATH" ]; then
    echo "ERROR: Failed to build the Nix shell or create GC root at $GC_ROOT_PATH"
    exit 1
fi

STORE_PATH=$(readlink -f "$GC_ROOT_PATH")
echo "✓ SUCCESS: Persistent GC Root created"
echo "  Symlink: $GC_ROOT_PATH"
echo "  Points to: $STORE_PATH"
echo "  To allow garbage collection later, run: rm $GC_ROOT_PATH"

echo -e "\n=== STEP 3: Verify GC root is registered ==="
if nix-store --gc --print-roots | grep -q "$GC_ROOT_PATH"; then
    echo "✓ GC root is properly registered with Nix"
else
    echo "⚠ WARNING: GC root may not be properly registered"
fi



echo -e "\n=== STEP 4: Launch Positron and Enter Interactive Nix Shell (FINAL FIX for Darwin/macOS) ==="

# --- 4A: Resolve the GC Root Symlink to the actual Nix Store Path ---
if [ ! -L "$GC_ROOT_PATH" ]; then
    echo "ERROR: GC Root symlink not found at $GC_ROOT_PATH. Cannot proceed with fixed launch."
    exit 1
fi
# 1. Read the resolved path of the built Nix shell script from the GC root symlink
NIX_STORE_PATH=$(readlink "$GC_ROOT_PATH")

# 2. Prepare the environment file
# We strip the first 4 lines (warning banner) and 
# save to a temp file to ensure clean sourcing.
# FIX (2025-12-09): Explicitly set TMPDIR to a writable temporary directory
# to resolve "Read-only file system" error when creating temporary scripts.
export TMPDIR="/tmp" 
ENV_SCRIPT="$TMPDIR/nix-env-$(date +%s).sh"
tail -n +5 "$NIX_STORE_PATH" > "$ENV_SCRIPT"

# 3. Source the environment in the CURRENT shell
echo "Activating Nix environment..."
USER_HOME="$HOME"
USER_SHELL="$SHELL"

# CRITICAL: Save user's actual shell BEFORE sourcing Nix environment
# Why: Nix will override $SHELL to point to its own bash
# Impact: Without this, we can't detect if user runs zsh and needs zsh key bindings
# Used later: Line 231-247 to apply correct shell configuration
USER_ACTUAL_SHELL="$SHELL"

# Ensure HOME is a valid absolute path before running the shellHook.
# Note: is_valid_home() is defined at top of script
if ! is_valid_home "$USER_HOME"; then
    fallback="/Users/$(id -un)"
    if is_valid_home "$fallback"; then
        USER_HOME="$fallback"
    else
        USER_HOME="$TMPDIR"
    fi
    export HOME="$USER_HOME"
    echo "Reset HOME to $USER_HOME"
fi

# Define wrapper directory using USER_HOME (before sourcing Nix env)
if is_valid_home "$USER_HOME"; then
    WRAPPER_DIR="$USER_HOME/.config/positron"
    mkdir -p "$WRAPPER_DIR"
else
    WRAPPER_DIR="$TMPDIR/positron"
    mkdir -p "$WRAPPER_DIR"
    echo "Skipping wrapper setup due to invalid HOME."
fi

if ! source "$ENV_SCRIPT"; then
    echo "ERROR: Step 4 failed - could not source Nix environment script."
    exit 1
fi
export IN_NIX_SHELL=impure

# Generate a clean environment file using export -p to properly handle multi-line variables
# We filter out BASH*, SHLVL, PWD, OLDPWD, and Nix internals
CLEAN_ENV_FILE="$WRAPPER_DIR/nix_env.sh"
rm -f "$CLEAN_ENV_FILE"
echo "Generating clean environment using export -p..."

# Use export -p which properly quotes all values, then filter and reformat
export -p | \
grep -vE "^declare -[a-zA-Z-]+ (BASH|SHLVL|PWD|OLDPWD|HOME|SHELL|TERM|USER|LOGNAME|DISPLAY|SSH_|Apple_|_|buildPhase|shellHook|builder|configureFlags|deps|doCheck|mesonFlags|name|nativeBuildInputs|out|outputs|patches|phases|preferLocalBuild|propagated|stdenv|strictDeps|system|TEMP|TMP|TMPDIR|NIX_BUILD)=" | \
sed 's/^declare -x /export /' | \
sed 's/^declare -[a-zA-Z-]* /export /' > "$CLEAN_ENV_FILE"

# Restore HOME and append system PATH (to fix locale, direnv, etc.)
export HOME="$USER_HOME"
export PATH="$PATH:$USER_PATH"

rm -f "$ENV_SCRIPT"

# 4. Run the shell hook (sets up aliases, etc.)
if [ -n "$shellHook" ]; then
    eval "$shellHook"
    
    # MANUALLY CREATE THE WRAPPER SCRIPT
    # shellHook fails to create it reliably due to escaping issues.
    if is_valid_home "$HOME"; then
        WRAPPER_DIR="$HOME/.config/positron"
        /bin/mkdir -p "$WRAPPER_DIR"
        WRAPPER_FILE="$WRAPPER_DIR/nix-terminal-wrapper.sh"
        
        echo "Creating wrapper script at $WRAPPER_FILE..."
        /bin/cat > "$WRAPPER_FILE" <<WRAPPER_EOF
#!/bin/bash
# Wrapper script for Positron Terminal
# Generated by default.sh

# Source the Nix environment
if [ -n "\$RIX_NIX_SHELL_ROOT" ] && [ -f "\$RIX_NIX_SHELL_ROOT" ]; then
    # Source the environment (skipping first 4 lines)
    source <(tail -n +5 "\$RIX_NIX_SHELL_ROOT")
fi

# Save the Nix PATH to restore it after user rc files run
export POSITRON_NIX_PATH="\$PATH"
export POSITRON_NIX_ENV=1

# Create a custom rc file that preserves Nix PATH
CUSTOM_RC="\$HOME/.config/positron/positron-shell-rc.sh"
cat > "\$CUSTOM_RC" <<'RC_EOF'
# Source user's normal rc file
if [ -n "\$BASH_VERSION" ]; then
    [ -f ~/.bashrc ] && source ~/.bashrc
elif [ -n "\$ZSH_VERSION" ]; then
    [ -f ~/.zprofile ] && source ~/.zprofile
    [ -f ~/.zshrc ] && source ~/.zshrc
fi

# Restore Nix PATH priority (prepend Nix paths)
if [ -n "\$POSITRON_NIX_PATH" ]; then
    export PATH="\$POSITRON_NIX_PATH"
fi
export IN_NIX_SHELL=impure

# Readline configuration for bash (arrow keys for history)
set -o emacs
bind '"\e[A": history-search-backward'
bind '"\e[B": history-search-forward'
bind '"\e[C": forward-char'
bind '"\e[D": backward-char'
RC_EOF

# Launch shell with custom rc file
if [[ "$USER_SHELL" == *"zsh"* ]]; then
    # For zsh, create a custom zshrc that sources the user's and adds our config
    CUSTOM_ZSHRC="\$HOME/.config/positron/positron-zshrc"
    cat > "\$CUSTOM_ZSHRC" <<'ZSH_EOF'
# Source user's zshrc if it exists
[ -f ~/.zprofile ] && source ~/.zprofile
[ -f ~/.zshrc ] && source ~/.zshrc

# Restore Nix PATH
if [ -n "$POSITRON_NIX_PATH" ]; then
    export PATH="$POSITRON_NIX_PATH"
fi
export IN_NIX_SHELL=impure

# Zsh key bindings for history
bindkey '^[[A' up-line-or-history
bindkey '^[[B' down-line-or-history
bindkey '^[[C' forward-char
bindkey '^[[D' backward-char
ZSH_EOF
    exec $USER_SHELL -c "export ZDOTDIR=\$HOME/.config/positron; source \$CUSTOM_ZSHRC; exec $USER_SHELL -i"
else
    # For bash, use --rcfile
    exec $USER_SHELL --rcfile "\$CUSTOM_RC" -i
fi
WRAPPER_EOF
        /bin/chmod +x "$WRAPPER_FILE"
    else
        echo "Skipping manual wrapper setup due to invalid HOME."
    fi
fi

# Re-export critical variables
export NIXPKGS_ALLOW_BROKEN=1
export NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1
export NIXPKGS_ALLOW_UNFREE=1
export GITHUB_PAT="$GITHUB_PAT"
# Fix log file creation
touch "$HOME/.nix-session.log" 2>/dev/null || true
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
export TMPDIR="$TMPDIR"
# Export the GC root path so internal shells can source it
export RIX_NIX_SHELL_ROOT="$GC_ROOT_PATH"

debug "Git path: $(/usr/bin/which git)"
debug "SSL_CERT_FILE: $NIX_SSL_CERT_FILE"

# 5. Launch Positron (ONLY from Nix environment)
if command -v positron &> /dev/null; then
    echo "Launching Positron from Nix environment..."
    # Log output to file for debugging
    debug "Launching Positron with --verbose"
    nohup positron --verbose > "/tmp/positron.log" 2>&1 &
else
    echo "⚠️  Positron not found in Nix environment PATH."
    echo "   PATH: $PATH"
fi

echo -e "\n=============================================="
echo "Entering INTERACTIVE Nix Shell"
echo -e "==============================================\n"

# 6. Replace current process with interactive shell
# Use -i flag to enable interactive mode with command history and readline
# We avoid -l (login shell) to prevent resetting PATH via ~/.zprofile / ~/.bash_profile

# CRITICAL: Use USER_ACTUAL_SHELL (saved at line 138) not $SHELL
# Why: After sourcing Nix environment, $SHELL points to Nix's bash
# Impact: Using $SHELL would launch bash even if user runs zsh
# Solution: Use USER_ACTUAL_SHELL to detect and configure correct shell

# fix the TMPDIR issue.
debug "TMPDIR before unset: $TMPDIR"
unset TMPDIR
debug "TMPDIR after unset: $TMPDIR"

# Use the shellHook-created bashrc if it exists and we're using bash
if [[ "$USER_ACTUAL_SHELL" == *"bash"* ]] && [ -f ~/.nix-shell-bashrc ]; then
    exec $USER_ACTUAL_SHELL --rcfile ~/.nix-shell-bashrc -i
elif [[ "$USER_ACTUAL_SHELL" == *"zsh"* ]]; then
    # For zsh, create custom zshrc with key bindings for arrow keys
    # bindkey maps escape sequences (^[[A = up arrow) to zsh commands
    OMZ_PLUGIN_CUSTOM="$HOME/.config/oh-my-zsh/plugins/zsh-completions/zsh-completions.plugin.zsh"
    OMZ_PLUGIN_DEFAULT="$HOME/.oh-my-zsh/custom/plugins/zsh-completions/zsh-completions.plugin.zsh"
    for OMZ_PLUGIN in "$OMZ_PLUGIN_CUSTOM" "$OMZ_PLUGIN_DEFAULT"; do
        if [ ! -f "$OMZ_PLUGIN" ]; then
            /bin/mkdir -p "$(dirname "$OMZ_PLUGIN")"
            /bin/cat > "$OMZ_PLUGIN" <<'OMZ_EOF'
# Stub plugin to silence missing zsh-completions warnings in Nix shells.
return 0
OMZ_EOF
        fi
    done
    export NIX_SHELL_PATH_SAVED="$PATH"
    NIX_ZDOTDIR="$HOME/.nix-shell-zdotdir"
    /bin/mkdir -p "$NIX_ZDOTDIR"
    /bin/cat > "$NIX_ZDOTDIR/.zshenv" <<'ZSHENV'
if [ -n "$NIX_SHELL_PATH_SAVED" ]; then
    export PATH="$NIX_SHELL_PATH_SAVED"
fi
export IN_NIX_SHELL=impure
ZSHENV
    /bin/cat > "$NIX_ZDOTDIR/.zprofile" <<'ZPROFILE'
[ -f ~/.zprofile ] && source ~/.zprofile
if [ -n "$NIX_SHELL_PATH_SAVED" ]; then
    export PATH="$NIX_SHELL_PATH_SAVED"
fi
export IN_NIX_SHELL=impure
ZPROFILE
    /bin/cat > "$NIX_ZDOTDIR/.zshrc" <<'ZSHRC'
[ -f ~/.zshrc ] && source ~/.zshrc
if [ -n "$NIX_SHELL_PATH_SAVED" ]; then
    export PATH="$NIX_SHELL_PATH_SAVED"
fi
export IN_NIX_SHELL=impure
bindkey '^[[A' up-line-or-history
bindkey '^[[B' down-line-or-history
bindkey '^[[C' forward-char
bindkey '^[[D' backward-char
ZSHRC
    export ZDOTDIR="$NIX_ZDOTDIR"
    exec $USER_ACTUAL_SHELL -i
else
    # Fallback to Nix's SHELL
    exec $SHELL -i
fi

# NOTE: Lines below exec never execute (exec replaces the process)
# Kept as documentation only - the shell exits when user types 'exit'
