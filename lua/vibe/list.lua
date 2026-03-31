--- Shared list/navigation pattern
--- Handles j/k/arrows/CR/q keymaps, highlight management, cursor tracking
local util = require("vibe.util")

local M = {}

---@class ListOpts
---@field items table[] Items to display
---@field render function(item, idx, is_selected) -> string[] Lines for this item
---@field on_select function(item, idx)|nil Called on <CR>
---@field on_action table<string, function(item, idx)>|nil Additional key -> handler mappings
---@field title string|nil Window title
---@field header_lines string[]|nil Lines to show before items
---@field footer_lines string[]|nil Lines to show after items
---@field row_height number|nil Lines per item (default 1)
---@field min_width number|nil Minimum window width
---@field filetype string|nil Buffer filetype

---@param opts ListOpts
---@return integer bufnr, integer winid, function close, function refresh
function M.create(opts)
    local items = opts.items or {}
    local row_height = opts.row_height or 1
    local header_lines = opts.header_lines or {}
    local footer_lines = opts.footer_lines or {}
    local selected_idx = 1

    local function build_lines()
        local lines = {}
        for _, line in ipairs(header_lines) do
            table.insert(lines, line)
        end
        for i, item in ipairs(items) do
            local rendered = opts.render(item, i, i == selected_idx)
            if type(rendered) == "string" then
                rendered = { rendered }
            end
            for _, line in ipairs(rendered) do
                table.insert(lines, line)
            end
        end
        if #footer_lines > 0 then
            table.insert(lines, "")
            for _, line in ipairs(footer_lines) do
                table.insert(lines, line)
            end
        end
        return lines
    end

    local all_lines = build_lines()
    local height = math.min(25, #all_lines + 2)

    local bufnr, winid, close = util.create_centered_float({
        lines = all_lines,
        filetype = opts.filetype or "vibe_list",
        min_width = opts.min_width or 50,
        height = height,
        title = opts.title,
        cursorline = true,
    })

    local function refresh()
        all_lines = build_lines()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, all_lines)

        -- Highlight header
        for i = 1, #header_lines do
            if i == 1 then
                vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", i - 1, 0, -1)
            end
        end
    end

    local buf_opts = { buffer = bufnr, silent = true, noremap = true }

    -- Navigation
    local function move_down()
        if selected_idx < #items then
            selected_idx = selected_idx + 1
            refresh()
            local target_line = #header_lines + (selected_idx - 1) * row_height + 1
            pcall(vim.api.nvim_win_set_cursor, winid, { target_line, 2 })
        end
    end

    local function move_up()
        if selected_idx > 1 then
            selected_idx = selected_idx - 1
            refresh()
            local target_line = #header_lines + (selected_idx - 1) * row_height + 1
            pcall(vim.api.nvim_win_set_cursor, winid, { target_line, 2 })
        end
    end

    vim.keymap.set("n", "j", move_down, buf_opts)
    vim.keymap.set("n", "<Down>", move_down, buf_opts)
    vim.keymap.set("n", "k", move_up, buf_opts)
    vim.keymap.set("n", "<Up>", move_up, buf_opts)

    -- Selection
    if opts.on_select then
        vim.keymap.set("n", "<CR>", function()
            if selected_idx >= 1 and selected_idx <= #items then
                opts.on_select(items[selected_idx], selected_idx)
            end
        end, buf_opts)
    end

    -- Additional actions
    if opts.on_action then
        for key, handler in pairs(opts.on_action) do
            vim.keymap.set("n", key, function()
                if selected_idx >= 1 and selected_idx <= #items then
                    handler(items[selected_idx], selected_idx)
                end
            end, buf_opts)
        end
    end

    -- Set initial cursor
    if #items > 0 then
        pcall(vim.api.nvim_win_set_cursor, winid, { #header_lines + 1, 2 })
    end

    return bufnr, winid, close, refresh
end

return M
