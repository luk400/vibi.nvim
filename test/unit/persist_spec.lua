-- test/unit/persist_spec.lua
local persist = require("vibe.persist")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal
local is_not_nil = assert.is_not_nil

describe("Session Persistence", function()
	local cache_dir = vim.fn.stdpath("cache") .. "/vibe-worktrees"

	before_each(function()
		-- Wipe the real cache directory for clean persist tests
		if vim.fn.isdirectory(cache_dir) == 1 then
			vim.fn.delete(cache_dir, "rf")
		end
		vim.fn.mkdir(cache_dir, "p")
	end)

	it("saves and loads a session", function()
		local mock_session = {
			name = "dummy-session",
			worktree_path = cache_dir .. "/dummy-wt",
			branch = "vibe-dummy",
			snapshot_commit = "abcdef",
			original_branch = "main",
			repo_root = "/path/to/repo",
			cwd = "/path/to/repo",
			created_at = os.time(),
			has_terminal = true,
		}

		persist.save_session(mock_session)
		local loaded = persist.load_sessions()

		eq(1, #loaded)
		eq("dummy-session", loaded[1].name)
		eq(mock_session.snapshot_commit, loaded[1].snapshot_commit)
	end)

	it("filters out invalid persisted sessions on cleanup", function()
		local valid_wt = cache_dir .. "/valid-wt"
		local invalid_wt = cache_dir .. "/invalid-wt"

		vim.fn.mkdir(valid_wt, "p") -- Create physical dir for valid

		persist.save_session({ name = "valid", worktree_path = valid_wt })
		persist.save_session({ name = "invalid", worktree_path = invalid_wt })

		local before_cleanup = persist.load_sessions()
		eq(2, #before_cleanup)

		persist.cleanup_invalid_sessions()

		local after_cleanup = persist.load_sessions()
		eq(1, #after_cleanup)
		eq("valid", after_cleanup[1].name)
	end)
end)
