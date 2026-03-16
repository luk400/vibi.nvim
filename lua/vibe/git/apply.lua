local M = {}

local persist = require("vibe.persist")

--- Abstracted read/write file modifications for hunk resolutions
local function modify_user_file(worktrees, worktree_path, filepath, user_file_path, modify_fn)
	if not user_file_path then
		local info = worktrees[worktree_path]
		if not info then
			return false, "Could not determine user file path"
		end
		user_file_path = info.repo_root .. "/" .. filepath
	end

	local bufnr = vim.fn.bufnr(user_file_path)
	local lines
	if bufnr ~= -1 then
		lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	else
		lines = vim.fn.filereadable(user_file_path) == 1 and vim.fn.readfile(user_file_path) or {}
	end

	local ok, err = modify_fn(lines)
	if not ok then
		return false, err
	end

	local parent_dir = vim.fn.fnamemodify(user_file_path, ":h")
	if vim.fn.isdirectory(parent_dir) == 0 then
		vim.fn.mkdir(parent_dir, "p")
	end

	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.api.nvim_buf_call(bufnr, function()
			vim.cmd("write")
		end)
	else
		vim.fn.writefile(lines, user_file_path)
	end
	return true, nil
end

--- Apply classified resolution: write resolved lines to user file and sync
function M.apply_classified_resolution(worktrees, worktree_path, filepath, resolved_lines, user_file_path)
	local info = worktrees[worktree_path]
	if not info then
		return false, "Worktree info not found"
	end
	if not user_file_path then
		user_file_path = info.repo_root .. "/" .. filepath
	end

	local parent_dir = vim.fn.fnamemodify(user_file_path, ":h")
	if vim.fn.isdirectory(parent_dir) == 0 then
		vim.fn.mkdir(parent_dir, "p")
	end

	local bufnr = vim.fn.bufnr(user_file_path)
	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, resolved_lines)
		vim.api.nvim_buf_call(bufnr, function()
			vim.cmd("write")
		end)
	else
		vim.fn.writefile(resolved_lines, user_file_path)
	end

	M.sync_resolved_file(worktrees, worktree_path, filepath, user_file_path)
	return true
end

function M.sync_resolved_file(worktrees, worktree_path, filepath, user_file_path)
	local info = worktrees[worktree_path]
	if not info then
		return
	end

	local worktree_file = worktree_path .. "/" .. filepath
	local user_lines = {}

	local bufnr = vim.fn.bufnr(user_file_path)
	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		user_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	elseif vim.fn.filereadable(user_file_path) == 1 then
		user_lines = vim.fn.readfile(user_file_path)
	end

	local worktree_lines = {}
	if vim.fn.filereadable(worktree_file) == 1 then
		worktree_lines = vim.fn.readfile(worktree_file)
	end

	local is_modified = false
	if #user_lines ~= #worktree_lines then
		is_modified = true
	else
		for i = 1, #user_lines do
			if user_lines[i] ~= worktree_lines[i] then
				is_modified = true
				break
			end
		end
	end

	if is_modified then
		info.manually_modified_files = info.manually_modified_files or {}
		info.manually_modified_files[filepath] = true
	end

	vim.fn.mkdir(vim.fn.fnamemodify(worktree_file, ":h"), "p")
	vim.fn.writefile(user_lines, worktree_file)
end

function M.accept_file_from_worktree(worktrees, worktree_path, filepath, repo_root)
	repo_root = repo_root
		or (worktrees[worktree_path] and worktrees[worktree_path].repo_root)
	if not repo_root then
		return false, "Could not determine repo root"
	end

	local src_path = worktree_path .. "/" .. filepath
	local dst_path = repo_root .. "/" .. filepath

	vim.fn.mkdir(vim.fn.fnamemodify(dst_path, ":h"), "p")
	if vim.fn.filereadable(src_path) == 1 then
		vim.fn.writefile(vim.fn.readfile(src_path), dst_path)
	else
		vim.fn.delete(dst_path)
	end

	local bufnr = vim.fn.bufnr(dst_path)
	if bufnr ~= -1 then
		vim.cmd("checktime " .. bufnr)
	end
	return true
end

function M.accept_all_from_worktree(worktrees, worktree_path, get_changed_files_fn)
	for _, filepath in ipairs(get_changed_files_fn(worktree_path)) do
		local ok, err = M.accept_file_from_worktree(worktrees, worktree_path, filepath)
		if not ok then
			return false, err
		end
	end
	return true, nil
end

function M.mark_hunk_addressed(worktrees, worktree_path, filepath, hunk, action)
	local git_diff = require("vibe.git.diff")
	local info = worktrees[worktree_path]
	if not info then
		return
	end

	info.addressed_hunks = info.addressed_hunks or {}
	table.insert(
		info.addressed_hunks,
		{ filepath = filepath, hunk_hash = git_diff.hunk_hash(hunk), action = action, timestamp = os.time() }
	)

	local persisted = persist.load_sessions()
	for _, s in ipairs(persisted) do
		if s.worktree_path == worktree_path then
			s.addressed_hunks = info.addressed_hunks
			break
		end
	end
	persist.save_sessions(persisted)
end

function M.is_file_fully_addressed(worktrees, worktree_path, filepath, get_hunks_fn)
	local git_diff = require("vibe.git.diff")
	local info = worktrees[worktree_path]
	if not info then
		return false
	end

	local worktree_file = worktree_path .. "/" .. filepath
	local user_file = info.repo_root .. "/" .. filepath

	if vim.fn.filereadable(worktree_file) == 0 and vim.fn.filereadable(user_file) == 1 then
		return false
	end

	local hunks = get_hunks_fn(worktree_path, filepath, user_file)
	if #hunks == 0 then
		return true
	end
	if not info.addressed_hunks or #info.addressed_hunks == 0 then
		return false
	end

	local addressed_hashes = {}
	for _, addressed in ipairs(info.addressed_hunks) do
		if addressed.filepath == filepath then
			addressed_hashes[addressed.hunk_hash] = true
		end
	end

	local addressed_count = 0
	for _, hunk in ipairs(hunks) do
		if addressed_hashes[git_diff.hunk_hash(hunk)] then
			addressed_count = addressed_count + 1
		end
	end

	return addressed_count >= #hunks
end

return M
