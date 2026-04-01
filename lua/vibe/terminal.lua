local config = require("vibe.config")
local status = require("vibe.status")
local git = require("vibe.git")
local persist = require("vibe.persist")
local loading = require("vibe.loading")

local M = {}

--- Set of session names currently being created (guard against double-creation)
---@type table<string, boolean>
M.creating = {}

--- Dump terminal scrollback to a log file
---@param session_bufnr integer
---@param session_name string
local function dump_scrollback_log(session_bufnr, session_name)
    local log_config = config.options.log or {}
    if log_config.enabled == false then
        return
    end
    if not session_bufnr or not vim.api.nvim_buf_is_valid(session_bufnr) then
        return
    end

    local log_dir = vim.fn.stdpath("data") .. "/vibe-logs"
    vim.fn.mkdir(log_dir, "p")

    local ok, lines = pcall(vim.api.nvim_buf_get_lines, session_bufnr, 0, -1, false)
    if not ok or #lines == 0 then
        return
    end

    -- Cleanup: enforce max_files and max_size
    local max_files = log_config.max_files or 20
    local max_size_bytes = (log_config.max_size_mb or 50) * 1024 * 1024
    local existing = vim.fn.glob(log_dir .. "/*.log", false, true)
    table.sort(existing)

    -- Delete oldest files if over limit
    while #existing >= max_files do
        vim.fn.delete(existing[1])
        table.remove(existing, 1)
    end

    -- Check total size
    local total_size = 0
    for _, f in ipairs(existing) do
        total_size = total_size + vim.fn.getfsize(f)
    end
    while total_size > max_size_bytes and #existing > 0 do
        total_size = total_size - vim.fn.getfsize(existing[1])
        vim.fn.delete(existing[1])
        table.remove(existing, 1)
    end

    local safe_name = session_name:gsub("[^%w_-]", "_")
    local filename = string.format("%s/%s_%d.log", log_dir, safe_name, os.time())
    vim.fn.writefile(lines, filename)
    return filename
end

--- Dump scrollback for a named session (public wrapper)
---@param session_name string
---@return string|nil log_path
function M.dump_scrollback_log(session_name)
    local session = M.sessions[session_name]
    if not session or not session.bufnr then
        return nil
    end
    return dump_scrollback_log(session.bufnr, session_name)
end

---@class TerminalSession
---@field bufnr integer
---@field job_id integer
---@field winid integer|nil
---@field cwd string Original working directory (user's repo)
---@field worktree_path string|nil Path to the worktree for this session
---@field name string Session name
---@field created_at number|nil Unix timestamp when session was created
---@field is_resumed boolean|nil Whether this session was resumed from persistence

---@type table<string, TerminalSession>
M.sessions = {}

---@type string
M.current_session = nil

--- Save all modified buffers
local function save_buffers()
    local opts = config.options
    if opts.on_open == "none" then
        return
    end
    if opts.on_open == "save_current" then
        if vim.bo.modified then
            vim.cmd("write")
        end
    else
        vim.cmd("wall")
    end
end

--- Reload buffers from disk
local function reload_buffers()
    if config.options.on_close == "none" then
        return
    end
    vim.cmd("checktime")
end

--- Auto-scroll: track pending scheduled scrolls per buffer
local scroll_pending = {}

--- Attach an on_lines listener that scrolls the terminal window to the bottom
--- whenever new output arrives and the user is NOT focused on that window.
---@param bufnr integer
local function setup_auto_scroll(bufnr)
    if config.options.auto_scroll == false then
        return
    end

    vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = function(_, buf)
            if not vim.api.nvim_buf_is_valid(buf) then
                scroll_pending[buf] = nil
                return true -- detach
            end

            if scroll_pending[buf] then
                return
            end
            scroll_pending[buf] = true

            vim.schedule(function()
                scroll_pending[buf] = nil

                -- Find the session for this buffer
                local session
                for _, s in pairs(M.sessions) do
                    if s.bufnr == buf then
                        session = s
                        break
                    end
                end
                if not session then return end

                -- Only scroll if window exists and user is NOT in it
                local winid = session.winid
                if not winid or not vim.api.nvim_win_is_valid(winid) then
                    return
                end
                if vim.api.nvim_get_current_win() == winid then
                    return
                end

                -- Scroll to bottom
                local line_count = vim.api.nvim_buf_line_count(buf)
                vim.api.nvim_win_set_cursor(winid, { line_count, 0 })
            end)
        end,
    })
end

--- Create the terminal buffer and session object from a worktree_info (shared by get_or_create and resume)
---@param name string
---@param cwd string
---@param worktree_info table
---@return TerminalSession|nil
local function finalize_session(name, cwd, worktree_info)
    save_buffers()

    local bufnr = vim.api.nvim_create_buf(false, false)
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].filetype = "vibe"

    local job_id
    vim.api.nvim_buf_call(bufnr, function()
        job_id = vim.fn.termopen(config.options.command, {
            cwd = worktree_info.worktree_path,
            on_exit = function(_, exit_code)
                -- Resolve current name by bufnr (handles rename)
                local current_name = name
                for sname, sess in pairs(M.sessions) do
                    if sess.bufnr == bufnr then
                        current_name = sname
                        break
                    end
                end
                local log_path = dump_scrollback_log(bufnr, current_name)
                if exit_code ~= 0 then
                    vim.notify(string.format("[Vibe] Command exited with code %d", exit_code), vim.log.levels.WARN)
                end
                if M.sessions[current_name] then
                    M.sessions[current_name] = nil
                    status.hide()
                    persist.save_session({
                        name = current_name,
                        worktree_path = worktree_info.worktree_path,
                        branch = worktree_info.branch,
                        snapshot_commit = worktree_info.snapshot_commit,
                        original_branch = worktree_info.original_branch,
                        repo_root = worktree_info.repo_root,
                        cwd = cwd,
                        created_at = worktree_info.created_at,
                        last_active = os.time(),
                        has_terminal = false,
                        log_path = log_path,
                        source_worktrees = worktree_info.source_worktrees,
                    })
                    -- Refresh grid if active
                    if config.options.enable_agent_grid then
                        vim.schedule(function()
                            local grid = require("vibe.grid")
                            if grid.state.visible then
                                if vim.tbl_count(M.sessions) > 0 then
                                    grid.refresh()
                                else
                                    grid.hide_all()
                                end
                            end
                        end)
                    end
                end
            end,
        })
    end)

    if job_id <= 0 then
        vim.api.nvim_buf_delete(bufnr, { force = true })
        vim.notify("[Vibe] Failed to start command: " .. config.options.command, vim.log.levels.ERROR)
        git.remove_worktree(worktree_info.worktree_path)
        return nil
    end

    local session = {
        bufnr = bufnr,
        job_id = job_id,
        winid = nil,
        cwd = cwd,
        worktree_path = worktree_info.worktree_path,
        name = name,
        created_at = worktree_info.created_at,
        is_resumed = false,
    }

    M.sessions[name] = session
    M.current_session = name
    setup_auto_scroll(bufnr)

    status.show()
    return session
end

--- Get or create a session asynchronously
---@param name string|nil
---@param cwd string|nil Working directory for the session (user's repo)
---@param callback function Called with (session) — nil on failure
function M.get_or_create(name, cwd, callback)
    name = name or "default"

    if M.sessions[name] and vim.api.nvim_buf_is_valid(M.sessions[name].bufnr) then
        callback(M.sessions[name])
        return
    end

    if M.creating[name] then
        vim.notify("[Vibe] Already creating session '" .. name .. "'...", vim.log.levels.WARN)
        return
    end

    cwd = cwd or vim.fn.getcwd()
    M.creating[name] = true
    loading.show(name, function()
        M.cancel_creation(name)
    end)

    git.create_worktree_async(name, cwd, function(worktree_info, err)
        loading.hide()
        M.creating[name] = nil

        if not worktree_info then
            vim.notify("[Vibe] Failed to create worktree: " .. (err or "unknown error"), vim.log.levels.ERROR)
            callback(nil)
            return
        end

        local session = finalize_session(name, cwd, worktree_info)
        callback(session)
    end)
end

---@param name string|nil
---@param cwd string|nil Working directory (only used for new sessions)
function M.show(name, cwd)
    name = name or "default"

    -- Check if agent grid is active
    local grid = config.options.enable_agent_grid and require("vibe.grid") or nil

    -- If session already exists, show it immediately
    local existing = M.sessions[name]
    if existing and vim.api.nvim_buf_is_valid(existing.bufnr) then
        save_buffers()
        if grid and grid.state.visible then
            grid.refresh()
            grid.focus_or_navigate(name)
        else
            local window = require("vibe.window")
            existing.winid = window.create(existing.bufnr, name)
            vim.cmd("startinsert")
        end
        M.current_session = name
        return
    end

    -- Otherwise create async and show on completion
    M.get_or_create(name, cwd, function(session)
        if not session then
            return
        end
        save_buffers()
        if grid and grid.state.visible then
            grid.refresh()
            grid.focus_or_navigate(name)
        else
            local window = require("vibe.window")
            session.winid = window.create(session.bufnr, name)
            vim.cmd("startinsert")
        end
        M.current_session = name
    end)
end

---@param name string|nil
function M.hide(name)
    name = name or M.current_session or "default"

    -- In grid mode, hide the entire grid
    if config.options.enable_agent_grid then
        local grid = require("vibe.grid")
        if grid.state.visible then
            grid.hide_all()
            return
        end
    end

    local session = M.sessions[name]

    if session and session.winid then
        if vim.api.nvim_win_is_valid(session.winid) then
            vim.api.nvim_win_close(session.winid, false)
        end
        session.winid = nil
    end

    reload_buffers()
end

function M.on_window_closed()
    -- In grid mode, the grid's own WinClosed handler takes care of this
    if config.options.enable_agent_grid then
        local grid = require("vibe.grid")
        if grid.state.visible then
            return
        end
    end

    local name = M.current_session
    if name and M.sessions[name] then
        M.sessions[name].winid = nil
    end
    reload_buffers()
end

---@param name string|nil
---@param cwd string|nil Working directory (only used for new sessions)
function M.toggle(name, cwd)
    name = name or "default"
    local session = M.sessions[name]
    if session and session.winid and vim.api.nvim_win_is_valid(session.winid) then
        M.hide(name)
    else
        M.show(name, cwd)
    end
end

---@param name string|nil
function M.kill(name)
    name = name or M.current_session or "default"
    local session = M.sessions[name]

    if session then
        if session.winid and vim.api.nvim_win_is_valid(session.winid) then
            vim.api.nvim_win_close(session.winid, true)
        end
        -- Dump scrollback BEFORE stopping job/deleting buffer to avoid race condition
        -- (on_exit fires async after jobstop, but buf_delete may invalidate buffer first)
        if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
            dump_scrollback_log(session.bufnr, name)
        end
        if session.job_id then
            vim.fn.jobstop(session.job_id)
        end
        if vim.api.nvim_buf_is_valid(session.bufnr) then
            vim.api.nvim_buf_delete(session.bufnr, { force = true })
        end
        if session.worktree_path then
            -- Record history before removing worktree
            local history_ok, history = pcall(require, "vibe.history")
            if history_ok then
                local files = {}
                pcall(function()
                    files = git.get_worktree_changed_files(session.worktree_path)
                end)
                history.record({
                    name = name,
                    worktree_path = session.worktree_path,
                    repo_root = session.cwd,
                    files_changed = #files,
                })
            end
            git.remove_worktree(session.worktree_path)
        end

        M.sessions[name] = nil
        if M.current_session == name then
            M.current_session = nil
        end

        -- Refresh or hide grid if active
        if config.options.enable_agent_grid then
            local grid = require("vibe.grid")
            if grid.state.visible then
                if vim.tbl_count(M.sessions) > 0 then
                    vim.schedule(function()
                        grid.refresh()
                    end)
                else
                    vim.schedule(function()
                        grid.hide_all()
                    end)
                end
            end
        end

        status.hide()
    end
end

--- Resume a session from persistence
---@param persisted_session PersistedSession
---@return TerminalSession|nil
function M.resume(persisted_session)
    if not persisted_session or not persisted_session.worktree_path then
        return nil
    end

    if vim.fn.isdirectory(persisted_session.worktree_path) ~= 1 then
        persist.remove_session(persisted_session.worktree_path)
        return nil
    end

    local name = persisted_session.name

    if M.sessions[name] and vim.api.nvim_buf_is_valid(M.sessions[name].bufnr) then
        return M.sessions[name]
    end

    if not git.worktrees[persisted_session.worktree_path] then
        git.worktrees[persisted_session.worktree_path] = {
            name = persisted_session.name,
            worktree_path = persisted_session.worktree_path,
            branch = persisted_session.branch,
            snapshot_commit = persisted_session.snapshot_commit,
            original_branch = persisted_session.original_branch,
            repo_root = persisted_session.repo_root,
            uuid = persisted_session.worktree_path:match("([^/]+)$"),
            created_at = persisted_session.created_at,
            addressed_hunks = persisted_session.addressed_hunks or {},
            manually_modified_files = persisted_session.manually_modified_files or {},
            source_worktrees = persisted_session.source_worktrees or nil,
        }
    end

    save_buffers()

    local bufnr = vim.api.nvim_create_buf(false, false)
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].filetype = "vibe"

    local job_id
    vim.api.nvim_buf_call(bufnr, function()
        job_id = vim.fn.termopen(config.options.command, {
            cwd = persisted_session.worktree_path,
            on_exit = function(_, exit_code)
                -- Resolve current name by bufnr (handles rename)
                local current_name = name
                for sname, sess in pairs(M.sessions) do
                    if sess.bufnr == bufnr then
                        current_name = sname
                        break
                    end
                end
                local log_path = dump_scrollback_log(bufnr, current_name)
                if exit_code ~= 0 then
                    vim.notify(string.format("[Vibe] Command exited with code %d", exit_code), vim.log.levels.WARN)
                end
                if M.sessions[current_name] then
                    M.sessions[current_name] = nil
                    status.hide()
                    persist.save_session({
                        name = current_name,
                        worktree_path = persisted_session.worktree_path,
                        branch = persisted_session.branch,
                        snapshot_commit = persisted_session.snapshot_commit,
                        original_branch = persisted_session.original_branch,
                        repo_root = persisted_session.repo_root,
                        cwd = persisted_session.cwd,
                        created_at = persisted_session.created_at,
                        last_active = os.time(),
                        has_terminal = false,
                        log_path = log_path,
                        source_worktrees = persisted_session.source_worktrees,
                    })
                    -- Refresh grid if active
                    if config.options.enable_agent_grid then
                        vim.schedule(function()
                            local grid = require("vibe.grid")
                            if grid.state.visible then
                                if vim.tbl_count(M.sessions) > 0 then
                                    grid.refresh()
                                else
                                    grid.hide_all()
                                end
                            end
                        end)
                    end
                end
            end,
        })
    end)

    if job_id <= 0 then
        vim.api.nvim_buf_delete(bufnr, { force = true })
        return nil
    end

    local session = {
        bufnr = bufnr,
        job_id = job_id,
        winid = nil,
        cwd = persisted_session.cwd,
        worktree_path = persisted_session.worktree_path,
        name = name,
        created_at = persisted_session.created_at,
        is_resumed = true,
    }

    M.sessions[name] = session
    M.current_session = name
    setup_auto_scroll(bufnr)

    persist.save_session(vim.tbl_extend("force", persisted_session, { has_terminal = true }))

    status.show()
    return session
end

function M.get_session(name)
    return M.sessions[name]
end

--- Rename a session, updating all state locations
---@param old_name string
---@param new_name string
---@return boolean ok
---@return string|nil err
function M.rename(old_name, new_name)
    local sess = M.sessions[old_name]
    if not sess then
        return false, "Session '" .. old_name .. "' not found"
    end
    if M.sessions[new_name] then
        return false, "Session '" .. new_name .. "' already exists"
    end

    -- 1. Move session in table
    M.sessions[new_name] = sess
    M.sessions[old_name] = nil

    -- 2. Update name field
    sess.name = new_name

    -- 3. Update current_session
    if M.current_session == old_name then
        M.current_session = new_name
    end

    -- 4. Update git worktree metadata
    if sess.worktree_path and git.worktrees[sess.worktree_path] then
        git.worktrees[sess.worktree_path].name = new_name
    end

    -- 5. Persist to disk
    if sess.worktree_path then
        local wt = git.worktrees[sess.worktree_path]
        if wt then
            persist.save_session({
                name = new_name,
                worktree_path = sess.worktree_path,
                branch = wt.branch,
                snapshot_commit = wt.snapshot_commit,
                original_branch = wt.original_branch,
                repo_root = wt.repo_root,
                cwd = sess.cwd,
                created_at = sess.created_at or wt.created_at,
                last_active = os.time(),
                has_terminal = true,
                source_worktrees = wt.source_worktrees,
            })
        end
    end

    -- 6. Migrate status activity tracking
    if status.last_activity[old_name] then
        status.last_activity[new_name] = status.last_activity[old_name]
        status.last_activity[old_name] = nil
    end

    -- 7. Update window title
    if sess.winid and vim.api.nvim_win_is_valid(sess.winid) then
        local win_cfg = vim.api.nvim_win_get_config(sess.winid)
        if win_cfg.relative and win_cfg.relative ~= "" then
            pcall(vim.api.nvim_win_set_config, sess.winid, {
                title = " Vibe: " .. new_name .. " ",
                title_pos = "center",
            })
        else
            vim.wo[sess.winid].winbar = " Vibe: " .. new_name .. " "
        end
    end

    -- 8. Update grid state if visible
    if config.options.enable_agent_grid then
        local ok, grid = pcall(require, "vibe.grid")
        if ok and grid.state and grid.state.visible then
            if grid.state.maximized_session == old_name then
                grid.state.maximized_session = new_name
            end
            for _, entry in ipairs(grid.state.window_ids or {}) do
                if entry.name == old_name then
                    entry.name = new_name
                    if vim.api.nvim_win_is_valid(entry.winid) then
                        local gcfg = vim.api.nvim_win_get_config(entry.winid)
                        if gcfg.relative and gcfg.relative ~= "" then
                            pcall(vim.api.nvim_win_set_config, entry.winid, {
                                title = " Vibe: " .. new_name .. " ",
                                title_pos = "center",
                            })
                        else
                            vim.wo[entry.winid].winbar = " Vibe: " .. new_name .. " "
                        end
                    end
                    break
                end
            end
        end
    end

    return true, nil
end

--- Cancel a pending worktree creation
---@param name string
function M.cancel_creation(name)
    loading.hide()
    M.creating[name] = nil
    git.cancel_creation(name)
    vim.notify("[Vibe] Cancelled creation of session '" .. name .. "'", vim.log.levels.INFO)
end

--- Cancel all pending worktree creations
function M.cancel_all_creations()
    local names = {}
    for name, _ in pairs(M.creating) do
        table.insert(names, name)
    end
    for _, name in ipairs(names) do
        loading.hide()
        M.creating[name] = nil
    end
    git.cancel_all_creations()
end

return M
