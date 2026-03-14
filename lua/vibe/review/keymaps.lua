--- Unified keymap definitions for conflict resolution
local M = {}

--- Set up resolution keymaps on a buffer
---@param bufnr integer Buffer number
---@param handlers table Table of handler functions: keep_ours, keep_theirs, keep_both, keep_none, accept_all, next_conflict, prev_conflict, quit
function M.setup(bufnr, handlers)
	local opts = { buffer = bufnr, silent = true, noremap = true }

	-- Resolution keys (consistent across all views)
	vim.keymap.set("n", "u", handlers.keep_ours, vim.tbl_extend("force", opts, { desc = "Keep yours" }))
	vim.keymap.set("n", "a", handlers.keep_theirs, vim.tbl_extend("force", opts, { desc = "Keep AI's" }))
	vim.keymap.set("n", "b", handlers.keep_both, vim.tbl_extend("force", opts, { desc = "Keep both" }))
	vim.keymap.set("n", "n", handlers.keep_none, vim.tbl_extend("force", opts, { desc = "Keep none" }))

	-- Navigation
	vim.keymap.set("n", "]c", handlers.next_conflict, vim.tbl_extend("force", opts, { desc = "Next conflict" }))
	vim.keymap.set("n", "[c", handlers.prev_conflict, vim.tbl_extend("force", opts, { desc = "Previous conflict" }))

	-- Quit
	vim.keymap.set("n", "q", handlers.quit, vim.tbl_extend("force", opts, { desc = "Quit review" }))
	vim.keymap.set("n", "<Esc>", handlers.quit, vim.tbl_extend("force", opts, { desc = "Quit review" }))
end

--- Set up keymaps on a preview popup buffer
---@param preview_bufnr integer Preview buffer number
---@param handlers table Handler functions
function M.setup_preview(preview_bufnr, handlers)
	local opts = { buffer = preview_bufnr, silent = true, noremap = true }

	vim.keymap.set("n", "u", handlers.keep_ours, opts)
	vim.keymap.set("n", "a", handlers.keep_theirs, opts)
	vim.keymap.set("n", "b", handlers.keep_both, opts)
	vim.keymap.set("n", "n", handlers.keep_none, opts)
	vim.keymap.set("n", "q", handlers.close, opts)
	vim.keymap.set("n", "<Esc>", handlers.close, opts)
end

return M
