local config = require("vibe.config")
local git = require("vibe.git")
local dialog = require("vibe.dialog")
local conflict_popup = require("vibe.conflict_popup")
local util = require("vibe.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("vibe_diff")
M.buffer_hunks = {}
M.buffer_worktree = {}
M.buffer_filepath = {}

function M.classify_user_additions(hunks, worktree_path, filepath, user_file_path)
  if config.options.diff.review_user_additions == false then
    for _, hunk in ipairs(hunks) do hunk.user_added_indices = {} end
    return hunks
  end

  local user_added_lines = git.get_user_added_lines(worktree_path, filepath, user_file_path)
  if vim.tbl_isempty(user_added_lines) then
    for _, hunk in ipairs(hunks) do hunk.user_added_indices = {} end
    return hunks
  end

  for _, hunk in ipairs(hunks) do
    hunk.user_added_indices = {}
    for i = 1, #hunk.removed_lines do
      local line_num = hunk.old_start + i - 1
      if user_added_lines[line_num] then
        table.insert(hunk.user_added_indices, i)
      end
    end
  end

  return hunks
end

function M.has_overlap(hunk)
  local has_user_additions = #(hunk.user_added_indices or {}) > 0
  local ai_deletions = #(hunk.removed_lines or {}) - #(hunk.user_added_indices or {})
  local has_ai_changes = #(hunk.added_lines or {}) > 0 or ai_deletions > 0
  return has_user_additions and has_ai_changes
end

function M.show_for_file(worktree_path, filepath, review_mode)
  review_mode = review_mode or "manual"
  local bufnr = vim.api.nvim_get_current_buf()
  local user_file_path = vim.api.nvim_buf_get_name(bufnr)

  M.clear(bufnr)
  -- Still needed for diff.lua virtual text mode, though the actual review process relies on conflict_buffer
  local hunks = git.get_worktree_file_hunks(worktree_path, filepath, user_file_path)
  hunks = M.classify_user_additions(hunks, worktree_path, filepath, user_file_path)

  if #hunks == 0 then
    vim.notify("[Vibe] No changes in this file", vim.log.levels.INFO)
    util.check_remaining_files(worktree_path)
    return
  end

  if config.options.diff.raw_mode then
    require("vibe.conflict_buffer").show_file_with_conflicts(worktree_path, filepath, hunks, review_mode)
    return
  end

  require("vibe.collapsed_conflict").show_file_with_collapsed_conflicts(worktree_path, filepath, hunks, review_mode)
end

function M.show_for_current_file()
  local worktree_path = dialog.get_current_worktree()
  if not worktree_path then
    local worktrees = git.get_worktrees_with_changes()
    if #worktrees == 0 then
      vim.notify("[Vibe] No sessions with changes", vim.log.levels.INFO)
      return
    end
    worktree_path = worktrees[1].worktree_path
  end

  local info = git.get_worktree_info(worktree_path)
  if not info then return end

  local bufnr = vim.api.nvim_get_current_buf()
  local full_path = vim.api.nvim_buf_get_name(bufnr)
  local filepath = full_path:gsub("^" .. vim.pesc(info.repo_root) .. "/", "")
  
  if filepath == full_path then
    vim.notify("[Vibe] File not in repository", vim.log.levels.WARN)
    return
  end
  M.show_for_file(worktree_path, filepath, "manual")
end

function M.render(bufnr)
  local hunks = M.buffer_hunks[bufnr]
  if not hunks or #hunks == 0 then return end

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for hunk_idx, hunk in ipairs(hunks) do
    local row = math.max(0, hunk.old_start - 1)
    row = math.min(row, math.max(0, line_count - 1))

    if M.has_overlap(hunk) then
      local total_lines = hunk.old_count + #hunk.added_lines
      local conflict_text = string.format("<<<<<<< CONFLICT: %d lines affected (cursor here to resolve) >>>>>>>", total_lines)

      vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
        id = hunk_idx * 1000,
        virt_text = { { conflict_text, "VibeConflictCollapsed" } },
        virt_text_pos = "overlay",
        hl_mode = "combine",
        priority = 200,
      })

      if hunk.old_start > 0 and hunk.old_start <= line_count then
        vim.fn.sign_place(0, "vibe_diff", "VibeDiffConflict", bufnr, { lnum = hunk.old_start })
      end
    else
      if #hunk.added_lines > 0 then
        local virt_lines = {}
        for _, line in ipairs(hunk.added_lines) do
          table.insert(virt_lines, { { "+ " .. line, "DiffAdd" } })
        end

        local ok, _ = pcall(function()
          hunk.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
            id = hunk_idx * 1000,
            virt_lines = virt_lines,
            virt_lines_above = false,
            priority = 100,
          })
        end)
        if not ok and line_count > 0 then
          hunk.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, M.ns, line_count - 1, 0, {
            id = hunk_idx * 1000,
            virt_lines = virt_lines,
            virt_lines_above = true,
            priority = 100,
          })
        end
      end

      if #hunk.removed_lines > 0 then
        local user_added_set = {}
        for _, idx in ipairs(hunk.user_added_indices or {}) do user_added_set[idx] = true end

        for i, line in ipairs(hunk.removed_lines) do
          local del_row = row + i - 1
          if del_row >= 0 and del_row < line_count then
            local is_user_addition = user_added_set[i]
            local prefix = is_user_addition and "+~ " or "− "
            local hl_group = is_user_addition and "VibeUserAddition" or "DiffDelete"

            vim.api.nvim_buf_set_extmark(bufnr, M.ns, del_row, 0, {
              id = hunk_idx * 10000 + i,
              virt_text = { { prefix .. line, hl_group } },
              virt_text_pos = "eol",
              priority = 100,
            })
          end
        end
      end

      if hunk.old_start > 0 and hunk.old_start <= line_count then
        vim.fn.sign_place(0, "vibe_diff", "VibeDiffHunk", bufnr, { lnum = hunk.old_start })
      end
    end
  end
end

function M.clear(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  vim.fn.sign_unplace("vibe_diff", { buffer = bufnr })
  M.buffer_hunks[bufnr] = nil
  M.buffer_worktree[bufnr] = nil
  M.buffer_filepath[bufnr] = nil

  if conflict_popup.is_visible() then conflict_popup.close() end
end

function M.get_hunk_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = M.buffer_hunks[bufnr]
  if not hunks or #hunks == 0 then return nil, nil end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  for idx, hunk in ipairs(hunks) do
    if hunk.old_start == 0 then
      local hunk_end = #hunk.added_lines
      if cursor_line >= 1 and cursor_line <= hunk_end + 1 then
        return hunk, idx
      end
    else
      local hunk_start = hunk.old_start
      local hunk_end = hunk_start + math.max(hunk.old_count, 1) + #hunk.added_lines
      if cursor_line >= hunk_start and cursor_line <= hunk_end then
        return hunk, idx
      end
    end
  end
  return nil, nil
end

local function process_hunk_action(git_action_fn, action_name, success_msg)
  local bufnr = vim.api.nvim_get_current_buf()
  local worktree_path = M.buffer_worktree[bufnr]
  local filepath = M.buffer_filepath[bufnr]
  local user_file_path = vim.api.nvim_buf_get_name(bufnr)

  if not worktree_path or not filepath then return end

  local hunk, _ = M.get_hunk_at_cursor()
  if not hunk then return end

  local ok, err = git_action_fn(worktree_path, filepath, hunk, user_file_path)
  if not ok then
    vim.notify("[Vibe] Failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end

  git.mark_hunk_addressed(worktree_path, filepath, hunk, action_name)
  M.clear(bufnr)
  vim.cmd("checktime")

  if git.is_file_fully_addressed(worktree_path, filepath) then
    vim.fn.mkdir(vim.fn.fnamemodify(user_file_path, ":h"), "p")
    vim.cmd("write")
    git.sync_resolved_file(worktree_path, filepath, user_file_path)
    util.check_remaining_files(worktree_path)
  else
    local new_hunks = git.get_worktree_file_hunks(worktree_path, filepath, user_file_path)
    if new_hunks and #new_hunks > 0 then
      local info = git.get_worktree_info(worktree_path)
      local addressed_hashes = {}
      if info and info.addressed_hunks then
        for _, addressed in ipairs(info.addressed_hunks) do
          if addressed.filepath == filepath then addressed_hashes[addressed.hunk_hash] = true end
        end
      end

      local unaddressed_hunks = {}
      for _, h in ipairs(new_hunks) do
        if not addressed_hashes[git.hunk_hash(h)] then table.insert(unaddressed_hunks, h) end
      end

      if #unaddressed_hunks > 0 then
        unaddressed_hunks = M.classify_user_additions(unaddressed_hunks, worktree_path, filepath, user_file_path)
        M.buffer_hunks[bufnr] = unaddressed_hunks
        M.buffer_worktree[bufnr] = worktree_path
        M.buffer_filepath[bufnr] = filepath
        M.render(bufnr)
      else
        vim.fn.mkdir(vim.fn.fnamemodify(user_file_path, ":h"), "p")
        vim.cmd("write")
        git.sync_resolved_file(worktree_path, filepath, user_file_path)
        util.check_remaining_files(worktree_path)
      end
    else
      vim.fn.mkdir(vim.fn.fnamemodify(user_file_path, ":h"), "p")
      vim.cmd("write")
      git.sync_resolved_file(worktree_path, filepath, user_file_path)
      util.check_remaining_files(worktree_path)
    end
  end

  vim.notify("[Vibe] " .. success_msg, vim.log.levels.INFO)
end

function M.accept_hunk() process_hunk_action(git.accept_hunk_from_worktree, "accepted", "Hunk accepted") end
function M.reject_hunk() process_hunk_action(git.reject_hunk_from_worktree, "rejected", "Hunk rejected") end

function M.accept_all_in_file()
  local bufnr = vim.api.nvim_get_current_buf()
  local worktree_path = M.buffer_worktree[bufnr]
  local filepath = M.buffer_filepath[bufnr]
  local user_file_path = vim.api.nvim_buf_get_name(bufnr)

  if not worktree_path or not filepath then return end

  local hunks = vim.deepcopy(M.buffer_hunks[bufnr] or {})
  hunks = M.classify_user_additions(hunks, worktree_path, filepath, user_file_path)
  table.sort(hunks, function(a, b) return a.old_start > b.old_start end)

  for _, hunk in ipairs(hunks) do
    local ok, _ = git.accept_hunk_from_worktree(worktree_path, filepath, hunk, user_file_path)
    if ok then git.mark_hunk_addressed(worktree_path, filepath, hunk, "accepted") end
  end

  M.clear(bufnr)
  vim.cmd("checktime")
  vim.fn.mkdir(vim.fn.fnamemodify(user_file_path, ":h"), "p")
  vim.cmd("write")
  git.sync_resolved_file(worktree_path, filepath, user_file_path)
  
  vim.notify("[Vibe] All hunks in file accepted", vim.log.levels.INFO)
  util.check_remaining_files(worktree_path)
end

function M.reject_all_in_file()
  local bufnr = vim.api.nvim_get_current_buf()
  local worktree_path = M.buffer_worktree[bufnr]
  local filepath = M.buffer_filepath[bufnr]

  if not worktree_path or not filepath then return end

  if M.buffer_hunks[bufnr] then
    for _, hunk in ipairs(M.buffer_hunks[bufnr]) do
      git.mark_hunk_addressed(worktree_path, filepath, hunk, "rejected")
    end
  end

  M.clear(bufnr)
  git.reject_file_from_worktree(worktree_path, filepath)
  vim.fn.mkdir(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":h"), "p")
  vim.cmd("write")
  git.sync_resolved_file(worktree_path, filepath, vim.api.nvim_buf_get_name(bufnr))
  
  vim.notify("[Vibe] All hunks in file rejected", vim.log.levels.INFO)
  util.check_remaining_files(worktree_path)
end

function M.prev_hunk()
  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = M.buffer_hunks[bufnr]
  if not hunks or #hunks == 0 then return end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local target = nil
  for i = #hunks, 1, -1 do
    if hunks[i].old_start < cursor_line then
      target = hunks[i]; break
    end
  end
  if not target then target = hunks[#hunks] end
  vim.api.nvim_win_set_cursor(0, { target.old_start, 0 })
end

function M.next_hunk()
  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = M.buffer_hunks[bufnr]
  if not hunks or #hunks == 0 then return end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local target = nil
  for _, hunk in ipairs(hunks) do
    if hunk.old_start > cursor_line then
      target = hunk; break
    end
  end
  if not target then target = hunks[1] end
  vim.api.nvim_win_set_cursor(0, { target.old_start, 0 })
end

function M.setup_keymaps(bufnr)
  local keymaps = config.options.diff.keymaps
  local opts = { buffer = bufnr, silent = true, noremap = true }

  if keymaps.accept_hunk then vim.keymap.set("n", keymaps.accept_hunk, M.accept_hunk, vim.tbl_extend("force", opts, { desc = "Accept hunk" })) end
  if keymaps.reject_hunk then vim.keymap.set("n", keymaps.reject_hunk, M.reject_hunk, vim.tbl_extend("force", opts, { desc = "Reject hunk" })) end
  if keymaps.accept_all then vim.keymap.set("n", keymaps.accept_all, M.accept_all_in_file, vim.tbl_extend("force", opts, { desc = "Accept all in file" })) end
  if keymaps.reject_all then vim.keymap.set("n", keymaps.reject_all, M.reject_all_in_file, vim.tbl_extend("force", opts, { desc = "Reject all in file" })) end
  if keymaps.prev_hunk then vim.keymap.set("n", keymaps.prev_hunk, M.prev_hunk, vim.tbl_extend("force", opts, { desc = "Previous hunk" })) end
  if keymaps.next_hunk then vim.keymap.set("n", keymaps.next_hunk, M.next_hunk, vim.tbl_extend("force", opts, { desc = "Next hunk" })) end

  vim.keymap.set("n", "q", function()
    local wt = M.buffer_worktree[bufnr]
    M.clear(bufnr)
    if wt then dialog.show(wt) end
  end, vim.tbl_extend("force", opts, { desc = "Back to file list" }))

  if config.options.diff.conflict_popup.enabled then M.setup_conflict_tracking(bufnr) end
end

function M.setup_conflict_tracking(bufnr)
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = bufnr,
    callback = function()
      local hunk, idx = M.get_hunk_at_cursor()
      if hunk and M.has_overlap(hunk) then
        if not conflict_popup.is_visible() then conflict_popup.show(bufnr, hunk, idx) end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = bufnr,
    callback = function()
      if conflict_popup.is_visible() then conflict_popup.close() end
    end,
  })
end

function M.setup()
  vim.fn.sign_define("VibeDiffHunk", { text = "│", texthl = "WarningMsg" })
  vim.fn.sign_define("VibeDiffConflict", { text = "!", texthl = "ErrorMsg" })
  vim.api.nvim_set_hl(0, "VibeUserAddition", { fg = "#00CED1", bold = true, default = true })
  vim.api.nvim_set_hl(0, "VibeConflictCollapsed", { bg = "#8B0000", fg = "#FFFFFF", bold = true, default = true })

  dialog.setup_highlights()
  conflict_popup.setup()
  require("vibe.collapsed_conflict").setup()
end

return M
