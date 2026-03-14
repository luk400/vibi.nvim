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

		-- AI modifies two areas
		helpers.write_file(info.worktree_path .. "/test.txt", "AI line 1\nline 2\nline 3\nline 4\nAI line 5")

		-- Accept only the first hunk
		local hunks = git.get_worktree_file_hunks(worktree_path, "test.txt", user_file)
		assert.is_true(#hunks >= 1)

		hunks[1].user_added_indices = {}
		git.accept_hunk_from_worktree(worktree_path, "test.txt", hunks[1], user_file)

		-- Verify first change was accepted
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

		-- User file should only have the accepted change, not the second one
		local final = vim.fn.readfile(user_file)
		eq("AI line 1", final[1], "Accepted change should persist")
		-- The last line should still be original since we didn't accept the second hunk
		eq("line 5", final[#final], "Non-accepted change should not be in file")
	end)
end)
