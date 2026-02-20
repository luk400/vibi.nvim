local config = require("vibe.config")

local M = {}

---@param position string
---@return integer row, integer col, integer width, integer height
local function calculate_dimensions(position)
	local opts = config.options
	local total_width = vim.o.columns
	local total_height = vim.o.lines - vim.o.cmdheight - 2

	local width = math.floor(total_width * opts.width)
	local height = math.floor(total_height * opts.height)
	local row, col = 0, 0

	if position == "right" then
		height = total_height
		col = total_width - width
	elseif position == "left" then
		height = total_height
	elseif position == "top" then
		width = total_width
	elseif position == "bottom" then
		width = total_width
		row = total_height - height
	else -- centered
		row = math.floor((total_height - height) / 2)
		col = math.floor((total_width - width) / 2)
	end

	return row, col, width, height
end

---@param bufnr integer
---@return integer winid
function M.create(bufnr)
	local opts = config.options
	local row, col, width, height = calculate_dimensions(opts.position)

	local winid = vim.api.nvim_open_win(bufnr, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = opts.border,
		zindex = 50,
	})

	vim.wo[winid].winblend = 0
	vim.wo[winid].winhl = "Normal:Normal,FloatBorder:FloatBorder"

	local close_fn = function()
		require("vibe").toggle()
	end
	vim.keymap.set("n", "q", close_fn, { buffer = bufnr, silent = true, desc = "Close Vibe window" })
	vim.keymap.set("n", "<Esc>", close_fn, { buffer = bufnr, silent = true, desc = "Close Vibe window" })

	-- Terminal-mode keymaps
	vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-N>", { buffer = bufnr, silent = true, desc = "Exit terminal mode" })
	vim.keymap.set("t", "<M-h>", "<C-\\><C-N><C-w>h", { buffer = bufnr, silent = true, desc = "Go to left window" })
	vim.keymap.set("t", "<M-j>", "<C-\\><C-N><C-w>j", { buffer = bufnr, silent = true, desc = "Go to below window" })
	vim.keymap.set("t", "<M-k>", "<C-\\><C-N><C-w>k", { buffer = bufnr, silent = true, desc = "Go to above window" })
	vim.keymap.set("t", "<M-l>", "<C-\\><C-N><C-w>l", { buffer = bufnr, silent = true, desc = "Go to right window" })

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(winid),
		callback = function()
			require("vibe.terminal").on_window_closed()
		end,
		once = true,
	})

	return winid
end

return M
