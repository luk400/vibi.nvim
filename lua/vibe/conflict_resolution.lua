local terminal = require("vibe.terminal")
local git = require("vibe.git")
local worktree_mod = require("vibe.git.worktree")
local git_cmd_mod = require("vibe.git.cmd")
local util = require("vibe.util")

local M = {}

local HEADER_LINES = 2
local LINES_PER_ITEM = 2

function M.gather_worktree_context(info)
	local changed_files = git.get_worktree_changed_files(info.worktree_path)
	local commit_messages = git.get_worktree_commit_messages(info.worktree_path)
	return {
		name = info.name,
		worktree_path = info.worktree_path,
		branch = info.branch,
		changed_files = changed_files,
		commit_messages = commit_messages,
	}
end

local function strip_ansi(line)
	return (line:gsub("\27%[[%d;]*[A-Za-z]", ""):gsub("\r", ""))
end

function M.get_conversation_log(session_name)
	local session = terminal.sessions[session_name]
	if session and session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
		local ok, raw_lines = pcall(vim.api.nvim_buf_get_lines, session.bufnr, 0, -1, false)
		if ok and #raw_lines > 0 then
			local cleaned = {}
			for _, line in ipairs(raw_lines) do
				table.insert(cleaned, strip_ansi(line))
			end
			return cleaned
		end
	end

	local log_dir = vim.fn.stdpath("data") .. "/vibe-logs"
	if vim.fn.isdirectory(log_dir) == 1 then
		local safe_name = session_name:gsub("[^%w_-]", "_")
		local pattern = log_dir .. "/" .. safe_name .. "_*.log"
		local files = vim.fn.glob(pattern, false, true)
		if #files > 0 then
			table.sort(files)
			local raw_lines = vim.fn.readfile(files[#files])
			local cleaned = {}
			for _, line in ipairs(raw_lines) do
				table.insert(cleaned, strip_ansi(line))
			end
			return cleaned
		end
	end

	return nil
end

function M.copy_conversation_logs(merge_worktree_path, selected_worktrees)
	local conv_dir = merge_worktree_path .. "/worktree_conversations"
	vim.fn.mkdir(conv_dir, "p")

	local has_logs = {}
	for _, info in ipairs(selected_worktrees) do
		local log_lines = M.get_conversation_log(info.name)
		if log_lines then
			local safe_name = info.name:gsub("[^%w_-]", "_")
			vim.fn.writefile(log_lines, conv_dir .. "/" .. safe_name .. ".log")
			has_logs[info.name] = true
		else
			has_logs[info.name] = false
		end
	end
	return has_logs
end

function M.build_merge_prompt(contexts, has_logs)
	has_logs = has_logs or {}

	local any_logs = false
	for _, v in pairs(has_logs) do
		if v then
			any_logs = true
			break
		end
	end

	local lines = {}
	table.insert(lines, "Your job is to merge changes from " .. #contexts .. " worktree(s) into the current directory.")
	table.insert(lines, "")
	table.insert(
		lines,
		"For each worktree below, merge its branch into the current branch using `git merge <branch-name>`."
	)
	table.insert(
		lines,
		"Resolve any merge conflicts that arise. After merging all branches, verify the code compiles/works."
	)

	if any_logs then
		table.insert(lines, "")
		table.insert(
			lines,
			"Conversation logs for each worktree are in ./worktree_conversations/ — read them for context on what each agent was working on."
		)
	end
	table.insert(lines, "")

	for i, ctx in ipairs(contexts) do
		table.insert(lines, "## Worktree " .. i .. ": " .. ctx.name)
		table.insert(lines, "Branch: " .. ctx.branch)
		table.insert(lines, "Path: " .. ctx.worktree_path)
		if any_logs then
			if has_logs[ctx.name] then
				local safe_name = ctx.name:gsub("[^%w_-]", "_")
				table.insert(lines, "Conversation log: ./worktree_conversations/" .. safe_name .. ".log")
			else
				table.insert(lines, "Conversation log: (no conversation log available)")
			end
		end
		table.insert(lines, "")

		if #ctx.changed_files > 0 then
			table.insert(lines, "### Changed files:")
			for _, f in ipairs(ctx.changed_files) do
				table.insert(lines, "- " .. f)
			end
		else
			table.insert(lines, "### Changed files: (none detected)")
		end
		table.insert(lines, "")

		if #ctx.commit_messages > 0 then
			table.insert(lines, "### Commit messages:")
			for _, msg in ipairs(ctx.commit_messages) do
				table.insert(lines, "- " .. msg)
			end
		else
			table.insert(lines, "### Commit messages: (none)")
		end
		table.insert(lines, "")
	end

	table.insert(lines, "---")
	table.insert(lines, "")
	table.insert(lines, "Instructions:")
	if any_logs then
		table.insert(
			lines,
			"1. Read the conversation logs in ./worktree_conversations/ to understand what each worktree was doing"
		)
		table.insert(lines, "2. Merge each branch one at a time using: git merge <branch-name>")
		table.insert(
			lines,
			"3. If a merge conflict occurs, resolve it by examining both sides and choosing the correct resolution"
		)
		table.insert(lines, "4. After all merges, verify the result makes sense")
		table.insert(lines, "5. Only merge the branches listed above - do not merge any other branches")
	else
		table.insert(lines, "1. Merge each branch one at a time using: git merge <branch-name>")
		table.insert(
			lines,
			"2. If a merge conflict occurs, resolve it by examining both sides and choosing the correct resolution"
		)
		table.insert(lines, "3. After all merges, verify the result makes sense")
		table.insert(lines, "4. Only merge the branches listed above - do not merge any other branches")
	end

	return lines
end

function M.show_merge_prompt(contexts, has_logs)
	local prompt_lines = M.build_merge_prompt(contexts, has_logs)

	local display_lines = {}
	table.insert(display_lines, " Copy the prompt below and paste it into the agent")
	local sep = " " .. string.rep("-", 65)
	table.insert(display_lines, sep)
	table.insert(display_lines, "")
	for _, line in ipairs(prompt_lines) do
		table.insert(display_lines, " " .. line)
	end
	table.insert(display_lines, "")
	table.insert(display_lines, sep)
	table.insert(display_lines, " y yank to clipboard  q close")

	local bufnr, _, close = util.create_centered_float({
		lines = display_lines,
		filetype = "vibe_merge_prompt",
		min_width = 70,
		max_height = 30,
		title = "Vibe: Merge Prompt",
		cursorline = false,
		zindex = 100,
		no_default_keymaps = true,
	})

	local ns = vim.api.nvim_create_namespace("vibe_merge_prompt")
	vim.api.nvim_buf_add_highlight(bufnr, ns, "Title", 0, 0, -1)
	vim.api.nvim_buf_add_highlight(bufnr, ns, "Comment", 1, 0, -1)
	vim.api.nvim_buf_add_highlight(bufnr, ns, "Comment", #display_lines - 2, 0, -1)
	vim.api.nvim_buf_add_highlight(bufnr, ns, "Comment", #display_lines - 1, 0, -1)

	local opts = { buffer = bufnr, silent = true }

	vim.keymap.set("n", "y", function()
		local prompt_text = table.concat(prompt_lines, "\n")
		vim.fn.setreg("+", prompt_text)
		vim.fn.setreg('"', prompt_text)
		vim.notify("[Vibe] Merge prompt copied to clipboard", vim.log.levels.INFO)
		close()
	end, opts)

	vim.keymap.set("n", "q", close, opts)
	vim.keymap.set("n", "<Esc>", close, opts)
end

function M.start_merge_session(all_worktrees, selected_map)
	local selected_worktrees = {}
	for _, info in ipairs(all_worktrees) do
		if selected_map[info.worktree_path] then
			table.insert(selected_worktrees, info)
		end
	end

	local name = "merge-" .. os.date("%H%M%S")
	local base_name = name
	local counter = 1
	while terminal.sessions[name] do
		name = base_name .. "_" .. counter
		counter = counter + 1
	end

	local cwd = vim.fn.getcwd()

	terminal.get_or_create(name, cwd, function(session)
		if not session then
			return
		end
		session.winid = require("vibe.window").create(session.bufnr, name)
		vim.cmd("startinsert")

		local has_logs = M.copy_conversation_logs(session.worktree_path, selected_worktrees)

		local contexts = {}
		for _, info in ipairs(selected_worktrees) do
			table.insert(contexts, M.gather_worktree_context(info))
		end

		vim.defer_fn(function()
			M.show_merge_prompt(contexts, has_logs)
		end, 200)
	end)
end

function M.show_worktree_selector(worktrees)
	local selected = {}
	local cursor_idx = 1

	local file_counts = {}
	for _, info in ipairs(worktrees) do
		file_counts[info.worktree_path] = #git.get_worktree_changed_files(info.worktree_path)
	end

	local function build_lines()
		local lines = {}
		table.insert(lines, " Merge Worktrees")
		table.insert(lines, " " .. string.rep("-", 50))

		for i, info in ipairs(worktrees) do
			local check = selected[info.worktree_path] and "x" or " "
			local pointer = (i == cursor_idx) and ">" or " "
			local count = file_counts[info.worktree_path] or 0
			local count_str = count == 1 and "(1 file changed)" or ("(" .. count .. " files changed)")
			table.insert(lines, string.format(" %s [%s] %s  %s", pointer, check, info.name, count_str))
			table.insert(lines, string.format("       %s", vim.fn.pathshorten(info.worktree_path)))
		end

		table.insert(lines, "")
		local sel_count = vim.tbl_count(selected)
		table.insert(
			lines,
			string.format(" %d selected  |  <Space> toggle  |  a all  |  <CR> confirm  |  q cancel", sel_count)
		)
		return lines
	end

	local lines = build_lines()
	local bufnr, winid, close = util.create_centered_float({
		lines = lines,
		filetype = "vibe_conflict_select",
		min_width = 60,
		title = "Vibe: Conflict Resolution",
		cursorline = true,
		zindex = 100,
		no_default_keymaps = true,
	})

	local ns = vim.api.nvim_create_namespace("vibe_conflict_select")

	local function render()
		local new_lines = build_lines()
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
		vim.bo[bufnr].modifiable = false

		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		vim.api.nvim_buf_add_highlight(bufnr, ns, "Title", 0, 0, -1)
		vim.api.nvim_buf_add_highlight(bufnr, ns, "Comment", 1, 0, -1)

		for i, info in ipairs(worktrees) do
			local name_line = HEADER_LINES + (i - 1) * LINES_PER_ITEM
			local path_line = name_line + 1
			if selected[info.worktree_path] then
				vim.api.nvim_buf_add_highlight(bufnr, ns, "String", name_line, 0, -1)
			end
			vim.api.nvim_buf_add_highlight(bufnr, ns, "Comment", path_line, 0, -1)
		end

		vim.api.nvim_buf_add_highlight(bufnr, ns, "Comment", #new_lines - 1, 0, -1)

		if vim.api.nvim_win_is_valid(winid) then
			local target_line = HEADER_LINES + (cursor_idx - 1) * LINES_PER_ITEM + 1
			vim.api.nvim_win_set_cursor(winid, { target_line, 2 })
		end
	end

	render()

	local opts = { buffer = bufnr, silent = true }

	local function move_down()
		if cursor_idx < #worktrees then
			cursor_idx = cursor_idx + 1
			render()
		end
	end

	local function move_up()
		if cursor_idx > 1 then
			cursor_idx = cursor_idx - 1
			render()
		end
	end

	vim.keymap.set("n", "j", move_down, opts)
	vim.keymap.set("n", "<Down>", move_down, opts)
	vim.keymap.set("n", "k", move_up, opts)
	vim.keymap.set("n", "<Up>", move_up, opts)

	vim.keymap.set("n", "<Space>", function()
		local info = worktrees[cursor_idx]
		if info then
			if selected[info.worktree_path] then
				selected[info.worktree_path] = nil
			else
				selected[info.worktree_path] = true
			end
			render()
		end
	end, opts)

	vim.keymap.set("n", "a", function()
		local all_selected = vim.tbl_count(selected) == #worktrees
		if all_selected then
			selected = {}
		else
			for _, info in ipairs(worktrees) do
				selected[info.worktree_path] = true
			end
		end
		render()
	end, opts)

	vim.keymap.set("n", "<CR>", function()
		local sel_count = vim.tbl_count(selected)
		if sel_count == 0 then
			vim.notify("[Vibe] Select at least 1 worktree to merge", vim.log.levels.WARN)
			return
		end
		close()
		M.start_merge_session(worktrees, selected)
	end, opts)

	vim.keymap.set("n", "q", close, opts)
	vim.keymap.set("n", "<Esc>", close, opts)
end

function M.show()
	git.scan_for_vibe_worktrees()

	local repo_root = worktree_mod.get_repo_root(vim.fn.getcwd())
	if not repo_root then
		vim.notify("[Vibe] Not inside a git repository", vim.log.levels.ERROR)
		return
	end

	local eligible = {}
	for _, info in pairs(git.worktrees) do
		if
			vim.fn.isdirectory(info.worktree_path) == 1
			and info.repo_root == repo_root
		then
			local _, exit_code = git_cmd_mod.git_cmd(
				{ "rev-parse", "--verify", info.branch },
				{ cwd = info.repo_root, ignore_error = true }
			)
			if exit_code == 0 then
				table.insert(eligible, info)
			end
		end
	end

	if #eligible == 0 then
		vim.notify("[Vibe] No active worktrees to merge", vim.log.levels.INFO)
		return
	end

	table.sort(eligible, function(a, b)
		return a.name < b.name
	end)

	M.show_worktree_selector(eligible)
end

return M
