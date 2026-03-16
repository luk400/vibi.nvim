local types = require("vibe.review.types")

local M = {}

--- Resolve a suggestion (USER_ONLY / AI_ONLY / CONVERGENT)
---@param action string "accept" | "reject"
---@param change_lines string[] The changed lines
---@param base_lines string[] The original base lines
---@return string[]
function M.resolve_suggestion(action, change_lines, base_lines)
	if action == "accept" then
		return change_lines
	else
		return base_lines
	end
end

--- Resolve a conflict
---@param action string "keep_user" | "keep_ai" | "edit_manually"
---@param user_lines string[]
---@param ai_lines string[]
---@return string[]|nil nil signals renderer should open edit buffer
function M.resolve_conflict(action, user_lines, ai_lines)
	if action == "keep_user" then
		return user_lines
	elseif action == "keep_ai" then
		return ai_lines
	elseif action == "edit_manually" then
		return nil
	end
	return user_lines
end

--- Map a classification + resolution to an action string for mark_hunk_addressed
---@param classification string
---@param resolution string
---@return string "accepted"|"rejected"
function M.resolution_to_action_v2(classification, resolution)
	if classification == types.USER_ONLY then
		return resolution == "accept" and "accepted" or "rejected"
	elseif classification == types.AI_ONLY then
		return resolution == "accept" and "accepted" or "rejected"
	elseif classification == types.CONVERGENT then
		return resolution == "accept" and "accepted" or "rejected"
	elseif classification == types.CONFLICT then
		if resolution == "keep_user" then
			return "rejected"
		elseif resolution == "keep_ai" then
			return "accepted"
		elseif resolution == "edit_manually" then
			return "accepted" -- user edited = accepted with modifications
		end
	end
	return "rejected"
end

--- Get replacement lines based on classification and resolution
--- Unified interface for the renderer
---@param classification string
---@param resolution string
---@param region table ClassifiedRegion
---@return string[]|nil
function M.get_replacement_for_region(classification, resolution, region)
	if classification == types.CONFLICT then
		return M.resolve_conflict(resolution, region.user_lines, region.ai_lines)
	end

	-- For suggestions: determine which lines are the "change" and which are "base"
	local change_lines, base_lines
	if classification == types.USER_ONLY then
		change_lines = region.user_lines
		base_lines = region.base_lines
	elseif classification == types.AI_ONLY then
		change_lines = region.ai_lines
		base_lines = region.base_lines
	elseif classification == types.CONVERGENT then
		change_lines = region.user_lines -- both sides agree
		base_lines = region.base_lines
	else
		return region.base_lines
	end

	local action = (resolution == "accept") and "accept" or "reject"
	return M.resolve_suggestion(action, change_lines, base_lines)
end

-- Legacy compat wrappers (used by old code paths during transition)
function M.get_replacement_lines(resolution, ours_lines, theirs_lines)
	if resolution == "ours" then
		return ours_lines
	elseif resolution == "theirs" then
		return theirs_lines
	elseif resolution == "both" then
		local result = {}
		for _, line in ipairs(ours_lines) do
			table.insert(result, line)
		end
		for _, line in ipairs(theirs_lines) do
			table.insert(result, line)
		end
		return result
	elseif resolution == "none" then
		return {}
	end
	return ours_lines
end

function M.resolution_to_action(resolution)
	if resolution == "ours" then
		return "rejected"
	elseif resolution == "theirs" then
		return "accepted"
	elseif resolution == "both" then
		return "accepted"
	elseif resolution == "none" then
		return "rejected"
	end
	return "rejected"
end

return M
