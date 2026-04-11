--- Large file detection and handling for :VibeReview
--- Shows a VibeCopyFiles-style toggle dialog for files above the size threshold,
--- letting users select which large files to include in the review (default: none).
--- Unselected files are ignored (not indexed, not committed, not reviewed).
local config = require("vibe.config")
local util = require("vibe.util")
local persist = require("vibe.persist")

local M = {}

-- Decision constants
M.IGNORE = "ignore"
M.MERGE = "merge"

-- Dialog state
M.bufnr = nil
M.winid = nil
M.cursor_idx = 1
M.entries = {}      -- Hierarchical (top-level dirs + files)
M.flat_entries = {} -- Flattened for rendering (includes expanded dir children)
M.worktree_path = nil
M.worktree_info = nil
M.on_complete = nil
M.on_cancel = nil

---@param bytes integer
---@return string
function M.format_size(bytes)
    if bytes < 0 then
        return "0 B"
    elseif bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1048576 then
        return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1073741824 then
        return string.format("%.1f MB", bytes / 1048576)
    else
        return string.format("%.1f GB", bytes / 1073741824)
    end
end

--- Detect large files from the changed files list.
---@param worktree_path string
---@param changed_files string[]
---@param repo_root string
---@return table[] entries Array of {type, path, size, children, expanded, selected}
---@return boolean has_large
---@return integer total_size
function M.detect_large_files(worktree_path, changed_files, repo_root)
    local threshold = config.options.large_files and config.options.large_files.threshold or 1048576
    local large = {}

    for _, filepath in ipairs(changed_files) do
        local wt_file = worktree_path .. "/" .. filepath
        local user_file = repo_root .. "/" .. filepath
        local wt_size = vim.fn.getfsize(wt_file)
        local user_size = vim.fn.getfsize(user_file)
        local max_size = math.max(wt_size or 0, user_size or 0)

        if max_size > threshold then
            table.insert(large, { path = filepath, size = max_size })
        end
    end

    if #large == 0 then
        return {}, false, 0
    end

    -- Group by immediate parent directory
    local dir_files = {}
    for _, f in ipairs(large) do
        local dir = vim.fn.fnamemodify(f.path, ":h")
        if dir == "." then
            dir = nil
        end
        if dir then
            dir_files[dir] = dir_files[dir] or {}
            table.insert(dir_files[dir], f)
        end
    end

    local entries = {}
    local grouped_files = {}
    local total_size = 0

    -- Create directory entries for dirs with 2+ large files
    for dir, files in pairs(dir_files) do
        if #files >= 2 then
            local dir_size = 0
            local children = {}
            for _, f in ipairs(files) do
                dir_size = dir_size + f.size
                grouped_files[f.path] = true
                table.insert(children, {
                    type = "file",
                    path = f.path,
                    size = f.size,
                    selected = false,
                })
            end
            table.sort(children, function(a, b)
                return a.path < b.path
            end)
            total_size = total_size + dir_size
            table.insert(entries, {
                type = "dir",
                path = dir .. "/",
                size = dir_size,
                file_count = #files,
                children = children,
                expanded = true,
                selected = false,
            })
        end
    end

    -- Add remaining ungrouped files as top-level entries
    for _, f in ipairs(large) do
        if not grouped_files[f.path] then
            total_size = total_size + f.size
            table.insert(entries, {
                type = "file",
                path = f.path,
                size = f.size,
                selected = false,
            })
        end
    end

    -- Sort: directories first, then files, alphabetically within each
    table.sort(entries, function(a, b)
        if a.type ~= b.type then
            return a.type == "dir"
        end
        return a.path < b.path
    end)

    return entries, true, total_size
end

--- Build the flat entries list from hierarchical entries for rendering.
function M.build_flat_entries()
    M.flat_entries = {}
    for _, entry in ipairs(M.entries) do
        table.insert(M.flat_entries, entry)
        if entry.type == "dir" and entry.expanded and entry.children then
            for _, child in ipairs(entry.children) do
                table.insert(M.flat_entries, child)
            end
        end
    end
end

--- Toggle selection on an entry. On a directory, toggles all children.
---@param entry table
local function toggle_selection(entry)
    if entry.type == "dir" and entry.children then
        -- If any child is selected, deselect all; otherwise select all
        local any_selected = false
        for _, child in ipairs(entry.children) do
            if child.selected then
                any_selected = true
                break
            end
        end
        local new_state = not any_selected
        entry.selected = new_state
        for _, child in ipairs(entry.children) do
            child.selected = new_state
        end
    else
        entry.selected = not entry.selected
    end
end

--- Sync directory entry selected state based on children.
function M.sync_dir_selections()
    for _, entry in ipairs(M.entries) do
        if entry.type == "dir" and entry.children and #entry.children > 0 then
            local all_selected = true
            local any_selected = false
            for _, child in ipairs(entry.children) do
                if child.selected then
                    any_selected = true
                else
                    all_selected = false
                end
            end
            entry.selected = all_selected or any_selected
        end
    end
end

--- Count how many files are selected (included in review).
---@return integer
function M.count_selected()
    local n = 0
    for _, entry in ipairs(M.entries) do
        if entry.type == "file" and entry.selected then
            n = n + 1
        elseif entry.type == "dir" and entry.children then
            for _, child in ipairs(entry.children) do
                if child.selected then
                    n = n + 1
                end
            end
        end
    end
    return n
end

--- Load previously stored decisions for this worktree.
---@param worktree_path string
---@return table<string, string>
function M.load_decisions(worktree_path)
    local git = require("vibe.git")
    local info = git.worktrees[worktree_path]
    if info and info.large_file_decisions then
        return info.large_file_decisions
    end
    return {}
end

--- Persist decisions to worktree info and sessions.json.
---@param worktree_path string
---@param decisions table<string, string>
function M.save_decisions(worktree_path, decisions)
    local git = require("vibe.git")
    local info = git.worktrees[worktree_path]
    if not info then
        return
    end

    info.large_file_decisions = decisions

    local persisted = persist.load_sessions()
    for _, s in ipairs(persisted) do
        if s.worktree_path == worktree_path then
            s.large_file_decisions = decisions
            break
        end
    end
    persist.save_sessions(persisted)
end

--- Collect decisions from dialog entries into a flat table.
--- Selected = "merge" (include in review), unselected = "ignore" (exclude).
---@return table<string, string>
function M.collect_decisions()
    local decisions = {}
    for _, entry in ipairs(M.entries) do
        if entry.type == "file" then
            decisions[entry.path] = entry.selected and M.MERGE or M.IGNORE
        elseif entry.type == "dir" and entry.children then
            for _, child in ipairs(entry.children) do
                decisions[child.path] = child.selected and M.MERGE or M.IGNORE
            end
        end
    end
    return decisions
end

--- Execute decisions. "ignore" files are excluded downstream.
--- "merge" files proceed to review.
---@param worktree_path string
---@param worktree_info table
---@param decisions table<string, string>
---@return string[] merge_files
function M.execute_decisions(worktree_path, worktree_info, decisions)
    if not decisions or not next(decisions) then
        return {}
    end

    local merge_files = {}
    for filepath, decision in pairs(decisions) do
        if decision == M.MERGE then
            table.insert(merge_files, filepath)
        end
        -- M.IGNORE: no action needed, file excluded downstream via large_file_decisions
    end

    return merge_files
end

--- Check if an entry is a child of a directory (for indentation).
---@param entry table
---@return boolean
local function is_child_entry(entry)
    for _, top_entry in ipairs(M.entries) do
        if top_entry.type == "dir" and top_entry.children then
            for _, child in ipairs(top_entry.children) do
                if child == entry then
                    return true
                end
            end
        end
    end
    return false
end

--- Render the dialog buffer.
function M.render()
    if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
        return
    end

    M.build_flat_entries()

    -- Count totals
    local total_files = 0
    local total_size = 0
    for _, entry in ipairs(M.entries) do
        if entry.type == "file" then
            total_files = total_files + 1
            total_size = total_size + entry.size
        elseif entry.type == "dir" then
            total_files = total_files + (entry.file_count or #entry.children)
            total_size = total_size + entry.size
        end
    end

    local selected_count = M.count_selected()
    local lines = {}
    local hl_data = {} -- {line_idx, hl_group}

    -- Hint bar at top (VibeCopyFiles style)
    table.insert(lines, string.format(
        " %d of %d file(s) included  |  <Space> toggle  |  <CR>/<Esc>/q close",
        selected_count, total_files
    ))
    table.insert(hl_data, { 0, "VibePickerFooter" })
    table.insert(lines, " " .. string.rep("\xe2\x94\x80", 60))
    table.insert(hl_data, { 1, "VibePickerFooter" })
    table.insert(lines, string.format(
        " Large files detected (%s total) \xe2\x80\x94 select files to include in review:",
        M.format_size(total_size)
    ))
    table.insert(hl_data, { 2, "VibePickerHeader" })
    table.insert(lines, "")

    -- 4 lines of header before items
    local items_offset = 4

    for i, entry in ipairs(M.flat_entries) do
        local pointer = i == M.cursor_idx and "\xe2\x96\xb6" or " "
        local check = entry.selected and "\xe2\x9c\x93" or " "

        if entry.type == "dir" then
            local arrow = entry.expanded and "\xe2\x96\xbc" or "\xe2\x96\xb8"
            table.insert(lines, string.format(
                " %s %s %s %s  (%d file%s, %s)",
                pointer, check, arrow, entry.path,
                entry.file_count or #entry.children,
                (entry.file_count or #entry.children) == 1 and "" or "s",
                M.format_size(entry.size)
            ))
        else
            local indent = is_child_entry(entry) and "    " or ""
            local display_name = indent .. (indent ~= "" and vim.fn.fnamemodify(entry.path, ":t") or entry.path)
            table.insert(lines, string.format(
                " %s %s %s  (%s)",
                pointer, check, display_name,
                M.format_size(entry.size)
            ))
        end

        -- Determine highlight
        local line_idx = #lines - 1
        local hl_group
        if i == M.cursor_idx then
            hl_group = "VibeDialogSelected"
        elseif entry.type == "dir" then
            hl_group = "VibePickerDir"
        elseif entry.selected then
            hl_group = "VibePickerSelected"
        else
            hl_group = "VibeLargeFileIgnore"
        end
        table.insert(hl_data, { line_idx, hl_group })
    end

    vim.bo[M.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, lines)
    vim.bo[M.bufnr].modifiable = false

    -- Apply highlights
    for _, hl in ipairs(hl_data) do
        vim.api.nvim_buf_add_highlight(M.bufnr, -1, hl[2], hl[1], 0, -1)
    end

    -- Keep cursor on selected entry
    if M.winid and vim.api.nvim_win_is_valid(M.winid) then
        local cursor_line = M.cursor_idx + items_offset
        if cursor_line > #lines then
            cursor_line = #lines
        end
        pcall(vim.api.nvim_win_set_cursor, M.winid, { cursor_line, 0 })
    end
end

--- Set up keymaps for the dialog.
function M.setup_keymaps()
    local opts = { buffer = M.bufnr, silent = true, noremap = true }

    local function move_down()
        if M.cursor_idx < #M.flat_entries then
            M.cursor_idx = M.cursor_idx + 1
            M.render()
        end
    end

    local function move_up()
        if M.cursor_idx > 1 then
            M.cursor_idx = M.cursor_idx - 1
            M.render()
        end
    end

    vim.keymap.set("n", "j", move_down, opts)
    vim.keymap.set("n", "<Down>", move_down, opts)
    vim.keymap.set("n", "k", move_up, opts)
    vim.keymap.set("n", "<Up>", move_up, opts)

    -- Space: toggle selection and advance cursor (VibeCopyFiles style)
    vim.keymap.set("n", "<Space>", function()
        local entry = M.flat_entries[M.cursor_idx]
        if entry then
            toggle_selection(entry)
            M.sync_dir_selections()
            if M.cursor_idx < #M.flat_entries then
                M.cursor_idx = M.cursor_idx + 1
            end
            M.render()
        end
    end, opts)

    -- Tab: toggle expand/collapse on directory entries
    vim.keymap.set("n", "<Tab>", function()
        local entry = M.flat_entries[M.cursor_idx]
        if entry and entry.type == "dir" then
            entry.expanded = not entry.expanded
            M.build_flat_entries()
            if M.cursor_idx > #M.flat_entries then
                M.cursor_idx = #M.flat_entries
            end
            M.render()
        end
    end, opts)

    -- All close paths save decisions so the dialog doesn't re-appear
    local function confirm_and_close()
        local decisions = M.collect_decisions()
        local on_complete = M.on_complete
        M.close()
        if on_complete then
            on_complete(decisions)
        end
    end

    vim.keymap.set("n", "<CR>", confirm_and_close, opts)
    vim.keymap.set("n", "q", confirm_and_close, opts)
    vim.keymap.set("n", "<Esc>", confirm_and_close, opts)
end

function M.close()
    -- Clear callbacks before closing window to prevent WinClosed autocmd from double-firing
    M.on_complete = nil
    M.on_cancel = nil
    if M.winid and vim.api.nvim_win_is_valid(M.winid) then
        vim.api.nvim_win_close(M.winid, true)
    end
    M.winid = nil
    M.bufnr = nil
    M.cursor_idx = 1
end

--- Show the large file dialog. Calls on_complete(decisions) when user confirms.
--- If no large files detected, calls on_complete({}) immediately (zero overhead).
---@param worktree_path string
---@param worktree_info table
---@param changed_files string[]
---@param on_complete function
---@param on_cancel function|nil
function M.show(worktree_path, worktree_info, changed_files, on_complete, on_cancel)
    local lf_config = config.options.large_files
    if not lf_config or not lf_config.enabled then
        on_complete({})
        return
    end

    local entries, has_large, _ = M.detect_large_files(worktree_path, changed_files, worktree_info.repo_root)
    if not has_large then
        on_complete({})
        return
    end

    -- Apply any previously saved decisions as defaults
    local saved = M.load_decisions(worktree_path)
    if next(saved) then
        for _, entry in ipairs(entries) do
            if entry.type == "file" and saved[entry.path] then
                entry.selected = saved[entry.path] == M.MERGE
            elseif entry.type == "dir" and entry.children then
                for _, child in ipairs(entry.children) do
                    if saved[child.path] then
                        child.selected = saved[child.path] == M.MERGE
                    end
                end
            end
        end
    end

    M.entries = entries
    M.worktree_path = worktree_path
    M.worktree_info = worktree_info
    M.on_complete = on_complete
    M.on_cancel = on_cancel
    M.cursor_idx = 1

    M.build_flat_entries()
    M.sync_dir_selections()

    local target_height = math.min(25, #M.flat_entries + 6)
    local bufnr, winid, _ = util.create_centered_float({
        filetype = "vibe_large_files",
        min_width = 70,
        height = target_height,
        title = "Large Files: " .. (worktree_info.name or "unknown"),
        cursorline = true,
        zindex = 210,
        no_default_keymaps = true,
    })

    M.bufnr = bufnr
    M.winid = winid
    vim.wo[winid].wrap = false

    M.render()
    M.setup_keymaps()

    -- Handle external window close (e.g., :q) — save decisions so the dialog
    -- doesn't keep re-appearing and the workflow chain isn't stuck.
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(winid),
        once = true,
        callback = function()
            if M.on_complete then
                local decisions = M.collect_decisions()
                local on_complete = M.on_complete
                M.on_complete = nil
                M.on_cancel = nil
                M.winid = nil
                M.bufnr = nil
                M.cursor_idx = 1
                vim.schedule(function()
                    on_complete(decisions)
                end)
            end
        end,
    })
end

return M
