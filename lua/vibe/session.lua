local terminal = require("vibe.terminal")
local status = require("vibe.status")
local git = require("vibe.git")
local persist = require("vibe.persist")
local util = require("vibe.util")

local M = {}

function M.list()
  local sessions = {}
  for name, session in pairs(terminal.sessions) do
    table.insert(sessions, {
      name = name,
      is_current = name == terminal.current_session,
      is_open = session.winid and vim.api.nvim_win_is_valid(session.winid) or false,
      is_alive = session.job_id and vim.fn.jobpid(session.job_id) > 0 or false,
      is_active = status.is_recently_active(name),
      job_id = session.job_id,
      bufnr = session.bufnr,
      cwd = session.cwd or vim.fn.getcwd(),
    })
  end

  table.sort(sessions, function(a, b)
    if a.is_current then return true end
    if b.is_current then return false end
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
    table.insert(lines, " Vibe Sessions")
    table.insert(lines, " " .. string.rep("─", 50))
    for _, info in ipairs(sessions) do
      local icon = info.is_active and "◉" or (info.is_alive and "○" or "✗")
      local flags = {}
      if info.is_current then table.insert(flags, "current") end
      if info.is_open then table.insert(flags, "open") end
      if not info.is_alive then table.insert(flags, "dead") end
      local flag_str = #flags > 0 and (" [" .. table.concat(flags, ", ") .. "]") or ""
      table.insert(lines, string.format(" %s %s%s", icon, info.name, flag_str))
      table.insert(lines, string.format(" %s", vim.fn.pathshorten(info.cwd)))
    end
    table.insert(lines, "")
    table.insert(lines, " <CR> open d kill q close")
  end

  local bufnr, winid, close = util.create_centered_float({ lines = lines, filetype = "vibelist", min_width = 40 })

  if #sessions > 0 then vim.api.nvim_win_set_cursor(winid, { 3, 2 }) end
  vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 0, 0, -1)

  for i, session in ipairs(sessions) do
    local line_num = 2 + (i - 1) * 2 + 1
    if session.is_active then vim.api.nvim_buf_add_highlight(bufnr, -1, "VibeActive", line_num - 1, 0, 5) end
  end

  local function get_session_at_cursor()
    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
    if cursor_line < 3 then return nil, nil end
    local session_idx = math.floor((cursor_line - 3) / 2) + 1
    if session_idx >= 1 and session_idx <= #sessions then return sessions[session_idx], session_idx end
    return nil, nil
  end

  vim.keymap.set("n", "<CR>", function()
    local session = get_session_at_cursor()
    if session then close(); terminal.show(session.name) end
  end, { buffer = bufnr, silent = true })

  vim.keymap.set("n", "d", function()
    local session = get_session_at_cursor()
    if session then terminal.kill(session.name); close(); M.show_list() end
  end, { buffer = bufnr, silent = true })

  vim.keymap.set("n", "j", function()
    local _, idx = get_session_at_cursor()
    if idx and idx < #sessions then vim.api.nvim_win_set_cursor(winid, { 3 + idx * 2, 2 }) end
  end, { buffer = bufnr, silent = true })

  vim.keymap.set("n", "k", function()
    local _, idx = get_session_at_cursor()
    if idx and idx > 1 then vim.api.nvim_win_set_cursor(winid, { 3 + (idx - 2) * 2, 2 }) end
  end, { buffer = bufnr, silent = true })
end

function M.show_kill_list()
  local sessions = M.list()
  if #sessions == 0 then vim.notify("[Vibe] No active sessions to kill", vim.log.levels.INFO); return end

  local lines = { " Kill Vibe Session", " " .. string.rep("─", 30) }
  for _, info in ipairs(sessions) do
    local icon = info.is_active and "◉" or (info.is_alive and "○" or "✗")
    table.insert(lines, string.format(" %s %s", icon, info.name))
  end
  table.insert(lines, ""); table.insert(lines, " <CR> kill q cancel")

  local bufnr, winid, close = util.create_centered_float({ lines = lines, filetype = "vibekill", min_width = 40 })

  vim.api.nvim_win_set_cursor(winid, { 3, 2 })
  vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 0, 0, -1)

  local function get_session_at_cursor()
    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
    local session_idx = cursor_line - 2
    if session_idx >= 1 and session_idx <= #sessions then return sessions[session_idx], session_idx end
    return nil, nil
  end

  vim.keymap.set("n", "<CR>", function()
    local session = get_session_at_cursor()
    if session then terminal.kill(session.name); close() end
  end, { buffer = bufnr, silent = true })

  vim.keymap.set("n", "j", function()
    local _, idx = get_session_at_cursor()
    if idx and idx < #sessions then vim.api.nvim_win_set_cursor(winid, { idx + 2 + 1, 2 }) end
  end, { buffer = bufnr, silent = true })

  vim.keymap.set("n", "k", function()
    local _, idx = get_session_at_cursor()
    if idx and idx > 1 then vim.api.nvim_win_set_cursor(winid, { idx + 2 - 1, 2 }) end
  end, { buffer = bufnr, silent = true })
end

function M.show_review_list()
  vim.cmd("silent! wall")
  local worktrees = git.get_worktrees_with_unresolved_files()
  if #worktrees == 0 then vim.notify("[Vibe] No sessions with unresolved changes", vim.log.levels.INFO); return end

  local lines = { " Vibe Sessions with Changes", " " .. string.rep("─", 50) }
  for _, info in ipairs(worktrees) do
    local session = terminal.get_session(info.name)
    local is_active = session and status.is_recently_active(info.name)
    local file_count = #git.get_worktree_changed_files(info.worktree_path)
    table.insert(lines, string.format(" %s %-20s (%d file%s)", is_active and "◉" or "○", info.name, file_count, file_count == 1 and "" or "s"))
    table.insert(lines, string.format(" %s", vim.fn.pathshorten(info.repo_root)))
  end
  table.insert(lines, ""); table.insert(lines, " <CR> review d discard q close")

  local bufnr, winid, close = util.create_centered_float({
    lines = lines, filetype = "vibereview", min_width = 60, title = "Vibe Review", cursorline = true
  })

  vim.api.nvim_win_set_cursor(winid, { 3, 2 })
  vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 0, 0, -1)

  local function get_worktree_at_cursor()
    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
    if cursor_line < 3 then return nil, nil end
    local idx = math.floor((cursor_line - 3) / 2) + 1
    if idx >= 1 and idx <= #worktrees then return worktrees[idx], idx end
    return nil, nil
  end

  vim.keymap.set("n", "<CR>", function()
    local info = get_worktree_at_cursor()
    if info then
      if #git.get_unresolved_files(info.worktree_path) == 0 then
        vim.notify("[Vibe] No unresolved files in this session", vim.log.levels.INFO)
        close()
        vim.defer_fn(M.show_review_list, 100)
        return
      end
      close()
      
      -- Prompt for Review Mode
      vim.ui.select({
        "1. Auto-Merge (Apply safe changes, only review conflicts)",
        "2. Manual Review (Review all changes manually)"
      }, { prompt = "Select Review Mode:" }, function(choice)
        if not choice then
          M.show_review_list()
          return
        end
        local mode = choice:match("^1") and "auto" or "manual"
        require("vibe.dialog").show(info.worktree_path, info, mode)
      end)
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
    if idx and idx < #worktrees then vim.api.nvim_win_set_cursor(winid, { 3 + idx * 2, 2 }) end
  end, { buffer = bufnr, silent = true })

  vim.keymap.set("n", "k", function()
    local _, idx = get_worktree_at_cursor()
    if idx and idx > 1 then vim.api.nvim_win_set_cursor(winid, { 3 + (idx - 2) * 2, 2 }) end
  end, { buffer = bufnr, silent = true })
end

function M.pick_directory(callback)
  local current_file_dir = vim.fn.expand("%:p:h")
  if current_file_dir == "" then current_file_dir = vim.fn.getcwd() end

  local options = {
    { label = "Current file directory", path = current_file_dir },
    { label = "Current working directory", path = vim.fn.getcwd() },
    { label = "Browse...", path = nil },
    { label = "Custom path...", path = nil },
  }

  local lines = { " Select Working Directory", " " .. string.rep("─", 50) }
  for _, opt in ipairs(options) do
    if opt.path then
      table.insert(lines, string.format(" %s", opt.label))
      table.insert(lines, string.format(" %s", vim.fn.pathshorten(opt.path)))
    else
      table.insert(lines, string.format(" %s", opt.label))
    end
  end
  table.insert(lines, ""); table.insert(lines, " <CR> select q cancel")

  local bufnr, winid, close = util.create_centered_float({ lines = lines, filetype = "vibepicker", min_width = 60 })

  vim.api.nvim_win_set_cursor(winid, { 3, 2 })
  vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 0, 0, -1)

  local function get_option_index()
    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
    local option_line = 3
    for i, opt in ipairs(options) do
      if cursor_line == option_line or (opt.path and cursor_line == option_line + 1) then return i end
      option_line = option_line + (opt.path and 2 or 1)
    end
    return nil
  end

  vim.keymap.set("n", "<CR>", function()
    local idx = get_option_index()
    if not idx then return end
    local opt = options[idx]
    close()

    if opt.path then
      callback(opt.path)
    elseif opt.label == "Browse..." then
      M.browse_directory(callback, current_file_dir)
    elseif opt.label == "Custom path..." then
      vim.ui.input({ prompt = "Enter directory path: ", default = current_file_dir, completion = "dir" }, function(input)
        if input and input ~= "" and vim.fn.isdirectory(input) == 1 then callback(input)
        elseif input and input ~= "" then vim.notify("[Vibe] Not a valid directory: " .. input, vim.log.levels.WARN) end
      end)
    end
  end, { buffer = bufnr, silent = true })

  vim.keymap.set("n", "j", function()
    local idx = get_option_index()
    if idx and idx < #options then
      local target_line = 3
      for i = 1, idx do target_line = target_line + (options[i].path and 2 or 1) end
      vim.api.nvim_win_set_cursor(winid, { target_line, 2 })
    end
  end, { buffer = bufnr, silent = true })

  vim.keymap.set("n", "k", function()
    local idx = get_option_index()
    if idx and idx > 1 then
      local target_line = 3
      for i = 1, idx - 2 do target_line = target_line + (options[i].path and 2 or 1) end
      vim.api.nvim_win_set_cursor(winid, { target_line, 2 })
    end
  end, { buffer = bufnr, silent = true })
end

function M.browse_directory(callback, start_path)
  local current_path = start_path or vim.fn.getcwd()

  local function show_dir(path)
    local entries = vim.fn.readdir(path)
    local dirs = {}
    for _, entry in ipairs(entries) do
      local full_path = path .. "/" .. entry
      if vim.fn.isdirectory(full_path) == 1 then table.insert(dirs, { name = entry, path = full_path }) end
    end
    table.sort(dirs, function(a, b) return a.name < b.name end)

    local lines = {
      "  Browse Directory",
      "  " .. string.rep("─", 50),
      "  " .. vim.fn.pathshorten(path),
      "  " .. string.rep("─", 50),
    }

    table.insert(dirs, 1, { name = "..", path = vim.fn.fnamemodify(path, ":h") })
    for _, dir in ipairs(dirs) do table.insert(lines, string.format("  📁 %s", dir.name)) end
    table.insert(lines, ""); table.insert(lines, "  <CR> enter/select  <Tab> select this dir  q cancel")

    local bufnr, winid, close = util.create_centered_float({ lines = lines, filetype = "vibebrowser", min_width = 60, max_height = 20 })

    if #dirs > 0 then vim.api.nvim_win_set_cursor(winid, { 6, 2 }) end
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(bufnr, -1, "Directory", 2, 0, -1)

    local function get_dir_at_cursor()
      local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
      local dir_idx = cursor_line - 5
      if dir_idx >= 1 and dir_idx <= #dirs then return dirs[dir_idx] end
      return nil
    end

    vim.keymap.set("n", "<CR>", function()
      local dir = get_dir_at_cursor()
      if dir then close(); show_dir(dir.path) end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "<Tab>", function() close(); callback(path) end, { buffer = bufnr, silent = true })
    vim.keymap.set("n", "j", function()
      local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
      if cursor_line - 5 < #dirs then vim.api.nvim_win_set_cursor(winid, { cursor_line + 1, 2 }) end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "k", function()
      local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
      if cursor_line > 6 then vim.api.nvim_win_set_cursor(winid, { cursor_line - 1, 2 }) end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "h", function() close(); show_dir(vim.fn.fnamemodify(path, ":h")) end, { buffer = bufnr, silent = true })

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
      if ps.worktree_path == worktree_path then found = true; break end
    end
    if not found then
      table.insert(orphaned, {
        name = info.name, worktree_path = info.worktree_path, branch = info.branch,
        snapshot_commit = info.snapshot_commit, original_branch = info.original_branch,
        repo_root = info.repo_root, created_at = info.created_at or os.time(),
        has_terminal = false, is_orphaned = true,
      })
    end
  end

  local all_sessions = {}
  for _, s in ipairs(persisted_sessions) do table.insert(all_sessions, s) end
  for _, s in ipairs(orphaned) do table.insert(all_sessions, s) end

  local resumable = {}
  for _, s in ipairs(all_sessions) do
    local active_session = terminal.get_session(s.name)
    if not active_session or not vim.api.nvim_buf_is_valid(active_session.bufnr) then
      table.insert(resumable, s)
    end
  end

  if #resumable == 0 then vim.notify("[Vibe] No paused sessions to resume", vim.log.levels.INFO); return end
  table.sort(resumable, function(a, b) return (a.created_at or 0) > (b.created_at or 0) end)

  local lines = { " Resume Vibe Session", " " .. string.rep("─", 50) }
  for _, s in ipairs(resumable) do
    local file_count = 0
    if not git.worktrees[s.worktree_path] then git.scan_for_vibe_worktrees() end
    if git.worktrees[s.worktree_path] then file_count = #git.get_worktree_changed_files(s.worktree_path) end

    local project_name = vim.fn.fnamemodify(s.repo_root or s.cwd or "", ":t")
    if project_name == "" then project_name = "unknown" end
    local status_text = s.is_orphaned and "[orphaned]" or "[paused]"

    table.insert(lines, string.format("  %s %s", project_name, status_text))
    table.insert(lines, string.format("    Created: %s | %d file%s changed", persist.format_timestamp(s.created_at), file_count, file_count == 1 and "" or "s"))
    table.insert(lines, string.format("    %s", vim.fn.pathshorten(s.worktree_path)))
  end
  table.insert(lines, ""); table.insert(lines, " <CR> resume n new d delete q cancel")

  local bufnr, winid, close = util.create_centered_float({
    lines = lines, filetype = "viberesume", min_width = 60, title = "Vibe Resume", cursorline = true
  })

  vim.api.nvim_win_set_cursor(winid, { 3, 2 })
  vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 0, 0, -1)

  local function get_session_at_cursor()
    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
    if cursor_line < 3 then return nil, nil, nil end
    local remainder = (cursor_line - 3) % 3
    local session_line = cursor_line - remainder
    local idx = (session_line - 3) / 3 + 1
    if idx >= 1 and idx <= #resumable then return resumable[idx], idx, session_line end
    return nil, nil, nil
  end

  vim.keymap.set("n", "<CR>", function()
    local session = get_session_at_cursor()
    if session then
      close(); local resumed = terminal.resume(session)
      if resumed then terminal.show(session.name) end
    end
  end, { buffer = bufnr, silent = true })

  vim.keymap.set("n", "n", function()
    close()
    M.pick_directory(function(cwd)
      local name = vim.fn.fnamemodify(cwd, ":t")
      if name == "" then name = "root" end
      local base_name = name; local counter = 1
      while terminal.sessions[name] do name = base_name .. "_" .. counter; counter = counter + 1 end
      terminal.toggle(name, cwd)
    end)
  end, { buffer = bufnr, silent = true })

  vim.keymap.set("n", "d", function()
    local session = get_session_at_cursor()
    if session then
      local project_name = vim.fn.fnamemodify(session.repo_root or session.cwd or "", ":t")
      if vim.fn.confirm("Delete session '" .. session.name .. "' (" .. project_name .. ")?\nThis will discard all changes.", "&Yes\n&No", 2) == 1 then
        if git.worktrees[session.worktree_path] then git.remove_worktree(session.worktree_path)
        else
          persist.remove_session(session.worktree_path)
          if vim.fn.isdirectory(session.worktree_path) == 1 then vim.fn.delete(session.worktree_path, "rf") end
        end
        close(); vim.defer_fn(M.show_resume_list, 100)
      end
    end
  end, { buffer = bufnr, silent = true })

  vim.keymap.set("n", "j", function()
    local _, idx = get_session_at_cursor()
    if idx and idx < #resumable then vim.api.nvim_win_set_cursor(winid, { 3 + idx * 3, 2 }) end
  end, { buffer = bufnr, silent = true })

  vim.keymap.set("n", "k", function()
    local _, idx = get_session_at_cursor()
    if idx and idx > 1 then vim.api.nvim_win_set_cursor(winid, { 3 + (idx - 2) * 3, 2 }) end
  end, { buffer = bufnr, silent = true })
end

return M
