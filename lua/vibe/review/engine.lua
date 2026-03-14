--- Merge engine extracted from conflict_buffer.insert_conflict_markers
--- Performs 3-way merge using git merge-file and classifies results
local git = require("vibe.git")

local M = {}

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

--- Perform 3-way merge and classify results
---@param user_lines string[] Current user file lines
---@param worktree_path string Path to worktree
---@param filepath string Relative file path
---@param session_name string Session name for markers
---@param review_mode string "auto" or "manual"
---@return string[] lines, table[] conflicts, table[] auto_merged_regions
function M.merge(user_lines, worktree_path, filepath, session_name, review_mode)
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

	-- Find true conflict ranges
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

	-- Classify hunks
	local hunk_types = {}
	for i, hunk in ipairs(hunks or {}) do
		local _, _, start_b, count_b = unpack(hunk)
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

		while curr_b < b_first do
			table.insert(final_lines, merged_output[curr_b])
			curr_b = curr_b + 1
			curr_a = curr_a + 1
		end

		if hunk_types[i] == "conflict" then
			while curr_b <= b_last do
				table.insert(final_lines, merged_output[curr_b])
				curr_b = curr_b + 1
			end
			curr_a = a_last + 1
		else
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

	while curr_b <= #merged_output do
		table.insert(final_lines, merged_output[curr_b])
		curr_b = curr_b + 1
	end

	local conflicts = parse_conflict_markers(final_lines)
	return final_lines, conflicts, auto_merged_regions
end

return M
