local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("Multi-session concurrent worktrees", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
	end)

	after_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
		helpers.cleanup_all()
	end)

	it("two sessions from same repo work independently", function()
		local repo_path = helpers.create_test_repo("multi-sess", {
			["file-a.js"] = "original a",
			["file-b.js"] = "original b",
		})

		-- Create two worktrees
		local info_a = git.create_worktree("sess-A", repo_path)
		assert.is_not_nil(info_a)

		local info_b = git.create_worktree("sess-B", repo_path)
		assert.is_not_nil(info_b)

		-- AI modifies different files in each
		helpers.write_file(info_a.worktree_path .. "/file-a.js", "AI modified a")
		helpers.write_file(info_b.worktree_path .. "/file-b.js", "AI modified b")

		-- Both should show changes
		local changes_a = git.get_worktree_changed_files(info_a.worktree_path)
		local changes_b = git.get_worktree_changed_files(info_b.worktree_path)

		assert.is_true(#changes_a >= 1, "Session A should have changes")
		assert.is_true(#changes_b >= 1, "Session B should have changes")

		-- Accept all from session A
		git.accept_all_from_worktree(info_a.worktree_path)

		-- Remove session A
		git.remove_worktree(info_a.worktree_path)

		-- Session B should still be functional
		local b_info = git.worktrees[info_b.worktree_path]
		assert.is_not_nil(b_info, "Session B should still exist after removing session A")

		local b_changes = git.get_worktree_changed_files(info_b.worktree_path)
		assert.is_true(#b_changes >= 1, "Session B should still have its changes")

		-- Verify file-a.js was accepted in user repo
		local accepted = vim.fn.readfile(repo_path .. "/file-a.js")
		eq("AI modified a", table.concat(accepted, "\n"), "Accepted file should have AI content")
	end)
end)
