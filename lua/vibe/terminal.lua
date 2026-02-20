local config = require("vibe.config")
local status = require("vibe.status")
local git = require("vibe.git")
local persist = require("vibe.persist")

local M = {}

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
  if opts.on_open == "none" then return end
  if opts.on_open == "save_current" then
    if vim.bo.modified then vim.cmd("write") end
  else
    vim.cmd("wall")
  end
end

--- Reload buffers from disk
local function reload_buffers()
  if config.options.on_close == "none" then return end
  vim.cmd("checktime")
end

---@param name string|nil
---@param cwd string|nil Working directory for the session (user's repo)
---@return TerminalSession|nil
function M.get_or_create(name, cwd)
  name = name or "default"

  if M.sessions[name] and vim.api.nvim_buf_is_valid(M.sessions[name].bufnr) then
    return M.sessions[name]
  end

  cwd = cwd or vim.fn.getcwd()

  local worktree_info, err = git.create_worktree(name, cwd)
  if not worktree_info then
    vim.notify("[Vibe] Failed to create worktree: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return nil
  end

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
        if exit_code ~= 0 then
          vim.notify(string.format("[Vibe] Command exited with code %d", exit_code), vim.log.levels.WARN)
        end
        if M.sessions[name] then
          M.sessions[name] = nil
          status.hide()
          persist.save_session({
            name = name,
            worktree_path = worktree_info.worktree_path,
            branch = worktree_info.branch,
            snapshot_commit = worktree_info.snapshot_commit,
            original_branch = worktree_info.original_branch,
            repo_root = worktree_info.repo_root,
            cwd = cwd,
            created_at = worktree_info.created_at,
            last_active = os.time(),
            has_terminal = false,
          })
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

  status.show()
  return session
end

---@param name string|nil
---@param cwd string|nil Working directory (only used for new sessions)
function M.show(name, cwd)
  name = name or "default"
  local session = M.get_or_create(name, cwd)
  if not session then return end

  save_buffers()
  local window = require("vibe.window")
  session.winid = window.create(session.bufnr)
  vim.cmd("startinsert")
  M.current_session = name
end

---@param name string|nil
function M.hide(name)
  name = name or M.current_session or "default"
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
  local name = M.current_session
  if name and M.sessions[name] then M.sessions[name].winid = nil end
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
    if session.job_id then vim.fn.jobstop(session.job_id) end
    if vim.api.nvim_buf_is_valid(session.bufnr) then
      vim.api.nvim_buf_delete(session.bufnr, { force = true })
    end
    if session.worktree_path then
      git.remove_worktree(session.worktree_path)
    end

    M.sessions[name] = nil
    if M.current_session == name then M.current_session = nil end

    status.hide()
  end
end

--- Resume a session from persistence
---@param persisted_session PersistedSession
---@return TerminalSession|nil
function M.resume(persisted_session)
  if not persisted_session or not persisted_session.worktree_path then return nil end

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
        if exit_code ~= 0 then
          vim.notify(string.format("[Vibe] Command exited with code %d", exit_code), vim.log.levels.WARN)
        end
        if M.sessions[name] then
          M.sessions[name] = nil
          status.hide()
          persist.save_session({
            name = name,
            worktree_path = persisted_session.worktree_path,
            branch = persisted_session.branch,
            snapshot_commit = persisted_session.snapshot_commit,
            original_branch = persisted_session.original_branch,
            repo_root = persisted_session.repo_root,
            cwd = persisted_session.cwd,
            created_at = persisted_session.created_at,
            last_active = os.time(),
            has_terminal = false,
          })
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

  persist.save_session(vim.tbl_extend("force", persisted_session, { has_terminal = true }))

  status.show()
  return session
end

function M.get_session(name)
  return M.sessions[name]
end

return M
