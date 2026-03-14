local config = require("vibe.config")
local util = require("vibe.util")

local M = {}

local function get_context()
	local bufnr = vim.api.nvim_get_current_buf()
	local ft = vim.bo[bufnr].filetype

	if ft == "vibe" then
		return "terminal"
	end

	local collapsed = require("vibe.collapsed_conflict")
	if collapsed.buffer_state[bufnr] then
		return "conflict"
	end

	local conflict_buf = require("vibe.conflict_buffer")
	if conflict_buf.buffer_state[bufnr] then
		return "conflict_raw"
	end

	local diff = require("vibe.diff")
	if diff.buffer_hunks[bufnr] then
		return "diff"
	end

	if ft == "vibe_dialog" then
		return "dialog"
	end

	return "normal"
end

local function get_help_lines(context)
	local km = config.options.diff.keymaps
	local cb_km = config.options.diff.conflict_buffer and config.options.diff.conflict_buffer.keymaps or {}
	local cp_km = config.options.diff.conflict_popup.keymaps

	local lines = { " Vibe Help", " " .. string.rep("─", 50), "" }

	if context == "terminal" then
		table.insert(lines, " Terminal Mode:")
		table.insert(lines, "  <Esc><Esc>    Exit terminal mode")
		table.insert(lines, "  <C-n>         Next session")
		table.insert(lines, "  <C-p>         Previous session")
		table.insert(lines, "  q / <Esc>     Close window (normal mode)")
		table.insert(lines, "  <M-h/j/k/l>  Navigate windows")
	elseif context == "conflict" then
		table.insert(lines, " Collapsed Conflict Mode:")
		table.insert(lines, string.format("  %-14s Keep yours", cb_km.keep_ours or "<leader>du"))
		table.insert(lines, string.format("  %-14s Keep AI's", cb_km.keep_theirs or "<leader>da"))
		table.insert(lines, string.format("  %-14s Keep both", cb_km.keep_both or "<leader>db"))
		table.insert(lines, string.format("  %-14s Keep none", cb_km.keep_none or "<leader>dn"))
		table.insert(lines, string.format("  %-14s Accept all", cb_km.accept_all or "<leader>dA"))
		table.insert(lines, string.format("  %-14s Next conflict", cb_km.next_conflict or "]c"))
		table.insert(lines, string.format("  %-14s Prev conflict", cb_km.prev_conflict or "[c"))
		table.insert(lines, "")
		table.insert(lines, " Preview Popup (hover over conflict):")
		table.insert(lines, string.format("  %s  yours  %s  AI  %s  both  %s  none",
			cp_km.accept_user, cp_km.accept_ai, cp_km.accept_both, cp_km.accept_none))
	elseif context == "conflict_raw" then
		table.insert(lines, " Raw Conflict Mode:")
		table.insert(lines, string.format("  %-14s Keep yours", cb_km.keep_ours or "<leader>du"))
		table.insert(lines, string.format("  %-14s Keep AI's", cb_km.keep_theirs or "<leader>da"))
		table.insert(lines, string.format("  %-14s Keep both", cb_km.keep_both or "<leader>db"))
		table.insert(lines, string.format("  %-14s Keep none", cb_km.keep_none or "<leader>dn"))
		table.insert(lines, string.format("  %-14s Accept all", cb_km.accept_all or "<leader>dA"))
		table.insert(lines, string.format("  %-14s Next conflict", cb_km.next_conflict or "]c"))
		table.insert(lines, string.format("  %-14s Prev conflict", cb_km.prev_conflict or "[c"))
	elseif context == "diff" then
		table.insert(lines, " Diff Mode:")
		table.insert(lines, string.format("  %-14s Accept hunk", km.accept_hunk))
		table.insert(lines, string.format("  %-14s Reject hunk", km.reject_hunk))
		table.insert(lines, string.format("  %-14s Accept all", km.accept_all))
		table.insert(lines, string.format("  %-14s Reject all", km.reject_all))
		table.insert(lines, string.format("  %-14s Prev hunk", km.prev_hunk))
		table.insert(lines, string.format("  %-14s Next hunk", km.next_hunk))
		table.insert(lines, "  q              Back to file list")
	elseif context == "dialog" then
		table.insert(lines, " File Dialog:")
		table.insert(lines, "  <CR>          View file")
		table.insert(lines, "  A             Accept all changes")
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
