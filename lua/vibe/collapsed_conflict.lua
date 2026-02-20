local git = require("vibe.git")
local config = require("vibe.config")
local conflict_buffer = require("vibe.conflict_buffer")
local util = require("vibe.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("vibe_collapsed_conflict")

M.buffer_state = {}
M.preview_winnr = nil
M.preview_bufnr = nil

local function get_current_line(bufnr, idx)
	local marks = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, idx * 1000, {})
	if marks and #marks > 0 then
		return marks[1]
	end
	return nil
end

function M.show_file_with_collapsed_conflicts(worktree_path, filepath, _, review_mode)
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
		conflict_buffer.insert_conflict_markers(user_lines, worktree_path, filepath, info.name, review_mode)

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
	M.setup_cursor_tracking(bufnr)
	M.setup_keymaps(bufnr)

	if #conflicts > 0 then
		local first_line = get_current_line(bufnr, 1) or conflicts[1].start_line
		vim.api.nvim_win_set_cursor(0, { first_line + 1, 0 })
		vim.defer_fn(function()
			M.show_preview()
		end, 100)
		vim.notify(
			string.format(
				"[Vibe] %d conflict(s). Hover to preview. [u]yours [a]AI [b]both [n]none",
				M.count_remaining_conflicts()
			),
			vim.log.levels.INFO
		)
	else
		vim.notify("[Vibe] All changes safely auto-merged. Press 'A' or ':w' to accept and save.", vim.log.levels.INFO)
	end
end

function M.collapse_all_conflicts(bufnr)
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end

	state.conflict_contents = {}
	local actual_conflicts = state.conflicts
	if #actual_conflicts == 0 then
		return
	end

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

		local collapse_text = string.format(
			"<<<<<<< CONFLICT: %d lines (yours: %d, AI: %d) >>>>>>>",
			total_lines,
			ours_count,
			theirs_count
		)

		vim.api.nvim_buf_set_lines(bufnr, current_start, current_end + 1, false, { collapse_text })
		total_shift = total_shift + (1 - total_lines)

		local sign_id = i * 1000
		vim.fn.sign_place(
			sign_id,
			"vibe_collapsed_conflict",
			"VibeCollapsedConflict",
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
	vim.api.nvim_set_hl(0, "VibePreviewTheirs", { fg = "#69DB7C", bold = true, default = true })
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

function M.get_conflict_at_cursor()
	local bufnr = vim.api.nvim_get_current_buf()
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

function M.show_preview()
	local bufnr = vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end

	local conflict, idx = M.get_conflict_at_cursor()
	if not conflict or conflict.resolved then
		M.close_preview()
		return
	end

	local stored_lines = state.conflict_contents and state.conflict_contents[idx]
	local ours_lines, theirs_lines, in_ours, in_theirs = {}, {}, false, false

	if stored_lines then
		for _, line in ipairs(stored_lines) do
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
	end

	M.show_floating_preview(bufnr, conflict, idx, ours_lines, theirs_lines)
end

function M.show_floating_preview(bufnr, conflict, idx, ours_lines, theirs_lines)
	M.close_preview()
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

	M.highlight_preview(M.preview_bufnr, #ours_lines)
	M.setup_preview_keymaps(M.preview_bufnr, bufnr, conflict, idx)
end

function M.highlight_preview(preview_bufnr, ours_line_count)
	local ns = vim.api.nvim_create_namespace("vibe_preview_hl")
	for i = 1, ours_line_count + 1 do
		vim.api.nvim_buf_add_highlight(preview_bufnr, ns, "VibePreviewYours", i - 1, 0, -1)
	end
	for i = ours_line_count + 3, vim.api.nvim_buf_line_count(preview_bufnr) - 3 do
		vim.api.nvim_buf_add_highlight(preview_bufnr, ns, "VibePreviewTheirs", i - 1, 0, -1)
	end
	vim.api.nvim_buf_add_highlight(
		preview_bufnr,
		ns,
		"VibePreviewKeymap",
		vim.api.nvim_buf_line_count(preview_bufnr) - 1,
		0,
		-1
	)
end

function M.setup_preview_keymaps(preview_bufnr, source_bufnr, conflict, idx)
	local opts = { buffer = preview_bufnr, silent = true, noremap = true }
	vim.keymap.set("n", "u", function()
		M.close_preview()
		M.resolve_conflict("ours")
	end, opts)
	vim.keymap.set("n", "a", function()
		M.close_preview()
		M.resolve_conflict("theirs")
	end, opts)
	vim.keymap.set("n", "b", function()
		M.close_preview()
		M.resolve_conflict("both")
	end, opts)
	vim.keymap.set("n", "n", function()
		M.close_preview()
		M.resolve_conflict("none")
	end, opts)
	vim.keymap.set("n", "q", M.close_preview, opts)
	vim.keymap.set("n", "<Esc>", M.close_preview, opts)
end

function M.close_preview()
	if M.preview_winnr and vim.api.nvim_win_is_valid(M.preview_winnr) then
		vim.api.nvim_win_close(M.preview_winnr, true)
	end
	M.preview_winnr, M.preview_bufnr = nil, nil
end

function M.resolve_conflict(resolution)
	local bufnr = vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return false
	end

	local conflict, idx = M.get_conflict_at_cursor()
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

	local ours_lines, theirs_lines, in_ours, in_theirs = {}, {}, false, false
	for _, line in ipairs(stored_lines) do
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

	local replacement_lines = {}
	if resolution == "ours" then
		replacement_lines = ours_lines
	elseif resolution == "theirs" then
		replacement_lines = theirs_lines
	elseif resolution == "both" then
		for _, line in ipairs(ours_lines) do
			table.insert(replacement_lines, line)
		end
		for _, line in ipairs(theirs_lines) do
			table.insert(replacement_lines, line)
		end
	end

	pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, idx * 1000)
	pcall(vim.fn.sign_unplace, "vibe_collapsed_conflict", { buffer = bufnr, id = idx * 1000 })

	vim.api.nvim_buf_set_lines(bufnr, conflict_line, conflict_line + 1, false, replacement_lines)

	state.conflicts[idx].resolved = true
	state.resolved_count = state.resolved_count + 1

	local action = resolution == "ours" and "rejected" or (resolution == "theirs" and "accepted" or resolution)
	if conflict.hunk then
		git.mark_hunk_addressed(state.worktree_path, state.filepath, conflict.hunk, action)
	end

	local remaining = M.count_remaining_conflicts()
	if remaining == 0 then
		M.finalize_file()
	else
		M.next_conflict()
		vim.defer_fn(M.show_preview, 100)
		vim.notify(string.format("[Vibe] Conflict resolved. %d remaining", remaining), vim.log.levels.INFO)
	end
	return true
end

function M.accept_all()
	local bufnr = vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end

	local remaining = M.count_remaining_conflicts()
	if remaining == 0 then
		M.finalize_file()
		return
	end

	for i = #state.conflicts, 1, -1 do
		local conflict = state.conflicts[i]
		if not conflict.resolved then
			local stored_lines = state.conflict_contents and state.conflict_contents[conflict.idx]
			if stored_lines then
				local conflict_line = get_current_line(bufnr, conflict.idx)
				if conflict_line then
					local theirs_lines, in_theirs = {}, false
					for _, line in ipairs(stored_lines) do
						if line:match("^=======") then
							in_theirs = true
						elseif line:match("^>>>>>>> ") then
							in_theirs = false
						elseif in_theirs then
							table.insert(theirs_lines, line)
						end
					end

					pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, conflict.idx * 1000)
					pcall(vim.fn.sign_unplace, "vibe_collapsed_conflict", { buffer = bufnr, id = conflict.idx * 1000 })

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
	M.finalize_file()
end

function M.keep_ours()
	M.resolve_conflict("ours")
end
function M.keep_theirs()
	M.resolve_conflict("theirs")
end
function M.keep_both()
	M.resolve_conflict("both")
end
function M.keep_none()
	M.resolve_conflict("none")
end

function M.count_remaining_conflicts()
	local state = M.buffer_state[vim.api.nvim_get_current_buf()]
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

function M.next_conflict()
	local bufnr = vim.api.nvim_get_current_buf()
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

function M.prev_conflict()
	local bufnr = vim.api.nvim_get_current_buf()
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

function M.setup_cursor_tracking(bufnr)
	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = bufnr,
		callback = function()
			local conflict = M.get_conflict_at_cursor()
			if conflict and not conflict.resolved then
				if not M.is_preview_visible() then
					M.show_preview()
				end
			else
				M.close_preview()
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufLeave", { buffer = bufnr, callback = M.close_preview })
end

function M.setup_keymaps(bufnr)
	local opts = { buffer = bufnr, silent = true, noremap = true }
	vim.keymap.set("n", "u", M.keep_ours, opts)
	vim.keymap.set("n", "a", M.keep_theirs, opts)
	vim.keymap.set("n", "b", M.keep_both, opts)
	vim.keymap.set("n", "n", M.keep_none, opts)
	vim.keymap.set("n", "A", M.accept_all, opts)
	vim.keymap.set("n", "]c", M.next_conflict, opts)
	vim.keymap.set("n", "[c", M.prev_conflict, opts)
	vim.keymap.set("n", "q", M.quit, opts)
	vim.keymap.set("n", "<Esc>", M.quit, opts)
end

function M.quit()
	local bufnr = vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if
		M.count_remaining_conflicts() > 0
		and vim.fn.confirm("Unresolved conflict(s). Quit anyway?", "&Yes\n&No", 2) ~= 1
	then
		return
	end
	M.close_preview()
	if state then
		vim.cmd("edit!")
		M.buffer_state[bufnr] = nil
		vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
		vim.fn.sign_unplace("vibe_collapsed_conflict", { buffer = bufnr })
	end
	if state and state.worktree_path then
		require("vibe.dialog").show(state.worktree_path)
	end
end

function M.finalize_file()
	local bufnr = vim.api.nvim_get_current_buf()
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
	vim.fn.sign_unplace("vibe_collapsed_conflict", { buffer = bufnr })
	M.close_preview()
	util.check_remaining_files(state.worktree_path)
end

function M.setup()
	vim.fn.sign_define("VibeCollapsedConflict", { text = "!", texthl = "ErrorMsg" })
	vim.api.nvim_set_hl(0, "VibeConflictCollapsed", { bg = "#8B0000", fg = "#FFFFFF", bold = true, default = true })
end

function M.clear(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	M.buffer_state[bufnr] = nil
	vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
	vim.fn.sign_unplace("vibe_collapsed_conflict", { buffer = bufnr })
	M.close_preview()
end

function M.is_collapsed_conflict_buffer()
	return M.buffer_state[vim.api.nvim_get_current_buf()] ~= nil
end

return M
