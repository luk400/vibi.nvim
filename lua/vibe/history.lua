local config = require("vibe.config")
local util = require("vibe.util")

local M = {}

local function get_history_dir()
    return vim.fn.stdpath("data") .. "/vibe-history"
end

--- Record a session event to history
---@param session_info table
function M.record(session_info)
    local hist_config = config.options.history or {}
    if hist_config.enabled == false then
        return
    end

    local dir = get_history_dir()
    vim.fn.mkdir(dir, "p")

    local entry = {
        name = session_info.name,
        timestamp = os.time(),
        repo_root = session_info.repo_root or session_info.cwd,
        worktree_path = session_info.worktree_path,
        files_changed = session_info.files_changed or 0,
        accepted = session_info.accepted or 0,
        rejected = session_info.rejected or 0,
    }

    local filename = string.format("%s/%d_%s.json", dir, entry.timestamp, entry.name:gsub("[^%w_-]", "_"))
    local json = vim.fn.json_encode(entry)
    vim.fn.writefile({ json }, filename)

    M.cleanup()
end

--- Clean up old entries beyond max_entries
function M.cleanup()
    local hist_config = config.options.history or {}
    local max_entries = hist_config.max_entries or 50

    local dir = get_history_dir()
    if vim.fn.isdirectory(dir) ~= 1 then
        return
    end

    local files = vim.fn.glob(dir .. "/*.json", false, true)
    table.sort(files)

    while #files > max_entries do
        vim.fn.delete(files[1])
        table.remove(files, 1)
    end
end

--- List history entries sorted newest-first
---@return table[]
function M.list()
    local dir = get_history_dir()
    if vim.fn.isdirectory(dir) ~= 1 then
        return {}
    end

    local files = vim.fn.glob(dir .. "/*.json", false, true)
    table.sort(files, function(a, b)
        return a > b
    end)

    local entries = {}
    for _, file in ipairs(files) do
        local content = vim.fn.readfile(file)
        if #content > 0 then
            local ok, entry = pcall(vim.fn.json_decode, content[1])
            if ok and entry then
                table.insert(entries, entry)
            end
        end
    end

    return entries
end

--- Show history in a floating window
function M.show()
    local entries = M.list()
    if #entries == 0 then
        vim.notify("[Vibe] No session history", vim.log.levels.INFO)
        return
    end

    local lines = { " Vibe Session History", " " .. string.rep("─", 50) }
    for _, entry in ipairs(entries) do
        local time_str = os.date("%Y-%m-%d %H:%M", entry.timestamp)
        local repo = vim.fn.fnamemodify(entry.repo_root or "", ":t")
        table.insert(lines, string.format(
            " %s  %-15s  %s  (%d files, +%d -%d)",
            time_str, entry.name, repo,
            entry.files_changed, entry.accepted, entry.rejected
        ))
    end
    table.insert(lines, "")
    table.insert(lines, " q close")

    local bufnr, _, _ = util.create_centered_float({
        lines = lines,
        filetype = "vibe_history",
        min_width = 70,
        max_height = 25,
        title = "Vibe History",
    })
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 0, 0, -1)
end

return M
