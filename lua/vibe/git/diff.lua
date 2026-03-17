local M = {}

local git_cmd_mod = require("vibe.git.cmd")
local git_cmd = git_cmd_mod.git_cmd

local function simple_hash(str)
	local h = 0
	for i = 1, #str do
		h = (h * 31 + string.byte(str, i)) % 2147483647
	end
	return tostring(h)
end

function M.hunk_hash(hunk)
	local removed_content = table.concat(hunk.removed_lines or {}, "\n")
	local added_content = table.concat(hunk.added_lines or {}, "\n")
	return table.concat(
		{
			tostring(hunk.old_count or 0),
			tostring(hunk.new_count or 0),
			simple_hash(removed_content),
			simple_hash(added_content),
		},
		":"
	)
end

function M.read_file_at_commit(worktree_path, filepath, commit)
	commit = commit or "HEAD"
	local cmd = string.format("cd %s && git --no-pager show %s:%s", vim.fn.shellescape(worktree_path), commit, filepath)
	local result = vim.fn.systemlist(cmd)
	if vim.v.shell_error ~= 0 then
		return {}
	end
	return (not result or #result == 0) and { "" } or result
end

function M.get_worktree_snapshot_lines(worktrees, worktree_path, filepath)
	local info = worktrees[worktree_path]
	return info and M.read_file_at_commit(worktree_path, filepath, info.snapshot_commit) or {}
end

function M.get_worktree_file_hunks(worktree_path, filepath, user_file_path)
	local worktree_file = worktree_path .. "/" .. filepath
	if vim.fn.filereadable(worktree_file) == 0 then
		return {}
	end

	local worktree_lines = vim.fn.readfile(worktree_file)
	local user_lines = {}
	local bufnr = vim.fn.bufnr(user_file_path)
	if bufnr ~= -1 then
		user_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	elseif vim.fn.filereadable(user_file_path) == 1 then
		user_lines = vim.fn.readfile(user_file_path)
	end

	if #worktree_lines == #user_lines then
		local same = true
		for i = 1, #worktree_lines do
			if worktree_lines[i] ~= user_lines[i] then
				same = false
				break
			end
		end
		if same then
			return {}
		end
	end

	local tmp_worktree = vim.fn.tempname()
	local tmp_user = vim.fn.tempname()
	vim.fn.writefile(worktree_lines, tmp_worktree)
	vim.fn.writefile(user_lines, tmp_user)

	local ok_diff, output = pcall(function()
		return git_cmd({ "diff", "--no-index", "-U0", "--no-color", tmp_user, tmp_worktree }, { cwd = vim.fn.fnamemodify(tmp_user, ":h"), ignore_error = true })
	end)
	vim.fn.delete(tmp_worktree)
	vim.fn.delete(tmp_user)
	if not ok_diff then
		return {}
	end
	if not output or output == "" then
		return {}
	end

	local hunks, current_hunk = {}, nil
	for line in output:gmatch("[^\r\n]+") do
		local old_start, old_count, new_start, new_count = line:match("^@@%s*%-(%d+),?(%d*)%s*%+(%d+),?(%d*)%s*@@")

		if old_start then
			if current_hunk then
				table.insert(hunks, current_hunk)
			end
			old_count = old_count ~= "" and tonumber(old_count) or 1
			new_count = new_count ~= "" and tonumber(new_count) or 1

			current_hunk = {
				old_start = tonumber(old_start),
				old_count = old_count,
				new_start = tonumber(new_start),
				new_count = new_count,
				type = old_count == 0 and "add" or (new_count == 0 and "delete" or "change"),
				lines = {},
				added_lines = {},
				removed_lines = {},
			}
		elseif current_hunk then
			if line:sub(1, 1) == "+" then
				table.insert(current_hunk.added_lines, line:sub(2))
				table.insert(current_hunk.lines, { type = "add", text = line:sub(2) })
			elseif line:sub(1, 1) == "-" then
				table.insert(current_hunk.removed_lines, line:sub(2))
				table.insert(current_hunk.lines, { type = "remove", text = line:sub(2) })
			end
		end
	end
	if current_hunk then
		table.insert(hunks, current_hunk)
	end

	return hunks
end

function M.get_user_added_lines(worktrees, worktree_path, filepath, user_file_path)
	local snapshot_lines = M.get_worktree_snapshot_lines(worktrees, worktree_path, filepath)
	if #snapshot_lines == 0 then
		return {}
	end

	local user_lines = {}
	local bufnr = vim.fn.bufnr(user_file_path)
	if bufnr ~= -1 then
		user_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	elseif vim.fn.filereadable(user_file_path) == 1 then
		user_lines = vim.fn.readfile(user_file_path)
	end
	if #user_lines == 0 then
		return {}
	end

	local tmp_snapshot, tmp_user = vim.fn.tempname(), vim.fn.tempname()
	vim.fn.writefile(snapshot_lines, tmp_snapshot)
	vim.fn.writefile(user_lines, tmp_user)
	local ok_diff, output = pcall(function()
		return git_cmd({ "diff", "--no-index", "-U0", "--no-color", tmp_snapshot, tmp_user }, { cwd = vim.fn.fnamemodify(tmp_snapshot, ":h"), ignore_error = true })
	end)
	vim.fn.delete(tmp_snapshot)
	vim.fn.delete(tmp_user)

	if not ok_diff or not output or output == "" then
		return {}
	end

	local user_added_lines = {}
	for line in output:gmatch("[^\r\n]+") do
		local old_start, old_count, new_start, new_count = line:match("^@@%s*%-(%d+),?(%d*)%s*%+(%d+),?(%d*)%s*@@")
		if old_start then
			new_count = new_count ~= "" and tonumber(new_count) or 1
			old_count = old_count ~= "" and tonumber(old_count) or 0
			if new_count > 0 and old_count == 0 then
				for i = 0, new_count - 1 do
					user_added_lines[new_start + i] = true
				end
			elseif new_count > old_count then
				for i = old_count, new_count - 1 do
					user_added_lines[new_start + i] = true
				end
			end
		end
	end
	return user_added_lines
end

return M
