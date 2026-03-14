local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("Hunk operations", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
		git.worktrees = {}
	end)

	after_each(function()
		helpers.cleanup_all()
	end)

	--- Helper: create repo + worktree + AI edit, return info and paths
	local function setup_hunk_test(name, original_content, ai_content)
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

	it("accept_hunk type=add inserts lines", function()
		local info, user_file = setup_hunk_test(
			"accept-add",
			"line 1\nline 2\nline 3",
			"line 1\nline 2\nnew line\nline 3"
		)

		local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)
		assert.is_true(#hunks >= 1, "Should have at least 1 hunk")

		local add_hunk = nil
		for _, h in ipairs(hunks) do
			if h.type == "add" then
				add_hunk = h
				break
			end
		end
		assert.is_not_nil(add_hunk, "Should find an add hunk")

		add_hunk.user_added_indices = add_hunk.user_added_indices or {}
		local ok = git.accept_hunk_from_worktree(info.worktree_path, "test.txt", add_hunk, user_file)
		assert.is_truthy(ok)

		local result = vim.fn.readfile(user_file)
		local found = false
		for _, line in ipairs(result) do
			if line == "new line" then
				found = true
				break
			end
		end
		assert.is_true(found, "Accepted add hunk should insert 'new line' into user file")
	end)

	it("accept_hunk type=delete removes lines", function()
		local info, user_file = setup_hunk_test(
			"accept-del",
			"line 1\nline 2\nline 3",
			"line 1\nline 3"
		)

		local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)
		assert.is_true(#hunks >= 1)

		local del_hunk = nil
		for _, h in ipairs(hunks) do
			if h.type == "delete" then
				del_hunk = h
				break
			end
		end
		assert.is_not_nil(del_hunk, "Should find a delete hunk")

		del_hunk.user_added_indices = del_hunk.user_added_indices or {}
		local ok = git.accept_hunk_from_worktree(info.worktree_path, "test.txt", del_hunk, user_file)
		assert.is_truthy(ok)

		local result = vim.fn.readfile(user_file)
		for _, line in ipairs(result) do
			assert.are_not.equal("line 2", line, "Deleted line should not be in user file")
		end
	end)

	it("accept_hunk type=change replaces lines", function()
		local info, user_file = setup_hunk_test(
			"accept-change",
			"line 1\nline 2\nline 3",
			"line 1\nmodified line 2\nline 3"
		)

		local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)
		assert.is_true(#hunks >= 1)

		local change_hunk = nil
		for _, h in ipairs(hunks) do
			if h.type == "change" then
				change_hunk = h
				break
			end
		end
		assert.is_not_nil(change_hunk, "Should find a change hunk")

		change_hunk.user_added_indices = change_hunk.user_added_indices or {}
		local ok = git.accept_hunk_from_worktree(info.worktree_path, "test.txt", change_hunk, user_file)
		assert.is_truthy(ok)

		local result = vim.fn.readfile(user_file)
		local found = false
		for _, line in ipairs(result) do
			if line == "modified line 2" then
				found = true
				break
			end
		end
		assert.is_true(found, "Changed line should be in user file")
	end)

	it("reject_hunk with no user additions is no-op", function()
		local info, user_file = setup_hunk_test(
			"reject-noop",
			"line 1\nline 2\nline 3",
			"line 1\nmodified line 2\nline 3"
		)

		local original = vim.fn.readfile(user_file)

		local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)
		assert.is_true(#hunks >= 1)

		local hunk = hunks[1]
		hunk.user_added_indices = {}
		local ok = git.reject_hunk_from_worktree(info.worktree_path, "test.txt", hunk, user_file)
		assert.is_truthy(ok)

		local result = vim.fn.readfile(user_file)
		eq(#original, #result, "File should be unchanged after rejecting with no user additions")
		for i = 1, #original do
			eq(original[i], result[i], "Line " .. i .. " should be unchanged")
		end
	end)

	it("keep_both_hunk type=change keeps both", function()
		local info, user_file = setup_hunk_test(
			"keep-both",
			"line 1\nline 2\nline 3",
			"line 1\nAI line 2\nline 3"
		)

		local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)
		assert.is_true(#hunks >= 1)

		local hunk = hunks[1]
		hunk.user_added_indices = hunk.user_added_indices or {}
		local ok = git.keep_both_hunk(info.worktree_path, "test.txt", hunk, user_file)
		assert.is_truthy(ok)

		local result = vim.fn.readfile(user_file)
		local result_str = table.concat(result, "\n")
		assert.is_truthy(result_str:find("AI line 2", 1, true), "AI line should be present")
	end)

	it("delete_hunk_range removes the range", function()
		local info, user_file = setup_hunk_test(
			"delete-range",
			"line 1\nline 2\nline 3\nline 4\nline 5",
			"line 1\nline 2\nline 3\nline 4\nline 5"
		)

		local hunk = {
			old_start = 2,
			old_count = 2,
			user_added_indices = {},
		}

		local ok = git.delete_hunk_range(info.worktree_path, "test.txt", hunk, user_file)
		assert.is_truthy(ok)

		local result = vim.fn.readfile(user_file)
		eq(3, #result, "Should have 3 lines after deleting range of 2")
		eq("line 1", result[1])
		eq("line 4", result[2])
		eq("line 5", result[3])
	end)

	it("accept_hunk at start of file (old_start=0)", function()
		local info, user_file = setup_hunk_test(
			"accept-start",
			"line 1\nline 2",
			"prepended\nline 1\nline 2"
		)

		local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)
		assert.is_true(#hunks >= 1)

		local hunk = hunks[1]
		hunk.user_added_indices = hunk.user_added_indices or {}
		local ok = git.accept_hunk_from_worktree(info.worktree_path, "test.txt", hunk, user_file)
		assert.is_truthy(ok)

		local result = vim.fn.readfile(user_file)
		local result_str = table.concat(result, "\n")
		assert.is_truthy(result_str:find("prepended", 1, true), "Prepended line should be present")
	end)
end)
