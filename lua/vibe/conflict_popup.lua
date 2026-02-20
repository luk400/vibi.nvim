local M = {}

local config = require("vibe.config")
local git = require("vibe.git")
local diff = nil

local function get_diff()
  if not diff then diff = require("vibe.diff") end
  return diff
end

M.ns = vim.api.nvim_create_namespace("vibe_conflict_popup")

M.popup_bufnr = nil
M.popup_winnr = nil
M.source_winnr = nil 
M.source_bufnr = nil 
M.current_hunk = nil
M.current_hunk_idx = nil

function M.setup_highlights()
  vim.api.nvim_set_hl(0, "VibeConflictBorder", { link = "FloatBorder", default = true })
  vim.api.nvim_set_hl(0, "VibeConflictTitle", { link = "ErrorMsg", default = true })
  vim.api.nvim_set_hl(0, "VibeConflictUserAdd", { fg = "#00CED1", default = true })
  vim.api.nvim_set_hl(0, "VibeConflictAIAdd", { fg = "#22C55E", default = true })
  vim.api.nvim_set_hl(0, "VibeConflictAIDel", { fg = "#F44747", default = true })
  vim.api.nvim_set_hl(0, "VibeConflictSection", { link = "Title", default = true })
end

local function get_user_addition_lines(hunk)
  local lines = {}
  local user_added_set = {}
  for _, idx in ipairs(hunk.user_added_indices or {}) do user_added_set[idx] = true end
  for i, line in ipairs(hunk.removed_lines) do
    if user_added_set[i] then table.insert(lines, line) end
  end
  return lines
end

local function get_ai_addition_lines(hunk)
  return vim.deepcopy(hunk.added_lines or {})
end

local function get_ai_deletion_lines(hunk)
  local lines = {}
  local user_added_set = {}
  for _, idx in ipairs(hunk.user_added_indices or {}) do user_added_set[idx] = true end
  for i, line in ipairs(hunk.removed_lines) do
    if not user_added_set[i] then table.insert(lines, line) end
  end
  return lines
end

local function build_popup_content(hunk)
  local conf = config.options.diff.conflict_popup
  local lines, highlights = {}, {}

  table.insert(lines, "  CONFLICT: User vs AI")
  table.insert(highlights, { line = #lines - 1, hl = "VibeConflictTitle" })
  table.insert(lines, string.rep("─", conf.width - 2))

  local user_adds = get_user_addition_lines(hunk)
  table.insert(lines, "  YOUR CHANGES:")
  table.insert(highlights, { line = #lines - 1, hl = "VibeConflictSection" })

  if #user_adds > 0 then
    for _, line in ipairs(user_adds) do
      local display_line = "  +~ " .. line
      if #display_line > conf.width - 2 then display_line = display_line:sub(1, conf.width - 5) .. "..." end
      table.insert(lines, display_line)
      table.insert(highlights, { line = #lines - 1, hl = "VibeConflictUserAdd" })
    end
  else
    table.insert(lines, "  (no user additions)")
  end

  table.insert(lines, "")
  local ai_adds = get_ai_addition_lines(hunk)
  local ai_dels = get_ai_deletion_lines(hunk)

  table.insert(lines, "  AI'S CHANGES:")
  table.insert(highlights, { line = #lines - 1, hl = "VibeConflictSection" })

  if #ai_adds > 0 or #ai_dels > 0 then
    for _, line in ipairs(ai_dels) do
      local display_line = "  - " .. line
      if #display_line > conf.width - 2 then display_line = display_line:sub(1, conf.width - 5) .. "..." end
      table.insert(lines, display_line)
      table.insert(highlights, { line = #lines - 1, hl = "VibeConflictAIDel" })
    end
    for _, line in ipairs(ai_adds) do
      local display_line = "  + " .. line
      if #display_line > conf.width - 2 then display_line = display_line:sub(1, conf.width - 5) .. "..." end
      table.insert(lines, display_line)
      table.insert(highlights, { line = #lines - 1, hl = "VibeConflictAIAdd" })
    end
  else
    table.insert(lines, "  (no AI changes)")
  end

  table.insert(lines, "")
  table.insert(lines, string.rep("─", conf.width - 2))

  local keymaps = conf.keymaps
  table.insert(lines, string.format(
    "  [%s] user   [%s] ai   [%s] both   [%s] none   [%s] close",
    keymaps.accept_user, keymaps.accept_ai, keymaps.accept_both, keymaps.accept_none, keymaps.close
  ))

  return lines, highlights
end

local function calculate_position(height)
  local conf = config.options.diff.conflict_popup
  local win_height = vim.api.nvim_win_get_height(0)
  local win_width = vim.api.nvim_win_get_width(0)

  local row = math.max(0, math.floor((win_height - height) / 2))
  local col = math.max(0, math.floor((win_width - conf.width) / 2))

  return row, col
end

function M.show(bufnr, hunk, hunk_idx)
  local conf = config.options.diff.conflict_popup
  if not conf.enabled then return end

  M.close()
  M.current_hunk = hunk
  M.current_hunk_idx = hunk_idx
  M.source_bufnr = bufnr
  M.source_winnr = vim.api.nvim_get_current_win()

  local lines, highlights = build_popup_content(hunk)
  M.popup_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.popup_bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(M.popup_bufnr, "filetype", "vibe-conflict")
  vim.api.nvim_buf_set_lines(M.popup_bufnr, 0, -1, false, lines)

  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(M.popup_bufnr, M.ns, hl.hl, hl.line, 0, -1)
  end

  local height = math.min(#lines, conf.max_height)
  local row, col = calculate_position(height)

  M.popup_winnr = vim.api.nvim_open_win(M.popup_bufnr, true, {
    relative = "win",
    win = M.source_winnr,
    row = row,
    col = col,
    width = conf.width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Vibe Conflict ",
    title_pos = "center",
    zindex = 100,
  })
  
  vim.api.nvim_win_set_option(M.popup_winnr, "winhl", "FloatBorder:VibeConflictBorder")
  vim.api.nvim_win_set_option(M.popup_winnr, "cursorline", true)

  M.setup_keymaps()
end

function M.close()
  if M.source_winnr and vim.api.nvim_win_is_valid(M.source_winnr) then
    vim.api.nvim_set_current_win(M.source_winnr)
  end

  if M.popup_winnr and vim.api.nvim_win_is_valid(M.popup_winnr) then
    vim.api.nvim_win_close(M.popup_winnr, true)
  end

  M.popup_winnr = nil
  M.popup_bufnr = nil
  M.current_hunk = nil
  M.current_hunk_idx = nil
  M.source_winnr = nil
  M.source_bufnr = nil
end

local function apply_resolution(resolve_fn, action_name, msg)
  if not M.current_hunk or not M.source_bufnr then
    M.close()
    return
  end

  local diff_mod = get_diff()
  local worktree_path = diff_mod.buffer_worktree[M.source_bufnr]
  local filepath = diff_mod.buffer_filepath[M.source_bufnr]
  local user_file_path = vim.api.nvim_buf_get_name(M.source_bufnr)

  if not worktree_path or not filepath then
    vim.notify("[Vibe] No diff context", vim.log.levels.WARN)
    M.close()
    return
  end

  local ok, err = resolve_fn(worktree_path, filepath, M.current_hunk, user_file_path)
  if not ok then
    vim.notify("[Vibe] Failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
    M.close()
    return
  end

  git.mark_hunk_addressed(worktree_path, filepath, M.current_hunk, action_name)
  M.close()

  vim.cmd("checktime")
  vim.notify("[Vibe] " .. msg, vim.log.levels.INFO)

  require("vibe.util").check_remaining_files(worktree_path)
end

function M.accept_user() apply_resolution(git.reject_hunk_from_worktree, "user", "Accepted your version") end
function M.accept_ai() apply_resolution(git.accept_hunk_from_worktree, "ai", "Accepted AI's version") end
function M.accept_both() apply_resolution(git.keep_both_hunk, "both", "Kept both versions") end
function M.accept_none() apply_resolution(git.delete_hunk_range, "none", "Removed all changes") end

function M.setup_keymaps()
  if not M.popup_bufnr then return end
  local keymaps = config.options.diff.conflict_popup.keymaps
  local opts = { buffer = M.popup_bufnr, silent = true, noremap = true }

  vim.keymap.set("n", keymaps.accept_user, M.accept_user, vim.tbl_extend("force", opts, { desc = "Accept user" }))
  vim.keymap.set("n", keymaps.accept_ai, M.accept_ai, vim.tbl_extend("force", opts, { desc = "Accept AI" }))
  vim.keymap.set("n", keymaps.accept_both, M.accept_both, vim.tbl_extend("force", opts, { desc = "Accept both" }))
  vim.keymap.set("n", keymaps.accept_none, M.accept_none, vim.tbl_extend("force", opts, { desc = "Accept none" }))
  vim.keymap.set("n", keymaps.close, M.close, vim.tbl_extend("force", opts, { desc = "Close" }))
  vim.keymap.set("n", "<Esc>", M.close, vim.tbl_extend("force", opts, { desc = "Close" }))
  vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "Close" }))
end

function M.is_visible()
  return M.popup_winnr ~= nil and vim.api.nvim_win_is_valid(M.popup_winnr)
end

function M.setup()
  M.setup_highlights()
end

return M
