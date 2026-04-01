local config = require("vibe.config")

local M = {}

---@param position string
---@return integer row, integer col, integer width, integer height
local function calculate_dimensions(position)
    local opts = config.options
    local total_width = vim.o.columns
    local total_height = vim.o.lines - vim.o.cmdheight - 2

    local width = math.floor(total_width * opts.width)
    local height = math.floor(total_height * opts.height)
    local row, col = 0, 0

    if position == "right" then
        height = total_height
        col = total_width - width
    elseif position == "left" then
        height = total_height
    elseif position == "top" then
        width = total_width
    elseif position == "bottom" then
        width = total_width
        row = total_height - height
    else -- centered
        row = math.floor((total_height - height) / 2)
        col = math.floor((total_width - width) / 2)
    end

    return row, col, width, height
end

--- Resize the PTY and send SIGWINCH to all descendant processes.
--- The job's process tree may include su/sudo which create new sessions —
--- the PTY's SIGWINCH only reaches the foreground process group and never
--- makes it to the actual TUI app.
---@param bufnr integer
---@param winid integer
local function resize_pty(bufnr, winid)
    local actual_w = vim.api.nvim_win_get_width(winid)
    local actual_h = vim.api.nvim_win_get_height(winid)
    local job = vim.b[bufnr].terminal_job_id
    if job then
        vim.fn.jobresize(job, actual_w, actual_h)

        local queue = { vim.fn.jobpid(job) }
        while #queue > 0 do
            local ppid = table.remove(queue, 1)
            local children =
                vim.fn.systemlist(string.format("ps --ppid %d -o pid= 2>/dev/null", ppid))
            for _, c in ipairs(children) do
                local cpid = tonumber(vim.trim(c))
                if cpid then
                    table.insert(queue, cpid)
                    pcall(vim.uv.kill, cpid, 28)
                end
            end
        end
    end
end

--- Create a split window for the terminal buffer.
---@param bufnr integer
---@param session_name string|nil
---@return integer winid
local function create_split_window(bufnr, session_name)
    local opts = config.options
    local total_height = vim.o.lines - vim.o.cmdheight - 2

    -- Map position to split direction ("centered" has no split equivalent, fallback to right)
    local split_map = {
        right = "right",
        left = "left",
        top = "above",
        bottom = "below",
        centered = "right",
    }
    local split_dir = split_map[opts.position] or "right"

    local winid = vim.api.nvim_open_win(bufnr, true, {
        split = split_dir,
        win = 0,
    })

    -- Set dimensions based on direction
    local is_vertical = (split_dir == "right" or split_dir == "left")
    if is_vertical then
        local width = math.floor(vim.o.columns * opts.width)
        vim.api.nvim_win_set_width(winid, width)
    else
        local height = math.floor(total_height * opts.height)
        vim.api.nvim_win_set_height(winid, height)
    end

    if session_name then
        vim.wo[winid].winbar = " Vibe: " .. session_name .. " "
    end

    vim.wo[winid].winhl = "Normal:Normal"

    return winid
end

---@param bufnr integer
---@param session_name string|nil
---@return integer winid
function M.create(bufnr, session_name)
    local opts = config.options
    local is_float = opts.window_mode ~= "split"

    local current_winid

    -- Float helpers (defined at function scope so the VimResized closure captures them)
    local make_win_config, apply_win_opts

    if is_float then
        make_win_config = function()
            local row, col, width, height = calculate_dimensions(opts.position)
            local wc = {
                relative = "editor",
                row = row,
                col = col,
                width = width,
                height = height,
                style = "minimal",
                border = opts.border,
                zindex = 50,
            }
            if session_name then
                wc.title = " Vibe: " .. session_name .. " "
                wc.title_pos = "center"
            end
            return wc
        end

        apply_win_opts = function(wid)
            vim.wo[wid].winblend = 0
            vim.wo[wid].winhl = "Normal:Normal,FloatBorder:FloatBorder"
        end

        current_winid = vim.api.nvim_open_win(bufnr, true, make_win_config())
        apply_win_opts(current_winid)
    else
        current_winid = create_split_window(bufnr, session_name)
    end

    -- Buffer-level keymaps (persist across window recreations)
    local close_fn = function()
        require("vibe").toggle(session_name)
    end
    vim.keymap.set("n", "q", close_fn, { buffer = bufnr, silent = true, desc = "Close Vibe window" })
    vim.keymap.set("n", "<Esc>", close_fn, { buffer = bufnr, silent = true, desc = "Close Vibe window" })

    local keymap = config.options.keymap
    if keymap then
        vim.keymap.set("n", keymap, close_fn, { buffer = bufnr, silent = true, desc = "Close Vibe window" })
    end

    -- Terminal-mode keymaps
    vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-N>", { buffer = bufnr, silent = true, desc = "Exit terminal mode" })
    vim.keymap.set("t", "<M-h>", "<C-\\><C-N><C-w>h", { buffer = bufnr, silent = true, desc = "Go to left window" })
    vim.keymap.set("t", "<M-j>", "<C-\\><C-N><C-w>j", { buffer = bufnr, silent = true, desc = "Go to below window" })
    vim.keymap.set("t", "<M-k>", "<C-\\><C-N><C-w>k", { buffer = bufnr, silent = true, desc = "Go to above window" })
    vim.keymap.set("t", "<M-l>", "<C-\\><C-N><C-w>l", { buffer = bufnr, silent = true, desc = "Go to right window" })

    -- Session cycling keymaps
    local function cycle_session(direction)
        local term = require("vibe.terminal")
        local names = vim.tbl_keys(term.sessions)
        table.sort(names)
        if #names <= 1 then
            return
        end
        local current = term.current_session or session_name
        local current_idx = 1
        for i, n in ipairs(names) do
            if n == current then
                current_idx = i
                break
            end
        end
        local next_idx = current_idx + direction
        if next_idx > #names then
            next_idx = 1
        elseif next_idx < 1 then
            next_idx = #names
        end
        term.hide(current)
        term.show(names[next_idx])
    end

    vim.keymap.set("t", "<C-n>", function()
        cycle_session(1)
    end, { buffer = bufnr, silent = true, desc = "Next Vibe session" })
    vim.keymap.set("t", "<C-p>", function()
        cycle_session(-1)
    end, { buffer = bufnr, silent = true, desc = "Previous Vibe session" })

    -- Resize / close handling
    -- Key the augroup on bufnr (stable across window recreations), not winid
    local resize_group = vim.api.nvim_create_augroup("VibeWindowResize" .. bufnr, { clear = true })
    local resizing = false

    local function setup_win_close(wid)
        vim.api.nvim_create_autocmd("WinClosed", {
            group = resize_group,
            pattern = tostring(wid),
            callback = function()
                if resizing then
                    return
                end
                pcall(vim.api.nvim_del_augroup_by_id, resize_group)
                require("vibe.terminal").on_window_closed()
            end,
            once = true,
        })
    end

    vim.api.nvim_create_autocmd("VimResized", {
        group = resize_group,
        callback = function()
            if not vim.api.nvim_win_is_valid(current_winid) then
                vim.api.nvim_del_augroup_by_id(resize_group)
                return
            end

            if is_float then
                -- Float mode: close and reopen at new dimensions
                local was_terminal = vim.api.nvim_get_mode().mode == "t"

                resizing = true
                vim.api.nvim_win_close(current_winid, true)

                current_winid = vim.api.nvim_open_win(bufnr, true, make_win_config())
                apply_win_opts(current_winid)

                -- Update session tracking so terminal.lua sees the new winid
                local term = require("vibe.terminal")
                for _, session in pairs(term.sessions) do
                    if session.bufnr == bufnr then
                        session.winid = current_winid
                        break
                    end
                end

                setup_win_close(current_winid)
                resizing = false

                resize_pty(bufnr, current_winid)

                if was_terminal then
                    vim.cmd("startinsert")
                end
            else
                -- Split mode: Neovim handles layout; just resize PTY
                resize_pty(bufnr, current_winid)
            end
        end,
    })

    vim.api.nvim_create_autocmd("WinResized", {
        group = resize_group,
        callback = function()
            if not vim.api.nvim_win_is_valid(current_winid) then
                return
            end
            for _, w in ipairs(vim.v.event.windows) do
                if w == current_winid then
                    resize_pty(bufnr, current_winid)
                    return
                end
            end
        end,
    })

    setup_win_close(current_winid)

    return current_winid
end

return M
