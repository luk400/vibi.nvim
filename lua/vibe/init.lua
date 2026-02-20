local config = require("vibe.config")
local terminal = require("vibe.terminal")
local session = require("vibe.session")
local status = require("vibe.status")
local diff = require("vibe.diff")
local git = require("vibe.git")
local dialog = require("vibe.dialog")
local persist = require("vibe.persist")

local M = {}

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
		if args.args ~= "" then
			terminal.toggle(args.args)
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
		desc = "Toggle Vibe floating terminal",
		complete = function(_, _, _)
			return vim.tbl_keys(terminal.sessions)
		end,
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

	-- Set up keybinding
	if config.options.keymap then
		vim.keymap.set("n", config.options.keymap, function()
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
		end, { silent = true, desc = "Toggle Vibe terminal" })
	end
end

--- Set up quit protection for unresolved changes
function M.setup_quit_protection()
	if config.options.quit_protection == false then
		return
	end

	local group = vim.api.nvim_create_augroup("VibeQuitProtection", { clear = true })

	vim.api.nvim_create_autocmd("CmdlineLeave", {
		group = group,
		callback = function(args)
			local cmd = vim.v.event.cmdline or ""
			if cmd:match("^[qwx]a?%s*$") or cmd:match("^%s*q%s*$") or cmd:match("^%s*q!%s*$") then
				if git.has_worktrees_with_changes() then
					local worktrees = git.get_worktrees_with_changes()
					local total_files = 0
					for _, info in ipairs(worktrees) do
						total_files = total_files + #git.get_unresolved_files(info.worktree_path)
					end
					if total_files > 0 then
						vim.notify(
							"[Vibe] Warning: " .. total_files .. " file(s) with unresolved AI changes will be lost!",
							vim.log.levels.WARN
						)
					end
					vim.schedule(function()
						session.show_review_list()
					end)
				end
			end
		end,
	})

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			git.scan_for_vibe_worktrees()
			local has_worktrees = next(git.worktrees) ~= nil

			if has_worktrees then
				local worktrees_with_changes = git.get_worktrees_with_changes()
				local total_unresolved = 0
				for _, info in ipairs(worktrees_with_changes) do
					total_unresolved = total_unresolved + #git.get_unresolved_files(info.worktree_path)
				end

				local session_count = 0
				for _ in pairs(git.worktrees) do
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

				if choice == 1 then
					git.cleanup_all_worktrees()
				elseif choice == 2 then
					persist.mark_all_sessions_paused()
				elseif has_unresolved and choice == 3 then
					vim.schedule(function()
						session.show_review_list()
					end)
					return false
				elseif (has_unresolved and choice == 4) or (not has_unresolved and choice == 3) then
					return false
				end
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
function M.accept_hunk()
	diff.accept_hunk()
end
function M.reject_hunk()
	diff.reject_hunk()
end
function M.accept_all_in_file()
	diff.accept_all_in_file()
end
function M.reject_all_in_file()
	diff.reject_all_in_file()
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
function M.has_unresolved_changes()
	return git.has_worktrees_with_changes()
end
function M.review()
	session.show_review_list()
end

return M
