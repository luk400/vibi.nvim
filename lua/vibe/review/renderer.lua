--- Unified review renderer
--- Provides collapsed conflict view with inline expansion
--- Replaces the separate conflict_popup.lua, collapsed_conflict.lua rendering,
--- and virtual text rendering from diff.lua
local git = require("vibe.git")
local resolve = require("vibe.resolve")
local review_keymaps = require("vibe.review.keymaps")
local engine = require("vibe.review.engine")
local util = require("vibe.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("vibe_review")

---@type table<integer, table> bufnr -> review state
M.buffer_state = {}

M.preview_winnr = nil
M.preview_bufnr = nil

--- Parse ours/theirs lines from stored conflict content
local function parse_conflict_sides(stored_lines)
	local ours_lines, theirs_lines = {}, {}
	local in_ours, in_theirs = false, false

	for _, line in ipairs(stored_lines or {}) do
		if line:match("^<<<<<<< HEAD") then
			in_ours, in_theirs = true, false
		elseif line:match("^=======") then
			in_ours, in_theirs = false, true
		elseif line:match("^>>>>>>> ") then
			in_ours, in_theirs = false, false
		elseif in_ours then
			table.insert(ours_lines, line)
		elseif in_theirs then
			table.insert(theirs_lines, line)
		end
	end

	return ours_lines, theirs_lines
end

local function get_current_line(bufnr, idx)
	local marks = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, idx * 1000, {})
	if marks and #marks > 0 then
		return marks[1]
	end
	return nil
end

--- Show file with unified review (collapsed conflicts)
function M.show_file(worktree_path, filepath, hunks, review_mode)
	local info = git.get_worktree_info(worktree_path)
	if not info then
		return
	end

	local user_file_path = info.repo_root .. "/" .. filepath
	local user_exists = vim.fn.filereadable(user_file_path) == 1

	local user_lines = {}
	if user_exists then
		local bufnr = vim.fn.bufnr(user_file_path)
		if bufnr ~= -1 then
			user_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		else
			user_lines = vim.fn.readfile(user_file_path)
		end
	end

	local lines_with_markers, conflicts, auto_merged_regions =
		engine.merge(user_lines, worktree_path, filepath, info.name, review_mode)

	local dir = vim.fn.fnamemodify(user_file_path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end

	vim.cmd("edit " .. vim.fn.fnameescape(user_file_path))
	local bufnr = vim.api.nvim_get_current_buf()

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines_with_markers)

	M.buffer_state[bufnr] = {
		worktree_path = worktree_path,
		filepath = filepath,
		session_name = info.name,
		conflicts = conflicts,
		auto_merged_regions = auto_merged_regions,
		original_lines = user_lines,
		resolved_count = 0,
	}

	M.collapse_all_conflicts(bufnr)
	M.setup_highlights(bufnr)
	M.setup_tracking(bufnr)
	M.setup_keymaps(bufnr)

	if #conflicts > 0 then
		local first_line = get_current_line(bufnr, 1) or conflicts[1].start_line
		vim.api.nvim_win_set_cursor(0, { first_line + 1, 0 })
		vim.defer_fn(function()
			M.show_preview()
		end, 50)

		local remaining = M.count_remaining(bufnr)
		vim.notify(
			string.format(
				"[Vibe] %d conflict(s). Hover to preview. [u]yours [a]AI [b]both [n]none",
				remaining
			),
			vim.log.levels.INFO
		)
	else
		vim.notify("[Vibe] All changes safely auto-merged. Press ':w' to accept and save.", vim.log.levels.INFO)
	end
end

function M.collapse_all_conflicts(bufnr)
	local state = M.buffer_state[bufnr]
	if not state or #state.conflicts == 0 then
		return
	end

	state.conflict_contents = {}
	local actual_conflicts = state.conflicts
	local total_shift = 0
	local new_conflicts = {}

	for i, conflict in ipairs(actual_conflicts) do
		local current_start = conflict.start_line + total_shift
		local current_end = conflict.end_line + total_shift

		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local conflict_lines = {}
		for line_idx = current_start, current_end do
			table.insert(conflict_lines, lines[line_idx + 1])
		end

		local total_lines = conflict.end_line - conflict.start_line + 1
		local ours_count = math.max(0, conflict.ours_end - conflict.ours_start + 1)
		local theirs_count = math.max(0, conflict.theirs_end - conflict.theirs_start + 1)

		local conflict_num = i
		local total_conflicts = #actual_conflicts
		local collapse_text = string.format(
			"[Conflict %d/%d] %d lines yours, %d lines AI — (u)yours (a)AI (b)both (n)none",
			conflict_num,
			total_conflicts,
			ours_count,
			theirs_count
		)

		vim.api.nvim_buf_set_lines(bufnr, current_start, current_end + 1, false, { collapse_text })
		total_shift = total_shift + (1 - total_lines)

		local sign_id = i * 1000
		vim.fn.sign_place(
			sign_id,
			"vibe_review",
			"VibeReviewConflict",
			bufnr,
			{ lnum = current_start + 1 }
		)
		vim.api.nvim_buf_set_extmark(bufnr, M.ns, current_start, 0, {
			id = sign_id,
			end_col = #collapse_text,
			hl_group = "VibeConflictCollapsed",
			priority = 200,
		})

		table.insert(new_conflicts, {
			idx = i,
			start_line = current_start,
			end_line = current_start,
			ours_start = conflict.ours_start,
			ours_end = conflict.ours_end,
			theirs_start = conflict.theirs_start,
			theirs_end = conflict.theirs_end,
			hunk = state.conflicts[i] and state.conflicts[i].hunk or nil,
			resolved = false,
		})

		state.conflict_contents[#new_conflicts] = conflict_lines
	end

	-- Adjust auto-merged region positions
	if state.auto_merged_regions then
		for _, am in ipairs(state.auto_merged_regions) do
			for _, actual_c in ipairs(actual_conflicts) do
				local net = 1 - (actual_c.end_line - actual_c.start_line + 1)
				if am.start_line > actual_c.end_line then
					am.start_line, am.end_line = am.start_line + net, am.end_line + net
				end
			end
		end
	end

	state.conflicts = new_conflicts
end

function M.setup_highlights(bufnr)
	vim.api.nvim_set_hl(0, "VibeConflictCollapsed", { bg = "#8B0000", fg = "#FFFFFF", bold = true, default = true })
	vim.api.nvim_set_hl(0, "VibePreviewYours", { fg = "#FF6B6B", bold = true, default = true })
	vim.api.nvim_set_hl(0, "VibePreviewAI", { fg = "#69DB7C", bold = true, default = true })
	vim.api.nvim_set_hl(0, "VibePreviewKeymap", { fg = "#74C0FC", bold = true, default = true })
	vim.api.nvim_set_hl(0, "VibeAutoMerged", { link = "DiffAdd", default = true })

	local state = M.buffer_state[bufnr]
	if state and state.auto_merged_regions then
		for _, am in ipairs(state.auto_merged_regions) do
			if am.type == "add" then
				for line = am.start_line, am.end_line do
					vim.api.nvim_buf_add_highlight(bufnr, M.ns, "VibeAutoMerged", line, 0, -1)
				end
			elseif am.type == "delete" then
				pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, am.start_line, 0, {
					virt_text = { { " Lines deleted by AI ", "Comment" } },
					virt_text_pos = "eol",
				})
			end
		end
	end
end

function M.get_conflict_at_cursor(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return nil, nil
	end

	local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
	for _, conflict in ipairs(state.conflicts) do
		if not conflict.resolved then
			local line = get_current_line(bufnr, conflict.idx)
			if line and cursor_line == line then
				return conflict, conflict.idx
			end
		end
	end
	return nil, nil
end

function M.is_preview_visible()
	return M.preview_winnr ~= nil and vim.api.nvim_win_is_valid(M.preview_winnr)
end

function M.close_preview()
	if M.preview_winnr and vim.api.nvim_win_is_valid(M.preview_winnr) then
		vim.api.nvim_win_close(M.preview_winnr, true)
	end
	M.preview_winnr, M.preview_bufnr = nil, nil
end

function M.show_preview()
	local bufnr = vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end

	local conflict, idx = M.get_conflict_at_cursor(bufnr)
	if not conflict or conflict.resolved then
		M.close_preview()
		return
	end

	local stored_lines = state.conflict_contents and state.conflict_contents[idx]
	local ours_lines, theirs_lines = parse_conflict_sides(stored_lines)

	M.close_preview()

	-- Build preview content
	local preview_lines = { "━━━━━━━━━ Yours ━━━━━━━━━" }
	if #ours_lines > 0 then
		for _, line in ipairs(ours_lines) do
			table.insert(preview_lines, line)
		end
	else
		table.insert(preview_lines, "(empty)")
	end

	table.insert(preview_lines, "")
	table.insert(preview_lines, "━━━━━━━━━━ AI ━━━━━━━━━━")
	if #theirs_lines > 0 then
		for _, line in ipairs(theirs_lines) do
			table.insert(preview_lines, line)
		end
	else
		table.insert(preview_lines, "(empty)")
	end

	table.insert(preview_lines, "")
	table.insert(preview_lines, "── Actions ──")
	table.insert(preview_lines, "[u] yours  [a] AI  [b] both  [n] none  [q] close")

	M.preview_bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(M.preview_bufnr, 0, -1, false, preview_lines)
	vim.api.nvim_buf_set_option(M.preview_bufnr, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(M.preview_bufnr, "modifiable", false)

	local width = 60
	local height = math.min(#preview_lines + 2, 20)
	local row = math.max(0, math.floor((vim.api.nvim_win_get_height(0) - height) / 2))
	local col = math.max(0, math.floor((vim.api.nvim_win_get_width(0) - width) / 2))

	M.preview_winnr = vim.api.nvim_open_win(M.preview_bufnr, false, {
		relative = "win",
		win = 0,
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " Vibe Conflict ",
		title_pos = "center",
		zindex = 100,
	})

	-- Highlight preview content
	local ns_preview = vim.api.nvim_create_namespace("vibe_preview_hl")
	for i = 1, #ours_lines + 1 do
		vim.api.nvim_buf_add_highlight(M.preview_bufnr, ns_preview, "VibePreviewYours", i - 1, 0, -1)
	end
	local ai_start = #ours_lines + 3
	for i = ai_start, vim.api.nvim_buf_line_count(M.preview_bufnr) - 3 do
		vim.api.nvim_buf_add_highlight(M.preview_bufnr, ns_preview, "VibePreviewAI", i - 1, 0, -1)
	end
	vim.api.nvim_buf_add_highlight(
		M.preview_bufnr,
		ns_preview,
		"VibePreviewKeymap",
		vim.api.nvim_buf_line_count(M.preview_bufnr) - 1,
		0,
		-1
	)

	-- Preview keymaps
	review_keymaps.setup_preview(M.preview_bufnr, {
		keep_ours = function()
			M.close_preview()
			M.resolve_conflict("ours")
		end,
		keep_theirs = function()
			M.close_preview()
			M.resolve_conflict("theirs")
		end,
		keep_both = function()
			M.close_preview()
			M.resolve_conflict("both")
		end,
		keep_none = function()
			M.close_preview()
			M.resolve_conflict("none")
		end,
		close = M.close_preview,
	})
end

function M.resolve_conflict(resolution)
	local bufnr = vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return false
	end

	local conflict, idx = M.get_conflict_at_cursor(bufnr)
	if not conflict then
		return false
	end

	local stored_lines = state.conflict_contents and state.conflict_contents[idx]
	if not stored_lines then
		return false
	end

	local conflict_line = get_current_line(bufnr, idx)
	if not conflict_line then
		return false
	end

	local ours_lines, theirs_lines = parse_conflict_sides(stored_lines)
	local replacement_lines = resolve.get_replacement_lines(resolution, ours_lines, theirs_lines)

	-- Use undojoin so resolution can be undone with 'u'
	pcall(vim.cmd, "undojoin")

	pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, idx * 1000)
	pcall(vim.fn.sign_unplace, "vibe_review", { buffer = bufnr, id = idx * 1000 })

	vim.api.nvim_buf_set_lines(bufnr, conflict_line, conflict_line + 1, false, replacement_lines)

	state.conflicts[idx].resolved = true
	state.resolved_count = state.resolved_count + 1

	local action = resolve.resolution_to_action(resolution)
	if conflict.hunk then
		git.mark_hunk_addressed(state.worktree_path, state.filepath, conflict.hunk, action)
	end

	local remaining = M.count_remaining(bufnr)
	if remaining == 0 then
		M.finalize_file(bufnr)
	else
		M.next_conflict(bufnr)
		vim.defer_fn(M.show_preview, 50)
		vim.notify(string.format("[Vibe] Conflict resolved. %d remaining", remaining), vim.log.levels.INFO)
	end
	return true
end

function M.accept_all(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end

	local remaining = M.count_remaining(bufnr)
	if remaining == 0 then
		M.finalize_file(bufnr)
		return
	end

	for i = #state.conflicts, 1, -1 do
		local conflict = state.conflicts[i]
		if not conflict.resolved then
			local stored_lines = state.conflict_contents and state.conflict_contents[conflict.idx]
			if stored_lines then
				local conflict_line = get_current_line(bufnr, conflict.idx)
				if conflict_line then
					local _, theirs_lines = parse_conflict_sides(stored_lines)

					pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, conflict.idx * 1000)
					pcall(vim.fn.sign_unplace, "vibe_review", { buffer = bufnr, id = conflict.idx * 1000 })

					vim.api.nvim_buf_set_lines(bufnr, conflict_line, conflict_line + 1, false, theirs_lines)

					conflict.resolved = true
					state.resolved_count = state.resolved_count + 1
					if conflict.hunk then
						git.mark_hunk_addressed(state.worktree_path, state.filepath, conflict.hunk, "accepted")
					end
				end
			end
		end
	end
	vim.notify("[Vibe] All conflicts accepted", vim.log.levels.INFO)
	M.finalize_file(bufnr)
end

function M.count_remaining(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	local count = 0
	if state then
		for _, c in ipairs(state.conflicts) do
			if not c.resolved then
				count = count + 1
			end
		end
	end
	return count
end

function M.next_conflict(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
	for _, c in ipairs(state.conflicts) do
		if not c.resolved then
			local line = get_current_line(bufnr, c.idx)
			if line and line > cursor_line then
				vim.api.nvim_win_set_cursor(0, { line + 1, 0 })
				return
			end
		end
	end
	-- Wrap around
	for _, c in ipairs(state.conflicts) do
		if not c.resolved then
			local line = get_current_line(bufnr, c.idx)
			if line then
				vim.api.nvim_win_set_cursor(0, { line + 1, 0 })
				return
			end
		end
	end
end

function M.prev_conflict(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
	for i = #state.conflicts, 1, -1 do
		local c = state.conflicts[i]
		if not c.resolved then
			local line = get_current_line(bufnr, c.idx)
			if line and line < cursor_line then
				vim.api.nvim_win_set_cursor(0, { line + 1, 0 })
				return
			end
		end
	end
	-- Wrap around
	for i = #state.conflicts, 1, -1 do
		local c = state.conflicts[i]
		if not c.resolved then
			local line = get_current_line(bufnr, c.idx)
			if line then
				vim.api.nvim_win_set_cursor(0, { line + 1, 0 })
				return
			end
		end
	end
end

function M.quit(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if
		M.count_remaining(bufnr) > 0
		and vim.fn.confirm("Unresolved conflict(s). Quit anyway?", "&Yes\n&No", 2) ~= 1
	then
		return
	end
	M.close_preview()
	if state then
		vim.cmd("edit!")
		M.buffer_state[bufnr] = nil
		vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
		vim.fn.sign_unplace("vibe_review", { buffer = bufnr })
	end
	if state and state.worktree_path then
		require("vibe.dialog").show(state.worktree_path)
	end
end

function M.finalize_file(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end

	if state.auto_merged_regions then
		for _, am in ipairs(state.auto_merged_regions) do
			if am.hunk then
				git.mark_hunk_addressed(state.worktree_path, state.filepath, am.hunk, "accepted")
			end
		end
	end

	local user_file_path = vim.api.nvim_buf_get_name(bufnr)
	vim.fn.mkdir(vim.fn.fnamemodify(user_file_path, ":h"), "p")
	vim.cmd("write")
	git.sync_resolved_file(state.worktree_path, state.filepath, user_file_path)

	M.buffer_state[bufnr] = nil
	vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
	vim.fn.sign_unplace("vibe_review", { buffer = bufnr })
	M.close_preview()
	util.check_remaining_files(state.worktree_path)
end

function M.setup_tracking(bufnr)
	local group = vim.api.nvim_create_augroup("Vibe_review_" .. bufnr, { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = bufnr,
		callback = function()
			local conflict = M.get_conflict_at_cursor(bufnr)
			if conflict and not conflict.resolved then
				if not M.is_preview_visible() then
					M.show_preview()
				end
			else
				M.close_preview()
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufLeave", { group = group, buffer = bufnr, callback = M.close_preview })
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = bufnr,
		callback = function()
			M.buffer_state[bufnr] = nil
			M.close_preview()
		end,
	})
end

function M.setup_keymaps(bufnr)
	review_keymaps.setup(bufnr, {
		keep_ours = function()
			M.close_preview()
			M.resolve_conflict("ours")
		end,
		keep_theirs = function()
			M.close_preview()
			M.resolve_conflict("theirs")
		end,
		keep_both = function()
			M.close_preview()
			M.resolve_conflict("both")
		end,
		keep_none = function()
			M.close_preview()
			M.resolve_conflict("none")
		end,
		next_conflict = function()
			M.next_conflict(bufnr)
		end,
		prev_conflict = function()
			M.prev_conflict(bufnr)
		end,
		quit = function()
			M.quit(bufnr)
		end,
	})

	-- Accept all via command (no 'A' keymap to avoid Vim append conflict)
	vim.api.nvim_buf_create_user_command(bufnr, "VibeAcceptAll", function()
		M.accept_all(bufnr)
	end, { desc = "Accept all conflicts" })
end

function M.setup()
	vim.fn.sign_define("VibeReviewConflict", { text = "!", texthl = "ErrorMsg" })
	vim.api.nvim_set_hl(0, "VibeConflictCollapsed", { bg = "#8B0000", fg = "#FFFFFF", bold = true, default = true })
end

function M.clear(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	M.buffer_state[bufnr] = nil
	vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
	vim.fn.sign_unplace("vibe_review", { buffer = bufnr })
	M.close_preview()
end

function M.is_review_buffer(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	return M.buffer_state[bufnr] ~= nil
end

return M
