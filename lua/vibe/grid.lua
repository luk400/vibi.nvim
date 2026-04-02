local config = require("vibe.config")
local terminal = require("vibe.terminal")
local util = require("vibe.util")

local M = {}

M.state = {
    visible = false,
    window_ids = {}, ---@type {name: string, winid: integer}[]
    augroup = nil, ---@type integer|nil
    current_page = 1,
    total_pages = 1,
    maximized_session = nil, ---@type string|nil session name when maximized
    saved_equalalways = nil, ---@type boolean|nil original equalalways value while grid is visible
}

-- ---------------------------------------------------------------------------
-- Layout helpers (pure functions)
-- ---------------------------------------------------------------------------

--- Calculate grid dimensions (rows x cols) for n sessions.
---@param n integer
---@return integer rows, integer cols
function M.grid_dimensions(n)
    if n <= 0 then
        return 0, 0
    end
    if n == 1 then
        return 1, 1
    end
    if n == 2 then
        return 2, 1
    end
    local cols = math.ceil(math.sqrt(n))
    local rows = math.ceil(n / cols)
    return rows, cols
end

--- Calculate cell positions for a floating-window grid on the right half.
---@param session_count integer
---@return {row: integer, col: integer, width: integer, height: integer}[]
function M.calculate_grid_cells(session_count)
    local opts = config.options
    local total_width = vim.o.columns
    local total_height = vim.o.lines - vim.o.cmdheight - 2

    local grid_width = math.floor(total_width * opts.width)
    local grid_col_start = total_width - grid_width

    local rows, cols = M.grid_dimensions(session_count)
    if rows == 0 or cols == 0 then
        return {}
    end

    local cell_width = math.floor(grid_width / cols)
    local cell_height = math.floor(total_height / rows)

    local cells = {}
    for i = 1, session_count do
        local row_idx = math.floor((i - 1) / cols)
        local col_idx = (i - 1) % cols

        local w = cell_width
        local h = cell_height

        -- Last column absorbs remaining width
        if col_idx == cols - 1 then
            w = grid_col_start + grid_width - (grid_col_start + col_idx * cell_width)
        end
        -- Last row absorbs remaining height
        if row_idx == rows - 1 then
            h = total_height - row_idx * cell_height
        end

        table.insert(cells, {
            row = row_idx * cell_height,
            col = grid_col_start + col_idx * cell_width,
            width = w,
            height = h,
        })
    end

    return cells
end

-- ---------------------------------------------------------------------------
-- Session ordering & pagination
-- ---------------------------------------------------------------------------

--- Get all sessions sorted by name.
---@return table[] sessions
local function get_ordered_sessions()
    local sessions = {}
    for _, sess in pairs(terminal.sessions) do
        table.insert(sessions, sess)
    end
    table.sort(sessions, function(a, b)
        return a.name < b.name
    end)
    return sessions
end

--- Get the slice of sessions for a given page.
---@param all_sessions table[]
---@param page integer 1-indexed
---@param max integer max per page
---@return table[] page_sessions
local function get_page_sessions(all_sessions, page, max)
    local start_idx = (page - 1) * max + 1
    local end_idx = math.min(page * max, #all_sessions)
    local result = {}
    for i = start_idx, end_idx do
        table.insert(result, all_sessions[i])
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Window helpers
-- ---------------------------------------------------------------------------

--- Find a non-floating, non-vibe editor window suitable as a split parent.
---@return integer winid (0 = current window fallback)
local function find_editor_window()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        local cfg = vim.api.nvim_win_get_config(w)
        if cfg.relative == "" then -- non-floating
            local buf = vim.api.nvim_win_get_buf(w)
            if vim.bo[buf].filetype ~= "vibe" then
                return w
            end
        end
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Resize helpers
-- ---------------------------------------------------------------------------

--- Resize all PTYs in the grid to match their window dimensions.
local function resize_all_ptys()
    local window = require("vibe.window")
    for _, entry in ipairs(M.state.window_ids) do
        local sess = terminal.sessions[entry.name]
        if sess and vim.api.nvim_win_is_valid(entry.winid) then
            window.resize_pty(sess.bufnr, entry.winid)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Show / Hide
-- ---------------------------------------------------------------------------

--- Create floating windows for a grid page.
---@param page_sessions table[]
---@param show_page_indicator boolean
local function show_float_grid(page_sessions, show_page_indicator)
    local opts = config.options
    local window = require("vibe.window")
    local cells = M.calculate_grid_cells(#page_sessions)

    local has_border = opts.border ~= "none"
    local border_offset = has_border and 2 or 0

    M.state.window_ids = {}
    for i, sess in ipairs(page_sessions) do
        local cell = cells[i]
        local title_name = sess.name
        if show_page_indicator and i == 1 then
            title_name = string.format("%s [%d/%d]", sess.name, M.state.current_page, M.state.total_pages)
        end

        local win_config = {
            relative = "editor",
            row = cell.row,
            col = cell.col,
            width = math.max(1, cell.width - border_offset),
            height = math.max(1, cell.height - border_offset),
            style = "minimal",
            border = opts.border,
            zindex = 50,
        }

        local winid = window.create_raw_float(sess.bufnr, win_config, title_name)
        sess.winid = winid
        table.insert(M.state.window_ids, { name = sess.name, winid = winid })
    end
end

--- Create split windows for a grid page.
---@param page_sessions table[]
---@param show_page_indicator boolean
local function show_split_grid(page_sessions, show_page_indicator)
    local opts = config.options
    local window = require("vibe.window")
    local n = #page_sessions
    local rows, cols = M.grid_dimensions(n)

    local total_height = vim.o.lines - vim.o.cmdheight - 2
    local grid_width = math.floor(vim.o.columns * opts.width)
    -- Account for winbar (1 line per window row) and separators between rows
    local height_overhead = rows + math.max(0, rows - 1)
    local row_height = math.floor((total_height - height_overhead) / rows)
    -- Account for separator columns between vertical splits
    local width_overhead = math.max(0, cols - 1)
    local col_width = math.floor((grid_width - width_overhead) / cols)

    -- Disable equalalways to prevent Neovim from redistributing space across
    -- ALL windows (including editor windows).  It stays off for the lifetime
    -- of the grid and is restored in hide_all().
    if M.state.saved_equalalways == nil then
        M.state.saved_equalalways = vim.o.equalalways
    end
    vim.o.equalalways = false

    -- Build a rows x cols matrix of windows
    ---@type integer[][] grid_wins[row][col] = winid
    local grid_wins = {}

    -- Step 1: Create the first window as a right split of an editor window
    local editor_win = find_editor_window()
    local first_sess = page_sessions[1]
    local first_title = first_sess.name
    if show_page_indicator then
        first_title = string.format("%s [%d/%d]", first_sess.name, M.state.current_page, M.state.total_pages)
    end
    local first_win = window.create_raw_split(first_sess.bufnr, "right", editor_win, first_title)
    vim.api.nvim_win_set_width(first_win, grid_width)
    grid_wins[1] = { first_win }

    -- Step 2: Create remaining rows by splitting below the first column
    for r = 2, rows do
        local session_idx = (r - 1) * cols + 1
        if session_idx > n then
            break
        end
        local sess = page_sessions[session_idx]
        local new_win = window.create_raw_split(sess.bufnr, "below", grid_wins[r - 1][1], sess.name)
        grid_wins[r] = { new_win }
    end

    -- Equalize row heights
    for r = 1, #grid_wins do
        if grid_wins[r][1] and vim.api.nvim_win_is_valid(grid_wins[r][1]) then
            vim.api.nvim_win_set_height(grid_wins[r][1], row_height)
            vim.wo[grid_wins[r][1]].winfixheight = true
        end
    end

    -- Step 3: Create columns within each row
    for r = 1, #grid_wins do
        for c = 2, cols do
            local session_idx = (r - 1) * cols + c
            if session_idx > n then
                break
            end
            local sess = page_sessions[session_idx]
            local new_win = window.create_raw_split(sess.bufnr, "right", grid_wins[r][c - 1], sess.name)
            grid_wins[r][c] = new_win
        end
    end

    -- Step 4: Enforce column widths and lock dimensions.
    -- Each row may have fewer windows than `cols` (partial last row).  A lone
    -- window that was never split horizontally is a direct child of the
    -- vertical container — setting its width to col_width would shrink the
    -- entire grid.  We therefore size each row based on its *actual* window
    -- count.
    for r = 1, #grid_wins do
        local actual_cols = 0
        for c = 1, cols do
            if grid_wins[r] and grid_wins[r][c] and vim.api.nvim_win_is_valid(grid_wins[r][c]) then
                actual_cols = actual_cols + 1
            end
        end

        for c = 1, actual_cols do
            local win = grid_wins[r][c]
            if win and vim.api.nvim_win_is_valid(win) then
                local w
                if actual_cols == 1 then
                    w = grid_width
                else
                    local row_overhead = actual_cols - 1
                    local row_usable = grid_width - row_overhead
                    local row_col_w = math.floor(row_usable / actual_cols)
                    w = (c == actual_cols)
                        and (row_usable - row_col_w * (actual_cols - 1))
                        or row_col_w
                end
                vim.api.nvim_win_set_width(win, w)
                vim.wo[win].winfixwidth = true
                vim.wo[win].winfixheight = true
            end
        end
    end

    -- Flatten to ordered list and record in state
    M.state.window_ids = {}
    for r = 1, #grid_wins do
        for c = 1, cols do
            if grid_wins[r] and grid_wins[r][c] then
                local session_idx = (r - 1) * cols + c
                if session_idx <= n then
                    local sess = page_sessions[session_idx]
                    sess.winid = grid_wins[r][c]
                    table.insert(M.state.window_ids, { name = sess.name, winid = grid_wins[r][c] })
                end
            end
        end
    end
end

--- Create a single floating window filling the entire grid area for a maximized session.
---@param sess table TerminalSession
local function show_maximized_float(sess)
    local opts = config.options
    local window = require("vibe.window")
    local cells = M.calculate_grid_cells(1)
    local cell = cells[1]

    local has_border = opts.border ~= "none"
    local border_offset = has_border and 2 or 0

    local title_name = string.format("%s [maximized]", sess.name)
    local win_config = {
        relative = "editor",
        row = cell.row,
        col = cell.col,
        width = math.max(1, cell.width - border_offset),
        height = math.max(1, cell.height - border_offset),
        style = "minimal",
        border = opts.border,
        zindex = 50,
    }

    local winid = window.create_raw_float(sess.bufnr, win_config, title_name)
    sess.winid = winid
    M.state.window_ids = { { name = sess.name, winid = winid } }
end

--- Create a single split window filling the entire grid area for a maximized session.
---@param sess table TerminalSession
local function show_maximized_split(sess)
    local opts = config.options
    local window = require("vibe.window")
    local grid_width = math.floor(vim.o.columns * opts.width)

    if M.state.saved_equalalways == nil then
        M.state.saved_equalalways = vim.o.equalalways
    end
    vim.o.equalalways = false

    local editor_win = find_editor_window()
    local title_name = string.format("%s [maximized]", sess.name)
    local winid = window.create_raw_split(sess.bufnr, "right", editor_win, title_name)
    vim.api.nvim_win_set_width(winid, grid_width)
    vim.wo[winid].winfixwidth = true

    sess.winid = winid
    M.state.window_ids = { { name = sess.name, winid = winid } }
end

--- Show all sessions in a grid.
---@param page integer|nil 1-indexed page number (default: current_page)
function M.show_all(page)
    local all_sessions = get_ordered_sessions()
    if #all_sessions == 0 then
        vim.notify("[Vibe] No sessions to display in grid", vim.log.levels.INFO)
        return
    end

    local max_sessions = config.options.agent_grid.max_sessions
    M.state.total_pages = math.max(1, math.ceil(#all_sessions / max_sessions))
    M.state.current_page = math.max(1, math.min(page or M.state.current_page, M.state.total_pages))

    local page_sessions = get_page_sessions(all_sessions, M.state.current_page, max_sessions)
    if #page_sessions == 0 then
        return
    end

    -- Close any pre-existing non-grid session windows to prevent orphans.
    -- This handles the case where sessions were opened in regular (non-grid)
    -- windows before the grid was toggled on.
    for _, sess in pairs(terminal.sessions) do
        if sess.winid and vim.api.nvim_win_is_valid(sess.winid) then
            local is_grid_win = false
            for _, entry in ipairs(M.state.window_ids) do
                if entry.winid == sess.winid then
                    is_grid_win = true
                    break
                end
            end
            if not is_grid_win then
                pcall(vim.api.nvim_win_close, sess.winid, true)
                sess.winid = nil
            end
        end
    end

    -- Save buffers
    if config.options.on_open ~= "none" then
        pcall(vim.cmd, "wall")
    end

    -- Hide status indicator (grid replaces it)
    require("vibe.status").close_status_window()

    local is_float = config.options.window_mode ~= "split"

    -- Maximized mode: show only the maximized session at full grid size
    if M.state.maximized_session then
        local max_sess = terminal.sessions[M.state.maximized_session]
        if max_sess then
            if is_float then
                show_maximized_float(max_sess)
            else
                show_maximized_split(max_sess)
            end

            M.state.visible = true
            M.setup_grid_autocmds()
            M.setup_grid_keymaps({ max_sess })

            resize_all_ptys()
            vim.defer_fn(function()
                if M.state.visible then
                    resize_all_ptys()
                end
            end, 100)

            if #M.state.window_ids > 0 then
                local entry = M.state.window_ids[1]
                if vim.api.nvim_win_is_valid(entry.winid) then
                    vim.api.nvim_set_current_win(entry.winid)
                    terminal.current_session = entry.name
                    vim.cmd("startinsert")
                end
            end
            return
        end
        -- Maximized session was killed; clear and fall through to normal grid
        M.state.maximized_session = nil
    end

    local show_page_indicator = M.state.total_pages > 1

    if is_float then
        show_float_grid(page_sessions, show_page_indicator)
    else
        show_split_grid(page_sessions, show_page_indicator)
    end

    M.state.visible = true
    M.setup_grid_autocmds()
    M.setup_grid_keymaps(page_sessions)

    -- Resize all PTYs to match their cell dimensions
    resize_all_ptys()

    -- Deferred resize: the process spawned by termopen() may read the (wrong)
    -- initial PTY size before the synchronous resize above takes effect.
    -- A second resize after a short delay ensures the process picks up the
    -- correct dimensions even if it missed the first SIGWINCH.
    vim.defer_fn(function()
        if M.state.visible then
            resize_all_ptys()
        end
    end, 100)

    -- Focus first cell and enter insert mode
    if #M.state.window_ids > 0 then
        local first = M.state.window_ids[1]
        if vim.api.nvim_win_is_valid(first.winid) then
            vim.api.nvim_set_current_win(first.winid)
            terminal.current_session = first.name
            vim.cmd("startinsert")
        end
    end
end

--- Hide all grid windows and background all sessions.
function M.hide_all()
    local was_visible = M.state.visible
    M.state.visible = false
    M.state.maximized_session = nil

    -- Delete augroup first to prevent WinClosed from re-triggering
    if M.state.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, M.state.augroup)
        M.state.augroup = nil
    end

    -- Close all grid windows
    for _, entry in ipairs(M.state.window_ids) do
        if vim.api.nvim_win_is_valid(entry.winid) then
            pcall(vim.api.nvim_win_close, entry.winid, true)
        end
        local sess = terminal.sessions[entry.name]
        if sess then
            sess.winid = nil
        end
    end
    M.state.window_ids = {}

    -- Restore equalalways now that all grid windows are closed
    if M.state.saved_equalalways ~= nil then
        vim.o.equalalways = M.state.saved_equalalways
        M.state.saved_equalalways = nil
    end

    -- Reload buffers
    if was_visible and config.options.on_close ~= "none" then
        pcall(vim.cmd, "checktime")
    end

    -- Re-show status indicator
    if not vim.tbl_isempty(terminal.sessions) then
        require("vibe.status").show()
    end
end

--- Toggle grid visibility.
function M.toggle()
    if M.state.visible then
        M.hide_all()
    else
        M.show_all()
    end
end

--- Re-layout the grid (preserving current page and maximize state).
function M.refresh()
    if not M.state.visible then
        return
    end
    local page = M.state.current_page
    local maximized = M.state.maximized_session
    M.hide_all()
    M.state.visible = false -- hide_all sets this, but be explicit
    M.state.maximized_session = maximized -- restore after hide_all clears it
    M.show_all(page)
end

--- Go to next page.
function M.next_page()
    if M.state.maximized_session or M.state.total_pages <= 1 then
        return
    end
    local page = M.state.current_page + 1
    if page > M.state.total_pages then
        page = 1
    end
    M.hide_all()
    M.show_all(page)
end

--- Go to previous page.
function M.prev_page()
    if M.state.maximized_session or M.state.total_pages <= 1 then
        return
    end
    local page = M.state.current_page - 1
    if page < 1 then
        page = M.state.total_pages
    end
    M.hide_all()
    M.show_all(page)
end

--- Focus a specific session in the grid.
---@param name string
function M.focus(name)
    for _, entry in ipairs(M.state.window_ids) do
        if entry.name == name and vim.api.nvim_win_is_valid(entry.winid) then
            vim.api.nvim_set_current_win(entry.winid)
            terminal.current_session = name
            vim.cmd("startinsert")
            return
        end
    end
end

--- Focus a session, navigating to its page if necessary.
--- Unlike `focus()`, this handles sessions that are on a different page than
--- the one currently displayed.
---@param name string
function M.focus_or_navigate(name)
    -- Fast path: session is on the current page.
    for _, entry in ipairs(M.state.window_ids) do
        if entry.name == name then
            if vim.api.nvim_win_is_valid(entry.winid) then
                vim.api.nvim_set_current_win(entry.winid)
                terminal.current_session = name
                vim.cmd("startinsert")
            end
            return
        end
    end

    -- Session is not on the current page — find its page and navigate there.
    local all_sessions = get_ordered_sessions()
    local max_sessions = config.options.agent_grid.max_sessions
    for i, sess in ipairs(all_sessions) do
        if sess.name == name then
            local target_page = math.ceil(i / max_sessions)
            M.hide_all()
            M.state.visible = false
            M.show_all(target_page)
            M.focus(name)
            return
        end
    end
end

--- Toggle maximize for the currently focused grid cell.
function M.toggle_maximize()
    if not M.state.visible then
        return
    end

    if M.state.maximized_session then
        -- Restore normal grid
        M.state.maximized_session = nil
        M.refresh()
    else
        -- Determine which session is focused
        local current_win = vim.api.nvim_get_current_win()
        local target_name = nil
        for _, entry in ipairs(M.state.window_ids) do
            if entry.winid == current_win then
                target_name = entry.name
                break
            end
        end
        if not target_name then
            target_name = terminal.current_session
        end
        if not target_name then
            return
        end
        M.state.maximized_session = target_name
        M.refresh()
    end
end

-- ---------------------------------------------------------------------------
-- Autocmds
-- ---------------------------------------------------------------------------

--- Set up grid-specific autocmds.
function M.setup_grid_autocmds()
    if M.state.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, M.state.augroup)
    end
    M.state.augroup = vim.api.nvim_create_augroup("VibeGrid", { clear = true })

    local is_float = config.options.window_mode ~= "split"

    -- VimResized: re-layout grid to recalculate proportions
    vim.api.nvim_create_autocmd("VimResized", {
        group = M.state.augroup,
        callback = function()
            if not M.state.visible then
                return
            end
            M.refresh()
        end,
    })

    -- WinResized: resize PTYs for split mode (manual resize)
    if not is_float then
        vim.api.nvim_create_autocmd("WinResized", {
            group = M.state.augroup,
            callback = function()
                if not M.state.visible then
                    return
                end
                resize_all_ptys()
            end,
        })
    end

    -- WinClosed: if any grid cell is closed externally, hide entire grid
    vim.api.nvim_create_autocmd("WinClosed", {
        group = M.state.augroup,
        callback = function(args)
            if not M.state.visible then
                return
            end
            local closed_winid = tonumber(args.match)
            for _, entry in ipairs(M.state.window_ids) do
                if entry.winid == closed_winid then
                    vim.schedule(function()
                        M.hide_all()
                    end)
                    return
                end
            end
        end,
    })

    -- BufEnter: track which session has focus
    vim.api.nvim_create_autocmd("BufEnter", {
        group = M.state.augroup,
        callback = function()
            if not M.state.visible then
                return
            end
            local bufnr = vim.api.nvim_get_current_buf()
            for name, sess in pairs(terminal.sessions) do
                if sess.bufnr == bufnr then
                    terminal.current_session = name
                    return
                end
            end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

--- Set up buffer-level keymaps for grid mode on each visible terminal.
---@param page_sessions table[]
function M.setup_grid_keymaps(page_sessions)
    local keymap = config.options.keymap

    for _, sess in ipairs(page_sessions) do
        local bufnr = sess.bufnr

        -- Normal mode: q / Esc hide entire grid
        vim.keymap.set("n", "q", function()
            M.hide_all()
        end, { buffer = bufnr, silent = true, desc = "Hide grid" })
        vim.keymap.set("n", "<Esc>", function()
            M.hide_all()
        end, { buffer = bufnr, silent = true, desc = "Hide grid" })

        -- Normal mode: leader-v toggles grid
        if keymap then
            vim.keymap.set("n", keymap, function()
                M.toggle()
            end, { buffer = bufnr, silent = true, desc = "Toggle grid" })
        end

        -- Terminal mode: Esc-Esc to exit terminal mode
        vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-N>", {
            buffer = bufnr,
            silent = true,
            desc = "Exit terminal mode",
        })

        -- Terminal mode: <leader>hjkl for window navigation
        vim.keymap.set("t", "<leader>h", "<C-\\><C-N><C-w>h", {
            buffer = bufnr,
            silent = true,
            desc = "Go to left window",
        })
        vim.keymap.set("t", "<leader>j", "<C-\\><C-N><C-w>j", {
            buffer = bufnr,
            silent = true,
            desc = "Go to below window",
        })
        vim.keymap.set("t", "<leader>k", "<C-\\><C-N><C-w>k", {
            buffer = bufnr,
            silent = true,
            desc = "Go to above window",
        })
        vim.keymap.set("t", "<leader>l", "<C-\\><C-N><C-w>l", {
            buffer = bufnr,
            silent = true,
            desc = "Go to right window",
        })

        -- Terminal mode: C-n/C-p for page cycling (only when multi-page)
        vim.keymap.set("t", "<C-n>", function()
            if M.state.total_pages > 1 then
                vim.cmd("stopinsert")
                M.next_page()
            end
        end, { buffer = bufnr, silent = true, desc = "Next grid page" })
        vim.keymap.set("t", "<C-p>", function()
            if M.state.total_pages > 1 then
                vim.cmd("stopinsert")
                M.prev_page()
            end
        end, { buffer = bufnr, silent = true, desc = "Previous grid page" })

        -- Session picker keymaps (terminal + normal mode)
        local picker_keymap = config.options.session_picker_keymap
        if picker_keymap then
            vim.keymap.set("t", picker_keymap, function()
                if M.state.visible then
                    M.show_session_picker()
                end
            end, { buffer = bufnr, silent = true, desc = "Open session picker" })
            vim.keymap.set("n", picker_keymap, function()
                if M.state.visible then
                    M.show_session_picker()
                end
            end, { buffer = bufnr, silent = true, desc = "Open session picker" })
        end

        -- Maximize toggle keymaps (terminal + normal mode)
        local maximize_keymap = config.options.agent_grid.maximize_keymap
        if maximize_keymap then
            vim.keymap.set("t", maximize_keymap, function()
                vim.cmd("stopinsert")
                M.toggle_maximize()
            end, { buffer = bufnr, silent = true, desc = "Toggle maximize grid cell" })
            vim.keymap.set("n", maximize_keymap, function()
                M.toggle_maximize()
            end, { buffer = bufnr, silent = true, desc = "Toggle maximize grid cell" })
        end
    end
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

--- Show the grid action menu (called from :Vibe when grid mode is enabled).
function M.show_menu()
    local session_count = vim.tbl_count(terminal.sessions)
    local grid_label = M.state.visible and "Hide grid" or "Show grid"

    local lines = {
        " Agent Grid",
        " " .. string.rep("\u{2500}", 40),
        string.format(" t  %s (%d session%s)", grid_label, session_count, session_count == 1 and "" or "s"),
        " n  Create new session",
        " l  Session list",
        "",
        " q  Cancel",
    }

    local bufnr, _, close = util.create_centered_float({
        lines = lines,
        filetype = "vibe_grid_menu",
        min_width = 45,
    })
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 0, 0, -1)

    vim.keymap.set("n", "t", function()
        close()
        M.toggle()
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "n", function()
        close()
        local session_mod = require("vibe.session")
        session_mod.pick_directory(function(cwd)
            local default_name = vim.fn.fnamemodify(cwd, ":t")
            if default_name == "" then
                default_name = "root"
            end
            session_mod.prompt_session_name(default_name, function(name)
                terminal.toggle(name, cwd)
            end)
        end)
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "l", function()
        close()
        require("vibe.session").show_list()
    end, { buffer = bufnr, silent = true })
end

-- ---------------------------------------------------------------------------
-- Session Picker
-- ---------------------------------------------------------------------------

--- Show a floating session picker over the grid for quick session switching.
function M.show_session_picker()
    if not M.state.visible or #M.state.window_ids == 0 then
        return
    end

    vim.cmd("stopinsert")

    local status = require("vibe.status")
    local list = require("vibe.list")

    -- When maximized, show all sessions (not just window_ids which has only one)
    local source_sessions
    if M.state.maximized_session then
        source_sessions = {}
        for name, sess in pairs(terminal.sessions) do
            table.insert(source_sessions, { name = name, sess = sess })
        end
        table.sort(source_sessions, function(a, b) return a.name < b.name end)
    else
        source_sessions = {}
        for _, entry in ipairs(M.state.window_ids) do
            table.insert(source_sessions, { name = entry.name, sess = terminal.sessions[entry.name] })
        end
    end

    local items = {}
    for _, src in ipairs(source_sessions) do
        local sess = src.sess
        local is_alive = sess and sess.job_id and (pcall(vim.fn.jobpid, sess.job_id)) or false
        local is_active = status.is_recently_active(src.name)
        local is_current = src.name == terminal.current_session
        local cwd = sess and sess.cwd or ""
        table.insert(items, {
            name = src.name,
            is_alive = is_alive,
            is_active = is_active,
            is_current = is_current,
            cwd = cwd,
        })
    end

    local close
    local bufnr
    bufnr, _, close = list.create({
        title = "Session Picker",
        items = items,
        min_width = 50,
        render = function(item, _idx, _is_selected)
            local icon = item.is_active and "◉" or (item.is_alive and "○" or "✗")
            local current_marker = item.is_current and " [current]" or ""
            local short_cwd = vim.fn.pathshorten(item.cwd)
            return string.format("  %s %s%s  %s", icon, item.name, current_marker, short_cwd)
        end,
        on_select = function(item)
            close()
            if M.state.maximized_session then
                M.state.maximized_session = item.name
                M.refresh()
            else
                M.focus(item.name)
            end
        end,
    })

    for i, item in ipairs(items) do
        if item.is_active then
            vim.api.nvim_buf_add_highlight(bufnr, -1, "VibeActive", i - 1, 0, 5)
        end
    end
end

return M
