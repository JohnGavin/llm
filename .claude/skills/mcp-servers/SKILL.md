# MCP (Model Context Protocol) Servers Guide

## Description

MCP servers extend Claude Code with additional capabilities through a standardized protocol. They provide specialized tools, resources, and context for domain-specific tasks.

## Purpose

Use this skill when:
- Understanding available MCP integrations
- Configuring new MCP servers
- Debugging MCP connection issues
- Choosing between MCP tools and built-in alternatives

## Available MCP Servers

### r-btw (R Session Integration)

**Purpose:** Provides live R session integration for documentation, data exploration, and GitHub API access.

**Key Tools:**

| Tool | Purpose | Example Use |
|------|---------|-------------|
| `btw_tool_docs_help_page` | Get R function documentation | Look up `dplyr::filter` help |
| `btw_tool_docs_available_vignettes` | List package vignettes | Find ggplot2 tutorials |
| `btw_tool_docs_vignette` | Read vignette content | Read "programming" vignette |
| `btw_tool_docs_package_news` | Check package changes | What changed in dplyr 1.1.0? |
| `btw_tool_env_describe_data_frame` | Inspect data structure | Skim a dataset |
| `btw_tool_env_describe_environment` | List R environment objects | What's in global env? |
| `btw_tool_files_code_search` | Search code files | Find function references |
| `btw_tool_files_list_files` | List project files | Navigate project structure |
| `btw_tool_files_read_text_file` | Read file contents | View R script |
| `btw_tool_git_*` | Git operations | Status, diff, commit, branch |
| `btw_tool_github` | GitHub API via gh() | Create issues, PRs |
| `btw_tool_search_packages` | Search CRAN packages | Find visualization packages |
| `btw_tool_session_*` | R session info | Check installed packages |

**Example Usage:**

```r
# Get help for a function
mcp__r-btw__btw_tool_docs_help_page(
  package_name = "dplyr",
  topic = "filter",
  _intent = "Looking up filter documentation"
)

# Describe a data frame
mcp__r-btw__btw_tool_env_describe_data_frame(
  data_frame = "mtcars",
  format = "skim",
  _intent = "Understanding mtcars structure"
)

# Search for packages
mcp__r-btw__btw_tool_search_packages(
  query = "random walk simulation",
  _intent = "Finding simulation packages"
)
```

### claude-in-chrome (Browser Automation)

**Purpose:** Browser automation for web interaction, screenshots, and testing.

**Key Tools:**

| Tool | Purpose |
|------|---------|
| `computer` | Mouse/keyboard actions, screenshots |
| `navigate` | URL navigation |
| `read_page` | Get page accessibility tree |
| `find` | Find elements by natural language |
| `form_input` | Fill form fields |
| `javascript_tool` | Execute page JavaScript |
| `get_page_text` | Extract page text content |

**Use Cases:**
- Testing Shinylive apps in browser
- Capturing screenshots for documentation
- Automating web workflows

## Configuration

### Project-Level MCP Config

Create `.claude/mcp.json`:

```json
{
  "mcpServers": {
    "r-btw": {
      "command": "Rscript",
      "args": ["-e", "btw::btw_mcp()"],
      "env": {
        "BTW_LOG_LEVEL": "info"
      }
    }
  }
}
```

### Global MCP Config

Located at `~/.claude/mcp.json` for servers available in all projects.

### Verify MCP Connection

```bash
# List available MCP resources
claude --mcp-list
```

## When to Use MCP vs Built-in Tools

| Task | MCP Tool | Built-in Alternative |
|------|----------|---------------------|
| Read R documentation | `btw_tool_docs_help_page` | WebFetch R-docs URL |
| Search CRAN | `btw_tool_search_packages` | WebSearch |
| Git operations | `btw_tool_git_*` | Bash git commands |
| GitHub API | `btw_tool_github` | Bash gh commands |
| Read files | `btw_tool_files_read_text_file` | Read tool |
| Search code | `btw_tool_files_code_search` | Grep tool |

**General Guidance:**
- Use MCP tools when they provide richer context (e.g., R help with examples)
- Use built-in tools for speed and simplicity
- MCP tools have R-specific knowledge that built-in tools lack

## Common Patterns

### Exploring a New Package

```r
# 1. Search for package
btw_tool_search_packages(query = "time series", ...)

# 2. Get package info
btw_tool_search_package_info(package_name = "forecast", ...)

# 3. List vignettes
btw_tool_docs_available_vignettes(package_name = "forecast", ...)

# 4. Read introductory vignette
btw_tool_docs_vignette(package_name = "forecast", ...)
```

### Debugging R Issues

```r
# 1. Check environment
btw_tool_env_describe_environment(...)

# 2. Get function documentation
btw_tool_docs_help_page(package_name = "pkg", topic = "func", ...)

# 3. Check package news for recent changes
btw_tool_docs_package_news(package_name = "pkg", search_term = "deprecated", ...)
```

### GitHub Workflow via MCP

```r
# Create issue
btw_tool_github(
  code = 'gh("POST /repos/{owner}/{repo}/issues",
         title = "Bug: fix X",
         body = "Description",
         owner = owner, repo = repo)',
  _intent = "Creating bug report issue"
)

# Get PR status
btw_tool_github(
  code = 'gh("/repos/{owner}/{repo}/pulls/123", owner = owner, repo = repo)',
  _intent = "Checking PR status"
)
```

## Troubleshooting

### MCP Server Not Responding

```bash
# Check if server process is running
ps aux | grep btw

# Restart Claude Code
# Exit and re-enter session
```

### "No R session found"

```bash
# Ensure R session is running with btw
R -e "btw::btw_mcp()"
```

### Tool Returns Empty

- Check `_intent` parameter is provided (required for all r-btw tools)
- Verify package/file exists
- Check R session is in correct directory

## Integration with Workflow

MCP servers enhance the 9-step workflow:

- **Step 1 (Create issue)**: `btw_tool_github` for issue creation
- **Step 3 (Make changes)**: `btw_tool_docs_*` for documentation lookup
- **Step 4 (Run checks)**: `btw_tool_env_*` for inspecting results
- **Step 7 (Wait for CI)**: `btw_tool_github` for PR status

## Resources

- [MCP Protocol Specification](https://modelcontextprotocol.io/)
- [btw Package](https://github.com/posit-dev/btw)
- [Claude Code MCP Documentation](https://docs.anthropic.com/claude-code/mcp)
