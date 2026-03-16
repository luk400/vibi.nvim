--- Unified classification-aware review renderer
--- Single rendering path for all review modes, replacing collapsed_conflict.lua,
--- conflict_buffer.lua, conflict_popup.lua, and inline diff rendering from diff.lua
local git = require("vibe.git")
local resolve = require("vibe.resolve")
local review_keymaps = require("vibe.review.keymaps")
local engine = require("vibe.review.engine")
local types = require("vibe.review.types")
local util = require("vibe.util")
local config = require("vibe.config")

local M = {}

M.ns = vim.api.nvim_create_namespace("vibe_review")

---@type table<integer, table> bufnr -> review state
M.buffer_state = {}

M.preview_winnr = nil
M.preview_bufnr = nil

--- Highlight group setup
function M.setup_highlights()
	-- Suggestions (blue)
	vim.api.nvim_set_hl(0, "VibeRegionSuggestion", { fg = "#74C0FC", bold = true, default = true })
	vim.api.nvim_set_hl(0, "VibeRegionSuggestionBg", { bg = "#1a2a3a", default = true })

	-- Convergent (green)
	vim.api.nvim_set_hl(0, "VibeRegionConvergent", { fg = "#69DB7C", bold = true, default = true })
	vim.api.nvim_set_hl(0, "VibeRegionConvergentBg", { bg = "#1a3a1a", default = true })

	-- Conflict (red)
	vim.api.nvim_set_hl(0, "VibeRegionConflict", { fg = "#FF6B6B", bg = "#3a1a1a", bold = true, default = true })

	-- Auto-merged (subtle)
	vim.api.nvim_set_hl(0, "VibeRegionAutoMerged", { bg = "#1a2a1a", default = true })

	-- Preview sections
	vim.api.nvim_set_hl(0, "VibePreviewUser", { fg = "#74C0FC", bold = true, default = true })
	vim.api.nvim_set_hl(0, "VibePreviewAI", { fg = "#69DB7C", bold = true, default = true })
	vim.api.nvim_set_hl(0, "VibePreviewBase", { fg = "#868E96", default = true })
	vim.api.nvim_set_hl(0, "VibePreviewKeymap", { fg = "#74C0FC", bold = true, default = true })

	-- Collapsed line highlights
	vim.api.nvim_set_hl(0, "VibeConflictCollapsed", { bg = "#3a1a1a", fg = "#FF6B6B", bold = true, default = true })
	vim.api.nvim_set_hl(0, "VibeSuggestionCollapsed", { bg = "#1a2a3a", fg = "#74C0FC", bold = true, default = true })
	vim.api.nvim_set_hl(0, "VibeConvergentCollapsed", { bg = "#1a3a1a", fg = "#69DB7C", bold = true, default = true })

	-- Sign definitions
	vim.fn.sign_define("VibeReviewConflict", { text = "!", texthl = "ErrorMsg" })
	vim.fn.sign_define("VibeReviewSuggestion", { text = "~", texthl = "WarningMsg" })
	vim.fn.sign_define("VibeReviewConvergent", { text = "=", texthl = "String" })
end

--- Get the current extmark line for a review item
local function get_current_line(bufnr, idx)
	local marks = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, idx * 1000, {})
	if marks and #marks > 0 then
		return marks[1]
	end
	return nil
end

--- Get highlight group for a classification
local function get_collapsed_hl(classification)
	if classification == types.CONFLICT then
		return "VibeConflictCollapsed"
	elseif classification == types.CONVERGENT then
		return "VibeConvergentCollapsed"
	else
		return "VibeSuggestionCollapsed"
	end
end

--- Get sign name for a classification
local function get_sign_name(classification)
	if classification == types.CONFLICT then
		return "VibeReviewConflict"
	elseif classification == types.CONVERGENT then
		return "VibeReviewConvergent"
	else
		return "VibeReviewSuggestion"
	end
end

--- Build collapsed text for a review item
local function build_collapse_text(item_num, total, region)
	local cls = region.classification
	local user_count = #(region.user_lines or {})
	local ai_count = #(region.ai_lines or {})

	if cls == types.USER_ONLY then
		return string.format(
			"[Your change %d/%d] %d lines modified -- (a)ccept (r)eject",
			item_num, total, user_count
		)
	elseif cls == types.AI_ONLY then
		return string.format(
			"[AI suggestion %d/%d] %d lines -- (a)ccept (r)eject",
			item_num, total, ai_count
		)
	elseif cls == types.CONVERGENT then
		return string.format(
			"[Both agree %d/%d] %d lines -- (a)ccept (r)eject",
			item_num, total, user_count
		)
	elseif cls == types.CONFLICT then
		local ct = region.conflict_type or types.MOD_VS_MOD
		if ct == types.MOD_VS_DEL then
			return string.format(
				"[Conflict %d/%d] %d yours vs deletion -- (u)keep (d)elete (e)dit",
				item_num, total, user_count
			)
		elseif ct == types.DEL_VS_MOD then
			return string.format(
				"[Conflict %d/%d] deletion vs %d AI -- (d)elete (a)keep (e)dit",
				item_num, total, ai_count
			)
		else
			return string.format(
				"[Conflict %d/%d] %d yours, %d AI -- (u)yours (a)AI (e)dit",
				item_num, total, user_count, ai_count
			)
		end
	end
	return string.format("[Region %d/%d]", item_num, total)
end

--- Show file with unified classification-aware review
function M.show_file(worktree_path, filepath, hunks, merge_mode)
	merge_mode = merge_mode or config.options.merge_mode or "user"

	local info = git.get_worktree_info(worktree_path)
	if not info then
		return
	end

	local user_file_path = info.repo_root .. "/" .. filepath
	local user_exists = vim.fn.filereadable(user_file_path) == 1

	local user_lines = {}
	if user_exists then
		local bufnr = vim.fn.bufnr(user_file_path)
		if bufnr ~= -1 then
			user_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		else
			user_lines = vim.fn.readfile(user_file_path)
		end
	end

	local result = engine.prepare_review(user_lines, worktree_path, filepath, info.name, merge_mode)
	local classified_file = result.classified_file
	local merged_lines = result.merged_lines
	local summary = result.summary

	-- Ensure directory exists
	local dir = vim.fn.fnamemodify(user_file_path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end

	vim.cmd("edit " .. vim.fn.fnameescape(user_file_path))
	local bufnr = vim.api.nvim_get_current_buf()

	-- Start with user's file content as the base buffer
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, user_lines)

	-- Separate regions into review items and auto-resolved items
	local review_items = {}
	local auto_items = {}
	for _, region in ipairs(classified_file.regions) do
		if region.auto_resolved then
			table.insert(auto_items, region)
		else
			table.insert(review_items, region)
		end
	end

	M.buffer_state[bufnr] = {
		worktree_path = worktree_path,
		filepath = filepath,
		session_name = info.name,
		classified_file = classified_file,
		merge_mode = merge_mode,
		review_items = review_items,
		auto_items = auto_items,
		item_contents = {},
		resolved_count = 0,
		original_lines = vim.deepcopy(user_lines),
		merged_lines = merged_lines,
	}

	M.setup_highlights()
	M.collapse_review_items(bufnr)
	M.highlight_auto_merged(bufnr)
	M.setup_tracking(bufnr)
	M.setup_keymaps(bufnr)

	if #review_items > 0 then
		local first_line = get_current_line(bufnr, 1) or 0
		vim.api.nvim_win_set_cursor(0, { first_line + 1, 0 })
		vim.defer_fn(function()
			M.show_preview()
		end, 50)

		local parts = {}
		if summary.conflict_count > 0 then
			table.insert(parts, summary.conflict_count .. " conflict(s)")
		end
		if summary.review_count > 0 then
			table.insert(parts, summary.review_count .. " suggestion(s)")
		end
		if summary.auto_count > 0 then
			table.insert(parts, summary.auto_count .. " auto-merged")
		end
		vim.notify(
			string.format("[Vibe] %s to review. %s", #review_items .. " item(s)", table.concat(parts, ", ")),
			vim.log.levels.INFO
		)
	else
		-- All auto-merged, apply and finalize
		vim.notify("[Vibe] All changes safely auto-merged. Saving...", vim.log.levels.INFO)
		M.apply_auto_merged_and_finalize(bufnr)
	end
end

--- Apply auto-merged regions to the buffer content and finalize
function M.apply_auto_merged_and_finalize(bufnr)
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end

	-- Build the resolved file content by applying all auto-resolved regions
	-- For auto-resolved: accept the change (user_lines for USER_ONLY, ai_lines for AI_ONLY, etc.)
	local resolved_lines = M._build_resolved_content(state)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, resolved_lines)

	-- Mark all auto items as addressed
	for _, region in ipairs(state.auto_items) do
		local action = resolve.resolution_to_action_v2(region.classification, "accept")
		M._mark_region_addressed(state, region, action)
	end

	M.finalize_file(bufnr)
end

--- Build resolved content from user lines + applying auto-resolved changes
function M._build_resolved_content(state)
	local base_lines = state.original_lines
	local regions = state.classified_file.regions

	-- If no regions with changes, return original
	if #regions == 0 then
		return vim.deepcopy(base_lines)
	end

	-- For auto-resolved regions, we need to figure out what the "accepted" version looks like
	-- The simplest approach: start from user's content and apply AI-only changes
	-- But we need a proper reconstruction. Let's compute the "desired" output.
	--
	-- The user_lines in each region tell us what the user's version looks like,
	-- and ai_lines tell us AI's version. base_lines tells us the original.
	--
	-- For auto-resolved:
	-- - USER_ONLY: keep user's version (already in the file)
	-- - AI_ONLY: use AI's version
	-- - CONVERGENT: use either (they're the same)
	--
	-- For review items (not auto): keep user's version (they'll be handled interactively)

	-- Since we're starting from the user's file content, USER_ONLY changes are already there.
	-- We only need to apply AI_ONLY and CONVERGENT (auto-resolved) changes.
	-- This requires mapping base ranges to user file positions.

	-- Actually, the safest approach is to reconstruct from base + all accepted changes.
	-- Let's use the classified regions to build the output.

	-- Get base (snapshot) lines
	local snapshot_lines = git.get_worktree_snapshot_lines(state.worktree_path, state.filepath)

	-- Build output by walking through base lines and applying changes
	local result = {}
	local base_pos = 1

	-- Sort regions by base_range start
	local sorted_regions = {}
	for _, r in ipairs(regions) do
		table.insert(sorted_regions, r)
	end
	table.sort(sorted_regions, function(a, b)
		return a.base_range[1] < b.base_range[1]
	end)

	for _, region in ipairs(sorted_regions) do
		local rstart = region.base_range[1]
		local rend = region.base_range[2]

		-- Add unchanged lines before this region
		while base_pos < rstart do
			table.insert(result, snapshot_lines[base_pos] or "")
			base_pos = base_pos + 1
		end

		-- Determine what lines to use for this region
		local replacement
		if region.auto_resolved then
			-- Use the accepted version
			if region.classification == types.USER_ONLY or region.classification == types.CONVERGENT then
				replacement = region.user_lines
			elseif region.classification == types.AI_ONLY then
				replacement = region.ai_lines
			else
				replacement = region.user_lines
			end
		else
			-- Not auto-resolved: keep user's version for now (will be handled interactively)
			replacement = region.user_lines
		end

		for _, line in ipairs(replacement or {}) do
			table.insert(result, line)
		end

		-- Skip the base lines covered by this region
		if rstart <= rend then
			base_pos = rend + 1
		end
	end

	-- Add remaining base lines
	while base_pos <= #snapshot_lines do
		table.insert(result, snapshot_lines[base_pos] or "")
		base_pos = base_pos + 1
	end

	return result
end

--- Collapse review items into single-line summaries in the buffer
function M.collapse_review_items(bufnr)
	local state = M.buffer_state[bufnr]
	if not state or #state.review_items == 0 then
		return
	end

	-- We need to find where each review item's region appears in the current buffer
	-- The buffer contains the user's file content. Review items correspond to
	-- regions that the user has in their file. We need to map base_range to buffer lines.

	-- For simplicity, we'll use the base_range to find the corresponding user lines
	-- in the buffer. Since the buffer starts as user_lines, and user's changes may have
	-- shifted line numbers relative to base, we need a mapping.

	-- Compute user line offsets from base using vim.diff
	local snapshot_lines = git.get_worktree_snapshot_lines(state.worktree_path, state.filepath)
	local user_lines = state.original_lines

	-- Build a map: base line -> user line
	local base_to_user = M._build_line_map(snapshot_lines, user_lines)

	local total_items = #state.review_items
	local total_shift = 0

	for i, region in ipairs(state.review_items) do
		local rstart = region.base_range[1]
		local rend = region.base_range[2]

		-- Map base range to user buffer lines
		local user_start = (base_to_user[rstart] or rstart) + total_shift
		local user_end

		-- Figure out how many user lines this region covers
		local user_line_count = #(region.user_lines or {})
		if user_line_count > 0 then
			user_end = user_start + user_line_count - 1
		else
			user_end = user_start - 1 -- zero-width (deletion)
		end

		-- Store the original content
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local content_lines = {}
		for li = user_start, math.min(user_end, #lines) do
			table.insert(content_lines, lines[li] or "")
		end
		state.item_contents[i] = {
			original_lines = content_lines,
			region = region,
			buffer_start = user_start, -- 1-indexed
		}

		-- Build collapse text
		local collapse_text = build_collapse_text(i, total_items, region)

		-- Replace the region with collapsed line (0-indexed for API)
		local api_start = user_start - 1
		local api_end = math.max(user_start - 1, user_end)
		if user_line_count == 0 then
			-- Insertion point: insert a line at this position
			vim.api.nvim_buf_set_lines(bufnr, api_start, api_start, false, { collapse_text })
			total_shift = total_shift + 1
		else
			vim.api.nvim_buf_set_lines(bufnr, api_start, api_end, false, { collapse_text })
			total_shift = total_shift + (1 - user_line_count)
		end

		-- Add extmark and sign
		local sign_id = i * 1000
		local hl_group = get_collapsed_hl(region.classification)
		local sign_name = get_sign_name(region.classification)

		pcall(vim.fn.sign_place, sign_id, "vibe_review", sign_name, bufnr, { lnum = api_start + 1 })
		vim.api.nvim_buf_set_extmark(bufnr, M.ns, api_start, 0, {
			id = sign_id,
			end_col = #collapse_text,
			hl_group = hl_group,
			priority = 200,
		})

		region._extmark_idx = i
		region._resolved = false
	end
end

--- Build a mapping from base line numbers to user file line numbers
function M._build_line_map(base_lines, user_lines)
	local base_str = table.concat(base_lines, "\n") .. (#base_lines > 0 and "\n" or "")
	local user_str = table.concat(user_lines, "\n") .. (#user_lines > 0 and "\n" or "")

	local hunks = vim.diff(base_str, user_str, { result_type = "indices" }) or {}

	-- Build the map by walking through hunks
	local map = {}
	local base_pos = 1
	local user_pos = 1

	for _, hunk in ipairs(hunks) do
		local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]

		-- Map unchanged lines before this hunk
		while base_pos < start_a do
			map[base_pos] = user_pos
			base_pos = base_pos + 1
			user_pos = user_pos + 1
		end

		-- Map the hunk: base lines start_a..start_a+count_a-1 -> user lines start_b
		if count_a > 0 then
			map[start_a] = (count_b > 0) and start_b or start_b
			for j = 1, count_a - 1 do
				map[start_a + j] = start_b + math.min(j, math.max(0, count_b - 1))
			end
		elseif count_a == 0 then
			-- Insertion: base line start_a maps to user line start_b
			map[start_a] = start_b
		end

		base_pos = (count_a > 0) and (start_a + count_a) or (start_a + 1)
		user_pos = (count_b > 0) and (start_b + count_b) or start_b
	end

	-- Map remaining lines
	while base_pos <= #base_lines do
		map[base_pos] = user_pos
		base_pos = base_pos + 1
		user_pos = user_pos + 1
	end

	return map
end

--- Highlight auto-merged regions in the buffer
function M.highlight_auto_merged(bufnr)
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end

	-- Auto-merged regions are shown with subtle background
	-- Since we haven't modified these regions in the buffer (they're in user's content),
	-- we can highlight them based on their buffer positions
	-- For now, add virtual text annotations
	for _, region in ipairs(state.auto_items) do
		-- We'd need to know the buffer line for this region
		-- For simplicity, add a note via extmark at estimated position
		-- This is a best-effort annotation
	end
end

--- Get the review item at cursor position
function M.get_item_at_cursor(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return nil, nil
	end

	local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
	for i, region in ipairs(state.review_items) do
		if not region._resolved then
			local line = get_current_line(bufnr, i)
			if line and cursor_line == line then
				return region, i
			end
		end
	end
	return nil, nil
end

function M.is_preview_visible()
	return M.preview_winnr ~= nil and vim.api.nvim_win_is_valid(M.preview_winnr)
end

function M.close_preview()
	if M.preview_winnr and vim.api.nvim_win_is_valid(M.preview_winnr) then
		vim.api.nvim_win_close(M.preview_winnr, true)
	end
	M.preview_winnr, M.preview_bufnr = nil, nil
end

--- Show preview popup for the item at cursor
function M.show_preview()
	local bufnr = vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end

	local region, idx = M.get_item_at_cursor(bufnr)
	if not region or region._resolved then
		M.close_preview()
		return
	end

	M.close_preview()

	local cls = region.classification
	local info = types.classification_info[cls] or { label = "Region" }

	-- Build preview content
	local preview_lines = {}
	local hl_ranges = {} -- {line_idx, hl_group}

	if cls == types.CONFLICT then
		table.insert(preview_lines, "━━━━━━━━━ Yours ━━━━━━━━━")
		table.insert(hl_ranges, { #preview_lines, "VibePreviewUser" })
		if #(region.user_lines or {}) > 0 then
			for _, line in ipairs(region.user_lines) do
				table.insert(preview_lines, line)
				table.insert(hl_ranges, { #preview_lines, "VibePreviewUser" })
			end
		else
			table.insert(preview_lines, "(empty / deleted)")
			table.insert(hl_ranges, { #preview_lines, "VibePreviewBase" })
		end

		table.insert(preview_lines, "")
		table.insert(preview_lines, "━━━━━━━━━━ AI ━━━━━━━━━━")
		table.insert(hl_ranges, { #preview_lines, "VibePreviewAI" })
		if #(region.ai_lines or {}) > 0 then
			for _, line in ipairs(region.ai_lines) do
				table.insert(preview_lines, line)
				table.insert(hl_ranges, { #preview_lines, "VibePreviewAI" })
			end
		else
			table.insert(preview_lines, "(empty / deleted)")
			table.insert(hl_ranges, { #preview_lines, "VibePreviewBase" })
		end

		table.insert(preview_lines, "")
		table.insert(preview_lines, "── Actions ──")
		table.insert(preview_lines, "[u] yours  [a] AI  [e] edit manually  [q] close")
	else
		-- Suggestion preview
		table.insert(preview_lines, "━━━━━━━━━ Base ━━━━━━━━━")
		table.insert(hl_ranges, { #preview_lines, "VibePreviewBase" })
		if #(region.base_lines or {}) > 0 then
			for _, line in ipairs(region.base_lines) do
				table.insert(preview_lines, line)
				table.insert(hl_ranges, { #preview_lines, "VibePreviewBase" })
			end
		else
			table.insert(preview_lines, "(new content)")
			table.insert(hl_ranges, { #preview_lines, "VibePreviewBase" })
		end

		table.insert(preview_lines, "")
		local change_label
		if cls == types.USER_ONLY then
			change_label = "━━━━━ Your version ━━━━━"
		elseif cls == types.AI_ONLY then
			change_label = "━━━━━ AI version ━━━━━━"
		else
			change_label = "━━━━ Agreed change ━━━━"
		end
		table.insert(preview_lines, change_label)

		local change_lines = (cls == types.AI_ONLY) and region.ai_lines or region.user_lines
		local change_hl = (cls == types.AI_ONLY) and "VibePreviewAI" or "VibePreviewUser"
		table.insert(hl_ranges, { #preview_lines, change_hl })
		if #(change_lines or {}) > 0 then
			for _, line in ipairs(change_lines) do
				table.insert(preview_lines, line)
				table.insert(hl_ranges, { #preview_lines, change_hl })
			end
		else
			table.insert(preview_lines, "(deleted)")
			table.insert(hl_ranges, { #preview_lines, "VibePreviewBase" })
		end

		table.insert(preview_lines, "")
		table.insert(preview_lines, "── Actions ──")
		table.insert(preview_lines, "[a] accept  [r] reject  [q] close")
	end

	-- Create preview buffer
	M.preview_bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(M.preview_bufnr, 0, -1, false, preview_lines)
	vim.bo[M.preview_bufnr].bufhidden = "wipe"
	vim.bo[M.preview_bufnr].modifiable = false

	local width = 60
	local height = math.min(#preview_lines + 2, 20)
	local row = math.max(0, math.floor((vim.api.nvim_win_get_height(0) - height) / 2))
	local col = math.max(0, math.floor((vim.api.nvim_win_get_width(0) - width) / 2))

	local title = " " .. info.label .. " "

	M.preview_winnr = vim.api.nvim_open_win(M.preview_bufnr, false, {
		relative = "win",
		win = 0,
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = title,
		title_pos = "center",
		zindex = 100,
	})

	-- Apply highlights
	local ns_preview = vim.api.nvim_create_namespace("vibe_preview_hl")
	for _, hl in ipairs(hl_ranges) do
		pcall(vim.api.nvim_buf_add_highlight, M.preview_bufnr, ns_preview, hl[2], hl[1] - 1, 0, -1)
	end
	-- Highlight action line
	pcall(
		vim.api.nvim_buf_add_highlight,
		M.preview_bufnr,
		ns_preview,
		"VibePreviewKeymap",
		#preview_lines - 1,
		0,
		-1
	)

	-- Preview keymaps
	if cls == types.CONFLICT then
		review_keymaps.setup_preview(M.preview_bufnr, {
			keep_user = function()
				M.close_preview()
				M.resolve_item("keep_user")
			end,
			keep_ai = function()
				M.close_preview()
				M.resolve_item("keep_ai")
			end,
			edit_manually = function()
				M.close_preview()
				M.resolve_item("edit_manually")
			end,
			close = M.close_preview,
		}, cls)
	else
		review_keymaps.setup_preview(M.preview_bufnr, {
			accept = function()
				M.close_preview()
				M.resolve_item("accept")
			end,
			reject = function()
				M.close_preview()
				M.resolve_item("reject")
			end,
			close = M.close_preview,
		}, cls)
	end
end

--- Resolve the review item at cursor
function M.resolve_item(resolution)
	local bufnr = vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return false
	end

	local region, idx = M.get_item_at_cursor(bufnr)
	if not region then
		return false
	end

	-- For "edit_manually", open the edit float
	if resolution == "edit_manually" then
		M.open_edit_float(bufnr, region, idx)
		return true
	end

	local replacement_lines = resolve.get_replacement_for_region(region.classification, resolution, region)
	if not replacement_lines then
		return false
	end

	local item_line = get_current_line(bufnr, idx)
	if not item_line then
		return false
	end

	-- Use undojoin so resolution can be undone with 'u' key... wait, 'u' is mapped.
	-- Use pcall to avoid error if this is the first change
	pcall(vim.cmd, "undojoin")

	-- Remove extmark and sign
	pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, idx * 1000)
	pcall(vim.fn.sign_unplace, "vibe_review", { buffer = bufnr, id = idx * 1000 })

	-- Replace collapsed line with resolved content
	vim.api.nvim_buf_set_lines(bufnr, item_line, item_line + 1, false, replacement_lines)

	region._resolved = true
	state.resolved_count = state.resolved_count + 1

	-- Mark as addressed
	local action = resolve.resolution_to_action_v2(region.classification, resolution)
	M._mark_region_addressed(state, region, action)

	local remaining = M.count_remaining(bufnr)
	if remaining == 0 then
		M.finalize_file(bufnr)
	else
		M.next_item(bufnr)
		vim.defer_fn(M.show_preview, 50)
		vim.notify(string.format("[Vibe] Resolved. %d remaining", remaining), vim.log.levels.INFO)
	end
	return true
end

--- Open edit-manually float for a conflict
function M.open_edit_float(bufnr, region, idx)
	M.close_preview()

	-- Build initial content with both sides
	local edit_lines = {}
	table.insert(edit_lines, "<<<<<<< YOURS")
	for _, line in ipairs(region.user_lines or {}) do
		table.insert(edit_lines, line)
	end
	table.insert(edit_lines, "=======")
	for _, line in ipairs(region.ai_lines or {}) do
		table.insert(edit_lines, line)
	end
	table.insert(edit_lines, ">>>>>>> AI")

	-- Create scratch buffer
	local edit_bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(edit_bufnr, 0, -1, false, edit_lines)
	vim.bo[edit_bufnr].bufhidden = "wipe"
	vim.bo[edit_bufnr].buftype = "nofile"
	vim.bo[edit_bufnr].filetype = vim.bo[bufnr].filetype -- match syntax

	-- Open centered float
	local width = math.min(80, math.floor(vim.o.columns * 0.7))
	local height = math.min(#edit_lines + 4, math.floor(vim.o.lines * 0.6))
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local edit_winid = vim.api.nvim_open_win(edit_bufnr, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " Edit Conflict (Enter=confirm, q=cancel) ",
		title_pos = "center",
		zindex = 110,
	})

	-- Set up keymaps
	local function confirm_edit()
		local result_lines = vim.api.nvim_buf_get_lines(edit_bufnr, 0, -1, false)
		-- Filter out conflict markers if user left them
		local clean_lines = {}
		for _, line in ipairs(result_lines) do
			if
				not line:match("^<<<<<<< ")
				and not line:match("^=======$")
				and not line:match("^>>>>>>> ")
			then
				table.insert(clean_lines, line)
			end
		end

		if vim.fn.confirm("Accept this resolution?", "&Yes\n&No", 2) == 1 then
			vim.api.nvim_win_close(edit_winid, true)
			-- Apply the edit
			local item_line = get_current_line(bufnr, idx)
			if item_line then
				pcall(vim.cmd, "undojoin")
				pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, idx * 1000)
				pcall(vim.fn.sign_unplace, "vibe_review", { buffer = bufnr, id = idx * 1000 })
				vim.api.nvim_buf_set_lines(bufnr, item_line, item_line + 1, false, clean_lines)

				local state = M.buffer_state[bufnr]
				if state then
					region._resolved = true
					state.resolved_count = state.resolved_count + 1
					M._mark_region_addressed(state, region, "accepted")

					local remaining = M.count_remaining(bufnr)
					if remaining == 0 then
						M.finalize_file(bufnr)
					else
						M.next_item(bufnr)
						vim.defer_fn(M.show_preview, 50)
						vim.notify(
							string.format("[Vibe] Conflict resolved. %d remaining", remaining),
							vim.log.levels.INFO
						)
					end
				end
			end
		end
	end

	local function cancel_edit()
		vim.api.nvim_win_close(edit_winid, true)
	end

	vim.keymap.set("n", "<CR>", confirm_edit, { buffer = edit_bufnr, silent = true })
	vim.keymap.set("n", "q", cancel_edit, { buffer = edit_bufnr, silent = true })
end

--- Mark a region as addressed in the hunk tracking system
function M._mark_region_addressed(state, region, action)
	-- Create a dummy hunk for the tracking system
	local dummy_hunk = {
		old_start = region.base_range[1],
		old_count = region.base_range[2] - region.base_range[1] + 1,
		new_start = region.base_range[1],
		new_count = #(region.ai_lines or {}),
		removed_lines = region.base_lines or {},
		added_lines = region.ai_lines or {},
		type = "change",
	}
	pcall(git.mark_hunk_addressed, state.worktree_path, state.filepath, dummy_hunk, action)
end

function M.count_remaining(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	local count = 0
	if state then
		for _, region in ipairs(state.review_items) do
			if not region._resolved then
				count = count + 1
			end
		end
	end
	return count
end

function M.next_item(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
	for i, region in ipairs(state.review_items) do
		if not region._resolved then
			local line = get_current_line(bufnr, i)
			if line and line > cursor_line then
				vim.api.nvim_win_set_cursor(0, { line + 1, 0 })
				return
			end
		end
	end
	-- Wrap around
	for i, region in ipairs(state.review_items) do
		if not region._resolved then
			local line = get_current_line(bufnr, i)
			if line then
				vim.api.nvim_win_set_cursor(0, { line + 1, 0 })
				return
			end
		end
	end
end

function M.prev_item(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
	for i = #state.review_items, 1, -1 do
		local region = state.review_items[i]
		if not region._resolved then
			local line = get_current_line(bufnr, i)
			if line and line < cursor_line then
				vim.api.nvim_win_set_cursor(0, { line + 1, 0 })
				return
			end
		end
	end
	-- Wrap around
	for i = #state.review_items, 1, -1 do
		local region = state.review_items[i]
		if not region._resolved then
			local line = get_current_line(bufnr, i)
			if line then
				vim.api.nvim_win_set_cursor(0, { line + 1, 0 })
				return
			end
		end
	end
end

function M.accept_all(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end

	local remaining = M.count_remaining(bufnr)
	if remaining == 0 then
		M.finalize_file(bufnr)
		return
	end

	-- Resolve all remaining items from bottom to top
	for i = #state.review_items, 1, -1 do
		local region = state.review_items[i]
		if not region._resolved then
			local item_line = get_current_line(bufnr, i)
			if item_line then
				local resolution
				if region.classification == types.CONFLICT then
					resolution = "keep_ai"
				else
					resolution = "accept"
				end

				local replacement = resolve.get_replacement_for_region(region.classification, resolution, region)
				if replacement then
					pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, i * 1000)
					pcall(vim.fn.sign_unplace, "vibe_review", { buffer = bufnr, id = i * 1000 })
					vim.api.nvim_buf_set_lines(bufnr, item_line, item_line + 1, false, replacement)

					region._resolved = true
					state.resolved_count = state.resolved_count + 1
					local action = resolve.resolution_to_action_v2(region.classification, resolution)
					M._mark_region_addressed(state, region, action)
				end
			end
		end
	end

	vim.notify("[Vibe] All items accepted", vim.log.levels.INFO)
	M.finalize_file(bufnr)
end

function M.quit(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if
		M.count_remaining(bufnr) > 0
		and vim.fn.confirm("Unresolved item(s). Quit anyway?", "&Yes\n&No", 2) ~= 1
	then
		return
	end
	M.close_preview()
	if state then
		vim.cmd("edit!")
		M.buffer_state[bufnr] = nil
		vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
		vim.fn.sign_unplace("vibe_review", { buffer = bufnr })
	end
	if state and state.worktree_path then
		require("vibe.dialog").show(state.worktree_path)
	end
end

function M.finalize_file(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = M.buffer_state[bufnr]
	if not state then
		return
	end

	-- Mark auto-merged items as addressed
	for _, region in ipairs(state.auto_items) do
		local action = resolve.resolution_to_action_v2(region.classification, "accept")
		M._mark_region_addressed(state, region, action)
	end

	local user_file_path = vim.api.nvim_buf_get_name(bufnr)
	vim.fn.mkdir(vim.fn.fnamemodify(user_file_path, ":h"), "p")
	vim.cmd("write")
	git.sync_resolved_file(state.worktree_path, state.filepath, user_file_path)

	M.buffer_state[bufnr] = nil
	vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
	vim.fn.sign_unplace("vibe_review", { buffer = bufnr })
	M.close_preview()
	util.check_remaining_files(state.worktree_path)
end

function M.setup_tracking(bufnr)
	local group = vim.api.nvim_create_augroup("Vibe_review_" .. bufnr, { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = bufnr,
		callback = function()
			local region = M.get_item_at_cursor(bufnr)
			if region and not region._resolved then
				if not M.is_preview_visible() then
					M.show_preview()
				end
			else
				M.close_preview()
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufLeave", { group = group, buffer = bufnr, callback = M.close_preview })
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = bufnr,
		callback = function()
			M.buffer_state[bufnr] = nil
			M.close_preview()
		end,
	})
end

function M.setup_keymaps(bufnr)
	review_keymaps.setup(bufnr, {
		get_item_at_cursor = function()
			local region, _ = M.get_item_at_cursor(bufnr)
			return region
		end,
		resolve = function(resolution)
			M.close_preview()
			M.resolve_item(resolution)
		end,
		next_item = function()
			M.next_item(bufnr)
		end,
		prev_item = function()
			M.prev_item(bufnr)
		end,
		quit = function()
			M.quit(bufnr)
		end,
	})

	-- Accept all via command
	vim.api.nvim_buf_create_user_command(bufnr, "VibeAcceptAll", function()
		M.accept_all(bufnr)
	end, { desc = "Accept all review items" })
end

function M.setup()
	M.setup_highlights()
end

function M.clear(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	M.buffer_state[bufnr] = nil
	vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
	vim.fn.sign_unplace("vibe_review", { buffer = bufnr })
	M.close_preview()
end

function M.is_review_buffer(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	return M.buffer_state[bufnr] ~= nil
end

return M
