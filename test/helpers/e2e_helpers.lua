-- test/helpers/e2e_helpers.lua
-- Helpers for true end-to-end merge review tests
local git = require("vibe.git")
local renderer = require("vibe.review.renderer")
local helpers = require("test.helpers.git_repo")

local M = {}

--- Create a complete test scenario with repo + worktree + edits
---@param opts table { name, base_files, user_edits?, ai_edits }
---@return table { repo_path, worktree_path, info }
function M.setup_scenario(opts)
	local repo_path = helpers.create_test_repo(opts.name, opts.base_files)
	local info = git.create_worktree(helpers.unique_name(opts.name) .. "-sess", repo_path)
	assert(info, "Failed to create worktree")

	-- Apply user edits (to repo_root, after snapshot)
	if opts.user_edits then
		for filepath, content in pairs(opts.user_edits) do
			helpers.write_file(info.repo_root .. "/" .. filepath, content)
		end
	end

	-- Apply AI edits (to worktree)
	for filepath, content in pairs(opts.ai_edits) do
		helpers.write_file(info.worktree_path .. "/" .. filepath, content)
	end

	return {
		repo_path = repo_path,
		worktree_path = info.worktree_path,
		info = info,
	}
end

--- Open a file for review via the full renderer.show_file pipeline
---@param scenario table from setup_scenario
---@param filepath string relative file path
---@param merge_mode string "none"|"user"|"ai"|"both"
---@return integer bufnr
function M.open_review(scenario, filepath, merge_mode)
	-- show_file handles the :edit internally
	renderer.show_file(scenario.worktree_path, filepath, nil, merge_mode)
	local bufnr = vim.api.nvim_get_current_buf()
	-- Flush deferred preview
	vim.wait(60, function()
		return false
	end)
	return bufnr
end

--- Simulate keypresses via feedkeys
---@param keys string Key sequence (supports <leader>, ]c, etc.)
function M.feed(keys)
	local leader = vim.g.mapleader or "\\"
	keys = keys:gsub("<leader>", leader)
	local raw = vim.api.nvim_replace_termcodes(keys, true, false, true)
	vim.api.nvim_feedkeys(raw, "mx", false)
	-- Flush event loop for deferred callbacks
	vim.wait(30, function()
		return false
	end)
end

--- Wait for the file dialog to open (after finalize triggers check_remaining_files)
---@param timeout_ms integer? default 500
---@return boolean opened
function M.wait_for_dialog(timeout_ms)
	local dialog = require("vibe.dialog")
	local ok = vim.wait(timeout_ms or 500, function()
		return dialog.is_open()
	end, 20)
	return ok ~= false and dialog.is_open()
end

--- Wait for the file dialog to close
---@param timeout_ms integer? default 500
function M.wait_for_dialog_closed(timeout_ms)
	local dialog = require("vibe.dialog")
	vim.wait(timeout_ms or 500, function()
		return not dialog.is_open()
	end, 20)
end

--- Read file contents from disk
---@param path string absolute path
---@return string[]
function M.read_file(path)
	return vim.fn.readfile(path)
end

--- Format lines for debug output
---@param lines string[]
---@param label string
---@return string
local function format_lines_debug(lines, label)
	local parts = { label .. " (" .. #lines .. " lines):" }
	for i, line in ipairs(lines) do
		table.insert(parts, string.format("  %d: '%s'", i, line))
	end
	return table.concat(parts, "\n")
end

--- Assert file contents match expected lines (with full debug output on failure)
---@param path string absolute path
---@param expected string[] expected lines
function M.assert_file_contents(path, expected)
	local actual = vim.fn.readfile(path)
	local debug_msg = "\n"
		.. format_lines_debug(expected, "EXPECTED")
		.. "\n"
		.. format_lines_debug(actual, "ACTUAL")

	assert.are.equal(#expected, #actual, "Line count mismatch for " .. path .. debug_msg)
	for i = 1, #expected do
		if expected[i] ~= actual[i] then
			error(string.format("Line %d mismatch: expected '%s' got '%s'%s", i, expected[i], actual[i], debug_msg))
		end
	end
end

--- Get renderer buffer state
function M.get_state(bufnr)
	return renderer.buffer_state[bufnr]
end

--- Dump debug info about the current review buffer state
---@param bufnr integer
---@return string
function M.debug_dump(bufnr)
	local parts = { "=== E2E DEBUG DUMP ===" }
	local state = renderer.buffer_state[bufnr]

	table.insert(parts, string.format("bufnr=%d  valid=%s  buftype='%s'  name='%s'", bufnr, tostring(vim.api.nvim_buf_is_valid(bufnr)), vim.bo[bufnr].buftype, vim.api.nvim_buf_get_name(bufnr)))

	if not state then
		table.insert(parts, "NO BUFFER STATE (already finalized?)")
	else
		table.insert(parts, string.format("review_items=%d  auto_items=%d  resolved=%d  remaining=%d", #state.review_items, #state.auto_items, state.resolved_count, renderer.count_remaining(bufnr)))

		local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		table.insert(parts, format_lines_debug(buf_lines, "BUFFER CONTENT"))

		for i, region in ipairs(state.review_items) do
			table.insert(parts, string.format("  review[%d]: cls=%s resolved=%s base_lines=%d", i, region.classification, tostring(region._resolved), #(region.base_lines or {})))
			local ic = state.item_contents[i]
			if ic then
				table.insert(parts, string.format("    stored_lines=%d  is_deletion=%s", #(ic.stored_lines or {}), tostring(ic.is_deletion_sentinel)))
			end
		end
		for i, region in ipairs(state.auto_items) do
			local aic = state.auto_item_contents[i]
			table.insert(parts, string.format("  auto[%d]: cls=%s rejected=%s dismissed=%s sentinel=%s", i, region.classification, tostring(region._rejected), tostring(region._dismissed), tostring(aic and aic.is_sentinel)))
		end
	end
	table.insert(parts, "=== END DEBUG ===")
	return table.concat(parts, "\n")
end

--- Get count of remaining unresolved review items
function M.count_remaining(bufnr)
	return renderer.count_remaining(bufnr)
end

--- Cleanup scenario resources
function M.cleanup()
	-- Close floating windows
	pcall(renderer.close_preview)
	pcall(renderer.close_hint)

	local dialog = require("vibe.dialog")
	if dialog.is_open() then
		pcall(dialog.close)
	end

	-- Clear renderer state
	for bufnr, _ in pairs(renderer.buffer_state) do
		renderer.buffer_state[bufnr] = nil
		pcall(vim.api.nvim_buf_clear_namespace, bufnr, renderer.ns, 0, -1)
		pcall(vim.api.nvim_buf_clear_namespace, bufnr, renderer.ns_auto, 0, -1)
		pcall(vim.fn.sign_unplace, "vibe_review", { buffer = bufnr })
	end

	-- Wipe all buffers
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
		end
	end

	-- Remove worktrees
	for path, _ in pairs(git.worktrees) do
		pcall(git.remove_worktree, path)
	end

	-- Clean up repos
	helpers.cleanup_all()
end

return M
