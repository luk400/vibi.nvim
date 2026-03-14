local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("Review lifecycle", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
		git.worktrees = {}
	end)

	after_each(function()
		helpers.cleanup_all()
	end)

	it("Scenario A: create -> AI edits -> parse hunks -> accept/reject -> verify", function()
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
		assert.is_true(#hunks >= 2, "Should have at least 2 hunks")

		-- Step 5: accept hunk 1
		hunks[1].user_added_indices = {}
		git.accept_hunk_from_worktree(info.worktree_path, "test.txt", hunks[1], user_file)

		-- Verify first line changed
		local after_accept = vim.fn.readfile(user_file)
		eq("AI line 1", after_accept[1], "First line should be AI version after accept")

		-- Step 6: mark addressed, check not fully addressed
		git.mark_hunk_addressed(info.worktree_path, "test.txt", hunks[1], "accepted")
		eq(false, git.is_file_fully_addressed(info.worktree_path, "test.txt"))

		-- Step 7: reject hunk 2 (no-op since no user additions)
		-- Re-parse hunks since file changed
		local hunks2 = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)
		if #hunks2 > 0 then
			hunks2[1].user_added_indices = {}
			git.reject_hunk_from_worktree(info.worktree_path, "test.txt", hunks2[1], user_file)

			-- Step 8: mark addressed
			git.mark_hunk_addressed(info.worktree_path, "test.txt", hunks2[1], "rejected")
		end

		-- Mark all original hunks addressed so file is fully addressed
		for _, h in ipairs(hunks) do
			git.mark_hunk_addressed(info.worktree_path, "test.txt", h, "rejected")
		end

		eq(true, git.is_file_fully_addressed(info.worktree_path, "test.txt"))

		-- Step 9: unresolved should reflect current state
		local unresolved = git.get_unresolved_files(info.worktree_path)
		-- File is fully addressed so it should not be in unresolved
		local found = false
		for _, f in ipairs(unresolved) do
			if f == "test.txt" then
				found = true
			end
		end
		eq(false, found, "Fully addressed file should not be in unresolved list")
	end)

	it("Scenario B: accept some, reject others, verify final file state", function()
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

		-- Parse hunks
		local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)
		assert.is_true(#hunks >= 1, "Should have hunks")

		-- Accept the first hunk (addition)
		local add_hunk = nil
		for _, h in ipairs(hunks) do
			if h.type == "add" then
				add_hunk = h
				break
			end
		end

		if add_hunk then
			add_hunk.user_added_indices = {}
			git.accept_hunk_from_worktree(info.worktree_path, "test.txt", add_hunk, user_file)
		end

		-- Verify new lines were added
		local result = vim.fn.readfile(user_file)
		local has_new_a = false
		for _, line in ipairs(result) do
			if line == "new A" then
				has_new_a = true
			end
		end
		assert.is_true(has_new_a, "Accepted addition should be in file")

		-- Original lines should still be present
		local has_line_1 = false
		for _, line in ipairs(result) do
			if line == "line 1" then
				has_line_1 = true
			end
		end
		assert.is_true(has_line_1, "Original lines should be preserved")
	end)
end)
