local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("Review lifecycle", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
	end)

	after_each(function()
		helpers.cleanup_all()
	end)

	it("Scenario A: create -> AI edits -> detect changes -> accept file -> verify", function()
		local repo_path = helpers.create_test_repo("lifecycle-a", {
			["test.txt"] = "line 1\nline 2\nline 3\nline 4\nline 5",
		})
		local info = git.create_worktree("lifecycle-a-sess", repo_path)
		assert.is_not_nil(info)

		local user_file = info.repo_root .. "/test.txt"

		-- AI modifies lines 1 and 5
		helpers.write_file(info.worktree_path .. "/test.txt", "AI line 1\nline 2\nline 3\nline 4\nAI line 5")

		-- Step 3: detect changed files
		local changed = git.get_worktree_changed_files(info.worktree_path)
		assert.is_true(#changed >= 1, "Should detect changed file")

		-- Step 4: parse hunks
		local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)
		assert.is_true(#hunks >= 1, "Should have at least 1 hunk")

		-- Step 5: accept file using file-level accept
		local ok = git.accept_file_from_worktree(info.worktree_path, "test.txt")
		assert.is_truthy(ok)

		-- Verify changes were accepted
		local after_accept = vim.fn.readfile(user_file)
		eq("AI line 1", after_accept[1], "First line should be AI version after accept")
		eq("AI line 5", after_accept[5], "Last line should be AI version after accept")

		-- Step 6: mark all hunks addressed
		for _, h in ipairs(hunks) do
			git.mark_hunk_addressed(info.worktree_path, "test.txt", h, "accepted")
		end

		eq(true, git.is_file_fully_addressed(info.worktree_path, "test.txt"))

		-- Step 7: unresolved should be empty
		local unresolved = git.get_unresolved_files(info.worktree_path)
		local found = false
		for _, f in ipairs(unresolved) do
			if f == "test.txt" then
				found = true
			end
		end
		eq(false, found, "Fully addressed file should not be in unresolved list")
	end)

	it("Scenario B: apply classified resolution preserves correct state", function()
		local repo_path = helpers.create_test_repo("lifecycle-b", {
			["test.txt"] = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10",
		})
		local info = git.create_worktree("lifecycle-b-sess", repo_path)
		assert.is_not_nil(info)

		local user_file = info.repo_root .. "/test.txt"

		-- AI: add 2 lines after line 3, change line 9
		helpers.write_file(
			info.worktree_path .. "/test.txt",
			"line 1\nline 2\nline 3\nnew A\nnew B\nline 4\nline 5\nline 6\nline 7\nline 8\nAI line 9\nline 10"
		)

		-- Apply a classified resolution (simulating user accepted AI's additions but kept their line 9)
		local resolved_lines = {
			"line 1", "line 2", "line 3", "new A", "new B",
			"line 4", "line 5", "line 6", "line 7", "line 8",
			"line 9", "line 10",
		}
		local ok = git.apply_classified_resolution(info.worktree_path, "test.txt", resolved_lines, user_file)
		assert.is_truthy(ok)

		-- Verify the resolved state
		local result = vim.fn.readfile(user_file)
		local has_new_a = false
		for _, line in ipairs(result) do
			if line == "new A" then
				has_new_a = true
			end
		end
		assert.is_true(has_new_a, "Accepted addition should be in file")

		-- Original line 9 should be preserved (user rejected AI's change to line 9)
		local has_original_line9 = false
		for _, line in ipairs(result) do
			if line == "line 9" then
				has_original_line9 = true
			end
		end
		assert.is_true(has_original_line9, "Rejected change should preserve original")
	end)
end)
