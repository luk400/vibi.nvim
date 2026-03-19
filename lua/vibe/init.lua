local config = require("vibe.config")
local terminal = require("vibe.terminal")
local session = require("vibe.session")
local status = require("vibe.status")
local diff = require("vibe.diff")
local git = require("vibe.git")
local dialog = require("vibe.dialog")
local persist = require("vibe.persist")

local M = {}

--- Smart toggle: context-sensitive behavior for :Vibe and <leader>v
---@param session_name_arg string|nil Explicit session name from :Vibe command
local function smart_vibe(session_name_arg)
	if session_name_arg and session_name_arg ~= "" then
		terminal.toggle(session_name_arg)
		return
	end

	local session_count = vim.tbl_count(terminal.sessions)
	if session_count == 0 then
		-- No sessions: show directory picker
		session.pick_directory(function(cwd)
			local name = vim.fn.fnamemodify(cwd, ":t")
			if name == "" then
				name = "root"
			end
			local base_name = name
			local counter = 1
			while terminal.sessions[name] do
				name = base_name .. "_" .. counter
				counter = counter + 1
			end
			terminal.toggle(name, cwd)
		end)
	else
		-- One or more sessions: show list
		session.show_list()
	end
end

---@param opts VibeConfig|nil
function M.setup(opts)
	config.setup(opts)

	-- Set up highlights
	status.setup_highlights()

	-- Set up diff display
	diff.setup()

	-- Set up quit protection
	M.setup_quit_protection()

	-- Show notification for paused sessions on startup
	vim.defer_fn(function()
		persist.cleanup_invalid_sessions()
		local paused = persist.get_valid_persisted_sessions()
		if #paused > 0 then
			vim.notify("[Vibe] " .. #paused .. " paused session(s). :VibeResume to resume.", vim.log.levels.INFO)
		end
	end, 1000)

	-- Create :Vibe command
	vim.api.nvim_create_user_command("Vibe", function(args)
		smart_vibe(args.args)
	end, {
		nargs = "?",
		desc = "Toggle Vibe floating terminal",
		complete = function(_, _, _)
			return vim.tbl_keys(terminal.sessions)
		end,
	})

	-- Create :VibeNew command to always create a new parallel session
	vim.api.nvim_create_user_command("VibeNew", function(args)
		local explicit_name = args.args ~= "" and args.args or nil
		if explicit_name then
			local name = explicit_name
			local base_name = name
			local counter = 1
			while terminal.sessions[name] do
				name = base_name .. "_" .. counter
				counter = counter + 1
			end
			terminal.toggle(name)
		else
			session.pick_directory(function(cwd)
				local name = vim.fn.fnamemodify(cwd, ":t")
				if name == "" then
					name = "root"
				end
				local base_name = name
				local counter = 1
				while terminal.sessions[name] do
					name = base_name .. "_" .. counter
					counter = counter + 1
				end
				terminal.toggle(name, cwd)
			end)
		end
	end, {
		nargs = "?",
		desc = "Create a new Vibe session (always creates, never toggles)",
	})

	-- Create :VibeKill command to terminate a session
	vim.api.nvim_create_user_command("VibeKill", function(args)
		if args.args ~= "" then
			terminal.kill(args.args)
		else
			session.show_kill_list()
		end
	end, {
		nargs = "?",
		desc = "Kill a Vibe session",
		complete = function(_, _, _)
			return vim.tbl_keys(terminal.sessions)
		end,
	})

	-- Create :VibeList command to show all sessions
	vim.api.nvim_create_user_command("VibeList", function()
		session.show_list()
	end, {
		desc = "List all Vibe sessions",
	})

	-- Create :VibeReview command to review changes from AI sessions
	vim.api.nvim_create_user_command("VibeReview", function()
		session.show_review_list()
	end, {
		desc = "Review changes from AI sessions",
	})

	-- Create :VibeResume command to resume paused sessions
	vim.api.nvim_create_user_command("VibeResume", function()
		session.show_resume_list()
	end, {
		desc = "Resume a previous Vibe session",
	})

	-- Create :VibeStatus command
	vim.api.nvim_create_user_command("VibeStatus", function()
		local sessions_list = session.list()
		if #sessions_list == 0 then
			vim.notify("[Vibe] No active sessions", vim.log.levels.INFO)
			return
		end
		local parts = {}
		for _, s in ipairs(sessions_list) do
			local state = s.is_active and "active" or (s.is_alive and "idle" or "dead")
			table.insert(parts, s.name .. " (" .. state .. ")")
		end
		vim.notify("[Vibe] " .. #sessions_list .. " session(s): " .. table.concat(parts, ", "), vim.log.levels.INFO)
	end, {
		desc = "Show Vibe session status summary",
	})

	-- Create :VibeDiff command
	vim.api.nvim_create_user_command("VibeDiff", function()
		diff.show_for_current_file()
	end, {
		desc = "Show inline diff for current file",
	})

	-- Create :VibeRename command
	vim.api.nvim_create_user_command("VibeRename", function(args)
		local parts_split = vim.split(args.args, "%s+")
		if #parts_split < 2 then
			vim.notify("[Vibe] Usage: :VibeRename old_name new_name", vim.log.levels.ERROR)
			return
		end
		local old_name = parts_split[1]
		local new_name = parts_split[2]
		if not terminal.sessions[old_name] then
			vim.notify("[Vibe] Session '" .. old_name .. "' not found", vim.log.levels.ERROR)
			return
		end
		if terminal.sessions[new_name] then
			vim.notify("[Vibe] Session '" .. new_name .. "' already exists", vim.log.levels.ERROR)
			return
		end
		local sess = terminal.sessions[old_name]
		terminal.sessions[new_name] = sess
		terminal.sessions[old_name] = nil
		sess.name = new_name
		if terminal.current_session == old_name then
			terminal.current_session = new_name
		end
		if sess.worktree_path and git.worktrees[sess.worktree_path] then
			git.worktrees[sess.worktree_path].name = new_name
		end
		vim.notify("[Vibe] Renamed '" .. old_name .. "' -> '" .. new_name .. "'", vim.log.levels.INFO)
	end, {
		nargs = "+",
		desc = "Rename a Vibe session",
		complete = function(_, _, _)
			return vim.tbl_keys(terminal.sessions)
		end,
	})

	-- Create :VibeLog command
	vim.api.nvim_create_user_command("VibeLog", function(args)
		local log_dir = vim.fn.stdpath("data") .. "/vibe-logs"
		if vim.fn.isdirectory(log_dir) ~= 1 then
			vim.notify("[Vibe] No logs found", vim.log.levels.INFO)
			return
		end
		local pattern = args.args ~= "" and (args.args:gsub("[^%w_-]", "_") .. "_*.log") or "*.log"
		local files = vim.fn.glob(log_dir .. "/" .. pattern, false, true)
		if #files == 0 then
			vim.notify("[Vibe] No logs found" .. (args.args ~= "" and (" for '" .. args.args .. "'") or ""), vim.log.levels.INFO)
			return
		end
		table.sort(files)
		vim.cmd("edit " .. vim.fn.fnameescape(files[#files]))
	end, {
		nargs = "?",
		desc = "View terminal log for a session",
		complete = function(_, _, _)
			return vim.tbl_keys(terminal.sessions)
		end,
	})

	-- Create :VibeHistory command
	vim.api.nvim_create_user_command("VibeHistory", function()
		require("vibe.history").show()
	end, {
		desc = "Show Vibe session history",
	})

	-- Create :VibeCancel command to cancel pending session creation
	vim.api.nvim_create_user_command("VibeCancel", function(args)
		if args.args ~= "" then
			terminal.cancel_creation(args.args)
		else
			terminal.cancel_all_creations()
		end
	end, {
		nargs = "?",
		desc = "Cancel pending Vibe session creation",
		complete = function(_, _, _)
			return vim.tbl_keys(terminal.creating)
		end,
	})

	-- Create :VibeCopyFiles command to copy local files to active worktree
	vim.api.nvim_create_user_command("VibeCopyFiles", function(args)
		local session_name = args.args ~= "" and args.args or terminal.current_session
		if not session_name then
			local names = vim.tbl_keys(terminal.sessions)
			if #names == 1 then
				session_name = names[1]
			elseif #names > 1 then
				vim.notify("[Vibe] Multiple sessions active. Specify: :VibeCopyFiles <name>", vim.log.levels.WARN)
				return
			else
				vim.notify("[Vibe] No active sessions", vim.log.levels.ERROR)
				return
			end
		end

		local sess = terminal.sessions[session_name]
		if not sess or not sess.worktree_path then
			vim.notify("[Vibe] Session '" .. session_name .. "' not found", vim.log.levels.ERROR)
			return
		end

		local info = git.get_worktree_info(sess.worktree_path)
		if not info then
			vim.notify("[Vibe] Worktree info not found", vim.log.levels.ERROR)
			return
		end

		require("vibe.file_picker").show(sess.worktree_path, info.repo_root)
	end, {
		nargs = "?",
		desc = "Copy local files to active Vibe worktree",
		complete = function()
			return vim.tbl_keys(terminal.sessions)
		end,
	})

	-- Create :VibeSync command to bulk-sync local changes to active worktree
	vim.api.nvim_create_user_command("VibeSync", function(args)
		local session_name = args.args ~= "" and args.args or terminal.current_session
		if not session_name then
			local names = vim.tbl_keys(terminal.sessions)
			if #names == 1 then
				session_name = names[1]
			elseif #names > 1 then
				vim.notify("[Vibe] Multiple sessions active. Specify: :VibeSync <name>", vim.log.levels.WARN)
				return
			else
				vim.notify("[Vibe] No active sessions", vim.log.levels.ERROR)
				return
			end
		end

		local sess = terminal.sessions[session_name]
		if not sess or not sess.worktree_path then
			vim.notify("[Vibe] Session '" .. session_name .. "' not found", vim.log.levels.ERROR)
			return
		end

		local ok, err, count = git.sync_local_to_worktree(sess.worktree_path)
		if not ok then
			vim.notify("[Vibe] Sync failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
		elseif count > 0 then
			vim.notify("[Vibe] Synced " .. count .. " file(s) to worktree", vim.log.levels.INFO)
		else
			vim.notify("[Vibe] Everything already in sync", vim.log.levels.INFO)
		end
	end, {
		nargs = "?",
		desc = "Sync local files to active Vibe worktree",
		complete = function()
			return vim.tbl_keys(terminal.sessions)
		end,
	})

	-- Create :VibeHelp command
	vim.api.nvim_create_user_command("VibeHelp", function()
		require("vibe.help").show()
	end, {
		desc = "Show context-sensitive Vibe help",
	})

	-- Set up keybinding
	if config.options.keymap then
		vim.keymap.set("n", config.options.keymap, function()
			smart_vibe()
		end, { silent = true, desc = "Toggle Vibe terminal" })
	end

	-- which-key integration
	local wk_ok, wk = pcall(require, "which-key")
	if wk_ok then
		pcall(wk.add, {
			{ "<leader>d", group = "Vibe Diff" },
			{ "<leader>v", desc = "Vibe Terminal" },
		})
	end
end

--- Set up quit protection for unresolved changes
function M.setup_quit_protection()
	if config.options.quit_protection == false then
		return
	end

	local group = vim.api.nvim_create_augroup("VibeQuitProtection", { clear = true })

	--- Prevent quit by creating a split window.
	--- After QuitPre, ex_quit sees only_one_window() is false (2 windows),
	--- so it just closes the original window instead of quitting Neovim.
	--- The split survives as the user's window (same buffer, same cursor).
	---@param after function|nil Optional callback to run after quit is prevented
	local function prevent_quit(after)
		vim.cmd("split")
		if after then
			vim.schedule(after)
		end
	end

	vim.api.nvim_create_autocmd("QuitPre", {
		group = group,
		callback = function()
			-- Skip when closing a floating window (e.g. the :Vibe terminal)
			local cur_win = vim.api.nvim_get_current_win()
			if vim.api.nvim_win_get_config(cur_win).relative ~= "" then
				return
			end

			-- Only intervene when closing the last real (non-floating) window
			local non_float_wins = 0
			for _, w in ipairs(vim.api.nvim_list_wins()) do
				if vim.api.nvim_win_get_config(w).relative == "" then
					non_float_wins = non_float_wins + 1
				end
			end
			if non_float_wins > 1 then
				return
			end

			-- Scope to current git repo
			local current_repo_root = git.get_repo_root(vim.fn.getcwd())
			if not current_repo_root then
				return
			end

			-- Check for unresolved AI changes (scoped to current repo)
			if git.has_worktrees_with_changes() then
				local worktrees = git.get_worktrees_with_changes()
				local total_files = 0
				for _, info in ipairs(worktrees) do
					if info.repo_root == current_repo_root then
						total_files = total_files + #git.get_unresolved_files(info.worktree_path)
					end
				end
				if total_files > 0 then
					vim.notify(
						"[Vibe] Warning: " .. total_files .. " file(s) with unresolved AI changes!",
						vim.log.levels.WARN
					)
					prevent_quit(function()
						session.show_review_list()
					end)
					return
				end
			end

			-- Check for active worktree sessions
			git.scan_for_vibe_worktrees()

			-- Filter to current repo
			local repo_worktrees = {}
			for wt_path, info in pairs(git.worktrees) do
				if info.repo_root == current_repo_root then
					repo_worktrees[wt_path] = info
				end
			end
			if next(repo_worktrees) == nil then
				return
			end

			local worktrees_with_changes = git.get_worktrees_with_changes()
			local total_unresolved = 0
			for _, info in ipairs(worktrees_with_changes) do
				if info.repo_root == current_repo_root then
					total_unresolved = total_unresolved + #git.get_unresolved_files(info.worktree_path)
				end
			end

			local session_count = 0
			for _ in pairs(repo_worktrees) do
				session_count = session_count + 1
			end

			local has_unresolved = total_unresolved > 0
			local choices = has_unresolved
					and "&Delete All Worktrees\n&Keep All Worktrees\n&Review Changes\n&Cancel"
				or "&Delete All Worktrees\n&Keep All Worktrees\n&Cancel"
			local default_choice = has_unresolved and 4 or 3
			local choice = vim.fn.confirm(
				string.format("[Vibe] %d session(s) exist. What would you like to do?", session_count),
				choices,
				default_choice
			)

			if choice == 0 or (has_unresolved and choice == 4) or (not has_unresolved and choice == 3) then
				-- Cancel: prevent quit silently
				prevent_quit()
			elseif choice == 1 then
				-- Delete worktrees (scoped to current repo) with confirmation
				local confirm = vim.fn.confirm(
					"[Vibe] Are you sure? This will permanently delete the worktree(s).",
					"&Yes\n&No", 2
				)
				if confirm ~= 1 then
					prevent_quit()
					return
				end
				terminal.cancel_all_creations()
				for wt_path, _ in pairs(repo_worktrees) do
					git.remove_worktree(wt_path)
				end
			elseif choice == 2 then
				-- Keep all worktrees
				terminal.cancel_all_creations()
				persist.mark_all_sessions_paused()
			elseif has_unresolved and choice == 3 then
				-- Review changes
				prevent_quit(function()
					session.show_review_list()
				end)
			end
		end,
	})

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			-- Fallback: mark any remaining sessions as paused for recovery
			git.scan_for_vibe_worktrees()
			if next(git.worktrees) ~= nil then
				persist.mark_all_sessions_paused()
			end
		end,
	})
end

-- General Public API
function M.toggle(name, cwd)
	terminal.toggle(name, cwd)
end
function M.open(name, cwd)
	terminal.show(name, cwd)
end
function M.close(name)
	terminal.hide(name)
end
function M.kill(name)
	terminal.kill(name)
end
function M.is_open(name)
	name = name or "default"
	local sess = terminal.sessions[name]
	return sess and sess.winid and vim.api.nvim_win_is_valid(sess.winid) or false
end
function M.list()
	return session.list()
end
function M.show_diff()
	diff.show_for_current_file()
end
function M.clear_diff()
	diff.clear()
end
function M.diff()
	return diff
end
function M.git()
	return git
end
function M.cancel_session()
	git.cancel_session()
end
function M.cancel()
	terminal.cancel_all_creations()
end
function M.has_unresolved_changes()
	return git.has_worktrees_with_changes()
end
function M.review()
	session.show_review_list()
end

--- Lualine-compatible statusline component
---@return string
function M.statusline()
	local total = vim.tbl_count(terminal.sessions)
	if total == 0 then
		return ""
	end
	local active = 0
	for name, _ in pairs(terminal.sessions) do
		if status.is_recently_active(name) then
			active = active + 1
		end
	end
	return string.format("Vibe(%d/%d)", active, total)
end

return M
