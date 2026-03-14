local M = {}

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
