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
---@param session_name string|nil
---@return integer winid
function M.create(bufnr, session_name)
	local opts = config.options
	local row, col, width, height = calculate_dimensions(opts.position)

	local win_config = {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = opts.border,
		zindex = 50,
	}

	if session_name then
		win_config.title = " Vibe: " .. session_name .. " "
		win_config.title_pos = "center"
	end

	local winid = vim.api.nvim_open_win(bufnr, true, win_config)

	vim.wo[winid].winblend = 0
	vim.wo[winid].winhl = "Normal:Normal,FloatBorder:FloatBorder"

	local close_fn = function()
		require("vibe").toggle(session_name)
	end
	vim.keymap.set("n", "q", close_fn, { buffer = bufnr, silent = true, desc = "Close Vibe window" })
	vim.keymap.set("n", "<Esc>", close_fn, { buffer = bufnr, silent = true, desc = "Close Vibe window" })

	local keymap = config.options.keymap
	if keymap then
		vim.keymap.set("n", keymap, close_fn, { buffer = bufnr, silent = true, desc = "Close Vibe window" })
	end

	-- Terminal-mode keymaps
	vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-N>", { buffer = bufnr, silent = true, desc = "Exit terminal mode" })
	vim.keymap.set("t", "<M-h>", "<C-\\><C-N><C-w>h", { buffer = bufnr, silent = true, desc = "Go to left window" })
	vim.keymap.set("t", "<M-j>", "<C-\\><C-N><C-w>j", { buffer = bufnr, silent = true, desc = "Go to below window" })
	vim.keymap.set("t", "<M-k>", "<C-\\><C-N><C-w>k", { buffer = bufnr, silent = true, desc = "Go to above window" })
	vim.keymap.set("t", "<M-l>", "<C-\\><C-N><C-w>l", { buffer = bufnr, silent = true, desc = "Go to right window" })

	-- Session cycling keymaps
	local function cycle_session(direction)
		local term = require("vibe.terminal")
		local names = vim.tbl_keys(term.sessions)
		table.sort(names)
		if #names <= 1 then
			return
		end
		local current = term.current_session or session_name
		local current_idx = 1
		for i, n in ipairs(names) do
			if n == current then
				current_idx = i
				break
			end
		end
		local next_idx = current_idx + direction
		if next_idx > #names then
			next_idx = 1
		elseif next_idx < 1 then
			next_idx = #names
		end
		term.hide(current)
		term.show(names[next_idx])
	end

	vim.keymap.set("t", "<C-n>", function()
		cycle_session(1)
	end, { buffer = bufnr, silent = true, desc = "Next Vibe session" })
	vim.keymap.set("t", "<C-p>", function()
		cycle_session(-1)
	end, { buffer = bufnr, silent = true, desc = "Previous Vibe session" })

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
