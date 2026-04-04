--- Large file detection and handling for :VibeReview
--- Shows a dialog for files above the size threshold, letting users choose:
---   ignore (default) / copy over / merge
--- before any heavy processing occurs.
local config = require("vibe.config")
local util = require("vibe.util")
local persist = require("vibe.persist")

local M = {}

-- Decision constants
M.IGNORE = "ignore"
M.COPY_OVER = "copy_over"
M.MERGE = "merge"

-- Cycle order for Space key
M.CYCLE = { M.IGNORE, M.COPY_OVER, M.MERGE }

-- Display labels for each decision
M.LABELS = {
    [M.IGNORE] = "ignore",
    [M.COPY_OVER] = "copy over",
    [M.MERGE] = "merge",
}

-- Highlight groups for each decision
M.HIGHLIGHTS = {
    [M.IGNORE] = "VibeLargeFileIgnore",
    [M.COPY_OVER] = "VibeLargeFileCopyOver",
    [M.MERGE] = "VibeLargeFileMerge",
}

-- Dialog state
M.bufnr = nil
M.winid = nil
M.cursor_idx = 1
M.entries = {}
M.flat_entries = {}
M.worktree_path = nil
M.worktree_info = nil
M.on_complete = nil

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
---@return table[] entries Array of {type, path, size, children, expanded, decision}
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
                    decision = M.IGNORE,
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
                decision = M.IGNORE,
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
                decision = M.IGNORE,
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

--- Cycle the decision for an entry. On a directory, applies to all children.
---@param entry table
local function cycle_decision(entry)
    local current = entry.decision or M.IGNORE
    local next_idx = 1
    for i, v in ipairs(M.CYCLE) do
        if v == current then
            next_idx = (i % #M.CYCLE) + 1
            break
        end
    end
    entry.decision = M.CYCLE[next_idx]

    if entry.type == "dir" and entry.children then
        for _, child in ipairs(entry.children) do
            child.decision = entry.decision
        end
    end
end

--- Set a specific decision on an entry.
---@param entry table
---@param decision string
local function set_decision(entry, decision)
    entry.decision = decision
    if entry.type == "dir" and entry.children then
        for _, child in ipairs(entry.children) do
            child.decision = decision
        end
    end
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
---@return table<string, string>
function M.collect_decisions()
    local decisions = {}
    for _, entry in ipairs(M.entries) do
        if entry.type == "file" then
            decisions[entry.path] = entry.decision
        elseif entry.type == "dir" and entry.children then
            for _, child in ipairs(entry.children) do
                decisions[child.path] = child.decision
            end
        end
    end
    return decisions
end

--- Execute "copy over" and "ignore" actions. Returns files remaining for merge.
---@param worktree_path string
---@param worktree_info table
---@param decisions table<string, string>
---@return string[] merge_files
function M.execute_decisions(worktree_path, worktree_info, decisions)
    if not decisions or not next(decisions) then
        return {}
    end

    local repo_root = worktree_info.repo_root
    local merge_files = {}

    for filepath, decision in pairs(decisions) do
        if decision == M.COPY_OVER then
            local src = worktree_path .. "/" .. filepath
            local dst = repo_root .. "/" .. filepath
            local dst_dir = vim.fn.fnamemodify(dst, ":h")
            if vim.fn.isdirectory(dst_dir) == 0 then
                vim.fn.mkdir(dst_dir, "p")
            end
            -- Use system cp to avoid loading large files into Lua memory
            if vim.fn.filereadable(src) == 1 then
                vim.fn.system({ "cp", "--", src, dst })
                local bufnr = vim.fn.bufnr(dst)
                if bufnr ~= -1 then
                    vim.cmd("checktime " .. bufnr)
                end
            end
        elseif decision == M.MERGE then
            table.insert(merge_files, filepath)
        end
        -- M.IGNORE: no action needed, file excluded downstream via large_file_decisions
    end

    return merge_files
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

    local lines = {}
    table.insert(lines, string.format(
        " Large Files Detected (%d file%s, %s)",
        total_files,
        total_files == 1 and "" or "s",
        M.format_size(total_size)
    ))
    table.insert(lines, " " .. string.rep("\xe2\x94\x80", 54))

    for i, entry in ipairs(M.flat_entries) do
        local is_selected = i == M.cursor_idx
        local pointer = is_selected and "\xe2\x96\xb6 " or "  "
        local label = M.LABELS[entry.decision] or "ignore"
        local badge = string.format("[%s]", label)

        if entry.type == "dir" then
            local arrow = entry.expanded and "\xe2\x96\xbc" or "\xe2\x96\xb8"
            table.insert(lines, string.format(
                " %s%-12s %s %s  (%d file%s, %s)",
                pointer,
                badge,
                arrow,
                entry.path,
                entry.file_count or #entry.children,
                (entry.file_count or #entry.children) == 1 and "" or "s",
                M.format_size(entry.size)
            ))
        else
            -- Check if this is a child of a directory (indented)
            local indent = ""
            for _, top_entry in ipairs(M.entries) do
                if top_entry.type == "dir" and top_entry.children then
                    for _, child in ipairs(top_entry.children) do
                        if child == entry then
                            indent = "  "
                            break
                        end
                    end
                end
            end
            local display_name = indent .. vim.fn.fnamemodify(entry.path, ":t")
            if indent == "" then
                display_name = entry.path
            end
            table.insert(lines, string.format(
                " %s%-12s %s  (%s)",
                pointer,
                badge,
                display_name,
                M.format_size(entry.size)
            ))
        end
    end

    table.insert(lines, "")
    table.insert(lines, " " .. string.rep("\xe2\x94\x80", 54))
    table.insert(lines, " <Space> cycle  |  <Tab> expand  |  <CR> confirm  |  q cancel")

    vim.bo[M.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, lines)
    vim.bo[M.bufnr].modifiable = false

    -- Apply highlights
    local ns = vim.api.nvim_create_namespace("vibe_large_files")
    vim.api.nvim_buf_clear_namespace(M.bufnr, ns, 0, -1)

    -- Header
    vim.api.nvim_buf_add_highlight(M.bufnr, ns, "Title", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(M.bufnr, ns, "Comment", 1, 0, -1)

    -- Entries (starting at line 2)
    for i, entry in ipairs(M.flat_entries) do
        local line_idx = i + 1
        if i == M.cursor_idx then
            vim.api.nvim_buf_add_highlight(M.bufnr, ns, "VibeDialogSelected", line_idx, 0, -1)
        else
            local hl = M.HIGHLIGHTS[entry.decision] or "VibeLargeFileIgnore"
            if entry.type == "dir" then
                vim.api.nvim_buf_add_highlight(M.bufnr, ns, "VibeLargeFileDir", line_idx, 0, -1)
            else
                vim.api.nvim_buf_add_highlight(M.bufnr, ns, hl, line_idx, 0, -1)
            end
        end
    end

    -- Footer
    local footer_start = #M.flat_entries + 3
    if footer_start < #lines then
        vim.api.nvim_buf_add_highlight(M.bufnr, ns, "Comment", footer_start, 0, -1)
        if footer_start + 1 < #lines then
            vim.api.nvim_buf_add_highlight(M.bufnr, ns, "VibeDialogFooter", footer_start + 1, 0, -1)
        end
    end

    -- Keep cursor on selected entry
    if M.winid and vim.api.nvim_win_is_valid(M.winid) then
        vim.api.nvim_win_set_cursor(M.winid, { M.cursor_idx + 2, 0 })
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

    -- Space: cycle decision
    vim.keymap.set("n", "<Space>", function()
        local entry = M.flat_entries[M.cursor_idx]
        if entry then
            cycle_decision(entry)
            -- If child changed, sync parent dir decision if all children match
            M.sync_dir_decisions()
            M.render()
        end
    end, opts)

    -- Tab: toggle expand/collapse on directory entries
    vim.keymap.set("n", "<Tab>", function()
        local entry = M.flat_entries[M.cursor_idx]
        if entry and entry.type == "dir" then
            entry.expanded = not entry.expanded
            M.build_flat_entries()
            -- Clamp cursor
            if M.cursor_idx > #M.flat_entries then
                M.cursor_idx = #M.flat_entries
            end
            M.render()
        end
    end, opts)

    -- Direct decision shortcuts
    vim.keymap.set("n", "i", function()
        local entry = M.flat_entries[M.cursor_idx]
        if entry then
            set_decision(entry, M.IGNORE)
            M.sync_dir_decisions()
            M.render()
        end
    end, opts)

    vim.keymap.set("n", "c", function()
        local entry = M.flat_entries[M.cursor_idx]
        if entry then
            set_decision(entry, M.COPY_OVER)
            M.sync_dir_decisions()
            M.render()
        end
    end, opts)

    vim.keymap.set("n", "m", function()
        local entry = M.flat_entries[M.cursor_idx]
        if entry then
            set_decision(entry, M.MERGE)
            M.sync_dir_decisions()
            M.render()
        end
    end, opts)

    -- Enter: confirm
    vim.keymap.set("n", "<CR>", function()
        local decisions = M.collect_decisions()
        local on_complete = M.on_complete
        M.close()
        if on_complete then
            on_complete(decisions)
        end
    end, opts)

    -- Cancel
    local function cancel()
        local on_cancel = M.on_cancel
        M.close()
        if on_cancel then
            on_cancel()
        end
    end
    vim.keymap.set("n", "q", cancel, opts)
    vim.keymap.set("n", "<Esc>", cancel, opts)
end

--- Sync directory entry decisions based on children (if all children match, dir matches).
function M.sync_dir_decisions()
    for _, entry in ipairs(M.entries) do
        if entry.type == "dir" and entry.children and #entry.children > 0 then
            local first = entry.children[1].decision
            local all_same = true
            for _, child in ipairs(entry.children) do
                if child.decision ~= first then
                    all_same = false
                    break
                end
            end
            if all_same then
                entry.decision = first
            end
        end
    end
end

function M.close()
    if M.winid and vim.api.nvim_win_is_valid(M.winid) then
        vim.api.nvim_win_close(M.winid, true)
    end
    M.winid = nil
    M.bufnr = nil
    M.cursor_idx = 1
    M.on_complete = nil
    M.on_cancel = nil
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
                entry.decision = saved[entry.path]
            elseif entry.type == "dir" and entry.children then
                for _, child in ipairs(entry.children) do
                    if saved[child.path] then
                        child.decision = saved[child.path]
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

    -- Sync dir decisions from loaded children
    M.sync_dir_decisions()

    local target_height = math.min(25, #M.flat_entries + 6)
    local bufnr, winid, _ = util.create_centered_float({
        filetype = "vibe_large_files",
        min_width = 70,
        height = target_height,
        title = "Vibe: Large Files",
        cursorline = true,
        zindex = 210,
        no_default_keymaps = true,
    })

    M.bufnr = bufnr
    M.winid = winid
    vim.wo[winid].wrap = false

    M.render()
    M.setup_keymaps()
end

return M
