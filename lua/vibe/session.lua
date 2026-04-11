local terminal = require("vibe.terminal")
local status = require("vibe.status")
local git = require("vibe.git")
local config = require("vibe.config")
local persist = require("vibe.persist")
local util = require("vibe.util")

local M = {}

-- Originating buffer/window captured when :VibeReview is invoked.
-- Restored once all changes are reviewed (natural completion only).
M._return_buf = nil
M._return_win = nil

function M.capture_return_location()
    M._return_buf = vim.api.nvim_get_current_buf()
    M._return_win = vim.api.nvim_get_current_win()
end

function M.restore_return_location()
    local buf = M._return_buf
    local win = M._return_win
    M._return_buf = nil
    M._return_win = nil
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        if vim.api.nvim_win_get_buf(win) ~= buf then
            vim.api.nvim_win_set_buf(win, buf)
        end
    else
        -- Originating window is gone — fall back to editing the buffer in the current window.
        vim.api.nvim_set_current_buf(buf)
    end
end

-- Named constants for list layout calculations.
-- Headers are: hint bar + separator + title + separator (4 lines) before items.
local LIST_HEADER_LINES = 4
local LIST_LINES_PER_SESSION = 2 -- Name line + detail line
local RESUME_LINES_PER_SESSION = 3 -- Name line + created line + path line
local KILL_HEADER_LINES = 4
local KILL_LINES_PER_SESSION = 1 -- Single line per session
local BROWSE_HEADER_LINES = 6 -- hint + separator + title + separator + path + separator
local BROWSE_LINES_PER_DIR = 1 -- One line per directory
local SYNC_HEADER_LINES = 4
local SYNC_LINES_PER_SESSION = 2 -- Name line + path line

function M.list()
    local sessions = {}
    for name, session in pairs(terminal.sessions) do
        table.insert(sessions, {
            name = name,
            is_current = name == terminal.current_session,
            is_open = session.winid and vim.api.nvim_win_is_valid(session.winid) or false,
            is_alive = session.job_id and (pcall(vim.fn.jobpid, session.job_id)) or false,
            is_active = status.is_recently_active(name),
            job_id = session.job_id,
            bufnr = session.bufnr,
            cwd = session.cwd or vim.fn.getcwd(),
        })
    end

    table.sort(sessions, function(a, b)
        if a.is_current then
            return true
        end
        if b.is_current then
            return false
        end
        return a.name < b.name
    end)

    return sessions
end

function M.show_list()
    local sessions = M.list()
    local lines = {}
    if #sessions == 0 then
        table.insert(lines, " No active sessions")
        table.insert(lines, "")
        table.insert(lines, " Press <leader>v or :Vibe to start a session")
    else
        table.insert(lines, " <CR> open n new d kill q close")
        table.insert(lines, " " .. string.rep("─", 50))
        table.insert(lines, " Vibe Sessions")
        table.insert(lines, " " .. string.rep("─", 50))
        for _, info in ipairs(sessions) do
            local icon = info.is_active and "◉" or (info.is_alive and "○" or "✗")
            local flags = {}
            if info.is_current then
                table.insert(flags, "current")
            end
            if info.is_open then
                table.insert(flags, "open")
            end
            if not info.is_alive then
                table.insert(flags, "dead")
            end
            local flag_str = #flags > 0 and (" [" .. table.concat(flags, ", ") .. "]") or ""
            table.insert(lines, string.format(" %s %s%s", icon, info.name, flag_str))
            table.insert(lines, string.format(" %s", vim.fn.pathshorten(info.cwd)))
        end
    end

    local bufnr, winid, close = util.create_centered_float({ lines = lines, filetype = "vibelist", min_width = 40 })

    local first_session_line = LIST_HEADER_LINES + 1
    if #sessions > 0 then
        vim.api.nvim_win_set_cursor(winid, { first_session_line, 2 })
    end
    if #sessions > 0 then
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 0, 0, -1)
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 1, 0, -1)
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 2, 0, -1)
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 3, 0, -1)
    else
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 0, 0, -1)
    end

    for i, session in ipairs(sessions) do
        local line_num = LIST_HEADER_LINES + (i - 1) * LIST_LINES_PER_SESSION + 1
        if session.is_active then
            vim.api.nvim_buf_add_highlight(bufnr, -1, "VibeActive", line_num - 1, 0, 5)
        end
    end

    local function get_session_at_cursor()
        local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
        if cursor_line < first_session_line then
            return nil, nil
        end
        local session_idx = math.floor((cursor_line - first_session_line) / LIST_LINES_PER_SESSION) + 1
        if session_idx >= 1 and session_idx <= #sessions then
            return sessions[session_idx], session_idx
        end
        return nil, nil
    end

    vim.keymap.set("n", "<CR>", function()
        local session = get_session_at_cursor()
        if session then
            close()
            terminal.show(session.name)
        end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "d", function()
        local session = get_session_at_cursor()
        if session then
            terminal.kill(session.name)
            close()
            M.show_list()
        end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "n", function()
        close()
        M.pick_directory(function(cwd)
            local default_name = vim.fn.fnamemodify(cwd, ":t")
            if default_name == "" then
                default_name = "root"
            end
            M.prompt_session_name(default_name, function(name)
                terminal.toggle(name, cwd)
            end)
        end)
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "j", function()
        local _, idx = get_session_at_cursor()
        if idx and idx < #sessions then
            vim.api.nvim_win_set_cursor(winid, { first_session_line + idx * LIST_LINES_PER_SESSION, 2 })
        end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "<Down>", function()
        local _, idx = get_session_at_cursor()
        if idx and idx < #sessions then
            vim.api.nvim_win_set_cursor(winid, { first_session_line + idx * LIST_LINES_PER_SESSION, 2 })
        end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "k", function()
        local _, idx = get_session_at_cursor()
        if idx and idx > 1 then
            vim.api.nvim_win_set_cursor(winid, { first_session_line + (idx - 2) * LIST_LINES_PER_SESSION, 2 })
        end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "<Up>", function()
        local _, idx = get_session_at_cursor()
        if idx and idx > 1 then
            vim.api.nvim_win_set_cursor(winid, { first_session_line + (idx - 2) * LIST_LINES_PER_SESSION, 2 })
        end
    end, { buffer = bufnr, silent = true })
end

function M.show_kill_list()
    local sessions = M.list()
    if #sessions == 0 then
        vim.notify("[Vibe] No active sessions to kill", vim.log.levels.INFO)
        return
    end

    local lines = {
        " <CR> kill q cancel",
        " " .. string.rep("─", 30),
        " Kill Vibe Session",
        " " .. string.rep("─", 30),
    }
    for _, info in ipairs(sessions) do
        local icon = info.is_active and "◉" or (info.is_alive and "○" or "✗")
        table.insert(lines, string.format(" %s %s", icon, info.name))
    end

    local bufnr, winid, close = util.create_centered_float({ lines = lines, filetype = "vibekill", min_width = 40 })

    local kill_first_line = KILL_HEADER_LINES + 1
    vim.api.nvim_win_set_cursor(winid, { kill_first_line, 2 })
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 1, 0, -1)
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 2, 0, -1)
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 3, 0, -1)

    local function get_session_at_cursor()
        local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
        local session_idx = cursor_line - KILL_HEADER_LINES
        if session_idx >= 1 and session_idx <= #sessions then
            return sessions[session_idx], session_idx
        end
        return nil, nil
    end

    vim.keymap.set("n", "<CR>", function()
        local session = get_session_at_cursor()
        if session then
            terminal.kill(session.name)
            close()
        end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "j", function()
        local _, idx = get_session_at_cursor()
        if idx and idx < #sessions then
            vim.api.nvim_win_set_cursor(winid, { KILL_HEADER_LINES + idx + 1, 2 })
        end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "<Down>", function()
        local _, idx = get_session_at_cursor()
        if idx and idx < #sessions then
            vim.api.nvim_win_set_cursor(winid, { KILL_HEADER_LINES + idx + 1, 2 })
        end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "k", function()
        local _, idx = get_session_at_cursor()
        if idx and idx > 1 then
            vim.api.nvim_win_set_cursor(winid, { KILL_HEADER_LINES + idx - 1, 2 })
        end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "<Up>", function()
        local _, idx = get_session_at_cursor()
        if idx and idx > 1 then
            vim.api.nvim_win_set_cursor(winid, { KILL_HEADER_LINES + idx - 1, 2 })
        end
    end, { buffer = bufnr, silent = true })
end

function M.show_review_list()
    vim.cmd("silent! wall")

    -- Upfront large file detection: scan worktrees and prompt for undecided large files
    -- BEFORE the expensive get_unresolved_files() calls, so that decided files get skipped.
    git.scan_for_vibe_worktrees()
    local large_files_mod = require("vibe.large_files")
    local lf_config = config.options.large_files
    local pending_lf = {}

    if lf_config and lf_config.enabled then
        for _, info in pairs(git.worktrees) do
            local changed_files = git.get_worktree_changed_files(info.worktree_path)
            if #changed_files > 0 then
                local entries, has_large = large_files_mod.detect_large_files(
                    info.worktree_path, changed_files, info.repo_root
                )
                if has_large then
                    local saved = large_files_mod.load_decisions(info.worktree_path)
                    local has_undecided = false
                    for _, entry in ipairs(entries) do
                        if entry.type == "file" and not saved[entry.path] then
                            has_undecided = true
                            break
                        elseif entry.type == "dir" and entry.children then
                            for _, child in ipairs(entry.children) do
                                if not saved[child.path] then
                                    has_undecided = true
                                    break
                                end
                            end
                            if has_undecided then break end
                        end
                    end
                    if has_undecided then
                        table.insert(pending_lf, { info = info, changed_files = changed_files })
                    end
                end
            end
        end
    end

    local function show_session_list()
        local worktrees = git.get_worktrees_with_unresolved_files()
        if #worktrees == 0 then
            vim.notify("[Vibe] No sessions with unresolved changes", vim.log.levels.INFO)
            M.restore_return_location()
            return
        end

        local lines = {
            " <CR> review d discard q close",
            " " .. string.rep("─", 50),
            " Vibe Sessions with Changes",
            " " .. string.rep("─", 50),
        }
        for _, info in ipairs(worktrees) do
            local session = terminal.get_session(info.name)
            local is_active = session and status.is_recently_active(info.name)
            local file_count = #git.get_unresolved_files(info.worktree_path)
            table.insert(
                lines,
                string.format(
                    " %s %-20s (%d file%s)",
                    is_active and "◉" or "○",
                    info.name,
                    file_count,
                    file_count == 1 and "" or "s"
                )
            )
            table.insert(lines, string.format(" %s", vim.fn.pathshorten(info.repo_root)))
        end

        local bufnr, winid, close = util.create_centered_float({
            lines = lines,
            filetype = "vibereview",
            min_width = 60,
            title = "Vibe Review",
            cursorline = true,
        })

        local review_first_line = LIST_HEADER_LINES + 1
        vim.api.nvim_win_set_cursor(winid, { review_first_line, 2 })
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 0, 0, -1)
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 1, 0, -1)
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 2, 0, -1)
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 3, 0, -1)

        local function get_worktree_at_cursor()
            local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
            if cursor_line < review_first_line then
                return nil, nil
            end
            local idx = math.floor((cursor_line - review_first_line) / LIST_LINES_PER_SESSION) + 1
            if idx >= 1 and idx <= #worktrees then
                return worktrees[idx], idx
            end
            return nil, nil
        end

        vim.keymap.set("n", "<CR>", function()
            local info = get_worktree_at_cursor()
            if info then
                if #git.get_unresolved_files(info.worktree_path) == 0 then
                    if #git.get_worktree_changed_files(info.worktree_path) > 0 then
                        git.update_snapshot(info.worktree_path)
                    end
                    vim.notify("[Vibe] No unresolved files in this session", vim.log.levels.INFO)
                    close()
                    vim.defer_fn(M.show_review_list, 100)
                    return
                end
                close()

                -- Large file decisions already handled upfront, go straight to mode picker
                local function show_mode_picker()
                    -- Show review mode picker as float (4 options).
                    -- Layout: hint bar, separator, title, separator, then 4 options.
                    local mode_lines = {
                        " <CR> select  q cancel",
                        " " .. string.rep("\xe2\x94\x80", 50),
                        " Select Merge Mode",
                        " " .. string.rep("\xe2\x94\x80", 50),
                        " 1. Auto-Merge All Safe (only review true conflicts)",
                        " 2. Auto-Merge User Only (review AI suggestions + conflicts)",
                        " 3. Auto-Merge AI Only (review your changes + conflicts)",
                        " 4. Review Everything (review all changes)",
                    }
                    -- Map line numbers to merge modes (1-indexed)
                    local line_to_mode = { [5] = "both", [6] = "user", [7] = "ai", [8] = "none" }
                    local first_mode_line = 5
                    local last_mode_line = 8
                    -- Default cursor to line 6 (Auto-Merge User Only, matching default merge_mode)
                    local default_line = 6

                    local mode_bufnr, mode_winid, mode_close = util.create_centered_float({
                        lines = mode_lines,
                        filetype = "vibe_mode_select",
                        min_width = 60,
                        no_default_keymaps = true,
                    })
                    vim.api.nvim_win_set_cursor(mode_winid, { default_line, 2 })
                    vim.api.nvim_buf_add_highlight(mode_bufnr, -1, "Comment", 0, 0, -1)
                    vim.api.nvim_buf_add_highlight(mode_bufnr, -1, "Comment", 1, 0, -1)
                    vim.api.nvim_buf_add_highlight(mode_bufnr, -1, "Title", 2, 0, -1)
                    vim.api.nvim_buf_add_highlight(mode_bufnr, -1, "Comment", 3, 0, -1)
                    vim.wo[mode_winid].cursorline = true

                    local function mode_select()
                        local cursor = vim.api.nvim_win_get_cursor(mode_winid)[1]
                        local mode = line_to_mode[cursor] or "user"
                        mode_close()
                        require("vibe.dialog").show(info.worktree_path, info, mode)
                    end
                    local function mode_cancel()
                        mode_close()
                        M.show_review_list()
                    end
                    vim.keymap.set("n", "<CR>", mode_select, { buffer = mode_bufnr, silent = true })
                    vim.keymap.set("n", "q", mode_cancel, { buffer = mode_bufnr, silent = true })
                    vim.keymap.set("n", "<Esc>", mode_cancel, { buffer = mode_bufnr, silent = true })
                    vim.keymap.set("n", "j", function()
                        local cursor = vim.api.nvim_win_get_cursor(mode_winid)[1]
                        if cursor < last_mode_line then
                            vim.api.nvim_win_set_cursor(mode_winid, { cursor + 1, 2 })
                        end
                    end, { buffer = mode_bufnr, silent = true })
                    vim.keymap.set("n", "<Down>", function()
                        local cursor = vim.api.nvim_win_get_cursor(mode_winid)[1]
                        if cursor < last_mode_line then
                            vim.api.nvim_win_set_cursor(mode_winid, { cursor + 1, 2 })
                        end
                    end, { buffer = mode_bufnr, silent = true })
                    vim.keymap.set("n", "k", function()
                        local cursor = vim.api.nvim_win_get_cursor(mode_winid)[1]
                        if cursor > first_mode_line then
                            vim.api.nvim_win_set_cursor(mode_winid, { cursor - 1, 2 })
                        end
                    end, { buffer = mode_bufnr, silent = true })
                    vim.keymap.set("n", "<Up>", function()
                        local cursor = vim.api.nvim_win_get_cursor(mode_winid)[1]
                        if cursor > first_mode_line then
                            vim.api.nvim_win_set_cursor(mode_winid, { cursor - 1, 2 })
                        end
                    end, { buffer = mode_bufnr, silent = true })
                end

                show_mode_picker()
            end
        end, { buffer = bufnr, silent = true })

        vim.keymap.set("n", "d", function()
            local info = get_worktree_at_cursor()
            if info and vim.fn.confirm("Discard all changes in '" .. info.name .. "'?", "&Yes\n&No", 2) == 1 then
                git.discard_worktree(info.worktree_path)
                close()
                vim.defer_fn(M.show_review_list, 100)
            end
        end, { buffer = bufnr, silent = true })

        vim.keymap.set("n", "j", function()
            local _, idx = get_worktree_at_cursor()
            if idx and idx < #worktrees then
                vim.api.nvim_win_set_cursor(winid, { review_first_line + idx * LIST_LINES_PER_SESSION, 2 })
            end
        end, { buffer = bufnr, silent = true })

        vim.keymap.set("n", "<Down>", function()
            local _, idx = get_worktree_at_cursor()
            if idx and idx < #worktrees then
                vim.api.nvim_win_set_cursor(winid, { review_first_line + idx * LIST_LINES_PER_SESSION, 2 })
            end
        end, { buffer = bufnr, silent = true })

        vim.keymap.set("n", "k", function()
            local _, idx = get_worktree_at_cursor()
            if idx and idx > 1 then
                vim.api.nvim_win_set_cursor(winid, { review_first_line + (idx - 2) * LIST_LINES_PER_SESSION, 2 })
            end
        end, { buffer = bufnr, silent = true })

        vim.keymap.set("n", "<Up>", function()
            local _, idx = get_worktree_at_cursor()
            if idx and idx > 1 then
                vim.api.nvim_win_set_cursor(winid, { review_first_line + (idx - 2) * LIST_LINES_PER_SESSION, 2 })
            end
        end, { buffer = bufnr, silent = true })
    end -- show_session_list

    -- Chain large file dialogs for worktrees with undecided files, then show session list
    local function process_pending_lf(idx)
        if idx > #pending_lf then
            show_session_list()
            return
        end
        local item = pending_lf[idx]
        large_files_mod.show(item.info.worktree_path, item.info, item.changed_files, function(decisions)
            large_files_mod.save_decisions(item.info.worktree_path, decisions)
            process_pending_lf(idx + 1)
        end, function()
            -- Cancel: skip this worktree's large file decisions, continue
            process_pending_lf(idx + 1)
        end)
    end

    process_pending_lf(1)
end

function M.pick_directory(callback)
    local current_file_dir = vim.fn.expand("%:p:h")
    if current_file_dir == "" then
        current_file_dir = vim.fn.getcwd()
    end

    local git_root = vim.fn.systemlist("git -C " .. vim.fn.shellescape(current_file_dir) .. " rev-parse --show-toplevel")[1]
    if vim.v.shell_error ~= 0 then
        git_root = nil
    end

    local options = {
        { label = "Current file directory", path = current_file_dir },
        { label = "Current working directory", path = vim.fn.getcwd() },
    }
    if git_root then
        table.insert(options, { label = "Repo root", path = git_root })
    end
    table.insert(options, { label = "Browse...", path = nil })
    table.insert(options, { label = "Custom path...", path = nil })

    local lines = {
        " <CR> select q cancel",
        " " .. string.rep("─", 50),
        " Select Working Directory",
        " " .. string.rep("─", 50),
    }
    for _, opt in ipairs(options) do
        if opt.path then
            table.insert(lines, string.format(" %s", opt.label))
            table.insert(lines, string.format(" %s", vim.fn.pathshorten(opt.path)))
        else
            table.insert(lines, string.format(" %s", opt.label))
        end
    end

    local bufnr, winid, close = util.create_centered_float({ lines = lines, filetype = "vibepicker", min_width = 60 })

    -- 4 header lines (hint, separator, title, separator), so first option is at line 5
    local FIRST_OPT_LINE = 5
    vim.api.nvim_win_set_cursor(winid, { FIRST_OPT_LINE, 2 })
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 1, 0, -1)
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 2, 0, -1)
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 3, 0, -1)

    local function get_option_index()
        local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
        local option_line = FIRST_OPT_LINE
        for i, opt in ipairs(options) do
            if cursor_line == option_line or (opt.path and cursor_line == option_line + 1) then
                return i
            end
            option_line = option_line + (opt.path and 2 or 1)
        end
        return nil
    end

    vim.keymap.set("n", "<CR>", function()
        local idx = get_option_index()
        if not idx then
            return
        end
        local opt = options[idx]
        close()

        if opt.path then
            callback(opt.path)
        elseif opt.label == "Browse..." then
            M.browse_directory(callback, current_file_dir)
        elseif opt.label == "Custom path..." then
            vim.ui.input(
                { prompt = "Enter directory path: ", default = current_file_dir, completion = "dir" },
                function(input)
                    if input and input ~= "" and vim.fn.isdirectory(input) == 1 then
                        callback(input)
                    elseif input and input ~= "" then
                        vim.notify("[Vibe] Not a valid directory: " .. input, vim.log.levels.WARN)
                    end
                end
            )
        end
    end, { buffer = bufnr, silent = true })

    local function move_next()
        local idx = get_option_index()
        if idx and idx < #options then
            local target_line = FIRST_OPT_LINE
            for i = 1, idx do
                target_line = target_line + (options[i].path and 2 or 1)
            end
            vim.api.nvim_win_set_cursor(winid, { target_line, 2 })
        end
    end

    local function move_prev()
        local idx = get_option_index()
        if idx and idx > 1 then
            local target_line = FIRST_OPT_LINE
            for i = 1, idx - 2 do
                target_line = target_line + (options[i].path and 2 or 1)
            end
            vim.api.nvim_win_set_cursor(winid, { target_line, 2 })
        end
    end

    vim.keymap.set("n", "j", move_next, { buffer = bufnr, silent = true })
    vim.keymap.set("n", "<Down>", move_next, { buffer = bufnr, silent = true })
    vim.keymap.set("n", "k", move_prev, { buffer = bufnr, silent = true })
    vim.keymap.set("n", "<Up>", move_prev, { buffer = bufnr, silent = true })
end

function M.prompt_session_name(default, callback)
    local default_text = default or ""
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].buflisted = false

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { default_text })

    local width = math.min(math.max(40, vim.fn.strdisplaywidth(default_text) + 10), vim.o.columns - 4)
    local height = 1
    local row = math.max(0, math.floor((vim.o.lines - height) / 2))
    local col = math.max(0, math.floor((vim.o.columns - width) / 2))

    local winid = vim.api.nvim_open_win(bufnr, true, {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = " Session Name ",
        title_pos = "center",
        zindex = 60,
    })

    local closed = false
    local function close()
        if closed then
            return
        end
        closed = true
        if vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        vim.cmd("stopinsert")
    end

    local function submit()
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)
        local input = lines[1] or ""
        close()
        local name = input:gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then
            return
        end
        if terminal.sessions[name] then
            vim.notify("[Vibe] Session '" .. name .. "' already exists. Choose another name.", vim.log.levels.WARN)
            vim.schedule(function()
                M.prompt_session_name(name, callback)
            end)
            return
        end
        callback(name)
    end

    vim.keymap.set("i", "<CR>", submit, { buffer = bufnr, silent = true })
    vim.keymap.set("n", "<CR>", submit, { buffer = bufnr, silent = true })
    vim.keymap.set("i", "<Esc>", close, { buffer = bufnr, silent = true })
    vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, silent = true })
    vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true })

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = bufnr,
        once = true,
        callback = function()
            close()
        end,
    })

    vim.cmd("startinsert!")
end

function M.show_sync_selector()
    local sessions = M.list()
    if #sessions == 0 then
        vim.notify("[Vibe] No active sessions", vim.log.levels.ERROR)
        return
    end

    local selected = {}
    for _, info in ipairs(sessions) do
        selected[info.name] = true
    end
    local cursor_idx = 1

    -- Check for unreviewed AI changes per session
    local unreviewed = {}
    for _, info in ipairs(sessions) do
        local sess = terminal.sessions[info.name]
        if sess and sess.worktree_path then
            local files = git.get_unresolved_files(sess.worktree_path)
            if #files > 0 then
                unreviewed[info.name] = #files
            end
        end
    end

    local function build_lines()
        local lines = {}
        local sel_count = vim.tbl_count(selected)
        table.insert(
            lines,
            string.format(" %d selected  |  <Space> toggle  |  a all  |  <CR> sync  |  q cancel", sel_count)
        )
        table.insert(lines, " " .. string.rep("-", 50))
        table.insert(lines, " Sync Sessions")
        table.insert(lines, " " .. string.rep("-", 50))

        for i, info in ipairs(sessions) do
            local check = selected[info.name] and "x" or " "
            local pointer = (i == cursor_idx) and ">" or " "
            local icon = info.is_active and "◉" or (info.is_alive and "○" or "✗")
            local warn = unreviewed[info.name]
                    and string.format("  ⚠ %d unreviewed", unreviewed[info.name])
                or ""
            table.insert(lines, string.format(" %s [%s] %s %s%s", pointer, check, icon, info.name, warn))
            table.insert(lines, string.format("       %s", vim.fn.pathshorten(info.cwd)))
        end
        return lines
    end

    local lines = build_lines()
    local bufnr, winid, close = util.create_centered_float({
        lines = lines,
        filetype = "vibe_sync_select",
        min_width = 60,
        title = "Vibe: Sync",
        cursorline = true,
        zindex = 100,
        no_default_keymaps = true,
    })

    local ns = vim.api.nvim_create_namespace("vibe_sync_select")

    local function render()
        local new_lines = build_lines()
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
        vim.bo[bufnr].modifiable = false

        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        -- Hint bar (line 0), separator (line 1), title (line 2), separator (line 3)
        vim.api.nvim_buf_add_highlight(bufnr, ns, "Comment", 0, 0, -1)
        vim.api.nvim_buf_add_highlight(bufnr, ns, "Comment", 1, 0, -1)
        vim.api.nvim_buf_add_highlight(bufnr, ns, "Title", 2, 0, -1)
        vim.api.nvim_buf_add_highlight(bufnr, ns, "Comment", 3, 0, -1)

        for i, info in ipairs(sessions) do
            local name_line = SYNC_HEADER_LINES + (i - 1) * SYNC_LINES_PER_SESSION
            local path_line = name_line + 1
            if unreviewed[info.name] then
                vim.api.nvim_buf_add_highlight(bufnr, ns, "WarningMsg", name_line, 0, -1)
            elseif selected[info.name] then
                vim.api.nvim_buf_add_highlight(bufnr, ns, "String", name_line, 0, -1)
            end
            vim.api.nvim_buf_add_highlight(bufnr, ns, "Comment", path_line, 0, -1)
        end

        if vim.api.nvim_win_is_valid(winid) then
            local target_line = SYNC_HEADER_LINES + (cursor_idx - 1) * SYNC_LINES_PER_SESSION + 1
            vim.api.nvim_win_set_cursor(winid, { target_line, 2 })
        end
    end

    render()

    local opts = { buffer = bufnr, silent = true }

    local function move_down()
        if cursor_idx < #sessions then
            cursor_idx = cursor_idx + 1
            render()
        end
    end

    local function move_up()
        if cursor_idx > 1 then
            cursor_idx = cursor_idx - 1
            render()
        end
    end

    vim.keymap.set("n", "j", move_down, opts)
    vim.keymap.set("n", "<Down>", move_down, opts)
    vim.keymap.set("n", "k", move_up, opts)
    vim.keymap.set("n", "<Up>", move_up, opts)

    vim.keymap.set("n", "<Space>", function()
        local info = sessions[cursor_idx]
        if info then
            if selected[info.name] then
                selected[info.name] = nil
            else
                selected[info.name] = true
            end
            render()
        end
    end, opts)

    vim.keymap.set("n", "a", function()
        local all_selected = vim.tbl_count(selected) == #sessions
        if all_selected then
            selected = {}
        else
            for _, info in ipairs(sessions) do
                selected[info.name] = true
            end
        end
        render()
    end, opts)

    vim.keymap.set("n", "<CR>", function()
        local sel_count = vim.tbl_count(selected)
        if sel_count == 0 then
            vim.notify("[Vibe] Select at least 1 session to sync", vim.log.levels.WARN)
            return
        end

        -- Warn if any selected sessions have unreviewed AI changes
        local warn_names = {}
        for _, info in ipairs(sessions) do
            if selected[info.name] and unreviewed[info.name] then
                table.insert(
                    warn_names,
                    string.format("  • %s (%d unreviewed files)", info.name, unreviewed[info.name])
                )
            end
        end

        if #warn_names > 0 then
            close()
            local msg = "These sessions have unreviewed AI changes:\n"
                .. table.concat(warn_names, "\n")
                .. "\n\nSyncing may reset review progress. Continue?"
            local choice = vim.fn.confirm(msg, "&No\n&Yes", 1, "Warning")
            if choice ~= 2 then
                return
            end
        else
            close()
        end

        local success_count = 0
        local fail_count = 0
        local total_files = 0
        for _, info in ipairs(sessions) do
            if selected[info.name] then
                local sess = terminal.sessions[info.name]
                if sess and sess.worktree_path then
                    local ok, err, count = git.sync_local_to_worktree(sess.worktree_path)
                    if ok then
                        success_count = success_count + 1
                        total_files = total_files + (count or 0)
                    else
                        fail_count = fail_count + 1
                        vim.notify(
                            "[Vibe] Sync failed for '" .. info.name .. "': " .. (err or "unknown"),
                            vim.log.levels.ERROR
                        )
                    end
                end
            end
        end

        if fail_count == 0 then
            if total_files > 0 then
                vim.notify(
                    string.format("[Vibe] Synced %d file(s) across %d session(s)", total_files, success_count),
                    vim.log.levels.INFO
                )
            else
                vim.notify("[Vibe] All sessions already in sync", vim.log.levels.INFO)
            end
        else
            vim.notify(
                string.format("[Vibe] Sync: %d succeeded, %d failed", success_count, fail_count),
                vim.log.levels.WARN
            )
        end
    end, opts)

    vim.keymap.set("n", "q", close, opts)
    vim.keymap.set("n", "<Esc>", close, opts)
end

function M.browse_directory(callback, start_path)
    local current_path = start_path or vim.fn.getcwd()

    local function show_dir(path)
        local entries = vim.fn.readdir(path)
        local dirs = {}
        for _, entry in ipairs(entries) do
            local full_path = path .. "/" .. entry
            if vim.fn.isdirectory(full_path) == 1 then
                table.insert(dirs, { name = entry, path = full_path })
            end
        end
        table.sort(dirs, function(a, b)
            return a.name < b.name
        end)

        local lines = {
            "  <CR> enter/select  <Tab> select this dir  q cancel",
            "  " .. string.rep("─", 50),
            "  Browse Directory",
            "  " .. string.rep("─", 50),
            "  " .. vim.fn.pathshorten(path),
            "  " .. string.rep("─", 50),
        }

        table.insert(dirs, 1, { name = "..", path = vim.fn.fnamemodify(path, ":h"), is_git = false })
        for i, dir in ipairs(dirs) do
            if i > 1 then -- skip ".."
                dir.is_git = vim.fn.isdirectory(dir.path .. "/.git") == 1
            end
        end
        for _, dir in ipairs(dirs) do
            local git_indicator = dir.is_git and " [git]" or ""
            table.insert(lines, string.format("  📁 %s%s", dir.name, git_indicator))
        end
        table.insert(lines, "")
        table.insert(lines, "  (Only directories inside git repositories can be used)")

        local bufnr, winid, close =
            util.create_centered_float({ lines = lines, filetype = "vibebrowser", min_width = 60, max_height = 20 })

        local first_dir_line_1 = BROWSE_HEADER_LINES + 1 -- 1-indexed
        if #dirs > 0 then
            vim.api.nvim_win_set_cursor(winid, { first_dir_line_1, 2 })
        end
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 0, 0, -1)
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 1, 0, -1)
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 2, 0, -1)
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 3, 0, -1)
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Directory", 4, 0, -1)
        vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 5, 0, -1)

        local function get_dir_at_cursor()
            local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
            local dir_idx = cursor_line - BROWSE_HEADER_LINES
            if dir_idx >= 1 and dir_idx <= #dirs then
                return dirs[dir_idx]
            end
            return nil
        end

        vim.keymap.set("n", "<CR>", function()
            local dir = get_dir_at_cursor()
            if dir then
                close()
                show_dir(dir.path)
            end
        end, { buffer = bufnr, silent = true })

        vim.keymap.set("n", "<Tab>", function()
            close()
            callback(path)
        end, { buffer = bufnr, silent = true })
        local function browse_move_down()
            local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
            if cursor_line - first_dir_line_1 < #dirs - 1 then
                vim.api.nvim_win_set_cursor(winid, { cursor_line + 1, 2 })
            end
        end

        local function browse_move_up()
            local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
            if cursor_line > first_dir_line_1 then
                vim.api.nvim_win_set_cursor(winid, { cursor_line - 1, 2 })
            end
        end

        vim.keymap.set("n", "j", browse_move_down, { buffer = bufnr, silent = true })
        vim.keymap.set("n", "<Down>", browse_move_down, { buffer = bufnr, silent = true })
        vim.keymap.set("n", "k", browse_move_up, { buffer = bufnr, silent = true })
        vim.keymap.set("n", "<Up>", browse_move_up, { buffer = bufnr, silent = true })

        vim.keymap.set("n", "h", function()
            close()
            show_dir(vim.fn.fnamemodify(path, ":h"))
        end, { buffer = bufnr, silent = true })
    end
    show_dir(current_path)
end

function M.show_resume_list()
    persist.cleanup_invalid_sessions()
    local persisted_sessions = persist.get_valid_persisted_sessions()

    git.scan_for_vibe_worktrees()
    local orphaned = {}
    for worktree_path, info in pairs(git.worktrees) do
        local found = false
        for _, ps in ipairs(persisted_sessions) do
            if ps.worktree_path == worktree_path then
                found = true
                break
            end
        end
        if not found then
            table.insert(orphaned, {
                name = info.name,
                worktree_path = info.worktree_path,
                branch = info.branch,
                snapshot_commit = info.snapshot_commit,
                original_branch = info.original_branch,
                repo_root = info.repo_root,
                created_at = info.created_at or os.time(),
                has_terminal = false,
                is_orphaned = true,
            })
        end
    end

    local all_sessions = {}
    for _, s in ipairs(persisted_sessions) do
        table.insert(all_sessions, s)
    end
    for _, s in ipairs(orphaned) do
        table.insert(all_sessions, s)
    end

    local resumable = {}
    for _, s in ipairs(all_sessions) do
        local active_session = terminal.get_session(s.name)
        if not active_session or not vim.api.nvim_buf_is_valid(active_session.bufnr) then
            table.insert(resumable, s)
        end
    end

    if #resumable == 0 then
        vim.notify("[Vibe] No paused sessions to resume", vim.log.levels.INFO)
        return
    end
    table.sort(resumable, function(a, b)
        return (a.created_at or 0) > (b.created_at or 0)
    end)

    local lines = {
        " <CR> resume n new d delete q cancel",
        " " .. string.rep("─", 50),
        " Resume Vibe Session",
        " " .. string.rep("─", 50),
    }
    for _, s in ipairs(resumable) do
        local file_count = 0
        if not git.worktrees[s.worktree_path] then
            git.scan_for_vibe_worktrees()
        end
        if git.worktrees[s.worktree_path] then
            file_count = #git.get_worktree_changed_files(s.worktree_path)
        end

        local project_name = vim.fn.fnamemodify(s.repo_root or s.cwd or "", ":t")
        if project_name == "" then
            project_name = "unknown"
        end
        local status_text = s.is_orphaned and "[orphaned]" or "[paused]"

        table.insert(lines, string.format("  %s (%s) %s", s.name, project_name, status_text))
        table.insert(
            lines,
            string.format(
                "    Created: %s | %d file%s changed",
                persist.format_timestamp(s.created_at),
                file_count,
                file_count == 1 and "" or "s"
            )
        )
        table.insert(lines, string.format("    %s", vim.fn.pathshorten(s.worktree_path)))
    end

    local bufnr, winid, close = util.create_centered_float({
        lines = lines,
        filetype = "viberesume",
        min_width = 60,
        title = "Vibe Resume",
        cursorline = true,
    })

    local resume_first_line = LIST_HEADER_LINES + 1
    vim.api.nvim_win_set_cursor(winid, { resume_first_line, 2 })
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 1, 0, -1)
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 2, 0, -1)
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Comment", 3, 0, -1)

    local function get_session_at_cursor()
        local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
        if cursor_line < resume_first_line then
            return nil, nil, nil
        end
        local remainder = (cursor_line - resume_first_line) % RESUME_LINES_PER_SESSION
        local session_line = cursor_line - remainder
        local idx = (session_line - resume_first_line) / RESUME_LINES_PER_SESSION + 1
        if idx >= 1 and idx <= #resumable then
            return resumable[idx], idx, session_line
        end
        return nil, nil, nil
    end

    vim.keymap.set("n", "<CR>", function()
        local session = get_session_at_cursor()
        if session then
            close()
            local resumed = terminal.resume(session)
            if resumed then
                terminal.show(session.name)
            end
        end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "n", function()
        close()
        M.pick_directory(function(cwd)
            local default_name = vim.fn.fnamemodify(cwd, ":t")
            if default_name == "" then
                default_name = "root"
            end
            M.prompt_session_name(default_name, function(name)
                terminal.toggle(name, cwd)
            end)
        end)
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "d", function()
        local session = get_session_at_cursor()
        if session then
            local project_name = vim.fn.fnamemodify(session.repo_root or session.cwd or "", ":t")
            if
                vim.fn.confirm(
                    "Delete session '" .. session.name .. "' (" .. project_name .. ")?\nThis will discard all changes.",
                    "&Yes\n&No",
                    2
                ) == 1
            then
                if git.worktrees[session.worktree_path] then
                    git.remove_worktree(session.worktree_path)
                else
                    persist.remove_session(session.worktree_path)
                    if vim.fn.isdirectory(session.worktree_path) == 1 then
                        vim.fn.delete(session.worktree_path, "rf")
                    end
                end
                close()
                vim.defer_fn(M.show_resume_list, 100)
            end
        end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "j", function()
        local _, idx = get_session_at_cursor()
        if idx and idx < #resumable then
            vim.api.nvim_win_set_cursor(winid, { resume_first_line + idx * RESUME_LINES_PER_SESSION, 2 })
        end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "<Down>", function()
        local _, idx = get_session_at_cursor()
        if idx and idx < #resumable then
            vim.api.nvim_win_set_cursor(winid, { resume_first_line + idx * RESUME_LINES_PER_SESSION, 2 })
        end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "k", function()
        local _, idx = get_session_at_cursor()
        if idx and idx > 1 then
            vim.api.nvim_win_set_cursor(winid, { resume_first_line + (idx - 2) * RESUME_LINES_PER_SESSION, 2 })
        end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "<Up>", function()
        local _, idx = get_session_at_cursor()
        if idx and idx > 1 then
            vim.api.nvim_win_set_cursor(winid, { resume_first_line + (idx - 2) * RESUME_LINES_PER_SESSION, 2 })
        end
    end, { buffer = bufnr, silent = true })
end

return M
