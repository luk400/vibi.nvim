local util = require("vibe.util")
local git_cmd_mod = require("vibe.git.cmd")
local git_cmd = git_cmd_mod.git_cmd

local M = {}

-- State
M.bufnr = nil
M.winid = nil
M.current_path = ""
M.selected_items = {}
M.selected_dirs = {}
M.selected_idx = 1
M.entries = {}
M.repo_root = nil
M.worktree_path = nil
M.git_status_map = {}

function M.setup_highlights()
	vim.api.nvim_set_hl(0, "VibePickerUntracked", { default = true, fg = "#a6e3a1", bold = true })
	vim.api.nvim_set_hl(0, "VibePickerModified", { default = true, fg = "#f9e2af" })
	vim.api.nvim_set_hl(0, "VibePickerIgnored", { default = true, fg = "#6c7086", italic = true })
	vim.api.nvim_set_hl(0, "VibePickerNormal", { default = true, link = "Normal" })
	vim.api.nvim_set_hl(0, "VibePickerSelected", { default = true, fg = "#a6e3a1", bold = true })
	vim.api.nvim_set_hl(0, "VibePickerDir", { default = true, fg = "#89b4fa", bold = true })
	vim.api.nvim_set_hl(0, "VibePickerHeader", { default = true, link = "Title" })
	vim.api.nvim_set_hl(0, "VibePickerFooter", { default = true, link = "Comment" })
end

--- Build git status map for the repo
---@param repo_root string
---@return table<string, string>
local function build_git_status_map(repo_root)
	local status_map = {}

	-- Modified/untracked from porcelain status
	local porcelain = git_cmd({ "status", "--porcelain" }, { cwd = repo_root, ignore_error = true })
	for line in (porcelain or ""):gmatch("[^\r\n]+") do
		if #line >= 4 then
			local xy = line:sub(1, 2)
			local file = line:sub(4)
			local arrow = file:find(" -> ")
			if arrow then
				file = file:sub(arrow + 4)
			end
			file = file:gsub("/$", "")
			if xy == "??" then
				status_map[file] = "untracked"
			else
				status_map[file] = "modified"
			end
		end
	end

	-- Gitignored files (often the files users want to copy: .env, configs, etc.)
	local ignored = git_cmd(
		{ "ls-files", "--others", "--ignored", "--exclude-standard" },
		{ cwd = repo_root, ignore_error = true }
	)
	for file in (ignored or ""):gmatch("[^\r\n]+") do
		if file ~= "" then
			status_map[file] = "ignored"
		end
	end

	return status_map
end

--- Recursively enumerate all files under a directory
---@param abs_dir string Absolute directory path
---@param repo_root string Repo root for computing relative paths
---@return string[]
local function enumerate_files_recursive(abs_dir, repo_root)
	local files = {}
	local handle = vim.uv.fs_scandir(abs_dir)
	if not handle then
		return files
	end
	while true do
		local name, ftype = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if name ~= ".git" then
			local full = abs_dir .. "/" .. name
			if ftype == "directory" then
				vim.list_extend(files, enumerate_files_recursive(full, repo_root))
			else
				table.insert(files, full:sub(#repo_root + 2))
			end
		end
	end
	return files
end

--- Scan current directory and populate M.entries
function M.scan_directory()
	M.entries = {}
	local abs_path = M.repo_root
	if M.current_path ~= "" then
		abs_path = abs_path .. "/" .. M.current_path
	end

	local handle = vim.uv.fs_scandir(abs_path)
	if not handle then
		return
	end

	local dirs = {}
	local file_list = {}
	while true do
		local name, ftype = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if name ~= ".git" then
			local rel_path = M.current_path == "" and name or (M.current_path .. "/" .. name)
			local entry = {
				name = name,
				type = ftype == "directory" and "directory" or "file",
				rel_path = rel_path,
				git_status = M.git_status_map[rel_path] or "normal",
			}
			if ftype == "directory" then
				table.insert(dirs, entry)
			else
				table.insert(file_list, entry)
			end
		end
	end

	table.sort(dirs, function(a, b)
		return a.name < b.name
	end)
	table.sort(file_list, function(a, b)
		return a.name < b.name
	end)

	vim.list_extend(M.entries, dirs)
	vim.list_extend(M.entries, file_list)
end

--- Check if a path (or any child for directories) is selected
---@param rel_path string
---@param entry_type string
---@return boolean
local function is_selected(rel_path, entry_type)
	if entry_type == "file" then
		return M.selected_items[rel_path] == true
	end
	local prefix = rel_path .. "/"
	for sel_path, _ in pairs(M.selected_items) do
		if vim.startswith(sel_path, prefix) then
			return true
		end
	end
	return false
end

--- Toggle selection on an entry (directories toggle all children recursively)
---@param entry table
function M.toggle_selection(entry)
	if entry.type == "file" then
		if M.selected_items[entry.rel_path] then
			M.selected_items[entry.rel_path] = nil
		else
			M.selected_items[entry.rel_path] = true
		end
	else
		-- Directory: if any child selected, deselect all; otherwise select all
		local prefix = entry.rel_path .. "/"
		local has_any = false
		for sel_path, _ in pairs(M.selected_items) do
			if vim.startswith(sel_path, prefix) then
				has_any = true
				break
			end
		end

		if has_any then
			local to_remove = {}
			for sel_path, _ in pairs(M.selected_items) do
				if vim.startswith(sel_path, prefix) then
					table.insert(to_remove, sel_path)
				end
			end
			for _, p in ipairs(to_remove) do
				M.selected_items[p] = nil
			end
			M.selected_dirs[entry.rel_path] = nil
		else
			local abs_dir = M.repo_root .. "/" .. entry.rel_path
			local sub_files = enumerate_files_recursive(abs_dir, M.repo_root)
			for _, f in ipairs(sub_files) do
				M.selected_items[f] = true
			end
			M.selected_dirs[entry.rel_path] = true
		end
	end
end

---@return integer
local function count_selected()
	local n = 0
	for _ in pairs(M.selected_items) do
		n = n + 1
	end
	return n
end

--- Build .vibeinclude entries from selected files and directory selections
---@param selected_list string[] List of selected file paths
---@param dir_selections table<string, boolean> Map of directory paths that were selected
---@return string[] entries List of patterns for .vibeinclude
function M.build_vibeinclude_entries(selected_list, dir_selections)
	local entries = {}
	local dir_set = dir_selections or {}

	-- Add directory patterns
	for dir, _ in pairs(dir_set) do
		table.insert(entries, dir .. "/**")
	end

	-- Add individual files not covered by a directory selection
	for _, file in ipairs(selected_list) do
		local covered = false
		for dir, _ in pairs(dir_set) do
			if vim.startswith(file, dir .. "/") then
				covered = true
				break
			end
		end
		if not covered then
			table.insert(entries, file)
		end
	end

	table.sort(entries)
	return entries
end

---@return integer
function M.get_total_items()
	local parent_offset = M.current_path ~= "" and 1 or 0
	return #M.entries + parent_offset
end

--- Get the entry at current selected index
---@return table|nil entry, boolean is_parent_link
function M.get_current_entry()
	local has_parent = M.current_path ~= ""
	if has_parent and M.selected_idx == 1 then
		return nil, true
	end
	local entry_idx = has_parent and (M.selected_idx - 1) or M.selected_idx
	return M.entries[entry_idx], false
end

function M.render()
	if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
		return
	end

	local lines = {}
	local hl_data = {} -- {line_idx, hl_group}

	-- Header
	local path_display = M.current_path == "" and "/" or ("/" .. M.current_path .. "/")
	table.insert(lines, "  Copy files to worktree: " .. path_display)
	table.insert(hl_data, { 0, "VibePickerHeader" })
	table.insert(lines, "")

	local has_parent = M.current_path ~= ""
	local item_idx = 0

	-- Parent directory link
	if has_parent then
		item_idx = item_idx + 1
		local pointer = item_idx == M.selected_idx and "▶" or " "
		table.insert(lines, pointer .. "   ../")
		table.insert(hl_data, { #lines - 1, "VibePickerDir" })
	end

	-- Directory/file entries
	for _, entry in ipairs(M.entries) do
		item_idx = item_idx + 1
		local pointer = item_idx == M.selected_idx and "▶" or " "
		local sel = is_selected(entry.rel_path, entry.type)
		local check = sel and "✓" or " "
		local display_name = entry.name
		if entry.type == "directory" then
			display_name = display_name .. "/"
		end
		local status_label = ""
		if entry.git_status == "untracked" then
			status_label = "  [untracked]"
		elseif entry.git_status == "modified" then
			status_label = "  [modified]"
		elseif entry.git_status == "ignored" then
			status_label = "  [ignored]"
		end

		table.insert(lines, pointer .. " " .. check .. " " .. display_name .. status_label)

		-- Determine highlight
		local hl_group
		if entry.type == "directory" then
			hl_group = "VibePickerDir"
		elseif sel then
			hl_group = "VibePickerSelected"
		elseif entry.git_status == "untracked" then
			hl_group = "VibePickerUntracked"
		elseif entry.git_status == "modified" then
			hl_group = "VibePickerModified"
		elseif entry.git_status == "ignored" then
			hl_group = "VibePickerIgnored"
		else
			hl_group = "VibePickerNormal"
		end
		table.insert(hl_data, { #lines - 1, hl_group })
	end

	if #M.entries == 0 and not has_parent then
		table.insert(lines, "  (empty directory)")
		table.insert(hl_data, { #lines - 1, "Comment" })
	end

	-- Footer
	table.insert(lines, "")
	table.insert(lines, "────────────────────────────────────────")
	table.insert(hl_data, { #lines - 1, "VibePickerFooter" })
	table.insert(
		lines,
		string.format("%d file(s) selected  |  <Tab> toggle  |  <C-y> confirm  |  q cancel", count_selected())
	)
	table.insert(hl_data, { #lines - 1, "VibePickerFooter" })

	vim.bo[M.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, lines)
	vim.bo[M.bufnr].modifiable = false

	-- Apply highlights
	for _, hl in ipairs(hl_data) do
		vim.api.nvim_buf_add_highlight(M.bufnr, -1, hl[2], hl[1], 0, -1)
	end

	-- Scroll to keep selected item visible
	if M.winid and vim.api.nvim_win_is_valid(M.winid) then
		local cursor_line = M.selected_idx + 2 -- +2 for header + blank (1-indexed)
		if cursor_line > #lines then
			cursor_line = #lines
		end
		pcall(vim.api.nvim_win_set_cursor, M.winid, { cursor_line, 0 })
	end
end

function M.enter_directory(dir_rel_path)
	M.current_path = dir_rel_path
	M.selected_idx = 1
	M.scan_directory()
	M.render()
end

function M.go_up()
	if M.current_path == "" then
		return
	end
	local parent = M.current_path:match("(.+)/[^/]+$") or ""
	M.current_path = parent
	M.selected_idx = 1
	M.scan_directory()
	M.render()
end

function M.setup_keymaps()
	local opts = { buffer = M.bufnr, silent = true, noremap = true }

	local function move_down()
		if M.selected_idx < M.get_total_items() then
			M.selected_idx = M.selected_idx + 1
			M.render()
		end
	end
	local function move_up()
		if M.selected_idx > 1 then
			M.selected_idx = M.selected_idx - 1
			M.render()
		end
	end

	vim.keymap.set("n", "j", move_down, opts)
	vim.keymap.set("n", "k", move_up, opts)
	vim.keymap.set("n", "<Down>", move_down, opts)
	vim.keymap.set("n", "<Up>", move_up, opts)

	-- Enter on file = toggle selection, on directory = enter it
	vim.keymap.set("n", "<CR>", function()
		local entry, is_parent = M.get_current_entry()
		if is_parent then
			M.go_up()
			return
		end
		if not entry then
			return
		end
		if entry.type == "directory" then
			M.enter_directory(entry.rel_path)
		else
			M.toggle_selection(entry)
			M.render()
		end
	end, opts)

	-- Right/l: enter directory
	local function enter_dir()
		local entry, is_parent = M.get_current_entry()
		if is_parent then
			M.go_up()
			return
		end
		if entry and entry.type == "directory" then
			M.enter_directory(entry.rel_path)
		end
	end
	vim.keymap.set("n", "l", enter_dir, opts)
	vim.keymap.set("n", "<Right>", enter_dir, opts)

	-- Left/h/BS: go up
	vim.keymap.set("n", "h", M.go_up, opts)
	vim.keymap.set("n", "<Left>", M.go_up, opts)
	vim.keymap.set("n", "<BS>", M.go_up, opts)

	-- Tab: toggle selection and advance cursor
	vim.keymap.set("n", "<Tab>", function()
		local entry, is_parent = M.get_current_entry()
		if is_parent or not entry then
			return
		end
		M.toggle_selection(entry)
		if M.selected_idx < M.get_total_items() then
			M.selected_idx = M.selected_idx + 1
		end
		M.render()
	end, opts)

	-- Ctrl-Y: confirm copy
	vim.keymap.set("n", "<C-y>", function()
		local selected_list = vim.tbl_keys(M.selected_items)
		if #selected_list == 0 then
			vim.notify("[Vibe] No files selected", vim.log.levels.WARN)
			return
		end
		local worktree_path = M.worktree_path
		local repo_root = M.repo_root
		local dir_selections = vim.deepcopy(M.selected_dirs)
		M.close()
		local worktree = require("vibe.git.worktree")
		local ok, err, copied_count = worktree.copy_files_to_active_worktree(worktree_path, selected_list)
		if ok then
			vim.notify(string.format("[Vibe] Copied %d file(s) to worktree", copied_count), vim.log.levels.INFO)
			-- Prompt to add selections to .vibeinclude
			vim.schedule(function()
				local choice = vim.fn.confirm(
					"[Vibe] Always copy these files when :Vibe is called?",
					"&Yes\n&No",
					2
				)
				if choice == 1 then
					local new_entries = M.build_vibeinclude_entries(selected_list, dir_selections)
					if #new_entries == 0 then
						return
					end

					local vibeinclude_path = repo_root .. "/.vibeinclude"
					local existing_lines = {}
					local existing_set = {}
					if vim.fn.filereadable(vibeinclude_path) == 1 then
						existing_lines = vim.fn.readfile(vibeinclude_path)
						for _, line in ipairs(existing_lines) do
							local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
							if trimmed ~= "" and not trimmed:match("^#") then
								existing_set[trimmed] = true
							end
						end
					else
						table.insert(existing_lines, "# Files to copy to worktree when :Vibe is called")
						table.insert(existing_lines, "# One pattern per line (supports globs)")
					end

					local added = 0
					for _, entry in ipairs(new_entries) do
						if not existing_set[entry] then
							table.insert(existing_lines, entry)
							added = added + 1
						end
					end

					if added > 0 then
						vim.fn.writefile(existing_lines, vibeinclude_path)
						vim.notify(
							string.format(
								"[Vibe] Added %d rule(s) to .vibeinclude (edit %s to change)",
								added,
								vibeinclude_path
							),
							vim.log.levels.INFO
						)
					else
						vim.notify("[Vibe] All patterns already in .vibeinclude", vim.log.levels.INFO)
					end
				end
			end)
		else
			vim.notify("[Vibe] Copy failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
		end
	end, opts)

	-- Cancel
	vim.keymap.set("n", "q", function()
		M.close()
	end, opts)
	vim.keymap.set("n", "<Esc>", function()
		M.close()
	end, opts)
end

function M.close()
	if M.winid and vim.api.nvim_win_is_valid(M.winid) then
		vim.api.nvim_win_close(M.winid, true)
	end
	M.winid = nil
	M.bufnr = nil
end

--- Open the file picker for copying files to a worktree
---@param worktree_path string
---@param repo_root string
function M.show(worktree_path, repo_root)
	M.close()
	M.setup_highlights()

	M.repo_root = repo_root
	M.worktree_path = worktree_path
	M.current_path = ""
	M.selected_items = {}
	M.selected_dirs = {}
	M.selected_idx = 1
	M.git_status_map = build_git_status_map(repo_root)

	M.scan_directory()

	local target_height = math.max(10, math.min(25, M.get_total_items() + 6))

	local bufnr, winid = util.create_centered_float({
		filetype = "vibe_file_picker",
		min_width = math.max(60, math.floor(vim.o.columns * 0.5)),
		height = target_height,
		title = "Vibe: Copy Files",
		cursorline = true,
		zindex = 200,
		no_default_keymaps = true,
	})

	M.bufnr = bufnr
	M.winid = winid
	vim.wo[winid].wrap = false

	M.render()
	M.setup_keymaps()
end

return M
