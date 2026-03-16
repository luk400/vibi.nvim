-- test/unit/hunk_operations_spec.lua
-- Tests for file-level operations and classified resolution through git re-exports
local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("File-level operations", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
		git.worktrees = {}
	end)

	after_each(function()
		helpers.cleanup_all()
	end)

	local function setup_test(name, original_content, ai_content)
		local repo_path = helpers.create_test_repo(name, {
			["test.txt"] = original_content,
		})
		local info, err = git.create_worktree(name, repo_path)
		assert.is_nil(err)
		assert.is_not_nil(info)

		helpers.write_file(info.worktree_path .. "/test.txt", ai_content)

		local user_file = info.repo_root .. "/test.txt"
		return info, user_file
	end

	it("accept_file_from_worktree copies AI file to user repo", function()
		local info, user_file = setup_test(
			"accept-file",
			"line 1\nline 2\nline 3",
			"line 1\nAI line 2\nline 3"
		)

		local ok = git.accept_file_from_worktree(info.worktree_path, "test.txt")
		assert.is_truthy(ok)

		local result = vim.fn.readfile(user_file)
		local found = false
		for _, line in ipairs(result) do
			if line == "AI line 2" then
				found = true
				break
			end
		end
		assert.is_true(found, "AI changes should be in user file after accept")
	end)

	it("apply_classified_resolution writes resolved content", function()
		local info, user_file = setup_test(
			"classify-resolve",
			"line 1\nline 2\nline 3",
			"line 1\nAI line 2\nline 3"
		)

		local resolved_lines = { "line 1", "manually resolved line 2", "line 3" }
		local ok = git.apply_classified_resolution(info.worktree_path, "test.txt", resolved_lines, user_file)
		assert.is_truthy(ok)

		local result = vim.fn.readfile(user_file)
		eq(3, #result)
		eq("manually resolved line 2", result[2])
	end)

	it("mark_hunk_addressed records the hunk", function()
		local info, _ = setup_test(
			"mark-hunk",
			"line 1\nline 2",
			"line 1\nAI line 2"
		)

		local hunk = {
			old_start = 2,
			old_count = 1,
			new_start = 2,
			new_count = 1,
			removed_lines = { "line 2" },
			added_lines = { "AI line 2" },
		}
		git.mark_hunk_addressed(info.worktree_path, "test.txt", hunk, "accepted")

		local wt_info = git.worktrees[info.worktree_path]
		assert.is_not_nil(wt_info.addressed_hunks)
		assert.is_true(#wt_info.addressed_hunks >= 1)
		eq("accepted", wt_info.addressed_hunks[1].action)
	end)

	it("sync_resolved_file copies user file back to worktree", function()
		local info, user_file = setup_test(
			"sync-resolve",
			"line 1\nline 2",
			"line 1\nAI line 2"
		)

		-- Manually change user file
		vim.fn.writefile({ "line 1", "user resolved" }, user_file)
		git.sync_resolved_file(info.worktree_path, "test.txt", user_file)

		local wt_file = vim.fn.readfile(info.worktree_path .. "/test.txt")
		eq("user resolved", wt_file[2])
	end)

	it("accept_all_from_worktree accepts all changed files", function()
		local repo_path = helpers.create_test_repo("accept-all", {
			["a.txt"] = "a content",
			["b.txt"] = "b content",
		})
		local info = git.create_worktree("accept-all", repo_path)
		assert.is_not_nil(info)

		helpers.write_file(info.worktree_path .. "/a.txt", "a modified")
		helpers.write_file(info.worktree_path .. "/b.txt", "b modified")

		local ok = git.accept_all_from_worktree(info.worktree_path)
		assert.is_truthy(ok)

		eq("a modified", vim.fn.readfile(info.repo_root .. "/a.txt")[1])
		eq("b modified", vim.fn.readfile(info.repo_root .. "/b.txt")[1])
	end)
end)
