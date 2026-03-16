local config = require("vibe.config")
local util = require("vibe.util")

local M = {}

local function get_context()
	local bufnr = vim.api.nvim_get_current_buf()
	local ft = vim.bo[bufnr].filetype

	if ft == "vibe" then
		return "terminal"
	end

	local renderer = require("vibe.review.renderer")
	if renderer.buffer_state[bufnr] then
		return "review"
	end

	if ft == "vibe_dialog" then
		return "dialog"
	end

	return "normal"
end

local function get_help_lines(context)
	local lines = { " Vibe Help", " " .. string.rep("─", 50), "" }

	if context == "terminal" then
		table.insert(lines, " Terminal Mode:")
		table.insert(lines, "  <Esc><Esc>    Exit terminal mode")
		table.insert(lines, "  <C-n>         Next session")
		table.insert(lines, "  <C-p>         Previous session")
		table.insert(lines, "  q / <Esc>     Close window (normal mode)")
		table.insert(lines, "  <M-h/j/k/l>  Navigate windows")
	elseif context == "review" then
		table.insert(lines, " Review Mode:")
		table.insert(lines, "")
		table.insert(lines, " Suggestions (your change / AI suggestion / both agree):")
		table.insert(lines, "  a             Accept change")
		table.insert(lines, "  r             Reject change (keep base)")
		table.insert(lines, "")
		table.insert(lines, " Conflicts:")
		table.insert(lines, "  u             Keep your version")
		table.insert(lines, "  a             Keep AI version")
		table.insert(lines, "  e             Edit manually")
		table.insert(lines, "")
		table.insert(lines, " Navigation:")
		table.insert(lines, "  ]c            Next item")
		table.insert(lines, "  [c            Previous item")
		table.insert(lines, "  q/<Esc>       Quit review")
		table.insert(lines, "  :VibeAcceptAll  Accept all items")
	elseif context == "dialog" then
		table.insert(lines, " File Dialog:")
		table.insert(lines, "  <CR>          View file (granular review)")
		table.insert(lines, "  a             Accept file (use AI version)")
		table.insert(lines, "  r             Reject file (keep yours)")
		table.insert(lines, "  A             Accept all files")
		table.insert(lines, "  j/k           Navigate")
		table.insert(lines, "  q/<Esc>       Back to review list")
	else
		table.insert(lines, " Commands:")
		table.insert(lines, "  :Vibe [name]     Toggle terminal (smart)")
		table.insert(lines, "  :VibeList        List sessions")
		table.insert(lines, "  :VibeKill [name] Kill session")
		table.insert(lines, "  :VibeReview      Review AI changes")
		table.insert(lines, "  :VibeResume      Resume paused session")
		table.insert(lines, "  :VibeStatus      Show status summary")
		table.insert(lines, "  :VibeDiff        Diff current file")
		table.insert(lines, "  :VibeRename      Rename session")
		table.insert(lines, "  :VibeHistory     Session history")
		table.insert(lines, "  :VibeLog [name]  View terminal logs")
		table.insert(lines, "  :VibeHelp        This help")
		table.insert(lines, "")
		table.insert(lines, " Merge Modes (set via config or review picker):")
		table.insert(lines, "  none    Review everything")
		table.insert(lines, "  user    Auto-merge user changes (default)")
		table.insert(lines, "  ai      Auto-merge AI changes")
		table.insert(lines, "  both    Auto-merge all safe changes")
	end

	table.insert(lines, "")
	table.insert(lines, " q close")
	return lines
end

function M.show()
	local context = get_context()
	local lines = get_help_lines(context)

	local bufnr, _, _ = util.create_centered_float({
		lines = lines,
		filetype = "vibe_help",
		min_width = 60,
		title = "Vibe Help",
	})
	vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 0, 0, -1)
end

return M
