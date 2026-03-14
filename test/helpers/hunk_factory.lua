--- Factory for creating test hunks with specific properties
local M = {}

--- Create an add hunk
---@param opts table { start, lines }
function M.add(opts)
	opts = opts or {}
	local lines = opts.lines or { "added line" }
	return {
		type = "add",
		old_start = opts.start or 0,
		old_count = 0,
		new_start = (opts.start or 0) + 1,
		new_count = #lines,
		added_lines = lines,
		removed_lines = {},
		user_added_indices = opts.user_added_indices or {},
		lines = {},
	}
end

--- Create a delete hunk
---@param opts table { start, lines, user_added_indices }
function M.delete(opts)
	opts = opts or {}
	local lines = opts.lines or { "deleted line" }
	return {
		type = "delete",
		old_start = opts.start or 1,
		old_count = #lines,
		new_start = opts.start or 1,
		new_count = 0,
		added_lines = {},
		removed_lines = lines,
		user_added_indices = opts.user_added_indices or {},
		lines = {},
	}
end

--- Create a change hunk
---@param opts table { start, removed, added, user_added_indices }
function M.change(opts)
	opts = opts or {}
	local removed = opts.removed or { "old line" }
	local added = opts.added or { "new line" }
	return {
		type = "change",
		old_start = opts.start or 1,
		old_count = #removed,
		new_start = opts.start or 1,
		new_count = #added,
		added_lines = added,
		removed_lines = removed,
		user_added_indices = opts.user_added_indices or {},
		lines = {},
	}
end

return M
