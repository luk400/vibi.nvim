--- Context-sensitive keymap definitions for classification-aware review
local types = require("vibe.review.types")

local M = {}

--- Set up classification-aware keymaps on a review buffer
---@param bufnr integer Buffer number
---@param handlers table Handler functions with get_item_at_cursor, resolve, navigate, quit
function M.setup(bufnr, handlers)
	local opts = { buffer = bufnr, silent = true, noremap = true }

	-- '<leader>a' key: accept suggestion OR keep AI version for conflicts
	vim.keymap.set("n", "<leader>a", function()
		local item = handlers.get_item_at_cursor()
		if not item then
			return
		end
		if item.classification == types.CONFLICT then
			handlers.resolve("keep_ai")
		else
			handlers.resolve("accept")
		end
	end, vim.tbl_extend("force", opts, { desc = "Accept / Keep AI" }))

	-- '<leader>r' key: reject suggestion (not valid for conflicts)
	vim.keymap.set("n", "<leader>r", function()
		local item = handlers.get_item_at_cursor()
		if not item then
			return
		end
		if item.classification == types.CONFLICT then
			vim.notify("[Vibe] Use <leader>u yours <leader>a AI <leader>e dit for conflicts", vim.log.levels.INFO)
		else
			handlers.resolve("reject")
		end
	end, vim.tbl_extend("force", opts, { desc = "Reject change" }))

	-- '<leader>u' key: keep user version (conflicts only)
	vim.keymap.set("n", "<leader>u", function()
		local item = handlers.get_item_at_cursor()
		if not item then
			return
		end
		if item.classification == types.CONFLICT then
			handlers.resolve("keep_user")
		else
			vim.notify("[Vibe] Use <leader>a accept <leader>r reject for suggestions", vim.log.levels.INFO)
		end
	end, vim.tbl_extend("force", opts, { desc = "Keep yours (conflicts)" }))

	-- '<leader>e' key: edit manually (conflicts only)
	vim.keymap.set("n", "<leader>e", function()
		local item = handlers.get_item_at_cursor()
		if not item then
			return
		end
		if item.classification == types.CONFLICT then
			handlers.resolve("edit_manually")
		else
			vim.notify("[Vibe] Edit is only available for conflicts", vim.log.levels.INFO)
		end
	end, vim.tbl_extend("force", opts, { desc = "Edit manually (conflicts)" }))

	-- Navigation
	vim.keymap.set("n", "]c", handlers.next_item, vim.tbl_extend("force", opts, { desc = "Next review item" }))
	vim.keymap.set("n", "[c", handlers.prev_item, vim.tbl_extend("force", opts, { desc = "Previous review item" }))

	-- Scroll preview window
	vim.keymap.set("n", "<C-d>", function()
		local renderer = require("vibe.review.renderer")
		if renderer.is_preview_visible() then
			vim.api.nvim_win_call(renderer.preview_winnr, function()
				vim.cmd("normal! \4") -- <C-d>
			end)
		end
	end, vim.tbl_extend("force", opts, { desc = "Scroll preview down" }))

	vim.keymap.set("n", "<C-u>", function()
		local renderer = require("vibe.review.renderer")
		if renderer.is_preview_visible() then
			vim.api.nvim_win_call(renderer.preview_winnr, function()
				vim.cmd("normal! \21") -- <C-u>
			end)
		end
	end, vim.tbl_extend("force", opts, { desc = "Scroll preview up" }))

	-- Quit
	vim.keymap.set("n", "q", handlers.quit, vim.tbl_extend("force", opts, { desc = "Quit review" }))
	vim.keymap.set("n", "<Esc>", handlers.quit, vim.tbl_extend("force", opts, { desc = "Quit review" }))
end

--- Set up keymaps on a preview popup buffer
---@param preview_bufnr integer Preview buffer number
---@param handlers table Handler functions
---@param classification string Classification of the item being previewed
function M.setup_preview(preview_bufnr, handlers, classification)
	local opts = { buffer = preview_bufnr, silent = true, noremap = true }

	if classification == types.CONFLICT then
		vim.keymap.set("n", "<leader>u", handlers.keep_user, opts)
		vim.keymap.set("n", "<leader>a", handlers.keep_ai, opts)
		vim.keymap.set("n", "<leader>e", handlers.edit_manually, opts)
	else
		vim.keymap.set("n", "<leader>a", handlers.accept, opts)
		vim.keymap.set("n", "<leader>r", handlers.reject, opts)
	end
	vim.keymap.set("n", "q", handlers.close, opts)
	vim.keymap.set("n", "<Esc>", handlers.close, opts)
end

return M
