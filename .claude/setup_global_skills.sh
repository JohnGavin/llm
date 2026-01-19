#!/bin/bash
# =============================================================================
# Setup Global Claude Skills via Hard Links
# =============================================================================
#
# PURPOSE: Creates hard links from this repo's skills to ~/.claude/skills/
# so skills are both version-controlled (git) and globally accessible.
#
# USAGE:
#   cd /path/to/llm/.claude
#   chmod +x setup_global_skills.sh
#   ./setup_global_skills.sh
#
# OPTIONS:
#   --force    Overwrite existing files in ~/.claude/skills/
#   --dry-run  Show what would be done without making changes
#
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
FORCE=false
DRY_RUN=false
for arg in "$@"; do
    case $arg in
        --force) FORCE=true ;;
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# Get script directory (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SKILLS="$SCRIPT_DIR/skills"
TARGET_SKILLS="$HOME/.claude/skills"

echo "=== Setup Global Claude Skills ==="
echo "Source: $SOURCE_SKILLS"
echo "Target: $TARGET_SKILLS"
echo ""

# Verify source exists
if [ ! -d "$SOURCE_SKILLS" ]; then
    echo -e "${RED}ERROR: Source skills directory not found: $SOURCE_SKILLS${NC}"
    exit 1
fi

# Create target directory if needed
if [ ! -d "$TARGET_SKILLS" ]; then
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would create: $TARGET_SKILLS${NC}"
    else
        echo "Creating: $TARGET_SKILLS"
        mkdir -p "$TARGET_SKILLS"
    fi
fi

# Count operations
LINKED=0
SKIPPED=0
UPDATED=0
ERRORS=0

# Process each skill directory
for skill_dir in "$SOURCE_SKILLS"/*/; do
    skill_name=$(basename "$skill_dir")

    # Skip hidden directories
    [[ "$skill_name" == .* ]] && continue

    source_file="$SOURCE_SKILLS/$skill_name/SKILL.md"
    target_dir="$TARGET_SKILLS/$skill_name"
    target_file="$target_dir/SKILL.md"

    # Skip if no SKILL.md in source
    if [ ! -f "$source_file" ]; then
        echo -e "${YELLOW}SKIP: $skill_name (no SKILL.md)${NC}"
        ((SKIPPED++))
        continue
    fi

    # Check if already hard-linked (same inode)
    if [ -f "$target_file" ]; then
        source_inode=$(ls -i "$source_file" | awk '{print $1}')
        target_inode=$(ls -i "$target_file" | awk '{print $1}')

        if [ "$source_inode" = "$target_inode" ]; then
            echo -e "${GREEN}OK: $skill_name (already linked)${NC}"
            ((SKIPPED++))
            continue
        fi

        # Different file exists
        if [ "$FORCE" = true ]; then
            if [ "$DRY_RUN" = true ]; then
                echo -e "${YELLOW}[DRY-RUN] Would replace: $skill_name${NC}"
            else
                rm "$target_file"
                echo -e "${YELLOW}REPLACE: $skill_name${NC}"
            fi
            ((UPDATED++))
        else
            echo -e "${YELLOW}EXISTS: $skill_name (use --force to replace)${NC}"
            ((SKIPPED++))
            continue
        fi
    fi

    # Create target directory if needed
    if [ ! -d "$target_dir" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY-RUN] Would create dir: $target_dir${NC}"
        else
            mkdir -p "$target_dir"
        fi
    fi

    # Create hard link
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would link: $skill_name${NC}"
    else
        if ln "$source_file" "$target_file" 2>/dev/null; then
            echo -e "${GREEN}LINKED: $skill_name${NC}"
            ((LINKED++))
        else
            # Hard link failed (cross-device?), try symlink
            if ln -s "$source_file" "$target_file" 2>/dev/null; then
                echo -e "${GREEN}SYMLINK: $skill_name (cross-device)${NC}"
                ((LINKED++))
            else
                echo -e "${RED}ERROR: $skill_name (link failed)${NC}"
                ((ERRORS++))
            fi
        fi
    fi
done

echo ""
echo "=== Summary ==="
echo -e "Linked:  ${GREEN}$LINKED${NC}"
echo -e "Updated: ${YELLOW}$UPDATED${NC}"
echo -e "Skipped: $SKIPPED"
if [ $ERRORS -gt 0 ]; then
    echo -e "Errors:  ${RED}$ERRORS${NC}"
fi

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${YELLOW}This was a dry run. Run without --dry-run to apply changes.${NC}"
fi

# Also handle agents if they exist
if [ -d "$SCRIPT_DIR/agents" ]; then
    echo ""
    echo "=== Agents ==="
    TARGET_AGENTS="$HOME/.claude/agents"

    if [ ! -d "$TARGET_AGENTS" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY-RUN] Would create: $TARGET_AGENTS${NC}"
        else
            mkdir -p "$TARGET_AGENTS"
        fi
    fi

    for agent_file in "$SCRIPT_DIR/agents"/*.md; do
        [ -f "$agent_file" ] || continue
        agent_name=$(basename "$agent_file")
        target_agent="$TARGET_AGENTS/$agent_name"

        if [ -f "$target_agent" ]; then
            source_inode=$(ls -i "$agent_file" | awk '{print $1}')
            target_inode=$(ls -i "$target_agent" | awk '{print $1}')

            if [ "$source_inode" = "$target_inode" ]; then
                echo -e "${GREEN}OK: $agent_name (already linked)${NC}"
                continue
            fi

            if [ "$FORCE" = true ]; then
                if [ "$DRY_RUN" = false ]; then
                    rm "$target_agent"
                fi
            else
                echo -e "${YELLOW}EXISTS: $agent_name (use --force)${NC}"
                continue
            fi
        fi

        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY-RUN] Would link: $agent_name${NC}"
        else
            if ln "$agent_file" "$target_agent" 2>/dev/null; then
                echo -e "${GREEN}LINKED: $agent_name${NC}"
            else
                ln -s "$agent_file" "$target_agent" 2>/dev/null && \
                    echo -e "${GREEN}SYMLINK: $agent_name${NC}" || \
                    echo -e "${RED}ERROR: $agent_name${NC}"
            fi
        fi
    done
fi

echo ""
echo "Done. Skills are now available globally at ~/.claude/skills/"
