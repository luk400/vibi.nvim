local git = require("vibe.git")
local persist = require("vibe.persist")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("Kill unfinished session", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
		git.worktrees = {}
	end)

	after_each(function()
		helpers.cleanup_all()
	end)

	it("remove_worktree cleans up partially reviewed session", function()
		local repo_path = helpers.create_test_repo("kill-partial", {
			["test.txt"] = "line 1\nline 2\nline 3\nline 4\nline 5",
		})
		local info = git.create_worktree("kill-partial-sess", repo_path)
		assert.is_not_nil(info)

		local user_file = info.repo_root .. "/test.txt"
		local worktree_path = info.worktree_path

		-- AI modifies the file
		helpers.write_file(info.worktree_path .. "/test.txt", "AI line 1\nline 2\nline 3\nline 4\nAI line 5")

		-- Accept the file (simulating partial review by accepting entire file)
		git.accept_file_from_worktree(worktree_path, "test.txt")

		-- Verify change was accepted
		local after_accept = vim.fn.readfile(user_file)
		eq("AI line 1", after_accept[1], "First line should have accepted AI change")

		-- Remove the worktree (kill the session)
		local ok = git.remove_worktree(worktree_path)
		assert.is_truthy(ok)

		-- Verify worktree is gone
		eq(nil, git.worktrees[worktree_path], "Worktree should be removed from cache")
		eq(0, vim.fn.isdirectory(worktree_path), "Worktree directory should be deleted")

		-- Verify session removed from persistence
		local sessions = persist.load_sessions()
		for _, s in ipairs(sessions) do
			assert.are_not.equal(worktree_path, s.worktree_path, "Session should be removed from persistence")
		end
	end)
end)
