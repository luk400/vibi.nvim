--- Standalone merge module: builds resolved content from classified regions without UI dependencies
local types = require("vibe.review.types")

local M = {}

--- Build resolved file content by walking snapshot lines and substituting classified regions.
--- This is the headless equivalent of renderer._build_resolved_content, without sentinel logic.
---@param snapshot_lines string[] Base (snapshot) file lines
---@param regions table[] Classified regions with auto_resolved flags set
---@return string[] Merged file content
function M.build_resolved_content(snapshot_lines, regions)
	if #regions == 0 then
		return vim.deepcopy(snapshot_lines)
	end

	-- Sort regions by base_range start
	local sorted_regions = {}
	for _, r in ipairs(regions) do
		table.insert(sorted_regions, r)
	end
	table.sort(sorted_regions, function(a, b)
		return a.base_range[1] < b.base_range[1]
	end)

	local result = {}
	local base_pos = 1

	for _, region in ipairs(sorted_regions) do
		local rstart = region.base_range[1]
		local rend = region.base_range[2]
		local is_pure_insert = #(region.base_lines or {}) == 0

		-- Add unchanged lines before this region
		if is_pure_insert then
			-- Include the anchor line BEFORE inserting new content
			while base_pos <= rstart and base_pos <= #snapshot_lines do
				table.insert(result, snapshot_lines[base_pos])
				base_pos = base_pos + 1
			end
		else
			while base_pos < rstart and base_pos <= #snapshot_lines do
				table.insert(result, snapshot_lines[base_pos])
				base_pos = base_pos + 1
			end
		end

		-- Determine what lines to use for this region
		local replacement
		if region.auto_resolved then
			if region.classification == types.USER_ONLY or region.classification == types.CONVERGENT then
				replacement = region.user_lines
			elseif region.classification == types.AI_ONLY then
				replacement = region.ai_lines
			else
				-- Conflict fallback: keep user's version
				replacement = region.user_lines
			end
		else
			-- Not auto-resolved: keep user's version
			replacement = region.user_lines
		end

		for _, line in ipairs(replacement or {}) do
			table.insert(result, line)
		end

		-- Skip the base lines covered by this region (NOT for pure insertions)
		if not is_pure_insert and rstart <= rend then
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

--- Perform a complete 3-way merge for a file: classify + apply merge mode + build resolved content.
---@param worktree_path string Path to worktree
---@param filepath string Relative file path
---@param repo_root string Repo root path
---@param merge_mode string "none"|"user"|"ai"|"both"
---@return table { resolved_lines, has_conflicts, has_unresolved, auto_accept, classified_file, stats }
function M.merge_file(worktree_path, filepath, repo_root, merge_mode)
	local classifier = require("vibe.review.classifier")
	local git = require("vibe.git")

	merge_mode = merge_mode or "both"

	-- Classify the file (3-way: base=snapshot, user=current, AI=worktree)
	local classified_file = classifier.classify_file(worktree_path, filepath, repo_root)

	-- Handle trivial cases (both deleted, user-only new file, etc.)
	if classified_file.auto_accept then
		return {
			resolved_lines = nil,
			has_conflicts = false,
			has_unresolved = false,
			auto_accept = true,
			classified_file = classified_file,
			stats = { auto_count = 0, review_count = 0, conflict_count = 0 },
		}
	end

	-- Apply merge mode to determine auto-resolution
	local stats = classifier.apply_merge_mode(classified_file.regions, merge_mode)

	-- New AI files have no user content to merge with — always auto-resolve
	-- (matching engine.lua:29-39)
	if classified_file.file_status == types.FILE_NEW_AI then
		for _, region in ipairs(classified_file.regions) do
			if not region.auto_resolved then
				region.auto_resolved = true
				stats.auto_count = stats.auto_count + 1
				if stats.review_count > 0 then
					stats.review_count = stats.review_count - 1
				end
			end
		end
	end

	-- Get snapshot (base) lines
	local snapshot_lines = git.get_worktree_snapshot_lines(worktree_path, filepath)

	-- Build merged content
	local resolved_lines = M.build_resolved_content(snapshot_lines, classified_file.regions)

	return {
		resolved_lines = resolved_lines,
		has_conflicts = stats.conflict_count > 0,
		has_unresolved = stats.review_count > 0,
		auto_accept = false,
		classified_file = classified_file,
		stats = stats,
	}
end

return M
