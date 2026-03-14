local M = {}

local persist = require("vibe.persist")
local config = require("vibe.config")
local git_cmd_mod = require("vibe.git.cmd")
local git_cmd = git_cmd_mod.git_cmd
local get_worktree_base_dir = git_cmd_mod.get_worktree_base_dir

---@type table<string, WorktreeInfo> worktree_path -> WorktreeInfo
M.worktrees = {}

local random_seeded = false
local function seed_random()
	if not random_seeded then
		math.randomseed(os.time() * 1000 + vim.loop.hrtime() % 1000000)
		math.random()
		math.random()
		random_seeded = true
	end
end

local function generate_timestamped_uuid()
	seed_random()
	local timestamp = os.time()
	local time_str = os.date("%Y%m%d-%H%M%S", timestamp)
	local ns = vim.loop.hrtime() % 1000000000
	local ns_hex = string.format("%08x", ns)
	return time_str .. "-" .. ns_hex, timestamp
end

local function get_vibeinclude_patterns(repo_root)
	local vibeinclude_path = repo_root .. "/.vibeinclude"
	if vim.fn.filereadable(vibeinclude_path) ~= 1 then
		return nil
	end

	local patterns = {}
	for line in io.lines(vibeinclude_path) do
		line = line:gsub("^%s+", ""):gsub("%s+$", "")
		if line ~= "" and not line:match("^#") then
			table.insert(patterns, line)
		end
	end
	return #patterns > 0 and patterns or nil
end

function M.matches_patterns(file, patterns)
	for _, pattern in ipairs(patterns) do
		-- Convert glob to Lua pattern:
		-- 1. Escape Lua magic chars except * and ? (they're glob wildcards)
		local lua_pat = pattern:gsub("([%(%)%.%%%+%-%[%]%^%$])", "%%%1")
		-- 2. Convert glob wildcards (order matters: ** before *)
		lua_pat = lua_pat
			:gsub("%*%*", "\001") -- temp placeholder for **
			:gsub("%*", "[^/]*") -- * = any non-slash chars
			:gsub("\001", ".*") -- ** = anything including slashes
			:gsub("%?", ".") -- ? = single char
		if file:match("^" .. lua_pat .. "$") then
			return true
		end
	end
	return false
end

local function get_untracked_patterns(repo_root)
	local opts = config.options or {}
	local worktree_opts = opts.worktree or {}

	if worktree_opts.use_vibeinclude ~= false then
		local vibeinclude_patterns = get_vibeinclude_patterns(repo_root)
		if vibeinclude_patterns then
			return vibeinclude_patterns
		end
	end

	local copy_untracked = worktree_opts.copy_untracked
	if copy_untracked == true then
		return {}
	elseif type(copy_untracked) == "table" then
		return copy_untracked
	end

	return {}
end

function M.is_git_repo(cwd)
	local _, exit_code, _ = git_cmd({ "rev-parse", "--is-inside-work-tree" }, { cwd = cwd, ignore_error = true })
	return exit_code == 0
end

function M.get_repo_root(cwd)
	local output, exit_code, _ = git_cmd({ "rev-parse", "--show-toplevel" }, { cwd = cwd, ignore_error = true })
	if exit_code ~= 0 or not output or output == "" then
		return nil
	end
	return output:gsub("^%s+", ""):gsub("%s+$", "")
end

function M.get_current_branch(cwd)
	local output, exit_code, _ = git_cmd({ "branch", "--show-current" }, { cwd = cwd, ignore_error = true })
	if exit_code ~= 0 or not output or output == "" then
		output, exit_code, _ = git_cmd({ "rev-parse", "--short", "HEAD" }, { cwd = cwd, ignore_error = true })
		if exit_code ~= 0 then
			return nil
		end
	end
	return output:gsub("^%s+", ""):gsub("%s+$", "")
end

local function init_repo(cwd)
	local _, exit_code, err = git_cmd({ "init" }, { cwd = cwd })
	if exit_code ~= 0 then
		return false, "git init failed: " .. (err or "unknown error")
	end
	return true, nil
end

local function cleanup_old_vibe_branches(repo_cwd)
	local output = git_cmd({ "branch", "--list", "vibe-" }, { cwd = repo_cwd, ignore_error = true })
	if output and output ~= "" then
		for branch in output:gmatch("[^\r\n]+") do
			branch = branch:gsub("^%s", ""):gsub("%s*$", ""):gsub("^%%s", "")
			if branch:match("^vibe%-") then
				git_cmd({ "branch", "-D", branch }, { cwd = repo_cwd, ignore_error = true })
			end
		end
	end

	local base_dir = get_worktree_base_dir()
	if vim.fn.isdirectory(base_dir) == 1 then
		for _, uuid in ipairs(vim.fn.readdir(base_dir) or {}) do
			local worktree_path = base_dir .. "/" .. uuid
			local wt_list = git_cmd({ "worktree", "list" }, { cwd = repo_cwd, ignore_error = true })
			local is_registered = false
			if wt_list then
				for line in wt_list:gmatch("[^\r\n]+") do
					if line:match(vim.pesc(worktree_path)) then
						is_registered = true
						break
					end
				end
			end
			if not is_registered then
				vim.fn.delete(worktree_path, "rf")
			end
		end
	end
end

function M.create_worktree(session_name, repo_cwd)
	repo_cwd = repo_cwd or vim.fn.getcwd()

	if not M.is_git_repo(repo_cwd) then
		vim.notify("[Vibe] Initializing git repository...", vim.log.levels.INFO)
		local ok, err = init_repo(repo_cwd)
		if not ok then
			return nil, "Failed to initialize git repository: " .. (err or "unknown error")
		end
	end

	local repo_root = M.get_repo_root(repo_cwd)
	if not repo_root then
		return nil, "Failed to get repository root"
	end

	cleanup_old_vibe_branches(repo_root)

	local original_branch = M.get_current_branch(repo_cwd) or "main"
	local uuid, created_at = generate_timestamped_uuid()
	local branch_name = "vibe-" .. uuid
	local base_dir = get_worktree_base_dir()
	local worktree_path = base_dir .. "/" .. uuid

	vim.fn.mkdir(base_dir, "p")

	local _, no_commits_code = git_cmd({ "rev-parse", "HEAD" }, { cwd = repo_cwd, ignore_error = true })
	if no_commits_code ~= 0 then
		git_cmd({ "add", "-A" }, { cwd = repo_cwd })
		local _, _, commit_err = git_cmd({ "commit", "-m", "Initial commit" }, { cwd = repo_cwd })
		if commit_err then
			return nil, "Failed to create initial commit: " .. commit_err
		end
	end

	local _, worktree_code, worktree_err = git_cmd(
		{ "worktree", "add", worktree_path, "-b", branch_name },
		{ cwd = repo_cwd }
	)
	if worktree_code ~= 0 then
		for _ = 1, 3 do
			uuid, created_at = generate_timestamped_uuid()
			branch_name = "vibe-" .. uuid
			worktree_path = base_dir .. "/" .. uuid
			_, worktree_code, worktree_err = git_cmd(
				{ "worktree", "add", worktree_path, "-b", branch_name },
				{ cwd = repo_cwd }
			)
			if worktree_code == 0 then
				break
			end
		end
		if worktree_code ~= 0 then
			return nil, "Failed to create worktree: " .. (worktree_err or "unknown error")
		end
	end

	local changed_output = git_cmd({ "diff", "--name-only", "HEAD" }, { cwd = repo_cwd, ignore_error = true })
	local untracked_output = git_cmd(
		{ "ls-files", "--others", "--exclude-standard" },
		{ cwd = repo_cwd, ignore_error = true }
	)

	local files_to_copy = {}
	for file in (changed_output or ""):gmatch("[^\r\n]+") do
		if file ~= "" then
			files_to_copy[file] = true
		end
	end

	local untracked_patterns = get_untracked_patterns(repo_root)
	local copy_all_untracked = config.options
		and config.options.worktree
		and config.options.worktree.copy_untracked == true

	for file in (untracked_output or ""):gmatch("[^\r\n]+") do
		if file ~= "" then
			if copy_all_untracked or (#untracked_patterns > 0 and M.matches_patterns(file, untracked_patterns)) then
				files_to_copy[file] = true
			end
		end
	end

	if repo_cwd ~= repo_root then
		local cwd_relative = repo_cwd
		if vim.startswith(cwd_relative, repo_root .. "/") then
			cwd_relative = cwd_relative:sub(#repo_root + 2)
		elseif vim.startswith(cwd_relative, repo_root) then
			cwd_relative = cwd_relative:sub(#repo_root + 1)
			if cwd_relative:sub(1, 1) == "/" then
				cwd_relative = cwd_relative:sub(2)
			end
		end

		if cwd_relative ~= "" then
			local filtered_files = {}
			for file, _ in pairs(files_to_copy) do
				if vim.startswith(file, cwd_relative .. "/") or file == cwd_relative then
					filtered_files[file] = true
				end
			end
			files_to_copy = filtered_files
		end
	end

	for file, _ in pairs(files_to_copy) do
		local src_path = repo_root .. "/" .. file
		local dst_path = worktree_path .. "/" .. file

		if vim.fn.filereadable(src_path) == 1 then
			vim.fn.mkdir(vim.fn.fnamemodify(dst_path, ":h"), "p")
			vim.fn.writefile(vim.fn.readfile(src_path, "b"), dst_path, "b")
		elseif vim.fn.isdirectory(src_path) == 1 then
			vim.fn.mkdir(dst_path, "p")
		end
	end

	git_cmd({ "add", "-A" }, { cwd = worktree_path })
	local _, commit_code, commit_err = git_cmd(
		{ "commit", "-m", "Vibe snapshot", "--allow-empty" },
		{ cwd = worktree_path }
	)
	if commit_code ~= 0 then
		git_cmd({ "worktree", "remove", "--force", worktree_path }, { cwd = repo_cwd, ignore_error = true })
		return nil, "Failed to create snapshot commit: " .. (commit_err or "unknown error")
	end

	local commit_hash, _, hash_err = git_cmd({ "rev-parse", "HEAD" }, { cwd = worktree_path })
	if not commit_hash or commit_hash == "" then
		git_cmd({ "worktree", "remove", "--force", worktree_path }, { cwd = repo_cwd, ignore_error = true })
		return nil, "Failed to get commit hash: " .. (hash_err or "unknown error")
	end

	local info = {
		name = session_name,
		worktree_path = worktree_path,
		branch = branch_name,
		snapshot_commit = commit_hash:gsub("^%s+", ""):gsub("%s+$", ""),
		original_branch = original_branch,
		repo_root = repo_root,
		uuid = uuid,
		created_at = created_at,
		addressed_hunks = {},
	}
	M.worktrees[worktree_path] = info

	persist.save_session(
		vim.tbl_extend("force", info, { cwd = repo_cwd, last_active = os.time(), has_terminal = true })
	)

	vim.notify("[Vibe] Created worktree: " .. worktree_path, vim.log.levels.INFO)
	return info, nil
end

function M.scan_for_vibe_worktrees()
	local base_dir = get_worktree_base_dir()
	if vim.fn.isdirectory(base_dir) == 0 then
		return
	end

	local persisted = persist.get_valid_persisted_sessions()
	local persisted_by_path = {}
	for _, s in ipairs(persisted) do
		persisted_by_path[s.worktree_path] = s
	end

	for _, uuid in ipairs(vim.fn.readdir(base_dir) or {}) do
		local worktree_path = base_dir .. "/" .. uuid
		if vim.fn.isdirectory(worktree_path) == 1 and not M.worktrees[worktree_path] then
			local branch = M.get_current_branch(worktree_path)
			if branch and branch:match("^vibe%-") then
				local main_repo_root = nil
				local wt_list = git_cmd({ "worktree", "list" }, { cwd = worktree_path, ignore_error = true })
				if wt_list then
					local first_line = wt_list:match("[^\r\n]+")
					if first_line then
						main_repo_root = first_line:match("^%S+")
					end
				end

				if not main_repo_root then
					local git_file = worktree_path .. "/.git"
					if vim.fn.filereadable(git_file) == 1 then
						local common_dir = vim.fn.readfile(git_file)[1]
						if common_dir and common_dir:match("^git%-dir:") then
							main_repo_root = vim.fn.fnamemodify(common_dir:gsub("^git%-dir:%s*", ""), ":h:h:h")
						end
					end
				end

				if main_repo_root and vim.fn.isdirectory(main_repo_root) == 1 then
					local log_output = git_cmd(
						{ "log", "--reverse", "--format=%H", "-n", "1" },
						{ cwd = worktree_path, ignore_error = true }
					)
					local snapshot_commit = log_output and log_output:gsub("^%s+", ""):gsub("%s+$", "") or nil

					if not snapshot_commit or snapshot_commit == "" then
						local first_commit = git_cmd(
							{ "rev-list", "--max-parents=0", "HEAD" },
							{ cwd = worktree_path, ignore_error = true }
						)
						if first_commit and first_commit ~= "" then
							snapshot_commit = first_commit:gsub("^%s+", ""):gsub("%s+$", "")
						end
					end

					if (not snapshot_commit or snapshot_commit == "") and persisted_by_path[worktree_path] then
						snapshot_commit = persisted_by_path[worktree_path].snapshot_commit
					end

					local persisted_info = persisted_by_path[worktree_path]
					local created_at = persisted_info and persisted_info.created_at or os.time()

					if not persisted_info then
						local ts_part = uuid:match("^(%d+%-?%d+)%-")
						if ts_part then
							local year, month, day, hour, min, sec =
								ts_part:match("(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)")
							if year then
								created_at = os.time({
									year = tonumber(year),
									month = tonumber(month),
									day = tonumber(day),
									hour = tonumber(hour),
									min = tonumber(min),
									sec = tonumber(sec),
								}) or os.time()
							end
						end
					end

					M.worktrees[worktree_path] = {
						name = persisted_info and persisted_info.name or uuid:sub(1, 8),
						worktree_path = worktree_path,
						branch = branch,
						snapshot_commit = snapshot_commit,
						original_branch = persisted_info and persisted_info.original_branch or "main",
						repo_root = main_repo_root,
						uuid = uuid,
						created_at = created_at,
						addressed_hunks = persisted_info and persisted_info.addressed_hunks or {},
						manually_modified_files = persisted_info and persisted_info.manually_modified_files or {},
					}
				end
			end
		end
	end
end

function M.remove_worktree(worktree_path)
	local info = M.worktrees[worktree_path]
	if not info then
		return false, "Worktree not found"
	end

	local _, remove_code, remove_err = git_cmd(
		{ "worktree", "remove", "--force", worktree_path },
		{ cwd = info.repo_root, ignore_error = true }
	)
	git_cmd({ "branch", "-D", info.branch }, { cwd = info.repo_root, ignore_error = true })

	M.worktrees[worktree_path] = nil
	persist.remove_session(worktree_path)
	if vim.fn.isdirectory(worktree_path) == 1 then
		vim.fn.delete(worktree_path, "rf")
	end

	if remove_code ~= 0 then
		return false, "Failed to remove worktree: " .. (remove_err or "unknown error")
	end
	vim.notify("[Vibe] Removed worktree: " .. worktree_path, vim.log.levels.INFO)
	return true, nil
end

function M.discard_worktree(worktree_path)
	return M.remove_worktree(worktree_path)
end

function M.get_worktree_info(worktree_path)
	return M.worktrees[worktree_path]
end

function M.get_worktree_by_session(session_name)
	for _, info in pairs(M.worktrees) do
		if info.name == session_name then
			return info
		end
	end
	return nil
end

function M.cleanup_all_worktrees()
	for worktree_path, _ in pairs(M.worktrees) do
		M.remove_worktree(worktree_path)
	end
end

return M
