local git = require("vibe.git")
local config = require("vibe.config")
local util = require("vibe.util")

local M = {}

---@type integer|nil
M.dialog_bufnr = nil

---@type integer|nil
M.dialog_winid = nil

---@type string[] Changed files
M.changed_files = {}

---@type integer Current selection index
M.selected_idx = 1

---@type string|nil Current worktree path being reviewed
M.current_worktree_path = nil

---@type string|nil Current session name being reviewed
M.current_session_name = nil

---@type string
M.review_mode = "manual"

---@type table<string, {added: integer, removed: integer}> Per-file hunk stats cache
M.hunk_cache = {}

--- Open the modified files dialog for a worktree
---@param worktree_path string|nil The worktree to review (uses first available if nil)
---@param worktree_info table|nil Optional worktree info (avoids lookup)
---@param review_mode string|nil Mode for reviewing ("auto" or "manual")
function M.show(worktree_path, worktree_info, review_mode)
	M.close()

	-- Full state reset before any early returns
	M.changed_files = {}
	M.selected_idx = 1
	M.review_mode = review_mode or "manual"
	M.current_worktree_path = nil
	M.current_session_name = nil

	if not worktree_path then
		local worktrees = git.get_worktrees_with_changes()
		if #worktrees == 0 then
			vim.notify("[Vibe] No sessions with changes to review", vim.log.levels.INFO)
			return
		end
		worktree_path = worktrees[1].worktree_path
		worktree_info = worktrees[1]
	end

	local info = worktree_info or git.get_worktree_info(worktree_path)
	if not info then
		vim.notify("[Vibe] Worktree info lost, scanning...", vim.log.levels.WARN)
		git.scan_for_vibe_worktrees()
		info = git.get_worktree_info(worktree_path)
		if not info then
			vim.notify("[Vibe] Worktree not found: " .. tostring(worktree_path), vim.log.levels.ERROR)
			return
		end
	end

	M.current_worktree_path = worktree_path
	M.current_session_name = info.name
	M.changed_files = git.get_unresolved_files(worktree_path)
	M.hunk_cache = {}
	for _, file in ipairs(M.changed_files) do
		local user_file_path = info.repo_root .. "/" .. file
		local ok, hunks = pcall(git.get_worktree_file_hunks, worktree_path, file, user_file_path)
		if ok and hunks then
			local added, removed = 0, 0
			for _, hunk in ipairs(hunks) do
				added = added + #(hunk.added_lines or {})
				removed = removed + #(hunk.removed_lines or {})
			end
			M.hunk_cache[file] = { added = added, removed = removed }
		end
	end

	if #M.changed_files == 0 then
		vim.notify("[Vibe] No unresolved files in this session", vim.log.levels.INFO)
		M.current_worktree_path = nil
		M.current_session_name = nil
		return
	end

	local target_height = math.min(20, #M.changed_files + 6)

	local bufnr, winid, close = util.create_centered_float({
		filetype = "vibe_dialog",
		min_width = math.max(60, math.floor(vim.o.columns * 0.5)),
		height = target_height,
		title = "Vibe: Modified Files (" .. info.name .. ")",
		cursorline = true,
		zindex = 200,
		no_default_keymaps = true,
	})

	M.dialog_bufnr = bufnr
	M.dialog_winid = winid
	M.selected_idx = 1
	vim.wo[winid].wrap = false

	M.render()
	M.setup_keymaps()
end

function M.close()
	if M.dialog_winid and vim.api.nvim_win_is_valid(M.dialog_winid) then
		vim.api.nvim_win_close(M.dialog_winid, true)
	end
	M.dialog_winid = nil
	M.dialog_bufnr = nil
	M.selected_idx = 1
	M.current_worktree_path = nil
	M.current_session_name = nil
end

function M.is_open()
	return M.dialog_winid ~= nil and vim.api.nvim_win_is_valid(M.dialog_winid)
end

function M.render()
	if not M.dialog_bufnr then
		return
	end

	local lines = {}
	local mode_label = M.review_mode == "auto" and " (Auto-Merge Mode)" or ""
	table.insert(lines, "Files modified by AI" .. mode_label .. ":")
	table.insert(lines, "")

	for i, file in ipairs(M.changed_files) do
		local prefix = i == M.selected_idx and "▶ " or "  "
		local stats = M.hunk_cache[file]
		local suffix = ""
		if stats then
			suffix = string.format("  +%d -%d", stats.added, stats.removed)
		end
		table.insert(lines, prefix .. file .. suffix)
	end

	table.insert(lines, "")
	table.insert(
		lines,
		"────────────────────────────────────────"
	)
	table.insert(lines, "<CR> view file  │  A accept all  │  q back")

	vim.bo[M.dialog_bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(M.dialog_bufnr, 0, -1, false, lines)
	vim.bo[M.dialog_bufnr].modifiable = false

	for i, _ in ipairs(M.changed_files) do
		local line_idx = i + 1
		if i == M.selected_idx then
			vim.api.nvim_buf_add_highlight(M.dialog_bufnr, -1, "VibeDialogSelected", line_idx, 0, -1)
		else
			vim.api.nvim_buf_add_highlight(M.dialog_bufnr, -1, "VibeDialogFile", line_idx, 0, -1)
		end
	end

	vim.api.nvim_buf_add_highlight(M.dialog_bufnr, -1, "VibeDialogHeader", 0, 0, -1)
	local footer_start = #M.changed_files + 3
	vim.api.nvim_buf_add_highlight(M.dialog_bufnr, -1, "VibeDialogFooter", footer_start, 0, -1)
	vim.api.nvim_buf_add_highlight(M.dialog_bufnr, -1, "VibeDialogFooter", footer_start + 1, 0, -1)
end

function M.setup_keymaps()
	local opts = { buffer = M.dialog_bufnr, silent = true, noremap = true }

	vim.keymap.set("n", "j", function()
		if M.selected_idx < #M.changed_files then
			M.selected_idx = M.selected_idx + 1
			M.render()
		end
	end, opts)

	vim.keymap.set("n", "k", function()
		if M.selected_idx > 1 then
			M.selected_idx = M.selected_idx - 1
			M.render()
		end
	end, opts)

	vim.keymap.set("n", "<Down>", function()
		if M.selected_idx < #M.changed_files then
			M.selected_idx = M.selected_idx + 1
			M.render()
		end
	end, opts)

	vim.keymap.set("n", "<Up>", function()
		if M.selected_idx > 1 then
			M.selected_idx = M.selected_idx - 1
			M.render()
		end
	end, opts)

	vim.keymap.set("n", "<CR>", M.jump_to_file, opts)
	vim.keymap.set("n", "A", M.accept_all, opts)
	local function back_to_review()
		M.close()
		require("vibe.session").show_review_list()
	end
	vim.keymap.set("n", "q", back_to_review, opts)
	vim.keymap.set("n", "<Esc>", back_to_review, opts)
end

function M.jump_to_file()
	if #M.changed_files == 0 then
		return
	end
	local file = M.changed_files[M.selected_idx]
	if not file then
		return
	end

	local worktree_path = M.current_worktree_path
	local info = git.get_worktree_info(worktree_path)
	if not info then
		vim.notify("[Vibe] Worktree info lost", vim.log.levels.ERROR)
		return
	end

	M.close()

	local user_file_path = info.repo_root .. "/" .. file

	-- Create directory if the file is completely new to avoid errors
	local dir = vim.fn.fnamemodify(user_file_path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end

	vim.cmd("edit " .. vim.fn.fnameescape(user_file_path))

	local diff = require("vibe.diff")
	diff.show_for_file(worktree_path, file, M.review_mode)
end

function M.accept_all()
	if not M.current_worktree_path then
		return
	end
	local file_count = #M.changed_files
	if vim.fn.confirm(
		string.format("Accept ALL changes in %d file(s)? This cannot be undone.", file_count),
		"&Yes\n&No",
		2
	) ~= 1 then
		return
	end
	local ok, err = git.accept_all_from_worktree(M.current_worktree_path)
	if not ok then
		vim.notify("[Vibe] Failed to accept all: " .. (err or "unknown error"), vim.log.levels.ERROR)
		return
	end

	M.close()
	vim.notify("[Vibe] All changes accepted. Agent may continue working.", vim.log.levels.INFO)

	local session = require("vibe.session")
	vim.defer_fn(function()
		session.show_review_list()
	end, 100)
end

function M.get_current_worktree()
	return M.current_worktree_path
end

function M.setup_highlights()
	vim.api.nvim_set_hl(0, "VibeDialogHeader", { link = "Title" })
	vim.api.nvim_set_hl(0, "VibeDialogFile", { link = "Normal" })
	vim.api.nvim_set_hl(0, "VibeDialogSelected", { link = "Visual" })
	vim.api.nvim_set_hl(0, "VibeDialogFooter", { link = "Comment" })
end

return M
