local M = {}

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_index = 1

---@type integer|nil
M.winid = nil

---@type integer|nil
M.bufnr = nil

---@type integer|nil
M.timer = nil

---@type string|nil
M.session_name = nil

---@type function|nil
M.on_cancel = nil

local function get_lines()
    local name = M.session_name or "session"
    local lines = {
        " " .. spinner_frames[spinner_index] .. " Creating worktree for '" .. name .. "'...",
        "   This may take longer for large repos.",
        "   Untracked files are also copied over —",
        "   exclude large ones via .gitignore or .vibeinclude",
    }
    if M.on_cancel then
        table.insert(lines, "")
        table.insert(lines, "   Press <Esc> to cancel")
    end
    return lines
end

local function get_win_config(lines)
    local width = 0
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    width = width + 2
    local height = #lines
    local col = math.floor((vim.o.columns - width) / 2)
    return {
        relative = "editor",
        row = 1,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        zindex = 200,
        focusable = false,
    }
end

local function refresh()
    if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
        return
    end
    local lines = get_lines()
    vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(M.bufnr, -1, 0, -1)
    vim.api.nvim_buf_add_highlight(M.bufnr, -1, "WarningMsg", 0, 0, -1)

    if M.winid and vim.api.nvim_win_is_valid(M.winid) then
        vim.api.nvim_win_set_config(M.winid, get_win_config(lines))
    end
end

---@param session_name string
---@param on_cancel function|nil Optional callback invoked when user presses ESC
function M.show(session_name, on_cancel)
    if M.winid and vim.api.nvim_win_is_valid(M.winid) then
        M.session_name = session_name
        M.on_cancel = on_cancel
        refresh()
        return
    end

    M.session_name = session_name
    M.on_cancel = on_cancel
    spinner_index = 1

    M.bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[M.bufnr].bufhidden = "wipe"
    vim.bo[M.bufnr].buflisted = false

    local lines = get_lines()
    vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_add_highlight(M.bufnr, -1, "WarningMsg", 0, 0, -1)

    local focusable = on_cancel ~= nil
    local win_config = get_win_config(lines)
    win_config.focusable = focusable
    M.winid = vim.api.nvim_open_win(M.bufnr, focusable, win_config)

    if on_cancel and M.bufnr then
        vim.keymap.set("n", "<Esc>", function()
            if M.on_cancel then
                M.on_cancel()
            end
        end, { buffer = M.bufnr, nowait = true, desc = "Cancel worktree creation" })
    end

    M.timer = vim.fn.timer_start(80, function()
        spinner_index = (spinner_index % #spinner_frames) + 1
        vim.schedule(refresh)
    end, { ["repeat"] = -1 })

    -- Reposition on resize
    M._resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
        callback = function()
            if M.winid and vim.api.nvim_win_is_valid(M.winid) then
                refresh()
            end
        end,
    })
end

function M.hide()
    if M.timer then
        vim.fn.timer_stop(M.timer)
        M.timer = nil
    end

    if M._resize_autocmd then
        pcall(vim.api.nvim_del_autocmd, M._resize_autocmd)
        M._resize_autocmd = nil
    end

    if M.winid and vim.api.nvim_win_is_valid(M.winid) then
        vim.api.nvim_win_close(M.winid, true)
    end
    M.winid = nil

    if M.bufnr and vim.api.nvim_buf_is_valid(M.bufnr) then
        vim.api.nvim_buf_delete(M.bufnr, { force = true })
    end
    M.bufnr = nil

    M.session_name = nil
    M.on_cancel = nil
end

return M
