local M = {}

local config = require("vibe.config")

function M.git_cmd(args, opts)
	opts = opts or {}
	local cmd_parts = {}
	if opts.cwd then
		table.insert(cmd_parts, "cd")
		table.insert(cmd_parts, vim.fn.shellescape(opts.cwd))
		table.insert(cmd_parts, "&&")
	end
	table.insert(cmd_parts, "git")
	for _, arg in ipairs(args) do
		table.insert(cmd_parts, arg:match("[%s\"'`$]") and vim.fn.shellescape(arg) or arg)
	end
	local cmd = table.concat(cmd_parts, " ")
	local result = vim.fn.systemlist(cmd)
	local exit_code = vim.v.shell_error
	local output = table.concat(result, "\n")

	if exit_code ~= 0 then
		local error_msg = output:gsub("^%s+", ""):gsub("%s+$", "")
		if opts.ignore_error then
			return output, exit_code, error_msg
		end
		return "", exit_code, error_msg
	end
	return output, exit_code, nil
end

function M.get_worktree_base_dir()
	local opts = config.options or {}
	local worktree_opts = opts.worktree or {}
	return worktree_opts.worktree_dir or vim.fn.stdpath("cache") .. "/vibe-worktrees"
end

--- Execute a function with temporary files, guaranteeing cleanup
---@param count number Number of temp files to create
---@param fn function Function receiving temp file paths as arguments
---@return any result from fn
function M.with_temp_files(count, fn)
	local files = {}
	for i = 1, count do
		files[i] = vim.fn.tempname()
	end
	local ok, result = pcall(fn, unpack(files))
	for _, f in ipairs(files) do
		vim.fn.delete(f)
	end
	if not ok then
		error(result)
	end
	return result
end

return M
