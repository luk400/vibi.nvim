--- START OF FILE conflict_buffer.lua ---
local git = require("vibe.git")
local config = require("vibe.config")
local util = require("vibe.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("vibe_conflict_buffer")

---@type table<integer, table> bufnr -> conflict state
M.buffer_state = {}

local function parse_conflict_markers(lines)
	local conflicts = {}
	local i = 1
	while i <= #lines do
		if lines[i]:match("^<<<<<<< HEAD") then
			local conflict_start = i - 1
			local separator_line, conflict_end = nil, nil
			for j = i + 1, #lines do
				if lines[j]:match("^=======") then
					separator_line = j - 1
					break
				end
			end
			if separator_line then
				for j = separator_line + 2, #lines do
					if lines[j]:match("^>>>>>>> vibe%-") then
						conflict_end = j - 1
						break
					end
				end
			end
			if separator_line and conflict_end then
				local ours_start, ours_end = conflict_start + 1, separator_line - 1
				local theirs_start, theirs_end = separator_line + 1, conflict_end - 1
				if ours_start > ours_end then
					ours_start, ours_end = 0, -1
				end
				if theirs_start > theirs_end then
					theirs_start, theirs_end = 0, -1
				end

				-- Create a dummy hunk for fallback compatibility with git.lua
				local rem_lines, add_lines = {}, {}
				for k = ours_start + 1, ours_end + 1 do
					table.insert(rem_lines, lines[k])
				end
				for k = theirs_start + 1, theirs_end + 1 do
					table.insert(add_lines, lines[k])
				end

				local dummy_hunk = {
					old_start = ours_start,
					old_count = #rem_lines,
					new_start = theirs_start,
					new_count = #add_lines,
					removed_lines = rem_lines,
					added_lines = add_lines,
					type = "change",
				}

				table.insert(conflicts, {
					start_line = conflict_start,
					end_line = conflict_end,
					ours_start = ours_start,
					ours_end = ours_end,
					theirs_start = theirs_start,
					theirs_end = theirs_end,
					resolved = false,
					hunk = dummy_hunk,
				})
				i = conflict_end + 2
			else
				i = i + 1
			end
		else
			i = i + 1
		end
	end
	return conflicts
end

--- Robust 3-way merge using Git, mapping correctly without splitting conflicts
function M.insert_conflict_markers(user_lines, worktree_path, filepath, session_name, review_mode)
	local base_lines = git.get_worktree_snapshot_lines(worktree_path, filepath)

	local agent_file_path = worktree_path .. "/" .. filepath
	local agent_lines = {}
	if vim.fn.filereadable(agent_file_path) == 1 then
		agent_lines = vim.fn.readfile(agent_file_path)
	end

	local t_local = vim.fn.tempname()
	local t_base = vim.fn.tempname()
	local t_agent = vim.fn.tempname()
	vim.fn.writefile(user_lines, t_local)
	vim.fn.writefile(base_lines, t_base)
	vim.fn.writefile(agent_lines, t_agent)

	local cmd = string.format(
		"git merge-file -p -q -L HEAD -L Base -L vibe-%s %s %s %s",
		vim.fn.shellescape(session_name),
		vim.fn.shellescape(t_local),
		vim.fn.shellescape(t_base),
		vim.fn.shellescape(t_agent)
	)

	local merged_output = vim.fn.systemlist(cmd)

	vim.fn.delete(t_local)
	vim.fn.delete(t_base)
	vim.fn.delete(t_agent)

	local local_str = table.concat(user_lines, "\n") .. (user_lines[1] and "\n" or "")
	local merged_str = table.concat(merged_output, "\n") .. (merged_output[1] and "\n" or "")

	local hunks = vim.diff(local_str, merged_str, { result_type = "indices" })

	-- Find true conflict ranges in merged_output so we don't accidentally split them
	local true_conflicts = {}
	local in_conflict = false
	local conflict_start = 0
	for i, line in ipairs(merged_output) do
		if line:match("^<<<<<<< HEAD") then
			in_conflict = true
			conflict_start = i
		elseif in_conflict and line:match("^>>>>>>> vibe%-") then
			in_conflict = false
			table.insert(true_conflicts, { start_idx = conflict_start, end_idx = i })
		end
	end

	-- Classify hunks based on whether they overlap a true git merge-file conflict
	local hunk_types = {}
	for i, hunk in ipairs(hunks or {}) do
		local start_a, count_a, start_b, count_b = unpack(hunk)
		local b_first = count_b > 0 and start_b or start_b + 1
		local b_last = b_first + count_b - 1

		local is_conflict = false
		for _, tc in ipairs(true_conflicts) do
			local eff_first = math.min(b_first, b_last)
			local eff_last = math.max(b_first, b_last)
			if eff_last >= tc.start_idx and eff_first <= tc.end_idx then
				is_conflict = true
				break
			end
		end
		hunk_types[i] = is_conflict and "conflict" or "clean"
	end

	local final_lines = {}
	local auto_merged_regions = {}
	local curr_a = 1
	local curr_b = 1

	local function make_dummy_hunk(old_s, old_c, new_s, new_c)
		return {
			old_start = old_s,
			old_count = old_c,
			new_start = new_s,
			new_count = new_c,
			removed_lines = {},
			added_lines = {},
			type = "change",
		}
	end

	for i, hunk in ipairs(hunks or {}) do
		local start_a, count_a, start_b, count_b = unpack(hunk)
		local a_first = count_a > 0 and start_a or start_a + 1
		local a_last = a_first + count_a - 1
		local b_first = count_b > 0 and start_b or start_b + 1
		local b_last = b_first + count_b - 1

		-- Sync up to the start of the hunk
		while curr_b < b_first do
			table.insert(final_lines, merged_output[curr_b])
			curr_b = curr_b + 1
			curr_a = curr_a + 1
		end

		if hunk_types[i] == "conflict" then
			-- It's part of a native conflict block. Just output the lines.
			while curr_b <= b_last do
				table.insert(final_lines, merged_output[curr_b])
				curr_b = curr_b + 1
			end
			curr_a = a_last + 1
		else
			-- Clean AI addition / modification
			local dummy = make_dummy_hunk(start_a, count_a, start_b, count_b)
			if review_mode == "auto" then
				local highlight_start = #final_lines + 1
				while curr_b <= b_last do
					table.insert(final_lines, merged_output[curr_b])
					curr_b = curr_b + 1
				end
				local highlight_end = #final_lines

				if count_b > 0 then
					table.insert(auto_merged_regions, {
						type = "add",
						start_line = highlight_start - 1,
						end_line = highlight_end - 1,
						hunk = dummy,
					})
				elseif count_a > 0 and count_b == 0 then
					table.insert(auto_merged_regions, {
						type = "delete",
						start_line = highlight_start - 1,
						end_line = highlight_start - 1,
						hunk = dummy,
					})
				end
				curr_a = a_last + 1
			else
				-- Manual mode: Wrap the clean change in a conflict block
				table.insert(final_lines, "<<<<<<< HEAD")
				for k = a_first, a_last do
					if user_lines[k] then
						table.insert(final_lines, user_lines[k])
					end
				end
				table.insert(final_lines, "=======")
				for k = b_first, b_last do
					if merged_output[k] then
						table.insert(final_lines, merged_output[k])
					end
					curr_b = curr_b + 1
				end
				table.insert(final_lines, ">>>>>>> vibe-" .. session_name)
				curr_a = a_last + 1
			end
		end
	end

	-- Push remaining lines
	while curr_b <= #merged_output do
		table.insert(final_lines, merged_output[curr_b])
		curr_b = curr_b + 1
	end

	local conflicts = parse_conflict_markers(final_lines)
	return final_lines, conflicts, auto_merged_regions
end

function M.show_file_with_conflicts(worktree_path, filepath, _, review_mode)
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
		M.insert_conflict_markers(user_lines, worktree_path, filepath, info.name, review_mode)

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

	M.setup_keymaps(bufnr)
	M.setup_highlights(bufnr)

	if #conflicts > 0 then
		vim.api.nvim_win_set_cursor(0, { conflicts[1].start_line + 1, 0 })
		local keymaps = config.options.conflict_buffer and config.options.conflict_buffer.keymaps or {}
		vim.notify(
			string.format(
				"[Vibe] %d conflict(s). [%s] yours, [%s] AI's, [%s] both, [%s] none",
				#conflicts,
				keymaps.keep_ours or "o",
				keymaps.keep_theirs or "t",
				keymaps.keep_both or "b",
				keymaps.keep_none or "n"
			),
			vim.log.levels.INFO
		)
	else
		vim.notify("[Vibe] All changes safely auto-merged. Press 'A' or ':w' to accept and save.", vim.log.levels.INFO)
	end
end

function M.setup_highlights(bufnr)
	vim.api.nvim_set_hl(0, "VibeConflictMarker", { link = "DiffText", default = true })
	vim.api.nvim_set_hl(0, "VibeConflictOurs", { link = "DiffDelete", default = true })
	vim.api.nvim_set_hl(0, "VibeConflictTheirs", { link = "DiffAdd", default = true })
	vim.api.nvim_set_hl(0, "VibeConflictSeparator", { link = "DiffText", default = true })
	vim.api.nvim_set_hl(0, "VibeAutoMerged", { link = "DiffAdd", default = true })

	local state = M.buffer_state[bufnr]
	if not state then
		return
	end

	for _, conflict in ipairs(state.conflicts) do
		if not conflict.resolved then
			vim.api.nvim_buf_add_highlight(bufnr, M.ns, "VibeConflictMarker", conflict.start_line, 0, -1)
			if conflict.ours_start <= conflict.ours_end then
				for line = conflict.ours_start, conflict.ours_end do
					vim.api.nvim_buf_add_highlight(bufnr, M.ns, "VibeConflictOurs", line, 0, -1)
				end
			end
			local separator_line = conflict.ours_end + 1
			if conflict.ours_start > conflict.ours_end then
				separator_line = conflict.start_line + 1
			end
			vim.api.nvim_buf_add_highlight(bufnr, M.ns, "VibeConflictSeparator", separator_line, 0, -1)

			if conflict.theirs_start <= conflict.theirs_end then
				for line = conflict.theirs_start, conflict.theirs_end do
					vim.api.nvim_buf_add_highlight(bufnr, M.ns, "VibeConflictTheirs", line, 0, -1)
				end
			end
			vim.api.nvim_buf_add_highlight(bufnr, M.ns, "VibeConflictMarker", conflict.end_line, 0, -1)
		end
	end

	if state.auto_merged_regions then
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
	for idx, conflict in ipairs(state.conflicts) do
		if not conflict.resolved and cursor_line >= conflict.start_line and cursor_line <= conflict.end_line then
			return conflict, idx
		end
	end
	return nil, nil
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

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local ours_lines, theirs_lines = {}, {}

	if conflict.ours_start <= conflict.ours_end then
		for i = conflict.ours_start, conflict.ours_end do
			if lines[i + 1] then
				table.insert(ours_lines, lines[i + 1])
			end
		end
	end
	if conflict.theirs_start <= conflict.theirs_end then
		for i = conflict.theirs_start, conflict.theirs_end do
			if lines[i + 1] then
				table.insert(theirs_lines, lines[i + 1])
			end
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

	vim.api.nvim_buf_set_lines(bufnr, conflict.start_line, conflict.end_line + 1, false, replacement_lines)

	state.conflicts[idx].resolved = true
	state.resolved_count = state.resolved_count + 1

	local action = resolution
	if resolution == "ours" then
		action = "rejected"
	elseif resolution == "theirs" then
		action = "accepted"
	end
	if conflict.hunk then
		git.mark_hunk_addressed(state.worktree_path, state.filepath, conflict.hunk, action)
	end

	local line_diff = #replacement_lines - (conflict.end_line - conflict.start_line + 1)
	for i = idx + 1, #state.conflicts do
		if not state.conflicts[i].resolved then
			state.conflicts[i].start_line = state.conflicts[i].start_line + line_diff
			state.conflicts[i].end_line = state.conflicts[i].end_line + line_diff
			state.conflicts[i].ours_start = state.conflicts[i].ours_start + line_diff
			state.conflicts[i].ours_end = state.conflicts[i].ours_end + line_diff
			state.conflicts[i].theirs_start = state.conflicts[i].theirs_start + line_diff
			state.conflicts[i].theirs_end = state.conflicts[i].theirs_end + line_diff
		end
	end
	if state.auto_merged_regions then
		for _, am in ipairs(state.auto_merged_regions) do
			if am.start_line > conflict.end_line then
				am.start_line, am.end_line = am.start_line + line_diff, am.end_line + line_diff
			end
		end
	end

	vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
	M.setup_highlights(bufnr)

	local remaining = M.count_remaining_conflicts()
	if remaining == 0 then
		M.finalize_file()
	else
		vim.notify(string.format("[Vibe] Conflict resolved. %d remaining", remaining), vim.log.levels.INFO)
	end

	return true
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
	local bufnr = vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return 0
	end
	local count = 0
	for _, c in ipairs(state.conflicts) do
		if not c.resolved then
			count = count + 1
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
		if not c.resolved and c.start_line > cursor_line then
			vim.api.nvim_win_set_cursor(0, { c.start_line + 1, 0 })
			return
		end
	end
	for _, c in ipairs(state.conflicts) do
		if not c.resolved then
			vim.api.nvim_win_set_cursor(0, { c.start_line + 1, 0 })
			return
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
		if not c.resolved and c.start_line < cursor_line then
			vim.api.nvim_win_set_cursor(0, { c.start_line + 1, 0 })
			return
		end
	end
	for i = #state.conflicts, 1, -1 do
		local c = state.conflicts[i]
		if not c.resolved then
			vim.api.nvim_win_set_cursor(0, { c.start_line + 1, 0 })
			return
		end
	end
end

local function process_all_conflicts(resolution)
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
			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local r_lines = {}
			local start_idx = resolution == "ours" and conflict.ours_start or conflict.theirs_start
			local end_idx = resolution == "ours" and conflict.ours_end or conflict.theirs_end

			for line_idx = start_idx, end_idx do
				if lines[line_idx + 1] then
					table.insert(r_lines, lines[line_idx + 1])
				end
			end

			vim.api.nvim_buf_set_lines(bufnr, conflict.start_line, conflict.end_line + 1, false, r_lines)
			conflict.resolved = true
			state.resolved_count = state.resolved_count + 1

			if conflict.hunk then
				git.mark_hunk_addressed(
					state.worktree_path,
					state.filepath,
					conflict.hunk,
					resolution == "ours" and "rejected" or "accepted"
				)
			end

			local line_diff = #r_lines - (conflict.end_line - conflict.start_line + 1)
			for j = i - 1, 1, -1 do
				if not state.conflicts[j].resolved then
					state.conflicts[j].start_line = state.conflicts[j].start_line + line_diff
					state.conflicts[j].end_line = state.conflicts[j].end_line + line_diff
					state.conflicts[j].ours_start = state.conflicts[j].ours_start + line_diff
					state.conflicts[j].ours_end = state.conflicts[j].ours_end + line_diff
					state.conflicts[j].theirs_start = state.conflicts[j].theirs_start + line_diff
					state.conflicts[j].theirs_end = state.conflicts[j].theirs_end + line_diff
				end
			end
		end
	end
	vim.notify("[Vibe] All conflicts processed", vim.log.levels.INFO)
	M.finalize_file()
end

function M.accept_all()
	process_all_conflicts("theirs")
end
function M.reject_all()
	process_all_conflicts("ours")
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

	local conf = config.options.conflict_buffer or {}
	if conf.auto_next_file ~= false then
		util.check_remaining_files(state.worktree_path)
	else
		vim.notify("[Vibe] File resolved", vim.log.levels.INFO)
	end
end

function M.quit()
	local bufnr = vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	local worktree_path = state and state.worktree_path

	if M.count_remaining_conflicts() > 0 then
		if vim.fn.confirm("Unresolved conflict(s). Quit anyway?", "&Yes\n&No", 2) ~= 1 then
			return
		end
	end

	if state then
		vim.cmd("edit!")
		M.buffer_state[bufnr] = nil
		vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
	end

	if worktree_path then
		require("vibe.dialog").show(worktree_path)
	end
end

function M.setup_keymaps(bufnr)
	local keymaps = config.options.conflict_buffer and config.options.conflict_buffer.keymaps or {}
	local opts = { buffer = bufnr, silent = true, noremap = true }

	if keymaps.keep_ours then
		vim.keymap.set("n", keymaps.keep_ours, M.keep_ours, opts)
	end
	if keymaps.keep_theirs then
		vim.keymap.set("n", keymaps.keep_theirs, M.keep_theirs, opts)
	end
	if keymaps.keep_both then
		vim.keymap.set("n", keymaps.keep_both, M.keep_both, opts)
	end
	if keymaps.keep_none then
		vim.keymap.set("n", keymaps.keep_none, M.keep_none, opts)
	end
	if keymaps.next_conflict then
		vim.keymap.set("n", keymaps.next_conflict, M.next_conflict, opts)
	end
	if keymaps.prev_conflict then
		vim.keymap.set("n", keymaps.prev_conflict, M.prev_conflict, opts)
	end
	if keymaps.accept_all then
		vim.keymap.set("n", keymaps.accept_all, M.accept_all, opts)
	end
	if keymaps.reject_all then
		vim.keymap.set("n", keymaps.reject_all, M.reject_all, opts)
	end
	if keymaps.quit then
		vim.keymap.set("n", keymaps.quit, M.quit, opts)
	end
	vim.keymap.set("n", "<Esc>", M.quit, opts)
end

function M.setup()
	vim.api.nvim_set_hl(0, "VibeConflictMarker", { link = "DiffText", default = true })
	vim.api.nvim_set_hl(0, "VibeConflictOurs", { link = "DiffDelete", default = true })
	vim.api.nvim_set_hl(0, "VibeConflictTheirs", { link = "DiffAdd", default = true })
	vim.api.nvim_set_hl(0, "VibeConflictSeparator", { link = "DiffText", default = true })
	vim.api.nvim_set_hl(0, "VibeAutoMerged", { link = "DiffAdd", default = true })
end

function M.clear(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	M.buffer_state[bufnr] = nil
	vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
end

function M.is_conflict_buffer()
	return M.buffer_state[vim.api.nvim_get_current_buf()] ~= nil
end

return M
