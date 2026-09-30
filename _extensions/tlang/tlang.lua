local t_state = {session_source = ""}

local function has_class(el, class_name)
    for _, class in ipairs(el.classes) do
        -- Strip any surrounding {} and convert to lower for robustness
        local clean_class = class:gsub("^{", ""):gsub("}$", ""):lower()
        if clean_class == class_name:lower() then return true end
    end
    return false
end

local function split_lines(text)
    local lines = {}
    if text == "" then return lines end

    text = text:gsub("\r\n", "\n")
    text = text:gsub("\r", "\n")

    for line in (text .. "\n"):gmatch("(.-)\n") do table.insert(lines, line) end

    return lines
end

local function trim(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end

local function normalize_bool(value, default)
    if value == nil then return default end

    local lowered = trim(tostring(value)):lower()
    if lowered == "true" then return true end
    if lowered == "false" then return false end

    return default
end

local function parse_chunk_options(text)
    local options = {}
    local body_lines = {}
    local parsing_options = true

    for _, line in ipairs(split_lines(text)) do
        -- Accept Quarto-style leading chunk options such as:
        --   #| echo: false
        --   #| results: hide
        local key, value = line:match("^%s*#|%s*([%w_-]+)%s*:%s*(.-)%s*$")
        if parsing_options and key ~= nil then
            options[key] = value
        else
            parsing_options = false
            table.insert(body_lines, line)
        end
    end

    return options, table.concat(body_lines, "\n")
end

local function write_file(path, content)
    local handle, open_err = io.open(path, "w")
    if handle == nil then error(open_err) end

    handle:write(content)
    handle:close()
end

local function resolve_binary()
    local binary = os.getenv("TLANG_BIN")
    if binary == nil or trim(binary) == "" then return "t" end

    if binary:match("[\r\n]") ~= nil or binary:match("%z") ~= nil then
        error("TLANG_BIN must point to a single executable path.")
    end

    local normalized = binary
    if binary:match("^[A-Za-z]:[\\/]") ~= nil then
        normalized = binary:sub(3)
    elseif binary:match(":") ~= nil then
        error("TLANG_BIN may only use ':' in a Windows drive prefix.")
    end

    if not normalized:match("^[%w%._/%-\\]+$") then
        error("TLANG_BIN contains unsupported characters.")
    end

    -- LOCAL PATCH (VENDORED.md #3): reject ".." only as a whole path segment,
    -- so names such as "t..old" are not refused.
    if ("/" .. normalized:gsub("\\", "/") .. "/"):match("/%.%./") ~= nil then
        error("TLANG_BIN may not contain parent-directory traversal segments.")
    end

    if binary:match("[/\\]") ~= nil then
        local handle = io.open(binary, "r")
        if handle == nil then
            error("TLANG_BIN does not point to a readable executable path.")
        end
        handle:close()
    end

    return binary
end

local function render_error(message)
    return pandoc.CodeBlock("T execution failed:\n" .. tostring(message),
                            pandoc.Attr("", {"text", "t-error"}))
end

-- LOCAL PATCH (VENDORED.md #1): marker printed between chunks of the
-- accumulated source so earlier chunks' output can be discarded.
local CHUNK_SENTINEL = "@@tlang-chunk-boundary@@"

-- Returns the text after the last sentinel, or nil when none is present.
-- Only optional trailing spaces/tabs and at most one line terminator directly
-- after the sentinel are dropped; the real CLI emits "<text> \n" but the
-- terminator is not assumed.
local function after_last_sentinel(output)
    local last_end
    local pos = 1
    while true do
        local _, e = string.find(output, CHUNK_SENTINEL, pos, true)
        if e == nil then break end
        last_end = e
        pos = e + 1
    end
    if last_end == nil then return nil end
    return (string.sub(output, last_end + 1):gsub("^[ \t]*\r?\n?", "", 1))
end

-- Execute Quarto T chunks in strict mode while intentionally bypassing the
-- normal pipeline-only script guard so prose-first documents can render.
local function execute_t_unsafe(chunk_source)
    if pandoc.system == nil or pandoc.system.with_temporary_directory == nil then
        return false,
               "This Quarto filter requires pandoc.system.with_temporary_directory()."
    end

    local binary_ok, binary = pcall(resolve_binary)
    if not binary_ok then return false, tostring(binary) end
    local function run_temp_script(temp_path)
        write_file(temp_path, chunk_source)
        -- pandoc.pipe executes the binary directly with argv, not through a shell.
        return pcall(pandoc.pipe, binary,
                     {"--mode", "strict", "--unsafe", "run", temp_path}, "")
    end

    local wrapped_ok, ok, output = pcall(pandoc.system.with_temporary_directory,
                                         "tlang", function(temp_dir)
        return run_temp_script(temp_dir .. "/chunk.t")
    end)
    if not wrapped_ok then return false, tostring(ok) end

    if ok then return true, output end

    -- LOCAL PATCH (VENDORED.md #4): decide "binary missing" from how the call
    -- failed, not from the message text. pandoc.pipe raises a table with an
    -- `error_code` when the process ran and exited non-zero; any other error
    -- value means the process could not be spawned at all.
    local message = tostring(output)
    if type(output) ~= "table" or output.error_code == nil then
        return false, string.format(
                   "Could not run `%s`. Make sure the T CLI is installed or set TLANG_BIN to the correct binary.\n%s",
                   binary, message)
    end
    if type(output.output) == "string" and output.output ~= "" then
        -- LOCAL PATCH (VENDORED.md #4): the script is the accumulated source
        -- of earlier chunks, so keep only the failing chunk's own stdout.
        -- pandoc already embeds the full stdout in its own error message
        -- ("... (error code N): <stdout>"), so cut that suffix before
        -- appending the trimmed text. Only when a sentinel is present.
        local raw = output.output
        local stdout = after_last_sentinel(raw)
        if stdout ~= nil then
            if message:sub(-#raw) == raw then
                message = message:sub(1, #message - #raw):gsub("%s+$", "")
            end
            if stdout ~= "" then message = message .. "\n" .. stdout end
        else
            message = message .. "\n" .. raw
        end
    end
    return false, message
end

-- Returns the output following the last sentinel. If the sentinel is absent
-- (should not happen) the full output is returned and a warning logged,
-- rather than silently dropping output.
local function last_chunk_output(output)
    local rest = after_last_sentinel(output)
    if rest == nil then
        io.stderr:write(
            "[tlang] chunk-boundary sentinel missing from output; rendering unsplit output\n")
        return output
    end
    return rest
end

local function make_output_block(output)
    if output == nil or output == "" then return nil end

    return pandoc.CodeBlock(output, pandoc.Attr("", {"text", "t-output"}))
end

function CodeBlock(el)
    if not (has_class(el, "t") or has_class(el, "tlang")) then return nil end

    local options, body = parse_chunk_options(el.text)
    local include = normalize_bool(options.include, true)
    local should_eval = normalize_bool(options.eval, true)
    local show_code = normalize_bool(options.echo, true)
    local results = options.results and trim(options.results):lower() or nil
    local show_output = include and normalize_bool(options.output, true) and
                            results ~= "hide"

    if trim(body) == "" then
        local rendered_blocks = {}

        -- For chunks that only contain options (#| lines) and no body:
        -- - respect include/echo
        -- - do not re-emit the original block (which would include #| lines)
        if include and show_code then
            table.insert(rendered_blocks, pandoc.CodeBlock("", el.attr))
        end

        return rendered_blocks
    end

    local rendered_blocks = {}

    if include and show_code then
        table.insert(rendered_blocks, pandoc.CodeBlock(body, el.attr))
    end

    if not should_eval then return rendered_blocks end

    -- LOCAL PATCH (VENDORED.md #1): the `t` CLI has no persistent session mode
    -- for `run`, so each chunk still re-runs the accumulated source of all
    -- earlier chunks (O(n^2); side effects of earlier chunks repeat). What no
    -- longer repeats is their printed OUTPUT: a sentinel line is printed
    -- between chunks and only the text after the last sentinel is rendered.
    local new_session_source
    if t_state.session_source == "" then
        new_session_source = body
    else
        new_session_source = t_state.session_source .. "\n\n" ..
                                 string.format("print(%q)", CHUNK_SENTINEL) ..
                                 "\n\n" .. body
    end

    local ok, output = execute_t_unsafe(new_session_source)
    if not ok then
        -- LOCAL PATCH (VENDORED.md #2): never fail silently. The failed chunk
        -- is NOT added to the session, so later chunks run without it.
        io.stderr:write("[tlang] chunk failed", include and "" or
                            " (include: false, nothing rendered)",
                        "; excluded from the session state:\n",
                        tostring(output), "\n")
        if include then
            table.insert(rendered_blocks, render_error(output))
            return rendered_blocks
        end
        return {}
    end

    if t_state.session_source ~= "" then
        output = last_chunk_output(output)
    end

    -- Only update the session state after successful execution
    t_state.session_source = new_session_source

    if show_output then
        local output_block = make_output_block(output)
        if output_block ~= nil then
            table.insert(rendered_blocks, output_block)
        end
    end

    return rendered_blocks
end
