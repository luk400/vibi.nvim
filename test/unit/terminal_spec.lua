-- test/unit/terminal_spec.lua
local terminal = require("vibe.terminal")
local git = require("vibe.git")
local config = require("vibe.config")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal
local is_true = assert.is_true

describe("Terminal Session Management", function()
	before_each(function()
		config.setup({
			command = vim.fn.has("win32") == 1 and "ping 127.0.0.1 -n 10" or "sleep 10",
			on_open = "none",
		})
		for name, _ in pairs(terminal.sessions) do
			terminal.kill(name)
		end
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
	end)

	after_each(function()
		helpers.cleanup_all()
	end)

	it("creates a new terminal session with a valid buffer and job", function()
		local repo_path = helpers.create_test_repo("term-create")
		local session = terminal.get_or_create("ai-agent", repo_path)

		assert.is_not_nil(session)
		eq("ai-agent", session.name)
		is_true(vim.api.nvim_buf_is_valid(session.bufnr), "Terminal buffer should be valid")
		is_true(vim.fn.jobpid(session.job_id) > 0, "Job should be running")

		-- Internal tracker check
		assert.is_not_nil(terminal.sessions["ai-agent"])
	end)

	it("kills a session and cleans up its resources", function()
		local repo_path = helpers.create_test_repo("term-kill")
		local session = terminal.get_or_create("kill-agent", repo_path)

		local bufnr = session.bufnr
		local wt_path = session.worktree_path

		terminal.kill("kill-agent")

		assert.is_nil(terminal.sessions["kill-agent"], "Session should be removed from tracking")
		is_true(vim.fn.isdirectory(wt_path) == 0, "Worktree should be deleted on kill")
		is_true(not vim.api.nvim_buf_is_valid(bufnr), "Buffer should be deleted")
	end)

	it("toggles window visibility", function()
		local repo_path = helpers.create_test_repo("term-toggle")
		terminal.toggle("toggle-agent", repo_path)

		local session = terminal.sessions["toggle-agent"]
		is_true(session.winid ~= nil and vim.api.nvim_win_is_valid(session.winid), "Window should be open")

		terminal.toggle("toggle-agent")
		is_true(session.winid == nil, "Window should be closed")
	end)
end)
