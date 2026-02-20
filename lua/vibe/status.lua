local config = require("vibe.config")

local M = {}

-- Spinner frames
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_index = 1

-- Activity tracking
---@type table<string, number>
M.last_activity = {}

---@type table<integer, integer> bufnr -> last known changedtick
M.last_changedtick = {}

---@type integer|nil
M.status_winid = nil

---@type integer|nil
M.status_bufnr = nil

---@type integer|nil
M.timer = nil

---@type integer
M.inactivity_timeout = 500 -- ms

---@type integer Time to wait before considering AI "done" (ms)
M.completion_timeout = 2000 -- 2 seconds of inactivity

---@type integer|nil Last time AI was active
M.last_active_time = nil

---@type boolean Track if AI was previously active (for event emission)
M.was_active = false

---@type boolean Track if we've already triggered completion
M.completion_triggered = false

--- Mark a session as having recent activity
---@param name string
function M.mark_active(name)
  M.last_activity[name] = vim.loop.now()
end

--- Check if a session has recent activity
---@param name string
---@return boolean
function M.is_recently_active(name)
  local last = M.last_activity[name]
  if not last then
    return false
  end
  return (vim.loop.now() - last) < M.inactivity_timeout
end

--- Check terminal buffers for activity (called periodically)
function M.check_terminal_activity()
  local terminal = require("vibe.terminal")
  local git = require("vibe.git")
  local dialog = require("vibe.dialog")

  local any_active = false
  for name, session in pairs(terminal.sessions) do
    local bufnr = session.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      local current_tick = vim.b[bufnr].changedtick
      local last_tick = M.last_changedtick[bufnr] or 0
      if current_tick ~= last_tick then
        M.last_changedtick[bufnr] = current_tick
        M.mark_active(name)
        any_active = true
        M.last_active_time = vim.loop.now()
        -- Reset completion triggered when activity resumes
        M.completion_triggered = false
      end
      if M.is_recently_active(name) then
        any_active = true
      end
    end
  end

  -- Emit event when AI starts working (transitions from inactive to active)
  if any_active and not M.was_active then
    vim.api.nvim_exec_autocmds("User", { pattern = "VibeAIStarted", modeline = false })
    M.completion_triggered = false
  end

  -- Check if AI has completed (was active, now inactive for completion_timeout)
  if M.was_active and not any_active and M.last_active_time then
    local time_since_active = vim.loop.now() - M.last_active_time
    if time_since_active >= M.completion_timeout and not M.completion_triggered then
      -- AI is done! Check if there are changed files and show dialog
      M.completion_triggered = true
      if next(git.worktrees) ~= nil then
        local files = git.get_changed_files()
        if #files > 0 then
          vim.defer_fn(function()
            dialog.show()
          end, 100)
        end
      end
    end
  end

  M.was_active = any_active
end

--- Get status text for display
---@return string
local function get_status_text()
  local terminal = require("vibe.terminal")
  local lines = {}

  for name, session in pairs(terminal.sessions) do
    local is_current = name == terminal.current_session
    local is_open = session.winid and vim.api.nvim_win_is_valid(session.winid)
    local is_alive = vim.fn.jobpid(session.job_id) > 0
    local is_active = M.is_recently_active(name)

    local status_parts = {}

    -- Activity spinner or idle indicator
    if is_alive and is_active then
      table.insert(status_parts, spinner_frames[spinner_index])
    elseif is_alive then
      table.insert(status_parts, "○")
    else
      table.insert(status_parts, "✗")
    end

    -- Session name
    table.insert(status_parts, name)

    -- State indicators
    if is_current then
      table.insert(status_parts, "[current]")
    end
    if is_open then
      table.insert(status_parts, "[open]")
    end
    if not is_alive then
      table.insert(status_parts, "[dead]")
    end

    table.insert(lines, table.concat(status_parts, " "))
  end

  if #lines == 0 then
    return "No active sessions"
  end

  return table.concat(lines, "\n")
end

--- Update the spinner animation
local function update_spinner()
  -- Check for terminal activity before refreshing
  M.check_terminal_activity()
  spinner_index = (spinner_index % #spinner_frames) + 1
  M.refresh_status_window()
end

--- Create the status window
function M.create_status_window()
  if M.status_winid and vim.api.nvim_win_is_valid(M.status_winid) then
    return
  end

  M.status_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[M.status_bufnr].bufhidden = "wipe"
  vim.bo[M.status_bufnr].buflisted = false

  local width = 30
  local height = 1

  M.status_winid = vim.api.nvim_open_win(M.status_bufnr, false, {
    relative = "editor",
    row = 0,
    col = vim.o.columns - width - 2,
    width = width,
    height = height,
    style = "minimal",
    border = "none",
    zindex = 100,
    focusable = false,
  })

  vim.wo[M.status_winid].winblend = 0

  M.refresh_status_window()
  M.start_timer()
end

--- Refresh the status window content
function M.refresh_status_window()
  if not M.status_bufnr or not vim.api.nvim_buf_is_valid(M.status_bufnr) then
    return
  end

  local text = get_status_text()
  local lines = vim.split(text, "\n")

  -- Resize window based on content
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  if M.status_winid and vim.api.nvim_win_is_valid(M.status_winid) then
    vim.api.nvim_win_set_config(M.status_winid, {
      relative = "editor",
      width = width + 2,
      height = #lines,
      col = vim.o.columns - width - 4,
      row = 0,
    })
  end

  vim.api.nvim_buf_set_lines(M.status_bufnr, 0, -1, false, lines)

  -- Highlight active sessions
  for i, line in ipairs(lines) do
    if line:match("^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]") then
      vim.api.nvim_buf_add_highlight(M.status_bufnr, -1, "VibeActive", i - 1, 0, 3)
    end
  end
end

--- Close the status window
function M.close_status_window()
  if M.timer then
    vim.fn.timer_stop(M.timer)
    M.timer = nil
  end

  if M.status_winid and vim.api.nvim_win_is_valid(M.status_winid) then
    vim.api.nvim_win_close(M.status_winid, true)
    M.status_winid = nil
  end

  if M.status_bufnr and vim.api.nvim_buf_is_valid(M.status_bufnr) then
    vim.api.nvim_buf_delete(M.status_bufnr, { force = true })
    M.status_bufnr = nil
  end
end

--- Start the animation timer
function M.start_timer()
  if M.timer then
    return
  end

  M.timer = vim.fn.timer_start(80, function()
    update_spinner()
  end, { ["repeat"] = -1 })
end

--- Show status indicator (call this when any session is created)
function M.show()
  M.create_status_window()
end

--- Hide status indicator (call this when all sessions are closed)
function M.hide()
  local terminal = require("vibe.terminal")
  if vim.tbl_isempty(terminal.sessions) then
    M.close_status_window()
  end
end

--- Setup highlight groups
function M.setup_highlights()
  vim.api.nvim_set_hl(0, "VibeActive", { link = "WarningMsg" })
end

return M
