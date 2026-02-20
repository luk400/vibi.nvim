-- test/minimal_init.lua
local cwd = vim.fn.getcwd()
vim.opt.rtp:prepend(cwd)

-- Resolve plenary.nvim
local plenary_paths = {
	"/workspace/plenary.nvim",
}
for _, path in ipairs(plenary_paths) do
	if vim.fn.isdirectory(path) == 1 then
		vim.opt.rtp:prepend(path)
		break
	end
end

-- Disable swap and undo for headless speed
vim.opt.swapfile = false
vim.opt.undofile = false

-- Mock Git user for consistent commits
vim.env.GIT_AUTHOR_NAME = "Vibe Test"
vim.env.GIT_AUTHOR_EMAIL = "test@vibe.test"
vim.env.GIT_COMMITTER_NAME = "Vibe Test"
vim.env.GIT_COMMITTER_EMAIL = "test@vibe.test"

-- Configure Vibe with test-safe settings
require("vibe.config").setup({
	-- Use a dummy command that won't exit immediately so we can test terminal states
	command = "sleep 10",
	quit_protection = false,
	on_open = "none",
	on_close = "none",
	diff = {
		enabled = true,
		poll_interval = 0, -- Disable async polling for tests
	},
})

-- Ensure test cache directory exists
vim.g.vibe_test_cache = vim.fn.tempname() .. "-vibe-test"
vim.fn.mkdir(vim.g.vibe_test_cache, "p")
