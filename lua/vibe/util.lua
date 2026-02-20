local M = {}

--- Helper to create a centered floating window with common options
---@param opts table
---@return integer bufnr, integer winid, function close_fn
function M.create_centered_float(opts)
  local lines = opts.lines or {}
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].filetype = opts.filetype or "vibe_float"

  if #lines > 0 then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end

  local width = opts.min_width or 40
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  
  -- Calculate height (fallback to opts.height if lines are populated dynamically later)
  local height = opts.height or math.min(math.max(1, #lines), opts.max_height or 25)

  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win_opts = {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = opts.border or "rounded",
    zindex = opts.zindex or 60,
  }

  if opts.title then
    win_opts.title = " " .. opts.title .. " "
    win_opts.title_pos = "center"
  end

  local winid = vim.api.nvim_open_win(bufnr, true, win_opts)
  vim.wo[winid].winblend = 0
  if opts.cursorline then
    vim.wo[winid].cursorline = true
  end

  local close = function()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end

  -- Default close keymaps
  vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, silent = true })

  return bufnr, winid, close
end

--- Shared logic to check for remaining files
---@param worktree_path string
function M.check_remaining_files(worktree_path)
  local git = require("vibe.git")
  local files = git.get_unresolved_files(worktree_path)

  if #files == 0 then
    local info = git.get_worktree_info(worktree_path)
    local manual_files = {}
    if info and info.manually_modified_files then
      for f, _ in pairs(info.manually_modified_files) do table.insert(manual_files, f) end
      info.manually_modified_files = {} -- clear after reporting
    end

    if #manual_files > 0 then
      local lines = {
        " Review Complete",
        " " .. string.rep("─", 50),
        "",
        " All changes resolved! Agent may continue working.",
        "",
        " NOTE: You made manual edits to the following files",
        " that the agent does not know about yet. You should",
        " consider telling the agent what you modified:",
        ""
      }
      for _, f in ipairs(manual_files) do table.insert(lines, "  • " .. f) end
      table.insert(lines, "")
      table.insert(lines, " <CR>/q close")

      local bufnr, winid, close = M.create_centered_float({
        lines = lines, filetype = "vibe_notification", min_width = 60
      })
      vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 0, 0, -1)
      vim.api.nvim_buf_add_highlight(bufnr, -1, "WarningMsg", 5, 0, -1)
      
      vim.keymap.set("n", "<CR>", close, { buffer = bufnr, silent = true })
      vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true })
    else
      vim.notify("[Vibe] All current changes resolved. Agent may continue working.", vim.log.levels.INFO)
    end

    -- Only show review list if there are OTHER sessions with unresolved changes
    vim.defer_fn(function()
      local all_worktrees = git.get_worktrees_with_changes()
      local has_other_sessions = false
      for _, info2 in ipairs(all_worktrees) do
        if info2.worktree_path ~= worktree_path then
          local unresolved = git.get_unresolved_files(info2.worktree_path)
          if #unresolved > 0 then
            has_other_sessions = true
            break
          end
        end
      end

      if has_other_sessions then
        require("vibe.session").show_review_list()
      end
    end, 200)
    return
  end

  -- Show dialog with remaining unresolved files
  vim.defer_fn(function()
    require("vibe.dialog").show(worktree_path)
  end, 200)
end

return M
