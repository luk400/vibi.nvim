--- Dynamic keybind display utilities for review buffers
--- Provides desc constants and lookup functions so hint strings
--- always reflect the actual registered keymaps.
local M = {}

-- Desc constants used at both registration and lookup sites
M.DESC_ACCEPT = "Accept / Keep AI"
M.DESC_REJECT = "Reject change"
M.DESC_KEEP_YOURS = "Keep yours (conflicts)"
M.DESC_EDIT = "Edit manually (conflicts)"
M.DESC_NEXT = "Next review item"
M.DESC_PREV = "Previous review item"
M.DESC_SCROLL_DOWN = "Scroll preview down"
M.DESC_SCROLL_UP = "Scroll preview up"
M.DESC_QUIT = "Quit review"
M.DESC_DONE = "Accept file and continue"

--- Convert raw lhs (leader-expanded) back to <leader>X display form
---@param lhs string Raw lhs from nvim_buf_get_keymap (leader already expanded)
---@return string Formatted display string
function M.format_key_display(lhs)
	local leader = vim.g.mapleader
	if leader == nil then
		leader = "\\"
	end
	-- Normalise: nvim_buf_get_keymap returns lhs with leader expanded.
	-- A space leader is stored as " ", other leaders as their literal char.
	if type(leader) == "string" and #leader > 0 then
		-- Check if lhs starts with the expanded leader
		if lhs:sub(1, #leader) == leader then
			return "<leader>" .. lhs:sub(#leader + 1)
		end
	end
	return lhs
end

--- Look up the key bound to a given desc on a buffer
---@param bufnr integer Buffer number to query
---@param desc string The desc field to match
---@return string|nil Formatted key display, or nil if not found
function M.get_key_for_desc(bufnr, desc)
	local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
	for _, map in ipairs(maps) do
		if map.desc == desc then
			return M.format_key_display(map.lhs)
		end
	end
	return nil
end

--- Look up key with a fallback for robustness
---@param bufnr integer Buffer number
---@param desc string The desc field to match
---@param fallback string Fallback display string
---@return string Key display string
function M.get_key_or_fallback(bufnr, desc, fallback)
	return M.get_key_for_desc(bufnr, desc) or fallback
end

return M
